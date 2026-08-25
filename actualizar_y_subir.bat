@echo off
echo ==========================================================
echo   ACTUALIZACION AUTOMATICA - REPORTE HOGAR CLARO [5116]
echo ==========================================================
cd /d "C:\Users\braian.lopez\Documents\Hogar"

echo.
echo [1/4] Ejecutando consulta MySQL y actualizando informe HTML...
python actualizar_dashboard.py
if %errorlevel% neq 0 (
    echo [ERROR] Hubo un problema al ejecutar actualizar_dashboard.py.
    goto :fin
)

echo.
echo [2/4] Guardando cambios localmente en Git...
git add "Reporte Venta Cruzada Hogar [5116].html"
git commit -m "chore: actualizacion diaria automatica de datos %date% %time%"

echo.
echo [3/4] Subiendo cambios a GitHub...
git push origin main

echo.
echo [4/4] Desplegando directamente a produccion en Vercel...
call npx vercel --prod --yes

echo.
echo ==========================================================
echo   !PROCESO COMPLETADO! GITHUB Y VERCEL ESTAN AL DIA.
echo ==========================================================

:fin
