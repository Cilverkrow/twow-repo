@echo off
setlocal
title Stop TWoW MariaDB

set "MYSQLADMIN=C:\TW\ComTW\DB\bin\mysqladmin.exe"
set "DB_HOST=127.0.0.1"
set "DB_PORT=3307"
set "DB_USER=root"

call :is_running
if errorlevel 1 (
    echo [OK] mysqld.exe is already stopped.
    if not defined TWOW_NO_PAUSE pause
    exit /b 0
)

if not exist "%MYSQLADMIN%" (
    echo [ERROR] mysqladmin.exe was not found:
    echo         %MYSQLADMIN%
    if not defined TWOW_NO_PAUSE pause
    exit /b 1
)

echo.
echo MariaDB will be shut down cleanly at %DB_HOST%:%DB_PORT%.
echo Enter the password for database user "%DB_USER%" when prompted.
echo If this user has no password, press Enter.
echo.

"%MYSQLADMIN%" --protocol=TCP --host=%DB_HOST% --port=%DB_PORT% --user=%DB_USER% --password shutdown
if errorlevel 1 (
    echo.
    echo [ERROR] MariaDB rejected the shutdown request or could not be reached.
    echo No forced stop was attempted. Check the user, password, and port.
    if not defined TWOW_NO_PAUSE pause
    exit /b 1
)

set /a WAIT_COUNT=0
:wait_for_stop
call :is_running
if errorlevel 1 goto stopped
if %WAIT_COUNT% GEQ 15 goto still_running
set /a WAIT_COUNT+=1
timeout /t 1 /nobreak >nul
goto wait_for_stop

:stopped
echo [OK] MariaDB has stopped cleanly.
if not defined TWOW_NO_PAUSE pause
exit /b 0

:still_running
echo [ERROR] mysqladmin returned successfully, but mysqld.exe is still running.
echo Do not close it with X and do not use taskkill /F without a DB recovery plan.
if not defined TWOW_NO_PAUSE pause
exit /b 1

:is_running
tasklist /FI "IMAGENAME eq mysqld.exe" /NH 2^>nul | find /I "mysqld.exe" >nul
if errorlevel 1 exit /b 1
exit /b 0
