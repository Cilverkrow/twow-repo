@echo off
setlocal
title FORCE Stop TWoW World Server

tasklist /FI "IMAGENAME eq mangosd.exe" /NH 2^>nul | find /I "mangosd.exe" >nul
if errorlevel 1 (
    echo [OK] mangosd.exe is already stopped.
    pause
    exit /b 0
)

echo [WARNING] Force-stopping mangosd.exe. Unsaved runtime state may be lost.
choice /C JN /N /M "Continue? [J/N]: "
if errorlevel 2 exit /b 2

taskkill /F /IM mangosd.exe /T
pause
