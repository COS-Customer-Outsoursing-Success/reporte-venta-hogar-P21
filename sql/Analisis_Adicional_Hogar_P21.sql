-- ==============================================================================================
-- PARTE 1: PARTICIPACIÓN DE ORIGEN DE VENTAS (% VENTAS DENTRO Y FUERA DE BASE)
-- ==============================================================================================

-- 1. Crear temporal de ventas para Hogar
CREATE TEMPORARY TABLE tmp_ventas_hogar AS
SELECT 
    'CROSSELLING_HOGAR_P21' AS tipo_venta,
    v.`NUMERO DE VENTA` AS numero_venta,
    -- NOTA PARA CRUCE POR CÉDULA:
    -- Si necesitas cruzar por cédula, descomenta la línea de abajo y ajusta el nombre del campo:
    -- v.cedula_cliente AS documento_venta,
    v.ptar AS canal 
FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
WHERE v.fecha_venta >= '2026-07-01' 
  AND v.fecha_venta <= '2026-07-31';

-- 2. Crear temporal de asignación (Base P21)
CREATE TEMPORARY TABLE tmp_asignacion_hogar AS
SELECT DISTINCT Celular1 AS phone
    -- NOTA PARA CRUCE POR CÉDULA:
    -- Si necesitas cruzar por cédula, descomenta la línea de abajo y ajusta el nombre del campo:
    -- , Cedula AS documento_asignacion
FROM bbdd_cs_bog_tmk.tb_asignacion_hogar_p21
WHERE periodo = 202607; 

-- 3. Crear índices (optimizando para strings)
ALTER TABLE tmp_asignacion_hogar ADD INDEX idx_phone (phone(50));
ALTER TABLE tmp_ventas_hogar     ADD INDEX idx_numero (numero_venta(50));
ALTER TABLE tmp_ventas_hogar     ADD INDEX idx_canal (canal(50));

-- 4. Consulta final con la visualización desglosada
SELECT 
    v.tipo_venta                                                         AS "Nombre Campaña",
    v.canal                                                              AS "Canal (PTAR)",
    COUNT(v.numero_venta)                                                AS "Total Ventas",
    COUNT(a.phone)                                                       AS "Dentro Base",
    ROUND(COUNT(a.phone) * 100.0 / NULLIF(COUNT(v.numero_venta), 0), 2)  AS "%DB",
    COUNT(v.numero_venta) - COUNT(a.phone)                               AS "Fuera Base",
    ROUND((COUNT(v.numero_venta) - COUNT(a.phone)) * 100.0 
          / NULLIF(COUNT(v.numero_venta), 0), 2)                         AS "%FB"
FROM tmp_ventas_hogar v
LEFT JOIN tmp_asignacion_hogar a ON v.numero_venta = a.phone
-- NOTA PARA CRUCE POR CÉDULA: Cambia el ON de arriba por:
-- LEFT JOIN tmp_asignacion_hogar a ON v.documento_venta = a.documento_asignacion
GROUP BY 
    v.tipo_venta, 
    v.canal
ORDER BY 
    v.tipo_venta, 
    "Total Ventas" DESC;

-- 5. Limpieza de tablas temporales
DROP TEMPORARY TABLE IF EXISTS tmp_ventas_hogar;
DROP TEMPORARY TABLE IF EXISTS tmp_asignacion_hogar;


-- ==============================================================================================
-- PARTE 2: DETALLE DE TIPIFICACIÓN Y ALARMAS (GESTIÓN, INTENTOS, CONTACTO, VENTAS, EFECTIVIDAD)
-- ==============================================================================================

SELECT 
    c.CONCATENADO AS Tipificacion_Alarma,
    COUNT(DISTINCT b.Celular1) AS Gestion,
    COUNT(m.phone_number_dialed) AS Intentos_Totales,
    ROUND(COUNT(m.phone_number_dialed) / NULLIF(COUNT(DISTINCT b.Celular1), 0), 2) AS Intentos_Por_Registro,
    SUM(COALESCE(m.contacto, 0)) AS Contactos,
    SUM(CASE WHEN v.`NUMERO DE VENTA` IS NOT NULL THEN 1 ELSE 0 END) AS Ventas,
    ROUND(SUM(CASE WHEN v.`NUMERO DE VENTA` IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(DISTINCT b.Celular1), 0), 2) AS Efectividad_Porcentaje
FROM bbdd_cs_bog_tmk.tb_asignacion_hogar_p21 b
-- Cruzamos con la última llamada (o resumen de llamadas) por tipificación
INNER JOIN (
    SELECT 
        phone_number_dialed,
        status,
        contacto,
        contacto_efectivo,
        ROW_NUMBER() OVER(PARTITION BY phone_number_dialed ORDER BY prioridad ASC, call_date DESC) as fila
    FROM bbdd_cs_bog_tmk.tb_marcaciones_desgloce_dts
    WHERE periodo = 202607 AND campana = 'HOGAR'
) m ON b.Celular1 = m.phone_number_dialed AND m.fila = 1
LEFT JOIN (
    SELECT STATUS, MAX(CONCATENADO) AS CONCATENADO 
    FROM bbdd_cs_bog_tmk.tb_arbol_tmk_bogota_rp 
    GROUP BY STATUS
) c ON m.status = c.STATUS
LEFT JOIN (
    SELECT `NUMERO DE VENTA`
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar
    GROUP BY `NUMERO DE VENTA`
) v ON b.Celular1 = v.`NUMERO DE VENTA`
-- NOTA PARA CRUCE POR CÉDULA:
-- El cruce con ventas (v) debería cambiarse para usar cédula si es más preciso:
-- ON b.Cedula = v.Cedula
WHERE b.periodo = 202607
GROUP BY 
    c.CONCATENADO
ORDER BY 
    Gestion DESC;
