import pymysql
import csv
import os
import time
from pymysql.constants import CLIENT

# ==============================================================================
# CONFIGURACIÓN DE BASE DE DATOS
# ==============================================================================
DB_HOST = '172.70.7.60'
DB_PORT = 3306
DB_USER = 'braianlopez2004'
DB_PASSWORD = 'WSL7,B6sEgM4gfUQTeP8'
DB_NAME = 'bbdd_cs_bog_tmk'
# ==============================================================================

SQL_TEMP_TABLES = """
-- Evitar bloqueos y deadlocks en tablas productivas al realizar lecturas masivas
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- Paso 1: Materializar las marcaciones de Agosto-HOGAR ANTES del ROW_NUMBER
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

-- Paso 2: Total de intentos por telefono
DROP TEMPORARY TABLE IF EXISTS tmp_intentos;
CREATE TEMPORARY TABLE tmp_intentos AS
SELECT phone_number_dialed, COUNT(*) AS intentos
FROM tmp_marc_agosto
GROUP BY phone_number_dialed;

ALTER TABLE tmp_intentos ADD PRIMARY KEY (phone_number_dialed);

-- Paso 3: ULTIMA llamada por telefono
DROP TEMPORARY TABLE IF EXISTS tmp_ultima;
CREATE TEMPORARY TABLE tmp_ultima AS
SELECT phone_number_dialed, status, gestionado, contacto, contacto_efectivo, call_date
FROM (
    SELECT
        phone_number_dialed, status, gestionado, contacto, contacto_efectivo, call_date,
        ROW_NUMBER() OVER(PARTITION BY phone_number_dialed
                          ORDER BY prioridad ASC, call_date DESC) AS fila
    FROM tmp_marc_agosto
) sub
WHERE fila = 1;

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
    SELECT b.telenum AS celular_base
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
    INNER JOIN bbdd_cs_bog_tmk.tb_asignacion_claro_tmk b
        ON v.`NUMERO DE VENTA` = b.telenum
    WHERE v.`FECHA DE VENTA` >= '2026-08-01'
      AND v.`FECHA DE VENTA` <= '2026-08-31'
      AND b.periodo = '202608'
      AND b.nombrecampana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
      AND LENGTH(b.telenum) = 10

    UNION ALL

    -- Match 2: por cedula_cliente, solo si el telefono de la venta NO esta en la base
    SELECT b.telenum AS celular_base
    FROM bbdd_cs_bog_tmk.tb_crudo_ventas_hogar v
    INNER JOIN bbdd_cs_bog_tmk.tb_asignacion_claro_tmk b
        ON v.cedula_cliente = b.numeroidentificacion
    LEFT JOIN bbdd_cs_bog_tmk.tb_asignacion_claro_tmk b2
        ON v.`NUMERO DE VENTA` = b2.telenum AND b2.periodo = '202608'
    WHERE v.`FECHA DE VENTA` >= '2026-08-01'
      AND v.`FECHA DE VENTA` <= '2026-08-31'
      AND b.periodo = '202608'
      AND b.nombrecampana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
      AND LENGTH(b.telenum) = 10
      AND b2.telenum IS NULL
) combined
GROUP BY celular_base;

ALTER TABLE tmp_ventas_tel ADD PRIMARY KEY (celular_base);
"""

