import pymysql
import re
import json
import os
import time
from datetime import datetime
from pymysql.constants import CLIENT

# ==============================================================================
# CONFIGURACIÓN DE BASE DE DATOS
# Edita estas variables con tus credenciales de MySQL locales
# ==============================================================================
DB_HOST = '172.70.7.60'
DB_PORT = 3306
DB_USER = 'braianlopez2004'
DB_PASSWORD = 'WSL7,B6sEgM4gfUQTeP8'
DB_NAME = 'bbdd_cs_bog_tmk'
# ==============================================================================

def main():
    print("🚀 Iniciando actualización del Dashboard...")
    
    # 1. Conexión a MySQL
    try:
        print("Conectando a MySQL...")
        connection = pymysql.connect(
            host=DB_HOST, 
            port=DB_PORT,
            user=DB_USER, 
            password=DB_PASSWORD, 
            database=DB_NAME,
            cursorclass=pymysql.cursors.DictCursor,
            client_flag=CLIENT.MULTI_STATEMENTS
        )
    except Exception as e:
        print(f"❌ Error conectando a MySQL: {e}")
        print("💡 Por favor, abre este script (actualizar_dashboard.py) y edita DB_USER y DB_PASSWORD.")
        return

    # 2. Leer SQL
    sql_path = os.path.join("sql", "Consulta_Dashboard.sql")
    sql_parte1_path = os.path.join("sql", "Analisis_Adicional_Parte1.sql")
    sql_parte2_path = os.path.join("sql", "Analisis_Adicional_Parte2.sql")
    
    if not os.path.exists(sql_path):
        print(f"❌ No se encontró el archivo {sql_path}")
        return
        
    with open(sql_path, "r", encoding="utf-8") as f:
        sql = f.read()
    with open(sql_parte1_path, "r", encoding="utf-8") as f:
        sql_parte1 = f.read()
    with open(sql_parte2_path, "r", encoding="utf-8") as f:
        sql_parte2 = f.read()

    # Helper function para extraer el resultado de comandos multiples (con reintentos ante bloqueos)
    def execute_multi_statement(cursor, sql_text, max_retries=3):
        for attempt in range(1, max_retries + 1):
            try:
                # Evitar locks compartidos y deadlocks en tablas productivas al realizar lecturas masivas
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
                # 1213 = Deadlock, 1205 = Lock wait timeout
                if e.args[0] in (1213, 1205) and attempt < max_retries:
                    print(f"⚠️ Bloqueo temporal en MySQL ({e.args[1]}). Reintentando intento {attempt}/{max_retries} en 3 segundos...")
                    time.sleep(3)
                else:
                    raise

    # 3. Ejecutar SQL
    print("Ejecutando consultas (esto puede tardar unos segundos)...")
    try:
        with connection.cursor() as cursor:
            results = execute_multi_statement(cursor, sql)
            results_parte1 = execute_multi_statement(cursor, sql_parte1)
            results_parte2 = execute_multi_statement(cursor, sql_parte2)
    except Exception as e:
        print(f"❌ Error ejecutando la consulta: {e}")
        return
    finally:
        connection.close()

    # 4. Mapear resultados a un diccionario
    data = {}
    for row in results:
        metrica = row['Metrica']
        # Convertir a entero. Algunos vienen como string por el CAST que hicimos antes
        valor = int(float(row['Valor'])) if row['Valor'] is not None else 0
        data[metrica] = valor

    # 5. Construir el objeto JSON para Julio
    nuevo_dataJulio = {
        "fechaActualizacion": datetime.now().strftime("%d/%m/%Y %I:%M:%S %p"),
        "baseEntregada": data.get("Base Entregada", 0),
        "baseGestionada": data.get("Base Gestionada", 0),
        "baseContactada": data.get("Base Contactada", 0),
        "contactosEfectivos": data.get("Contactos Efectivos", 0),
        "contactosNoEfectivos": data.get("Contactos No Efectivos", 0),
        "noContactos": data.get("No Contactos", 0),
        "ventasHogares5116": data.get("Ventas Hogares @ 5116", 0),
        "ventasServicios5116": data.get("Ventas Servicios @ 5116", 0),
        "ventasHogares5143": data.get("Ventas Hogares @ 5143", 0),
        "ventasServicios5143": data.get("Ventas Servicios @ 5143", 0),
        "ventasHogaresOtrasPtar": data.get("Ventas Hogares @ Otras Ptar", 0),
        "ventasServiciosOtrasPtar": data.get("Ventas Servicios @ Otras Ptar", 0),
        "totalHogares": data.get("Venta", 0),
        "totalHogaresSoloArroba": data.get("Ventas Hogares @ 5116", 0) + data.get("Ventas Hogares @ 5143", 0) + data.get("Ventas Hogares @ Otras Ptar", 0),
        "totalServicios": data.get("Ventas Servicios @ 5116", 0) + data.get("Ventas Servicios @ 5143", 0) + data.get("Ventas Servicios @ Otras Ptar", 0),
        "venta": data.get("Venta", 0),
        "noVenta": data.get("No Venta", 0),
        "noVentaDesglose": {
            "No atractiva la oferta": data.get("No_Le_Parece_Atractiva_La_Oferta", 0),
            "Precio": data.get("Precio", 0),
            "Internet": data.get("Internet", 0),
            "TV": data.get("Tv", 0),
            "Mala experiencia": data.get("Mala Experiencia Con Procesos De Claro", 0),
            "Pide no volver a llamar": data.get("Cliente Pide No Volver A Llamar", 0),
            "Perm. con otro operador": data.get("Permanencia Activa Con Otro Operador", 0),
            "No Apto Cartera": data.get("No Apto Cartera", 0),
            "Cliente Mintic": data.get("Cliente Mintic", 0),
            "Cliente Corporativo": data.get("Cliente Corporativo", 0),
            "Mejores Promociones": data.get("Mejores_Promociones", 0)
        },
        "origenVentas": results_parte1,
        "detalleTipificacion": results_parte2
    }

    # 6. Leer y actualizar el HTML
    html_path = "Reporte Venta Cruzada Hogar [5116].html"
    print("Actualizando el archivo HTML...")
    
    with open(html_path, "r", encoding="utf-8") as f:
        html_content = f.read()

    # Formatear el JSON para que quede bonito en el JS
    import decimal
    class DecimalEncoder(json.JSONEncoder):
        def default(self, o):
            if isinstance(o, decimal.Decimal):
                return float(o)
            return super(DecimalEncoder, self).default(o)
            
    json_str = json.dumps(nuevo_dataJulio, indent=4, cls=DecimalEncoder)
    # Tabular el JSON para que quede alineado con el código JS
    json_str = json_str.replace('\n', '\n        ')
    
    # Expresión regular para buscar el bloque const dataJulio = { ... };
    pattern = r"const dataJulio = \{.*?\};"
    replacement = f"const dataJulio = {json_str};"
    
    new_html = re.sub(pattern, replacement, html_content, flags=re.DOTALL)

    with open(html_path, "w", encoding="utf-8") as f:
        f.write(new_html)

    print("✅ ¡Éxito! El archivo HTML ha sido actualizado con los últimos datos de la base de datos.")

if __name__ == "__main__":
    main()
