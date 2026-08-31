@echo off
setlocal
title FORCE Stop TWoW Login Server

tasklist /FI "IMAGENAME eq realmd.exe" /NH 2^>nul | find /I "realmd.exe" >nul
if errorlevel 1 (
    echo [OK] realmd.exe is already stopped.
    pause
    exit /b 0
)

echo [WARNING] Force-stopping realmd.exe. Unsaved runtime state may be lost.
choice /C JN /N /M "Continue? [J/N]: "
if errorlevel 2 exit /b 2

taskkill /F /IM realmd.exe /T
pause
