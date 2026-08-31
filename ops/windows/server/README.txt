TWoW SERVER STOP TOOLS
======================

Installation
------------
Extract this folder to:

  C:\TW\ComTW\server\tools\stop

The BAT files do not depend on their installation directory. Shortcuts may be
placed on the desktop.

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
  Runs stop-mangosd.bat first, stop-realmd.bat second, and stop-mariadb.bat last.
  It aborts before MariaDB if a preceding server could not be stopped.

stop-mangosd-force.bat / stop-realmd-force.bat
  Emergency tools for a hung process. They ask once, then use taskkill /F.

Important
---------

* These are external emergency/operations tools. If the mangosd console is still
  responsive, use its normal server shutdown command for the cleanest shutdown.
* A forced stop may lose runtime state that has not yet been written to the DB.
* The scripts target exact process names only: mangosd.exe and realmd.exe.
* Ollama, the LLM bridge, and Windows are never stopped by these files.
* MariaDB is stopped only by stop-mariadb.bat or stop-all.bat through its own
  mysqladmin shutdown mechanism. Never close the mysqld console with X.
* After mangosd crashes and the prompt C:\TW\ComTW\server> appears, typing
  "shutdown" invokes the Windows shutdown utility. Use these BAT files instead.
* If Windows reports "Access denied", right-click the BAT and choose
  "Run as administrator".
