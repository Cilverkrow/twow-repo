@echo off
setlocal
echo Checking database...
powershell -NoProfile -Command "try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', 3307); $c.Close(); exit 0 } catch { exit 1 }"
if %ERRORLEVEL% NEQ 0 (
  echo Starting database...
  start "MariaDB" "%~dp0..\DB\start-database.bat"
  timeout /t 8 /nobreak >nul
) else (
  echo Database already running.
)
echo Starting realmd...
start "realmd" "%~dp0start-realmd.bat"
timeout /t 3 /nobreak >nul
echo Starting mangosd - first start can take a long time (migrations + bot travel graph)...
start "mangosd" "%~dp0start-mangosd.bat"
echo.
echo Three windows should now be open: MariaDB, realmd, mangosd.
pause
