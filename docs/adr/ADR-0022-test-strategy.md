# ADR-0022: Test strategy

- Status: Proposed; amended 2026-09-02 (stale bot-tree paths; CI file corrected)
- Date: 2026-09-01
- Primary: WS-10 / WS-50
- Relates to: ADR-0024 (invariants 1 and 4), ADR-0021 (module boundaries), ADR-0023 (containerization)

## Context

The project has no automated verification. Measured:

- No `enable_testing()`, no `include(CTest)`, no `add_test()` anywhere in the tree.
  Nothing is runnable as a suite.
- Two disconnected C++ suites exist, neither reachable from a plain build:
  - `modules/mod-dungeon-clear/t/` — 54 gtest files, ~900 KB. googletest is never
    fetched, and both `src/test/mocks/TestMap.cpp` and the `game-interface` target it
    links against **do not exist**.
  - the vendored bot tree's `tests/` directory, added by commit `3c2b931` (then under
    `src/modules/`, now `modules/mod-playerbots/tests/`). Two targets, wired
    differently. `persistent_active_roster_database_tests` *is* in the main build behind
    the root option `BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS` (default OFF): 48 assertions
    plus a real multi-threaded concurrency scenario against a disposable MariaDB.
    `persistent_active_roster_tests` (7 functions, 142 assertions) is **not wired in at
    all** — a standalone `project()` with no `add_subdirectory`, hard-requiring an
    external `ROSTER_TEST_OPENSSL_LIBRARY` import library, unconditionally adding
    `dep/windows/include` (which shadows system OpenSSL headers on Linux), driven by
    `run-tests.ps1` with hardcoded Windows paths and the VS 2022 generator.
- Neither suite uses a framework: both are hand-rolled `CHECK` macros counting failures.
- Everything else the repository calls a "test" is a Windows PowerShell evidence script
  under `runbooks/`.

`3c2b931` is the tested OT-001 baseline and must not be rewritten (`TODOS.md` guardrail,
FG-072).

## Decision

Five levels, all registered with CTest, all runnable from a clean clone.

| Level | Scope | Mechanism |
|---|---|---|
| Unit | module logic, hook behaviour, config parsing — no DB, no server | C++ gtest via `ctest`; the bulk of coverage lives here |
| Characterization | proves an extracted feature behaves identically to the spliced original | written **before** each Phase 3 extraction, kept afterwards |
| Integration | migrations apply cleanly from empty; module tables land in the owning schema | compose-driven, ephemeral MariaDB |
| Smoke | is it alive | `make smoke`: ports, `migrations` row count, bot login, clean shutdown, **plus bot-persistence conformance** |
| Lint | everything non-compiling, incl. boundary and schema-ownership rules | `.github/workflows/ci.yml`, job `lint` |

Specifics:

- **`enable_testing()` / `include(CTest)` at the root.** googletest via `FetchContent`,
  **pinned by tag**, never floating.
- **Both existing suites are wired in and made cross-platform.** Create the missing
  `TestMap.cpp` mock and the `game-interface` target; add
  `add_subdirectory(modules/mod-playerbots/tests)` behind a new
  `BUILD_PERSISTENT_ROSTER_UNIT_TESTS` option and drop its standalone `project()`;
  replace the raw `ROSTER_TEST_OPENSSL_LIBRARY` filepath with
  `find_package(OpenSSL REQUIRED)` and `OpenSSL::Crypto`; **guard the
  `dep/windows/include` include directory** behind `WIN32`. The adapter suite is
  registered with `add_test()` only when a connection string is supplied, so `ctest`
  stays green without a database.
- **`3c2b931`'s test behaviour is preserved exactly.** Wiring, portability and
  registration changes only — no assertion is rewritten, reordered or removed. Its
  hand-rolled `CHECK` macros stay as they are; gtest is the framework for *new* tests.
- **The smoke suite enforces ADR-0024 invariant 1**: record the roster, restart the
  stack, assert identical GUIDs, item counts and progression. A bot lost is a failed
  build, not a report.
- **CI also builds and smoke-tests with every module disabled** (`-DMODULES=disabled`),
  enforcing invariant 4.
- Success criterion for Phase 0: `ctest` runs both existing suites on Linux and Windows
  from a clean clone.

## Consequences

- 190 existing roster assertions and 54 gtest files become CI coverage instead of dead
  code, at the cost of wiring rather than authoring.
- Characterization tests make Phase 3 extractions provably behaviour-preserving, and are
  the reason each extraction can be reviewed independently.
- Unpinning `dep/windows/include` on Linux is a prerequisite, not a nicety: unconditional,
  it shadows the system OpenSSL headers and the unit suite cannot build at all.
- Two test idioms coexist for a while (hand-rolled `CHECK` in the roster suite, gtest
  everywhere else). Accepted deliberately: converging them would rewrite the tested
  baseline.
- The adapter suite needs a real MariaDB, so full coverage is only reachable from the
  container stack — which ties this decision to ADR-0023 rather than making it optional.
- A defect found while surveying and to be fixed under this strategy:
  `PersistentActiveRoster.cpp:135-155` validates canonical admin requests differently per
  platform — the Windows branch checks UTF-8 **and** NFC normalization via
  `IsNormalizedString`, the POSIX branch checks only UTF-8 well-formedness. The same
  request is rejected on Windows and accepted on Linux, under a contract built on
  canonical bytes and SHA-256 digests. It needs one shared implementation and a test.

## Evidence

- `CMakeLists.txt` (no `enable_testing`), `modules/mod-dungeon-clear/t/`
- `modules/mod-playerbots/mod-playerbots.cmake`, `modules/mod-playerbots/tests.cmake`,
  `run-tests.ps1`
- `modules/mod-playerbots/src/playerbot/PersistentActiveRoster.{h,cpp}`
- Commit `3c2b931`; `docs/FOOTGUNS.md` FG-072
- `.github/workflows/ci.yml`, job `lint` (there is no standalone lint workflow file)
- `docs/issues/00-refactor-plan.md` (Phase 0 §3, Verification)
