# DEPLOY-SHUTDOWN-HELPER-REALMD-01

Result: `SHUTDOWN_HELPER_RESULT=PASS`

Evidence root: `C:\TW\evidence\DEPLOY-SHUTDOWN-HELPER-REALMD-01`

The requested `server\evidence` location could not be created because that directory denied creation. Evidence was therefore stored in the writable workspace-level `C:\TW\evidence` directory. Production files remained untouched until their originals were copied to `before`.

## Cause

`start-all.bat` launches Realmd with:

`start "realmd" "%~dp0start-realmd.bat"`

The original `start-realmd.bat` did not set its own title. While that batch file remains active, `cmd.exe` extends the initial title to the verified value:

`realmd - C:\TW\ComTW\server\start-realmd.bat`

`start-mangosd.bat` already avoids the same behavior with `title mangosd`. The corrected `start-realmd.bat` now likewise executes `title realmd` before starting `realmd.exe`.

## Changes

- `start-realmd.bat`: sets the stable console title `realmd`.
- `shutdown_all.bat`: passes exactly two allowed Realmd console titles to the helper:
  - `realmd`
  - `realmd - C:\TW\ComTW\server\start-realmd.bat`
- `shutdown-tortoise-servers-gracefully.ps1`: compares Realmd titles with ordinal exact equality only; no wildcard or substring title matching is used.
- Existing Realmd identity checks remain mandatory: exactly one `realmd.exe` at the expected full path, a valid current PID file, equality between PID file and process ID, and a final running-process refresh before console attachment.
- Realmd still receives `CTRL_BREAK_EVENT`, is waited on through its process handle, and must exit with code 0. No forced process termination exists in the active shutdown chain.
- A fully stopped Worldserver is now an informational success, allowing the already-stopped invocation test to continue through Realmd and MariaDB.
- MariaDB checks and waits now cover both `mysqld.exe` and `mariadbd.exe`.
- The local `mysqladmin` invocation explicitly uses TCP to `127.0.0.1:3307` with `--skip-ssl`. This was required because the installed client otherwise failed with `SEC_E_NO_CREDENTIALS`; the explicit local non-TLS ping returned `mysqld is alive`.

## Original metadata (UTC)

| File | Bytes | LastWriteTimeUtc | SHA-256 |
|---|---:|---|---|
| `shutdown_all.bat` | 3504 | 2026-08-26 16:39:20 | `88F28AD9B32FB16587804C883F1725BD66086743E4116BCC977CA61174FCBC2E` |
| `start-realmd.bat` | 36 | 2026-08-25 16:56:21 | `D7184CEECDA68CE939297A1D8110DFEBC8351D2AC7612E3408CD6A752AD8E9FC` |
| `shutdown-tortoise-servers-gracefully.ps1` | 17047 | 2026-08-28 16:30:48 | `76D899BE55BAE77E72CCD5DF6C5CBD8203986524E944C3AEE7B8C2DD7862EA1A` |

## Final metadata (UTC)

| File | Bytes | LastWriteTimeUtc | SHA-256 |
|---|---:|---|---|
| `shutdown_all.bat` | 3639 | 2026-08-29 18:13:28 | `EEB870A1C7040F489852EC01A97A3C40DBA997A877693EF7DCE4B767E2A02ED8` |
| `start-realmd.bat` | 48 | 2026-08-29 18:04:05 | `2D573C4EBD14A009AE2ABA15A48511A817603F5B73F6F5A8CE2EDDFF7B52CBE8` |
| `shutdown-tortoise-servers-gracefully.ps1` | 17837 | 2026-08-29 18:04:05 | `CC0BD46FEA50F653778A11711BC9D9FE1A1B0BBE84980440A18734C6632FE3B1` |

## Tests and observations

1. PowerShell parser: 0 errors. All required scripts, executables, and `mysqladmin.exe` exist.
2. Already-stopped invocation: exit code 0; Worldserver, Realmd, and MariaDB reported only as already stopped.
3. Final normal start used the existing `start-all.bat`.
4. Final Realmd identity before shutdown:
   - PID file and actual PID: `7140`
   - Process: `realmd.exe`
   - Executable path: `C:\TW\ComTW\server\realmd.exe`
   - Exact console title: `realmd`
   - Matching processes at expected full path: `1`
5. Final listeners before shutdown:
   - `3307` -> PID `28556` (`mysqld.exe`)
   - `3724` -> PID `7140` (`realmd.exe`)
   - `8090` -> PID `33196` (`mangosd.exe`)
6. Final shutdown helper output:
   - Worldserver PID `33196`, exact EXE path, title `mangosd`: controlled stop confirmed.
   - Realmd PID `7140`, exact EXE path, title `realmd`: controlled stop confirmed.
   - MariaDB: controlled stop confirmed.
   - Shutdown process exit code: `0`.
7. Process transition timeline (UTC):
   - `18:16:04.3019763`: mangosd + mysqld + realmd running.
   - `18:16:30.4107487`: mangosd ended; mysqld + realmd remained.
   - `18:16:31.1968301`: realmd ended; mysqld remained.
   - `18:16:31.7885964`: mysqld ended; no target process remained.
8. Independent final verification:
   - target process count (`mangosd`, `realmd`, `mysqld`, `mariadbd`): `0`
   - target listener count (ports `3307`, `3724`, `8090`): `0`
   - executable `taskkill` references in the active shutdown chain: `0`
   - exact title cases accepted: the two listed variants only
   - fuzzy, elevated-prefix, and case-variant examples rejected

## Evidence files

- `before\`: byte-for-byte original backups.
- `after\`: byte-for-byte final copies.
- `SHA256SUMS.txt`: before/after production-file hashes.
- `test-stopped-state-final.log`: already-stopped invocation.
- `start-all-final.log`: normal start-script output.
- `realmd-identity-final-before-shutdown.log`: PID/path/title identity capture.
- `listeners-final-before-shutdown.log`: pre-shutdown listener/PID mapping.
- `processes-final-before-shutdown.log`: pre-shutdown process/path mapping.
- `shutdown-full-final.log`: ordered batch stages and MariaDB success.
- `shutdown-helper-console-output-final.log`: Worldserver/Realmd helper confirmations and exit code.
- `process-transition-timeline-final.log`: observed process-exit order.
- `final-verification.log`: final process, port, title-match, parser, taskkill, metadata, and hash checks.
- `shutdown-full.log`: first fail-closed MariaDB attempt, retained as diagnostic evidence.
- `precondition-db-shutdown.log`: controlled cleanup before the final full rerun.

No database/schema, `mangosd.conf`, source code, donation-points migration, or Worldserver save/shutdown command behavior was changed.
