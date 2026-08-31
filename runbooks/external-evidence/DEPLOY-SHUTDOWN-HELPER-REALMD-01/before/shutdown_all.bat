@echo off
setlocal EnableExtensions
title Tortoise WoW - Controlled Shutdown

set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SHUTDOWN_HELPER=%~dp0shutdown-tortoise-servers-gracefully.ps1"
set "MYSQLADMIN=%~dp0..\DB\bin\mysqladmin.exe"

echo ==========================================
echo   Tortoise WoW Server wird kontrolliert beendet
echo ==========================================
echo.

if not exist "%SHUTDOWN_HELPER%" (
    echo [FEHLER] PowerShell-Helfer nicht gefunden:
    echo          %SHUTDOWN_HELPER%
    goto :abort
)

if not exist "%POWERSHELL_EXE%" (
    echo [FEHLER] Windows PowerShell wurde nicht gefunden.
    goto :abort
)

echo [1/5] Worldserver, PID, EXE-Pfad und Konsolentitel werden geprueft...
echo [2/5] Danach wird "saveall" gesendet und 5 Sekunden gewartet.
echo [3/5] Anschliessend wird "server shutdown 0" gesendet und auf das
echo       tatsaechliche Ende von mangosd.exe gewartet.
echo.

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SHUTDOWN_HELPER%" -Action World -ServerDirectory "%~dp0." -WorldWindowTitle "mangosd" -SaveDelaySeconds 5 -WorldExitTimeoutSeconds 180
if errorlevel 1 (
    echo.
    echo [FEHLER] Der Worldserver konnte nicht kontrolliert beendet werden.
    echo          Realmd und MariaDB werden nicht beendet.
    goto :abort
)

echo.
echo [4/5] Realmd wird nach dem Ende des Worldservers kontrolliert beendet...
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SHUTDOWN_HELPER%" -Action Realm -ServerDirectory "%~dp0." -RealmWindowTitle "realmd" -RealmExitTimeoutSeconds 30
if errorlevel 1 (
    echo.
    echo [FEHLER] Realmd konnte nicht kontrolliert beendet werden.
    echo          MariaDB wird nicht beendet.
    goto :abort
)

echo.
echo [5/5] MariaDB wird kontrolliert heruntergefahren...
if not exist "%MYSQLADMIN%" (
    echo [FEHLER] mysqladmin.exe wurde nicht gefunden:
    echo          %MYSQLADMIN%
    goto :abort
)

"%MYSQLADMIN%" --host=127.0.0.1 --port=3307 --user=root --silent ping >nul 2>&1
if errorlevel 1 (
    "%POWERSHELL_EXE%" -NoLogo -NoProfile -Command "if (Get-Process -Name mysqld -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
    if errorlevel 1 (
        echo [INFO] MariaDB laeuft bereits nicht mehr.
        goto :complete
    )

    echo [FEHLER] mysqld.exe laeuft, antwortet aber nicht auf Port 3307.
    echo          MariaDB wird nicht erzwungen beendet.
    goto :abort
)

"%MYSQLADMIN%" --host=127.0.0.1 --port=3307 --user=root shutdown
if errorlevel 1 (
    echo [FEHLER] MariaDB hat den kontrollierten Shutdown abgelehnt.
    goto :abort
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -Command "$limit = [DateTime]::UtcNow.AddSeconds(30); do { $running = Get-Process -Name mysqld -ErrorAction SilentlyContinue; if (-not $running) { exit 0 }; Start-Sleep -Milliseconds 250 } while ([DateTime]::UtcNow -lt $limit); exit 1"
if errorlevel 1 (
    echo [FEHLER] MariaDB laeuft nach 30 Sekunden noch.
    echo          Es wurde kein erzwungenes Beenden ausgefuehrt.
    goto :abort
)

echo [OK] MariaDB wurde kontrolliert beendet.

:complete
echo.
echo ==========================================
echo   Alle gestarteten Server wurden beendet.
echo ==========================================
echo.
pause
exit /b 0

:abort
echo.
echo ==========================================
echo   Abschaltung abgebrochen.
echo   Es wurde kein taskkill ausgefuehrt.
echo ==========================================
echo.
pause
exit /b 1
