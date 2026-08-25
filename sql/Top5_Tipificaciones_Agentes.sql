-- ==============================================================================
-- TOP 5 TIPIFICACIONES POR AGENTE ACTIVO (DE TODO EL MES)
-- ==============================================================================
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

WITH Agentes AS (
    SELECT DISTINCT Documento, Nombres_Apellidos
    FROM bbdd_config.tb_headcount
    WHERE campana = 'Claro - Hogar Tmk Bogota' 
      AND estado = 'activo' 
      AND cargo = 'asesor'
),
ConteoTipificaciones AS (
    SELECT 
        a.Documento,
        a.Nombres_Apellidos,
        COALESCE(t.CONCATENADO, m.status, 'Sin Tipificar') AS Tipificacion,
        COUNT(*) AS Cantidad
    FROM Agentes a
    INNER JOIN bbdd_cs_bog_tmk.tb_marcaciones_desgloce_dts m
        ON a.Documento = m.user
    LEFT JOIN (
        SELECT STATUS, MAX(CONCATENADO) AS CONCATENADO
        FROM (
            SELECT STATUS, CONCATENADO FROM bbdd_cs_bog_tmk.tb_arbol_tmk_bogota
            UNION ALL
            SELECT STATUS, CONCATENADO FROM bbdd_cs_bog_tmk.tb_arbol_tmk_bogota_rp_v2
        ) t_arbol
        GROUP BY STATUS
    ) t ON m.status = t.STATUS
    WHERE m.periodo = 202608 
      AND m.campana = 'HOGAR'
    GROUP BY a.Documento, a.Nombres_Apellidos, COALESCE(t.CONCATENADO, m.status, 'Sin Tipificar')
),
Ranked AS (
    SELECT 
        Documento,
        Nombres_Apellidos,
        Tipificacion,
        Cantidad,
        ROW_NUMBER() OVER(PARTITION BY Documento ORDER BY Cantidad DESC) AS rn
    FROM ConteoTipificaciones
)
SELECT 
    Documento,
    Nombres_Apellidos,
    rn AS Posicion,
    Tipificacion,
    Cantidad
FROM Ranked
WHERE rn <= 5
ORDER BY Nombres_Apellidos ASC, Posicion ASC;
