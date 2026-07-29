@echo off
echo ==============================================================
echo   SUBIENDO ACTUALIZACION A GIT Y VERCEL - HOGAR [5116]
echo ==============================================================
cd /d "C:\Users\braian.lopez\Documents\Hogar"

echo.
echo [1/3] Añadiendo archivos modificados y scripts nuevos...
git add .

echo.
echo [2/3] Creando commit...
git commit -m "feat: visualizacion de fecha/hora de actualizacion en HTML y scripts de limpieza de MySQL"

echo.
echo [3/3] Subiendo a GitHub (Vercel iniciara el despliegue automatico)...
git push origin main

echo.
echo ==============================================================
echo   !LISTO! CAMBIOS SUBIDOS A GIT Y DESPLIEGUE EN VERCEL INICIADO.
echo ==============================================================
echo.
pause
