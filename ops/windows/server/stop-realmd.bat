@echo off
setlocal
title Stop TWoW Login Server

call :is_running
if errorlevel 1 (
    echo [OK] realmd.exe is already stopped.
    if not defined TWOW_NO_PAUSE pause
    exit /b 0
)

echo Requesting realmd.exe to stop...
taskkill /IM realmd.exe /T >nul 2>&1
timeout /t 5 /nobreak >nul

call :is_running
if errorlevel 1 (
    echo [OK] realmd.exe has stopped.
    if not defined TWOW_NO_PAUSE pause
    exit /b 0
)

echo.
echo [WARNING] realmd.exe is still running.
choice /C JN /N /M "Force stop now? [J/N]: "
if errorlevel 2 (
    echo Force stop cancelled.
    if not defined TWOW_NO_PAUSE pause
    exit /b 2
)

taskkill /F /IM realmd.exe /T >nul 2>&1
timeout /t 2 /nobreak >nul
call :is_running
if errorlevel 1 (
    echo [OK] realmd.exe was force-stopped.
    pause
    exit /b 0
)

echo [ERROR] realmd.exe could not be stopped. Run this file as Administrator.
if not defined TWOW_NO_PAUSE pause
exit /b 1

:is_running
tasklist /FI "IMAGENAME eq realmd.exe" /NH 2^>nul | find /I "realmd.exe" >nul
if errorlevel 1 exit /b 1
exit /b 0
