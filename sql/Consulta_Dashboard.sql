-- ==============================================================================
-- CONSULTA PARA DASHBOARD HOGAR (VENTA CRUZADA)
-- Optimizada: Usa tablas temporales con PRIMARY KEY en vez de CTEs
-- Esto materializa cada paso y permite JOINs indexados en los pasos siguientes.
--
-- Para cambiar de mes:
--   1. Cambiar '202607' / 202607 al periodo deseado
--   2. Cambiar las fechas '2026-07-01' y '2026-07-31'
-- ==============================================================================

-- Evitar bloqueos y deadlocks en tablas productivas al realizar lecturas masivas
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- PASO 1: Base asignada P21 para el periodo
DROP TEMPORARY TABLE IF EXISTS tmp_base_hogar;
CREATE TEMPORARY TABLE tmp_base_hogar AS
SELECT
    telenum AS Celular1,
    MAX(numeroidentificacion) AS NumeroIdentificacion
FROM bbdd_cs_bog_tmk.tb_asignacion_hogar_p21
WHERE periodo = '202607'
  AND NombreCampaña = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
  AND LENGTH(telenum) = 10
GROUP BY telenum;

ALTER TABLE tmp_base_hogar ADD PRIMARY KEY (Celular1);

-- Copia de solo los telefonos (para evitar error 1137 'Can\'t reopen temp table')
DROP TEMPORARY TABLE IF EXISTS tmp_base_phones;
CREATE TEMPORARY TABLE tmp_base_phones AS SELECT Celular1 FROM tmp_base_hogar;
ALTER TABLE tmp_base_phones ADD PRIMARY KEY (Celular1);

-- Copia completa para la segunda parte del UNION ALL
DROP TEMPORARY TABLE IF EXISTS tmp_base_hogar_2;
CREATE TEMPORARY TABLE tmp_base_hogar_2 AS SELECT * FROM tmp_base_hogar;
ALTER TABLE tmp_base_hogar_2 ADD PRIMARY KEY (Celular1);

-- PASO 2a: Materializar marcaciones filtradas (evita escaneo doble de tabla grande)
DROP TEMPORARY TABLE IF EXISTS tmp_marc_filtradas;
CREATE TEMPORARY TABLE tmp_marc_filtradas AS
SELECT
    m.phone_number_dialed,
    m.status,
    m.gestionado,
    m.contacto,
    m.contacto_efectivo,
    m.prioridad,
    m.call_date
FROM bbdd_cs_bog_tmk.tb_marcaciones_desgloce_dts m
INNER JOIN tmp_base_hogar b ON m.phone_number_dialed = b.Celular1
WHERE m.periodo = 202607
  AND m.campana = 'HOGAR';

ALTER TABLE tmp_marc_filtradas ADD INDEX idx_tel (phone_number_dialed);

-- PASO 2b: Ultima llamada por telefono (ROW_NUMBER sobre tabla ya filtrada y pequeña)
DROP TEMPORARY TABLE IF EXISTS tmp_ultima_llamada;
CREATE TEMPORARY TABLE tmp_ultima_llamada AS
SELECT phone_number_dialed, status, gestionado, contacto, contacto_efectivo
FROM (
    SELECT
        phone_number_dialed, status, gestionado, contacto, contacto_efectivo,
        ROW_NUMBER() OVER(PARTITION BY phone_number_dialed
                          ORDER BY prioridad ASC, call_date DESC) AS fila
    FROM tmp_marc_filtradas
) sub
WHERE fila = 1;

ALTER TABLE tmp_ultima_llamada ADD PRIMARY KEY (phone_number_dialed);

-- PASO 3: Arbol de tipificaciones
DROP TEMPORARY TABLE IF EXISTS tmp_arbol_dash;
CREATE TEMPORARY TABLE tmp_arbol_dash AS
SELECT STATUS, MAX(CONCATENADO) AS CONCATENADO, MAX(TIPO_CONTACTO) AS TIPO_CONTACTO
FROM bbdd_cs_bog_tmk.tb_arbol_tmk_bogota_rp
GROUP BY STATUS;

