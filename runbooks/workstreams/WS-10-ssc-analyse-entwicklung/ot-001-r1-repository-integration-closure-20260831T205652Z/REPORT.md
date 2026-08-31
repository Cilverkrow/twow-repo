# OT-001-R1 repository integration closure

Task: `OT-001-R1-REPOSITORY-INTEGRATION-CLOSURE`
Captured: `2026-08-31T20:56:52Z`
Result: `PASS`

## Outcome

The previously reviewed persistent-active-roster delta is now secured in Git and integrated into local `main`. Exactly 28 source paths were committed. The rebased commit has the same stable patch ID and the same 28 path blobs as the pre-rebase tested commit.

- Documentation/evidence parent: `f28d9abf415f91174114b20e11f21e9c659faaa0`
- Source integration commit: `3c2b93102d2106cc7c4f9170598b56de060b41d3`
- Source commit tree: `e9e77b09259590557ebd32c4234b7c4c419745ba`
- Stable patch ID: `acd6fb63b7ede8882c20422f9b903161f2cd33b6`
- Integrated paths: `28`

The source commit contains 15 modified and 13 new paths. It contains no binary build input or output. The feature worktree and local `main` both resolved to the source integration commit and were clean at local closure capture.

## Build recovery and proof

A fresh isolated Windows Release build completed successfully after the required external inputs were materialized temporarily:

- external `mangosd.ico`: 16,958 bytes, SHA-256 `0BF6E8E0DAB99D6E47E3DC3FFCB02820414CBA97BCF97A79BFF4C2AE59896D4A`;
- external compiled libraries: exposed through a verified temporary `dep/windows/lib` junction;
- toolchain: Visual Studio 2022 Build Tools, MSVC 19.44.35228, linker 14.44, CMake 4.4.2, Windows SDK 10.0.26100.0;
- environment: de-duplicated case-insensitively so only one `Path` key reached MSBuild;
- target: serial `Release/mangosd` from an isolated clean configure/build directory.

Candidate identities, retained only outside Git:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `mangosd.exe` | 20,504,576 | `CECD5968906CB65FCB302E54B7F6565069B40113F5E5322F6DCD5D90CC6843C3` |
| `mangosd.pdb` | 206,278,656 | `EB388D009FEB62EE372B88339CE4E7FA1944C59BB2D62CB4E48D24816B16061E` |

The PE header identifies an x64 Windows CUI image. The temporary icon and junction were removed after the build, and the external library source remained intact.

## Tests and gates

- Two fresh fake/unit runs against the final pre-commit worktree: `PASS` and `PASS`.
- Prior two real C++ adapter runs against separate disposable MariaDB datadirs: `PASS` and `PASS`, referenced from the immutable OT-001 integration evidence.
- Changed-path scope: exactly 28, no unexpected or forbidden paths.
- `git diff --check`: pass for the source patch.
- Strict secret-pattern scan: zero credential literals or key patterns.
- Binary and oversized-file scan: zero source findings.
- Rebase verification: 28/28 source blobs unchanged and stable patch ID unchanged.

## Boundaries preserved

No deployment, production database access, migration application, active configuration change, production executable replacement, process control, candidate start, bot login, game chat, Phase C, or live LLM activity occurred. The verified 50-GUID request remains unapplied. A repository commit is not a deployment authorization.

The immutable earlier integration and recovery evidence retains its historical `PARTIAL` result. This later closure records the separate successful resource/link recovery and Git integration without rewriting those files.
