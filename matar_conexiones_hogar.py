import pymysql

DB_HOST = '172.70.7.60'
DB_PORT = 3306
DB_USER = 'braianlopez2004'
DB_PASSWORD = 'WSL7,B6sEgM4gfUQTeP8'
DB_NAME = 'bbdd_cs_bog_tmk'

def matar_procesos_hogar():
    print("=== CONECTANDO A MYSQL PARA MATAR PROCESOS EN HOGAR ===")
    try:
        conn = pymysql.connect(
            host=DB_HOST,
            port=DB_PORT,
            user=DB_USER,
            password=DB_PASSWORD,
            database=DB_NAME,
            autocommit=True
        )
        cursor = conn.cursor()
        
        # Obtener el ID de la conexión actual
        cursor.execute("SELECT CONNECTION_ID()")
        mi_id = cursor.fetchone()[0]
        print(f" ID de esta sesión de limpieza: {mi_id}")

        # Buscar todas las conexiones/consultas en bbdd_cs_bog_tmk o relacionadas con hogar
        query = """
            SELECT ID, DB, COMMAND, TIME, STATE, LEFT(IFNULL(INFO, 'Sin consulta (Sleep)'), 60) AS INFO
            FROM information_schema.processlist
            WHERE (DB = 'bbdd_cs_bog_tmk' 
                   OR IFNULL(INFO, '') LIKE '%bbdd_cs_bog_tmk%' 
                   OR IFNULL(INFO, '') LIKE '%hogar%' 
                   OR IFNULL(INFO, '') LIKE '%p21%')
              AND USER = 'braianlopez2004'
              AND ID != %s
        """
        cursor.execute(query, (mi_id,))
        procesos = cursor.fetchall()
        
        if not procesos:
            print(" No se encontraron consultas ni conexiones bloqueando en bbdd_cs_bog_tmk.")
        else:
            print(f" Se encontraron {len(procesos)} proceso(s) en bbdd_cs_bog_tmk:")
            for p in procesos:
                p_id, p_db, p_cmd, p_time, p_state, p_info = p
                print(f"   -> ID: {p_id} | DB: {p_db} | CMD: {p_cmd} | TIEMPO: {p_time}s | {p_info}")
                try:
                    print(f"   -> Matando proceso {p_id}...")
                    cursor.execute(f"KILL {p_id}")
                    print(f"      [OK] Proceso {p_id} eliminado exitosamente de raíz.")
                except Exception as e_kill:
                    print(f"      [ERROR] No se pudo matar el proceso {p_id}: {e_kill}")

        cursor.close()
        conn.close()
        print("=== LIMPIEZA DE HOGAR COMPLETADA ===")
    except Exception as e:
        print(f"Error al conectar o limpiar procesos: {e}")

if __name__ == '__main__':
    matar_procesos_hogar()
