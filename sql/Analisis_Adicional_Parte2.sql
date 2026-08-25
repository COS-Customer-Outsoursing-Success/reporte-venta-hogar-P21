-- ==============================================================================
-- PARTE 2: Detalle de tipificacion - ultima llamada por registro
-- Optimizaciones:
--   1. Materializar marcaciones filtradas ANTES del ROW_NUMBER (evita doble scan)
--   2. PRIMARY KEY en temp tables para JOINs O(1)
--   3. Ventas deduplicadas por telefono unico
-- ==============================================================================

-- Evitar bloqueos y deadlocks en tablas productivas al realizar lecturas masivas
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- Paso 1: Materializar las marcaciones de Agosto-HOGAR ANTES del ROW_NUMBER
--         (MySQL escanea la tabla grande solo 1 vez en vez de 2)
DROP TEMPORARY TABLE IF EXISTS tmp_marc_agosto;
CREATE TEMPORARY TABLE tmp_marc_agosto AS
SELECT
    phone_number_dialed,
    status,
    gestionado,
    contacto,
    contacto_efectivo,
    prioridad,
    call_date
FROM bbdd_cs_bog_tmk.tb_marcaciones_desgloce_dts
WHERE periodo = 202608
  AND campana = 'HOGAR';

ALTER TABLE tmp_marc_agosto ADD INDEX idx_tel (phone_number_dialed);

-- Paso 2: Total de intentos por telefono (sobre la tabla ya materializada)
DROP TEMPORARY TABLE IF EXISTS tmp_intentos;
CREATE TEMPORARY TABLE tmp_intentos AS
SELECT phone_number_dialed, COUNT(*) AS intentos
FROM tmp_marc_agosto
GROUP BY phone_number_dialed;

ALTER TABLE tmp_intentos ADD PRIMARY KEY (phone_number_dialed);

-- Paso 3a: Obtener tipificación ganadora en orden de prioridad
DROP TEMPORARY TABLE IF EXISTS tmp_status_ganador;
CREATE TEMPORARY TABLE tmp_status_ganador AS
SELECT phone_number_dialed, status
FROM (
    SELECT
        phone_number_dialed, status,
        ROW_NUMBER() OVER(PARTITION BY phone_number_dialed
                          ORDER BY prioridad ASC, call_date DESC) AS fila
    FROM tmp_marc_agosto
) sub
WHERE fila = 1;

ALTER TABLE tmp_status_ganador ADD PRIMARY KEY (phone_number_dialed);

-- Paso 3b: Agregación de marcaciones por MAX() con la tipificación ganadora
DROP TEMPORARY TABLE IF EXISTS tmp_ultima;
CREATE TEMPORARY TABLE tmp_ultima AS
SELECT 
    m.phone_number_dialed,
    s.status,
    MAX(m.gestionado) AS gestionado,
    MAX(m.contacto) AS contacto,
    MAX(m.contacto_efectivo) AS contacto_efectivo
FROM tmp_marc_agosto m
LEFT JOIN tmp_status_ganador s ON m.phone_number_dialed = s.phone_number_dialed
GROUP BY m.phone_number_dialed, s.status;

ALTER TABLE tmp_ultima ADD PRIMARY KEY (phone_number_dialed);

-- Paso 4: Arbol de tipificaciones
DROP TEMPORARY TABLE IF EXISTS tmp_arbol;
CREATE TEMPORARY TABLE tmp_arbol AS
SELECT STATUS, MAX(CONCATENADO) AS CONCATENADO
FROM (
    SELECT STATUS, CONCATENADO FROM bbdd_cs_bog_tmk.tb_arbol_tmk_bogota
    UNION ALL
    SELECT STATUS, CONCATENADO FROM bbdd_cs_bog_tmk.tb_arbol_tmk_bogota_rp_v2
) t_arbol
GROUP BY STATUS;

