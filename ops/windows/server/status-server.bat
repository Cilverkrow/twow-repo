@echo off
setlocal
title TWoW Server Status

echo.
echo ========================================
echo  TWoW server process status
echo ========================================
echo.

call :status mangosd.exe "World server"
call :status realmd.exe "Login server"
call :status mysqld.exe "MariaDB 127.0.0.1:3307"

echo.
if not defined TWOW_NO_PAUSE pause
exit /b 0

:status
tasklist /FI "IMAGENAME eq %~1" /NH 2^>nul | find /I "%~1" >nul
if errorlevel 1 (
    echo [OFF] %~2 ^(%~1^)
) else (
    echo [ON ] %~2 ^(%~1^)
    tasklist /FI "IMAGENAME eq %~1" /FO TABLE /NH
)
exit /b 0
