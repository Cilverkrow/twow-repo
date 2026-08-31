# OT-001-R1 Provenance-Aware Source Integration

Task: `OT-001-R1-PROVENANCE-AWARE-SOURCE-INTEGRATION`  
Mode: `AUTHORIZED_ISOLATED_REPOSITORY_SOURCE_INTEGRATION`  
Result: `PARTIAL`

## Provenance gates

The local hub preflight passed: the registry, global README and WS-10 README were read, and all 11 hub-manifest payloads matched. The repository main worktree was clean; `main` and `origin/main` both resolved to `f1f2e01026e54cd5c119c1e8e95fc107a01f4e2b` before the new worktree was created.

The complete external B-R2 package is valid: its 107-entry manifest has 107 present, matching payloads and SHA-256 `57856DED493FD744AC5BD51DA6307C0168872F8CBC04C949A23A75012F54068A`. Its ZIP is 66,319,254 bytes, has SHA-256 `D32453BE1F3283EFB3306E76F47E984CFB3228FB24AE814D04012C4B16C82088`, and contains 109 entries: 108 files, one directory and 107 internal-manifest payloads.

The GitHub projection is intentionally incomplete, not corrupt: its historical 107-record manifest has 66 present matching files and 41 omitted files (four artifacts, 36 evidence files and `racechange.log`). No omitted binary, PDB, log or external evidence file was copied into the repository.

The isolated baseline repository passed `git fsck`; only Git objects were used. Commit `42b8a7f742548793910fe8880463aeeb71627fb9`, tree `b2cf4e38fd288a53f61b9f2350f74caa85d606ab`, and parent `58d7bec64779d7c5a0e629e6e58633f04346bf1a` match. All 15 modified-path blobs bind to that tree and all 13 new paths are absent there. No Git object was imported into the target repository.

## Integration

The feature worktree is `C:\TW\worktrees\ot-001-r1-persistent-roster` on branch `work/ot-001-r1-persistent-roster-integration`, based on the verified main commit. Exactly 28 allowed paths are changed: 15 modified and 13 new. Twenty-five are byte-identical to their B-R2 source copy. Two test-only files were adjusted to require an explicit external OpenSSL dependency runtime, avoiding any dependency-binary copy into the worktree.

`src/modules/PlayerBots/CMakeLists.txt` was handled by controlled three-way integration. The apparent first conflict was solely mixed CRLF/LF source-copy representation. After canonical LF normalization, the merge was clean. The final file preserves main's existing `dep/include` addition and adds only B-R2's gated `persistent_active_roster_database_tests` target. No CMake file was blindly overwritten.

`WorldSession.cpp`, `Group.cpp`, LLM/Bridge/Ollama/Whisper/Persona files, active configuration and production source are unchanged.

## Tests and scans

Both fresh fake/unit test runs passed. The real C++ adapter executable was built from the integrated worktree and passed twice against separately started disposable MariaDB instances on loopback ports 13341 and 13342. Each run used a fresh datadir, applied the migration twice, ran the real adapter, rolled back, and verified zero remaining roster tables. Port 3307 was never used.

The final static scope gate passed: exactly 28 expected paths, zero unexpected/missing/forbidden paths, and `git diff --check` exit code zero. Secret and binary/oversize scans also passed.

## Clean-build blocker

The clean Release configuration succeeded, but candidate `mangosd.exe` was not produced. A direct build first failed from a duplicated caller environment key (`Path` and `PATH`). A subsequent sanitized build compiled PlayerBots but two build-owned MSBuild processes stopped making progress and never produced a candidate. After a documented timeout, only those two known isolated build processes were stopped; no server, database or Ollama process was controlled. The temporary dependency junction used solely for test/build resolution was verified and removed.

Because the required clean `Release/mangosd` build did not complete, this task cannot create a local feature commit. The exact uncommitted 28-file worktree state is retained without reset or cleanup.

## Production preservation

The production EXE and active configuration hashes remain unchanged: `mangosd.exe` `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`, `mangosd.conf` `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`, and `aiplayerbot.conf` `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF`.