-- PASO 4: Ventas cruzadas por TELEFONO y por CEDULA (sin doble conteo)
-- Logica:
--   Bloque 1: venta cuyo NUMERO DE VENTA coincide con Celular1 de la base
--   Bloque 2: venta cuya CEDULA coincide con NumeroIdentificacion de la base
--             PERO su NUMERO DE VENTA NO esta en la base (evita duplicados)
DROP TEMPORARY TABLE IF EXISTS tmp_ventas_claro;
CREATE TEMPORARY TABLE tmp_ventas_claro AS
SELECT celular_base, MAX(ptar) AS PTAR7, MAX(internet) AS internet, MAX(telefonia) AS telefonia, MAX(television) AS television
FROM (
    -- Match 1: por numero de telefono
    SELECT b.Celular1 AS celular_base, v.ptar, v.INTERNET AS internet, v.VOZ AS telefonia, v.TV AS television
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
    INNER JOIN tmp_base_hogar b ON v.`NUMERO DE VENTA` = b.Celular1
    WHERE v.`FECHA DE VENTA` >= '2026-07-01'
      AND v.`FECHA DE VENTA` <= '2026-07-31'

    UNION ALL

    -- Match 2: por cedula_cliente, solo ventas cuyo telefono NO esta ya en la base
    SELECT b.Celular1 AS celular_base, v.ptar, v.INTERNET, v.VOZ, v.TV
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
    INNER JOIN tmp_base_hogar_2  b  ON v.cedula_cliente   = b.NumeroIdentificacion
    LEFT  JOIN tmp_base_phones bp ON v.`NUMERO DE VENTA` = bp.Celular1
    WHERE v.`FECHA DE VENTA` >= '2026-07-01'
      AND v.`FECHA DE VENTA` <= '2026-07-31'
      AND bp.Celular1 IS NULL  -- excluir si ya lo encontro el bloque 1
) combined
GROUP BY celular_base;

ALTER TABLE tmp_ventas_claro ADD PRIMARY KEY (celular_base);

-- CONSULTA FINAL: Pivote de metricas
SELECT
    CAST(m.Metrica AS CHAR) AS Metrica,
    COALESCE(CAST(CASE m.id
        WHEN 1  THEN t.base_entregada
        WHEN 2  THEN t.base_gestionada
        WHEN 3  THEN t.base_contactada
        WHEN 4  THEN t.contactos_efectivos
        WHEN 5  THEN t.contactos_no_efectivos
        WHEN 6  THEN t.no_contactos
        WHEN 7  THEN t.ventas_hogares_5116
        WHEN 8  THEN t.ventas_servicios_5116
        WHEN 9  THEN t.ventas_hogares_5143
        WHEN 10 THEN t.ventas_servicios_5143
        WHEN 11 THEN t.ventas_hogares_otras_ptar
        WHEN 12 THEN t.ventas_servicios_otras_ptar
        WHEN 13 THEN t.venta_total
        WHEN 14 THEN t.no_venta_total
        WHEN 15 THEN t.nv_no_atractiva_general
        WHEN 16 THEN t.nv_precio
        WHEN 17 THEN t.nv_internet
        WHEN 18 THEN t.nv_tv
        WHEN 19 THEN t.nv_mala_experiencia
        WHEN 20 THEN t.nv_voz
        WHEN 21 THEN t.nv_no_volver_a_llamar
        WHEN 22 THEN t.nv_ya_tiene_servicio
        WHEN 23 THEN t.nv_permanencia_activa
        WHEN 24 THEN t.nv_no_apto_cartera
        WHEN 25 THEN t.nv_sin_cobertura
        WHEN 26 THEN t.nv_no_acepta_dth
        WHEN 27 THEN t.nv_cliente_mintic
        WHEN 28 THEN t.nv_cliente_corporativo
        WHEN 29 THEN t.nv_mejores_promociones
        WHEN 30 THEN t.nv_desconfia_tramites
        WHEN 31 THEN t.nv_cancelo_antes_90_dias
    END AS CHAR), '0') AS Valor
