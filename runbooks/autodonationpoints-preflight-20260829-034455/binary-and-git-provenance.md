# Binary and Git provenance

`BINARY_SUPPORT=PROVEN`

## Installed production binary

- Path: `C:\TW\ComTW\server\mangosd.exe`
- Bytes: 20,376,576
- SHA-256: `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`
- LastWriteTimeUtc: `2026-08-25T16:54:59.8378295Z`

The exact executable contains all four unique configuration strings,
`donation_point_progress`, and embedded revision
`42b8a7f742548793910f`. This proves that the installed binary contains the
feature implementation. The process was not running during this preflight, so
the conclusion applies to the installed production binary rather than a live
process image.

## Source state

- Repository: `C:\TW\ComTW\source`
- Branch: `playerbots-integration-gh`
- HEAD: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Date: `2026-08-25T15:22:11+01:00`
- Subject: `dc: load recorded routes at runtime, and raise the instance gate`

The four feature-relevant paths are byte-identical to their HEAD blobs; none is a
local modification:

- `src/game/World.cpp`
- `src/game/World.h`
- `src/mangosd/mangosd.conf.dist.in`
- `sql/logon/donation_point_progress.sql`

Introducing commits, all ancestors of HEAD:

1. `eb47ef5bb0cf08441e94eec24765754ce0ade80a`,
   `2026-07-28T10:10:26+01:00`,
   `Add world buffs, automatic donation points, and fix the donation shop`.
2. `65056948ccb52e7a96a623bff164d1abf87673b9`,
   `2026-07-28T11:38:02+01:00`,
   `Ship the config keys and SQL the fork features need`.
3. `df60a10712d1da359263ec752a26e0c147b55f1b`,
   `2026-08-10T17:53:56+01:00`,
   `Do not let a donation interval of zero flood the login database`.

The currently available Release build is a later, different executable
(`43EEB340...`, 20,421,632 bytes) and its PDB belongs to that later build. It is
not used as provenance for the production EXE. Production provenance is instead
bound directly by the embedded HEAD revision and feature-specific literals in
the exact production binary.
