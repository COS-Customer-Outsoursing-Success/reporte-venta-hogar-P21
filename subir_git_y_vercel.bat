@echo off
echo ==============================================================
echo   SUBIENDO ACTUALIZACION A GIT Y VERCEL - HOGAR [5116]
echo ==============================================================
cd /d "C:\Users\braian.lopez\Documents\Hogar"

echo.
echo [1/4] Añadiendo archivos modificados y scripts nuevos...
git add .

echo.
echo [2/4] Creando commit...
git commit -m "feat: visualizacion de fecha/hora, kpis dinamicos y automatizacion de vercel"

echo.
echo [3/4] Subiendo a GitHub...
git push origin main

echo.
echo [4/4] Desplegando directamente a produccion en Vercel...
call npx vercel --prod --yes

echo.
echo ==============================================================
echo   !LISTO! CAMBIOS SUBIDOS A GIT Y DESPLIEGUE EN VERCEL COMPLETADO.
echo ==============================================================
echo.
pause
