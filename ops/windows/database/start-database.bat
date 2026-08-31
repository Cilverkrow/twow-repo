@echo off
"%~dp0bin\mysqld.exe" --datadir="%~dp0data" --port=3307 --bind-address=127.0.0.1 --console