FROM (
    SELECT
        COUNT(DISTINCT b.Celular1)                                                                                        AS base_entregada,
        SUM(COALESCE(u.gestionado, 0))                                                                                    AS base_gestionada,
        SUM(COALESCE(u.contacto, 0))                                                                                      AS base_contactada,
        SUM(COALESCE(u.contacto_efectivo, 0))                                                                             AS contactos_efectivos,
        SUM(CASE WHEN COALESCE(u.contacto, 0) = 1 AND COALESCE(u.contacto_efectivo, 0) = 0 THEN 1 ELSE 0 END)            AS contactos_no_efectivos,
        SUM(CASE WHEN COALESCE(u.gestionado, 0) = 1 AND COALESCE(u.contacto, 0) = 0 THEN 1 ELSE 0 END)                   AS no_contactos,

        SUM(CASE WHEN d.PTAR7 IN ('5116','5116_F') AND d.internet = 1 THEN 1 ELSE 0 END)                                 AS ventas_hogares_5116,
        SUM(CASE WHEN d.PTAR7 IN ('5116','5116_F') THEN COALESCE(d.internet,0)+COALESCE(d.telefonia,0)+COALESCE(d.television,0) ELSE 0 END) AS ventas_servicios_5116,

        SUM(CASE WHEN d.PTAR7 IN ('5143','5143_F') AND d.internet = 1 THEN 1 ELSE 0 END)                                 AS ventas_hogares_5143,
        SUM(CASE WHEN d.PTAR7 IN ('5143','5143_F') THEN COALESCE(d.internet,0)+COALESCE(d.telefonia,0)+COALESCE(d.television,0) ELSE 0 END) AS ventas_servicios_5143,

        SUM(CASE WHEN (d.PTAR7 IS NULL OR d.PTAR7 NOT IN ('5116','5116_F','5143','5143_F')) AND d.celular_base IS NOT NULL AND d.internet = 1 THEN 1 ELSE 0 END) AS ventas_hogares_otras_ptar,
        SUM(CASE WHEN (d.PTAR7 IS NULL OR d.PTAR7 NOT IN ('5116','5116_F','5143','5143_F')) AND d.celular_base IS NOT NULL THEN COALESCE(d.internet,0)+COALESCE(d.telefonia,0)+COALESCE(d.television,0) ELSE 0 END) AS ventas_servicios_otras_ptar,

        SUM(CASE WHEN d.celular_base IS NOT NULL THEN 1 ELSE 0 END)                                                       AS venta_total,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%NO VENTA%' THEN 1 ELSE 0 END)           AS no_venta_total,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%NO VENTA-NO LE PARECE ATRACTIVA LA OFERTA%' THEN 1 ELSE 0 END)       AS nv_no_atractiva_general,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%NO VENTA-NO LE PARECE ATRACTIVA LA OFERTA-PRECIO%' THEN 1 ELSE 0 END) AS nv_precio,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND (c.CONCATENADO LIKE '%NO VENTA-NO LE PARECE ATRACTIVA LA OFERTA-INTERNET%' OR c.CONCATENADO LIKE '%NO VENTA-NO LE PARECE ATRACTIVA LA OFERTA-PRODUCTO%') THEN 1 ELSE 0 END) AS nv_internet,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%NO VENTA-NO LE PARECE ATRACTIVA LA OFERTA-TV%' THEN 1 ELSE 0 END)     AS nv_tv,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%MALA EXPERIENCIA%' THEN 1 ELSE 0 END)                                 AS nv_mala_experiencia,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%NO VENTA-NO LE PARECE ATRACTIVA LA OFERTA-VOZ%' THEN 1 ELSE 0 END)    AS nv_voz,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%CLIENTE PIDE NO VOLVER A LLAMAR%' THEN 1 ELSE 0 END)                   AS nv_no_volver_a_llamar,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%YA TIENE SERVICIO%' THEN 1 ELSE 0 END)                                AS nv_ya_tiene_servicio,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%PERMANENCIA ACTIVA%' THEN 1 ELSE 0 END)                               AS nv_permanencia_activa,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%CARTERA%' THEN 1 ELSE 0 END)                                          AS nv_no_apto_cartera,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%SIN COBERTURA%' THEN 1 ELSE 0 END)                                    AS nv_sin_cobertura,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%DTH%' THEN 1 ELSE 0 END)                                              AS nv_no_acepta_dth,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%MINTIC%' AND c.CONCATENADO LIKE '%NO VENTA%' THEN 1 ELSE 0 END)        AS nv_cliente_mintic,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%CORPORATIVO%' THEN 1 ELSE 0 END)                                      AS nv_cliente_corporativo,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%MEJORES PROMOCIONES%' THEN 1 ELSE 0 END)                              AS nv_mejores_promociones,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND c.CONCATENADO LIKE '%DESCONFIA%' THEN 1 ELSE 0 END)                                        AS nv_desconfia_tramites,
        SUM(CASE WHEN COALESCE(u.contacto_efectivo,0)=1 AND (c.CONCATENADO LIKE '%90 DIAS%' OR c.CONCATENADO LIKE '%90 DÍAS%') THEN 1 ELSE 0 END)       AS nv_cancelo_antes_90_dias

    FROM tmp_base_hogar b
    LEFT JOIN tmp_ultima_llamada u ON b.Celular1 = u.phone_number_dialed
    LEFT JOIN tmp_arbol_dash     c ON u.status   = c.STATUS
    LEFT JOIN tmp_ventas_claro   d ON b.Celular1 = d.celular_base
) AS t
CROSS JOIN (
    SELECT 1 AS id, 'Base Entregada' AS Metrica UNION ALL
    SELECT 2, 'Base Gestionada' UNION ALL
    SELECT 3, 'Base Contactada' UNION ALL
    SELECT 4, 'Contactos Efectivos' UNION ALL
    SELECT 5, 'Contactos No Efectivos' UNION ALL
    SELECT 6, 'No Contactos' UNION ALL
    SELECT 7, 'Ventas Hogares @ 5116' UNION ALL
    SELECT 8, 'Ventas Servicios @ 5116' UNION ALL
    SELECT 9, 'Ventas Hogares @ 5143' UNION ALL
    SELECT 10, 'Ventas Servicios @ 5143' UNION ALL
    SELECT 11, 'Ventas Hogares @ Otras Ptar' UNION ALL
    SELECT 12, 'Ventas Servicios @ Otras Ptar' UNION ALL
    SELECT 13, 'Venta' UNION ALL
    SELECT 14, 'No Venta' UNION ALL
    SELECT 15, 'No_Le_Parece_Atractiva_La_Oferta' UNION ALL
    SELECT 16, 'Precio' UNION ALL
    SELECT 17, 'Internet' UNION ALL
    SELECT 18, 'Tv' UNION ALL
    SELECT 19, 'Mala Experiencia Con Procesos De Claro' UNION ALL
    SELECT 20, 'Voz' UNION ALL
    SELECT 21, 'Cliente Pide No Volver A Llamar' UNION ALL
    SELECT 22, 'Ya Tiene Servicio En Misma Direccion A Nombre De Otra Persona' UNION ALL
    SELECT 23, 'Permanencia Activa Con Otro Operador' UNION ALL
    SELECT 24, 'No Apto Cartera' UNION ALL
    SELECT 25, 'Sin Cobertura' UNION ALL
    SELECT 26, 'No Acepta DTH' UNION ALL
    SELECT 27, 'Cliente Mintic' UNION ALL
    SELECT 28, 'Cliente Corporativo' UNION ALL
    SELECT 29, 'Mejores_Promociones' UNION ALL
    SELECT 30, 'Cliente Desconfia De Tramites Telefonicos' UNION ALL
    SELECT 31, 'Cliente Cancelo Antes De 90 Dias'
) AS m
ORDER BY m.id;

DROP TEMPORARY TABLE IF EXISTS tmp_base_hogar;
DROP TEMPORARY TABLE IF EXISTS tmp_marc_filtradas;
DROP TEMPORARY TABLE IF EXISTS tmp_ultima_llamada;
DROP TEMPORARY TABLE IF EXISTS tmp_arbol_dash;
DROP TEMPORARY TABLE IF EXISTS tmp_ventas_claro;
