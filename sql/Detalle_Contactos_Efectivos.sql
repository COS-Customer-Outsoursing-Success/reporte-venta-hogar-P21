-- ==============================================================================
-- DETALLE DE CONTACTOS EFECTIVOS (>= 180 SEG)
-- Esta consulta extrae el listado exacto de los teléfonos que cumplieron 
-- con la regla de Contacto Efectivo y TMO >= 3 minutos.
-- ==============================================================================

WITH tmp_base_hogar AS (
    -- Paso 1: Obtener la base asignada para el periodo
    SELECT 
        phone as Celular1, 
        numero_identificacion as NumeroIdentificacion
    FROM bbdd_cs_bog_tmk.tb_bd_gestion_asignacion_phone_dts  
    WHERE periodo = 202608                      -- CAMBIAR MES AQUÍ (ej. 202608)
      AND nombre_campana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
      AND LENGTH(phone) = 10
),
tmp_ultima_llamada AS (
    -- Paso 2: Obtener el estado de la última llamada de vicidial
    SELECT 
        phone_number_dialed,
        status,
        length_in_sec AS aht_seg,
        call_date
    FROM (
        SELECT 
            v.phone_number_dialed,
            v.status,
            v.length_in_sec,
            v.call_date,
            ROW_NUMBER() OVER(PARTITION BY v.phone_number_dialed ORDER BY v.call_date DESC) as fila
        FROM bbdd_bigdata_marcaciones_vicidial.tb_marcaciones_vicidial_out_tmk_bog v
        INNER JOIN tmp_base_hogar b ON v.phone_number_dialed = b.Celular1
        WHERE v.call_date >= '2026-08-01 00:00:00' -- CAMBIAR FECHA INICIAL AQUÍ
          AND v.call_date < '2026-09-01 00:00:00'  -- CAMBIAR FECHA FINAL AQUÍ
          AND v.campaign_id = 'PTMKBOHG'
    ) sub
    WHERE fila = 1
)
-- Paso 3: Traer solo los que cruzan como CONTACTO EFECTIVO y AHT >= 180
SELECT 
    b.Celular1 AS Telefono,
    b.NumeroIdentificacion,
    u.status AS Status_Vicidial,
    c.CONCATENADO AS Tipificacion_Arbol,
    u.aht_seg AS Duracion_Segundos,
    u.call_date AS Fecha_Ultima_Llamada
FROM tmp_base_hogar b
INNER JOIN tmp_ultima_llamada u ON b.Celular1 = u.phone_number_dialed
INNER JOIN (
    SELECT STATUS, MAX(CONCATENADO) AS CONCATENADO, MAX(TIPO_CONTACTO) AS TIPO_CONTACTO 
    FROM (
        SELECT STATUS, CONCATENADO, TIPO_CONTACTO FROM bbdd_cs_bog_tmk.tb_arbol_tmk_bogota
        UNION ALL
        SELECT STATUS, CONCATENADO, TIPO_CONTACTO FROM bbdd_cs_bog_tmk.tb_arbol_tmk_bogota_rp_v2
    ) t_arbol
    GROUP BY STATUS
) c ON u.status = c.STATUS
WHERE c.TIPO_CONTACTO IN ('CONTACTOS_EFECTIVOS', 'CONTACTOS EFECTIVOS')
  AND COALESCE(u.aht_seg, 0) >= 180;
