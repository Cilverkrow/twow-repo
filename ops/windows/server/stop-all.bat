@echo off
setlocal
title Stop All TWoW Servers

echo Shutdown order: world server, login server, MariaDB.
echo MariaDB will ask for the database password.
choice /C JN /N /M "Continue? [J/N]: "
if errorlevel 2 exit /b 2

set "TWOW_NO_PAUSE=1"
call "%~dp0stop-mangosd.bat"
if errorlevel 1 goto abort_sequence
call "%~dp0stop-realmd.bat"
if errorlevel 1 goto abort_sequence
call "%~dp0stop-mariadb.bat"
set "TWOW_NO_PAUSE="

echo.
echo Final status:
tasklist /FI "IMAGENAME eq mangosd.exe" /NH 2^>nul | find /I "mangosd.exe" >nul
if errorlevel 1 (echo [OFF] mangosd.exe) else (echo [ON ] mangosd.exe)
tasklist /FI "IMAGENAME eq realmd.exe" /NH 2^>nul | find /I "realmd.exe" >nul
if errorlevel 1 (echo [OFF] realmd.exe) else (echo [ON ] realmd.exe)
tasklist /FI "IMAGENAME eq mysqld.exe" /NH 2^>nul | find /I "mysqld.exe" >nul
if errorlevel 1 (echo [OFF] mysqld.exe) else (echo [ON ] mysqld.exe)

pause
exit /b 0

:abort_sequence
set "TWOW_NO_PAUSE="
echo.
echo [STOPPED] Shutdown sequence aborted because a previous server is still running.
echo MariaDB was not stopped. Resolve the reported process first.
pause
exit /b 1
