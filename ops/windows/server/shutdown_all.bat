@echo off
setlocal
title Tortoise WoW - Unsupported Windows Shutdown Helper

echo [UNSUPPORTED] This Windows graceful-shutdown path is retired.
echo The recorded helper is not reliable under headless execution and is kept only
echo as historical evidence. No process or database action was attempted.
echo.
echo The supported runtime is Linux with Docker. Use the container lifecycle from
echo the repository root, including "make down" for an operator-requested stop.
echo See docs\adr\ADR-0028-platform-and-ci-strategy.md.

exit /b 1
