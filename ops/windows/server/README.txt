TWoW WINDOWS SERVER TOOLS - HISTORICAL / UNSUPPORTED
====================================================

This directory is retained as historical evidence for the former live Windows
server. Linux with Docker is the supported runtime. None of these files authorizes
process or database control, and the repository does not provide Windows runtime
support.

Do not install or deploy these files from this repository. Follow the container
lifecycle in the root Makefile and ADR-0028 instead.

Files
-----

status-server.bat
  Shows whether mangosd.exe, realmd.exe, and mysqld.exe are running.

stop-mangosd.bat
  Stops only the world server. It first tries without /F. If the process remains,
  it asks before using a forced stop.

stop-realmd.bat
  Stops only the login server. It first tries without /F. If the process remains,
  it asks before using a forced stop.

stop-mariadb.bat
  Cleanly stops the standalone MariaDB server through mysqladmin. It targets
  127.0.0.1:3307 and asks for the root database password. No password is stored.
  MariaDB is never force-stopped by this package.

stop-all.bat
  Historical name-based stop sequence. It is not the supported graceful path.

shutdown_all.bat
  Retired fail-closed tombstone. It performs no process or database action and
  returns exit code 1.

shutdown-tortoise-servers-gracefully.ps1
  Historical implementation. The same recorded bytes passed an earlier interactive
  evidence run and later failed before delivering saveall under headless execution.
  It is not a supported runtime helper and must not be deployed or invoked.

stop-mangosd-force.bat / stop-realmd-force.bat
  Emergency tools for a hung process. They ask once, then use taskkill /F.

Important
---------

* These files are retained for provenance, not as an operations package.
* A forced stop may lose runtime state that has not yet been written to the DB.
* The scripts target exact process names only: mangosd.exe and realmd.exe.
* Ollama, the LLM bridge, and Windows are never stopped by these files.
* MariaDB is stopped only by stop-mariadb.bat or stop-all.bat through its own
  mysqladmin shutdown mechanism. Never close the mysqld console with X.
* The supported Docker entrypoint translates SIGTERM into saveall and
  server shutdown 0 through its console FIFO.