-- Paso 5: Ventas de Agosto - cruce por TELEFONO y por CEDULA (sin doble conteo)
DROP TEMPORARY TABLE IF EXISTS tmp_ventas_tel;
CREATE TEMPORARY TABLE tmp_ventas_tel AS
SELECT celular_base
FROM (
    -- Match 1: por numero de telefono
    SELECT b.phone AS celular_base
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
    INNER JOIN bbdd_cs_bog_tmk.tb_bd_gestion_asignacion_phone_dts b
        ON v.`NUMERO DE VENTA` = b.phone
    WHERE v.`FECHA DE VENTA` >= '2026-08-01'
      AND v.`FECHA DE VENTA` <= '2026-08-31'
      AND v.`ESTADO FINAL` = 'INSTALADO'
      AND b.periodo = 202608
      AND b.nombre_campana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
      AND LENGTH(b.phone) = 10

    UNION ALL

    -- Match 2: por cedula_cliente, solo si el telefono de la venta NO esta en la base
    SELECT b.phone AS celular_base
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
    INNER JOIN bbdd_cs_bog_tmk.tb_bd_gestion_asignacion_phone_dts b
        ON v.cedula_cliente = b.numero_identificacion
    LEFT JOIN bbdd_cs_bog_tmk.tb_bd_gestion_asignacion_phone_dts b2
        ON v.`NUMERO DE VENTA` = b2.phone AND b2.periodo = 202608
    WHERE v.`FECHA DE VENTA` >= '2026-08-01'
      AND v.`FECHA DE VENTA` <= '2026-08-31'
      AND v.`ESTADO FINAL` = 'INSTALADO'
      AND b.periodo = 202608
      AND b.nombre_campana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
      AND LENGTH(b.phone) = 10
      AND b2.phone IS NULL
) combined
GROUP BY celular_base;

ALTER TABLE tmp_ventas_tel ADD PRIMARY KEY (celular_base);

-- Resultado: 1 fila por tipificacion (ultima llamada).
-- La suma de Gestion = base gestionada total del dashboard.
SELECT
    COALESCE(c.CONCATENADO, 'Sin Tipificacion')                               AS Tipificacion_Alarma,
    COUNT(DISTINCT b.phone)                                                   AS Gestion,
    SUM(COALESCE(i.intentos, 0))                                               AS Intentos_Totales,
    ROUND(SUM(COALESCE(i.intentos, 0)) / NULLIF(COUNT(DISTINCT b.phone), 0), 2) AS Intentos_Por_Registro,
    SUM(COALESCE(u.contacto, 0))                                               AS Contactos,
    SUM(CASE WHEN v.celular_base IS NOT NULL THEN 1 ELSE 0 END)              AS Ventas,
    ROUND(
        SUM(CASE WHEN v.celular_base IS NOT NULL THEN 1 ELSE 0 END) * 100.0
        / NULLIF(COUNT(DISTINCT b.id_asignacion), 0), 2
    )                                                                          AS Efectividad_Porcentaje
FROM bbdd_cs_bog_tmk.tb_bd_gestion_asignacion_phone_dts b
INNER JOIN tmp_ultima u      ON b.phone = u.phone_number_dialed
LEFT  JOIN tmp_intentos i    ON b.phone = i.phone_number_dialed
LEFT  JOIN tmp_arbol c       ON u.status   = c.STATUS
LEFT  JOIN tmp_ventas_tel v  ON b.phone = v.celular_base
WHERE b.periodo = 202608
  AND b.nombre_campana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
  AND LENGTH(b.phone) = 10
  AND id_asignacion NOT IN (
      SELECT idasignacion FROM bbdd_cs_bog_tmk.tb_asignacion_claro_tmk 
      WHERE periodo = '202608' 
        AND nombrecampana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
        AND TRIM(UPPER(ciudad)) IN ('DOSQUEBRADAS', 'LA DORADA', 'PEREIRA', 'SANTA ROSA DE CABAL')
  )
GROUP BY c.CONCATENADO
ORDER BY Gestion DESC;

DROP TEMPORARY TABLE IF EXISTS tmp_marc_agosto;
DROP TEMPORARY TABLE IF EXISTS tmp_intentos;
DROP TEMPORARY TABLE IF EXISTS tmp_ultima;
DROP TEMPORARY TABLE IF EXISTS tmp_arbol;
DROP TEMPORARY TABLE IF EXISTS tmp_ventas_tel;
