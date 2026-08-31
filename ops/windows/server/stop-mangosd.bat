@echo off
setlocal
title Stop TWoW World Server

call :is_running
if errorlevel 1 (
    echo [OK] mangosd.exe is already stopped.
    if not defined TWOW_NO_PAUSE pause
    exit /b 0
)

echo Requesting mangosd.exe to stop...
taskkill /IM mangosd.exe /T >nul 2>&1
timeout /t 5 /nobreak >nul

call :is_running
if errorlevel 1 (
    echo [OK] mangosd.exe has stopped.
    if not defined TWOW_NO_PAUSE pause
    exit /b 0
)

echo.
echo [WARNING] mangosd.exe is still running.
choice /C JN /N /M "Force stop now? [J/N]: "
if errorlevel 2 (
    echo Force stop cancelled.
    if not defined TWOW_NO_PAUSE pause
    exit /b 2
)

taskkill /F /IM mangosd.exe /T >nul 2>&1
timeout /t 2 /nobreak >nul
call :is_running
if errorlevel 1 (
    echo [OK] mangosd.exe was force-stopped.
    pause
    exit /b 0
)

echo [ERROR] mangosd.exe could not be stopped. Run this file as Administrator.
if not defined TWOW_NO_PAUSE pause
exit /b 1

:is_running
tasklist /FI "IMAGENAME eq mangosd.exe" /NH 2^>nul | find /I "mangosd.exe" >nul
if errorlevel 1 exit /b 1
exit /b 0
