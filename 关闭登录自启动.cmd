@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action DisableAutostart
set "DGUT_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %DGUT_RESULT%
