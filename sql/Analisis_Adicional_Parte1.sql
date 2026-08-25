-- ==============================================================================
-- PARTE 1: Participacion de origen de ventas (Dentro/Fuera de base)
-- Optimizaciones:
--   1. Ventas deduplicadas por NUMERO DE VENTA (1 fila por cliente unico)
--   2. Indice en base y ventas para JOIN rapido
-- ==============================================================================

-- Evitar bloqueos y deadlocks en tablas productivas al realizar lecturas masivas
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- Paso 1: Base P21 de Agosto (una fila por telefono unico)
DROP TEMPORARY TABLE IF EXISTS tmp_base_p21;
CREATE TEMPORARY TABLE tmp_base_p21 AS
SELECT
    phone AS Celular1,
    MAX(numero_identificacion) AS NumeroIdentificacion,
    MAX(id_asignacion) AS id_asignacion
FROM bbdd_cs_bog_tmk.tb_bd_gestion_asignacion_phone_dts
WHERE periodo = 202608
  AND nombre_campana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
  AND LENGTH(phone) = 10
  AND id_asignacion NOT IN (
      SELECT idasignacion FROM bbdd_cs_bog_tmk.tb_asignacion_claro_tmk 
      WHERE periodo = '202608' 
        AND nombrecampana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
        AND TRIM(UPPER(ciudad)) IN ('DOSQUEBRADAS', 'LA DORADA', 'PEREIRA', 'SANTA ROSA DE CABAL')
  )
GROUP BY phone;

ALTER TABLE tmp_base_p21 ADD PRIMARY KEY (Celular1);

-- Copia de solo los telefonos (para evitar error 1137 'Can\'t reopen temp table')
DROP TEMPORARY TABLE IF EXISTS tmp_base_p21_phones;
CREATE TEMPORARY TABLE tmp_base_p21_phones AS SELECT Celular1 FROM tmp_base_p21;
ALTER TABLE tmp_base_p21_phones ADD PRIMARY KEY (Celular1);

-- Copia completa para la segunda parte del UNION ALL
DROP TEMPORARY TABLE IF EXISTS tmp_base_p21_2;
CREATE TEMPORARY TABLE tmp_base_p21_2 AS SELECT * FROM tmp_base_p21;
ALTER TABLE tmp_base_p21_2 ADD PRIMARY KEY (Celular1);

-- Paso 2: Ventas de Agosto - cruce por TELEFONO y por CEDULA (sin doble conteo)
DROP TEMPORARY TABLE IF EXISTS tmp_ventas_p1;
CREATE TEMPORARY TABLE tmp_ventas_p1 AS
SELECT celular_base, MAX(ptar) AS canal
FROM (
    -- Match 1: por numero de telefono
    SELECT b.Celular1 AS celular_base, v.ptar
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
    INNER JOIN tmp_base_p21 b ON v.`NUMERO DE VENTA` = b.Celular1
    WHERE v.`FECHA DE VENTA` >= '2026-08-01'
      AND v.`FECHA DE VENTA` <= '2026-08-31'
      AND v.`ESTADO FINAL` = 'INSTALADO'

    UNION ALL

    -- Match 2: por cedula_cliente, solo si el telefono de la venta NO esta en la base
    SELECT b.Celular1 AS celular_base, v.ptar
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
    INNER JOIN tmp_base_p21_2      b  ON v.cedula_cliente  = b.NumeroIdentificacion
    LEFT  JOIN tmp_base_p21_phones bp ON v.`NUMERO DE VENTA` = bp.Celular1
    WHERE v.`FECHA DE VENTA` >= '2026-08-01'
      AND v.`FECHA DE VENTA` <= '2026-08-31'
      AND v.`ESTADO FINAL` = 'INSTALADO'
      AND bp.Celular1 IS NULL
) combined
GROUP BY celular_base;

ALTER TABLE tmp_ventas_p1 ADD PRIMARY KEY (celular_base);

-- Resultado: Clientes unicos por canal, con % dentro/fuera de base
SELECT
    'CROSSELLING_HOGAR_P21'                                                  AS Nombre_Campana,
    v.canal                                                                   AS Canal_PTAR,
    COUNT(*)                                                                  AS Total_Ventas,
    COUNT(b.Celular1)                                                         AS Dentro_Base,
    ROUND(COUNT(b.Celular1) * 100.0 / COUNT(*), 2)                           AS Porcentaje_DB,
    COUNT(*) - COUNT(b.Celular1)                                              AS Fuera_Base,
    ROUND((COUNT(*) - COUNT(b.Celular1)) * 100.0 / COUNT(*), 2)              AS Porcentaje_FB
FROM tmp_ventas_p1 v
LEFT JOIN tmp_base_p21 b ON v.celular_base = b.Celular1
GROUP BY v.canal
ORDER BY Dentro_Base DESC;

DROP TEMPORARY TABLE IF EXISTS tmp_base_p21;
DROP TEMPORARY TABLE IF EXISTS tmp_ventas_p1;
