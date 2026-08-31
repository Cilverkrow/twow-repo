@echo off
setlocal
set "LAB_DIR=%~dp0"
set "TEMP=%LAB_DIR%temp"
set "TMP=%LAB_DIR%temp"
set "VSCMD_SKIP_SENDTELEMETRY=1"
if not exist "%TEMP%" mkdir "%TEMP%"
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b %errorlevel%
cl.exe /nologo /std:c++17 /utf-8 /EHsc /W4 /O2 /MT /DUNICODE /D_UNICODE /Fe:"%LAB_DIR%realmd.exe" /Fo:"%LAB_DIR%realm-console-emitter.obj" "%LAB_DIR%realm-console-emitter.cpp" /link /SUBSYSTEM:CONSOLE /INCREMENTAL:NO
exit /b %errorlevel%