SQL_SELECT_FINAL = """
SELECT
    b.*,
    COALESCE(c.CONCATENADO, 'Sin Tipificacion') AS Tipificacion_Alarma,
    u.status                                    AS Status_Ultima_Llamada,
    u.call_date                                 AS Fecha_Ultima_Llamada,
    COALESCE(i.intentos, 1)                     AS Intentos_Totales,
    COALESCE(u.contacto, 0)                     AS Es_Contacto,
    COALESCE(u.contacto_efectivo, 0)            AS Es_Contacto_Efectivo,
    CASE WHEN v.celular_base IS NOT NULL THEN 'SI' ELSE 'NO' END AS Venta_Hogar_Confirmada
FROM bbdd_cs_bog_tmk.tb_asignacion_claro_tmk b
INNER JOIN tmp_ultima u      ON b.telenum = u.phone_number_dialed
LEFT  JOIN tmp_intentos i    ON b.telenum = i.phone_number_dialed
LEFT  JOIN tmp_arbol c       ON u.status   = c.STATUS
LEFT  JOIN tmp_ventas_tel v  ON b.telenum = v.celular_base
WHERE b.periodo = '202608'
  AND b.nombrecampana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
  AND LENGTH(b.telenum) = 10
  AND b.idasignacion NOT IN (
    SELECT idasignacion FROM bbdd_cs_bog_tmk.tb_asignacion_claro_tmk 
    WHERE periodo = '202608' 
      AND nombrecampana = 'CROSSELLING_MOVIL_SIN_HOGAR_P21'
      AND TRIM(UPPER(ciudad)) IN ('DOSQUEBRADAS', 'LA DORADA', 'PEREIRA', 'SANTA ROSA DE CABAL')
  )
ORDER BY b.telenum;
"""

def execute_multi_statement(cursor, sql_text, max_retries=3):
    for attempt in range(1, max_retries + 1):
        try:
            cursor.execute("SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;")
            cursor.execute(sql_text)
            final_results = []
            while True:
                if cursor.description is not None:
                    final_results = cursor.fetchall()
                if not cursor.nextset():
                    break
            return final_results
        except pymysql.err.OperationalError as e:
            if e.args[0] in (1213, 1205) and attempt < max_retries:
                print(f"⚠️ Bloqueo temporal en MySQL ({e.args[1]}). Reintentando {attempt}/{max_retries} en 3 segundos...")
                time.sleep(3)
            else:
                raise

def main():
    output_filename = "base_p21_tipificados_agosto_2026.csv"
    output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), output_filename)

    print("🚀 Conectando a MySQL y preparando la exportación de tipificaciones...")
    try:
        connection = pymysql.connect(
            host=DB_HOST,
            port=DB_PORT,
            user=DB_USER,
            password=DB_PASSWORD,
            database=DB_NAME,
            client_flag=CLIENT.MULTI_STATEMENTS
        )
    except Exception as e:
        print(f"❌ Error conectando a MySQL: {e}")
        return

    try:
        with connection.cursor() as cursor:
            print("1️⃣ Generando tablas temporales consolidadas de la última llamada (sin bloqueo)...")
            execute_multi_statement(cursor, SQL_TEMP_TABLES)

            print("2️⃣ Extrayendo la base gestionada P21 con todas sus columnas y tipificación final...")
            for attempt in range(1, 4):
                try:
                    cursor.execute("SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;")
                    cursor.execute(SQL_SELECT_FINAL)
                    break
                except pymysql.err.OperationalError as e:
                    if e.args[0] in (1213, 1205) and attempt < 3:
                        print(f"⚠️ Bloqueo temporal al consultar filas ({e.args[1]}). Reintentando {attempt}/3 en 3s...")
                        time.sleep(3)
                    else:
                        raise

            headers = [col[0] for col in cursor.description]
            rows = cursor.fetchall()

            print(f"3️⃣ Escribiendo {len(rows):,} registros gestionados en '{output_filename}'...")
            with open(output_path, "w", newline="", encoding="utf-8-sig") as f:
                writer = csv.writer(f, delimiter=";")
                writer.writerow(headers)
                for row in rows:
                    writer.writerow(["" if val is None else str(val) for val in row])

            print(f"\n✅ ¡Exportación completa!")
            print(f"📂 Archivo generado: {output_path}")
            print(f"📊 Total registros gestionados exportados: {len(rows):,}")
            ventas_count = sum(1 for r in rows if r[-1] == 'SI')
            print(f"🛒 Total marcados con venta confirmada: {ventas_count}")

    except Exception as e:
        print(f"❌ Error durante la exportación: {e}")
    finally:
        connection.close()

if __name__ == "__main__":
    main()
