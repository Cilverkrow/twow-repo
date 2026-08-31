# ADR-0028: Linux and Docker are the deployment platform; Windows is compile-only

- Status: Proposed
- Date: 2026-08-31
- Primary: WS-40 / WS-50
- Relates to: ADR-0019 (external Windows build inputs), ADR-0023 (containerization)

## Context

The project needs automated builds and a deployment target. Two questions had to be
settled: whether to keep Windows as a first-class runtime, and whether Wine could stand
in for a Windows CI runner.

Measured facts:

- The server is portable C++ with CMake. Only 28 of ~1,978 source files carry `_WIN32`
  guards. `INSTALL-LINUX.md` documents a running Debian 13 install (gcc 14.2, CMake 3.31,
  MariaDB 11.8, ACE 8.0.2, Boost 1.83), and a container built from those exact packages
  configures cleanly.
- `src/mangosd/CMakeLists.txt:33` adds `mangosd.rc` only under `if(WIN32)`; Linux links
  system `libmysqlclient` and OpenSSL rather than `dep/windows/lib`.
- `dep/windows/include` **is** tracked (168 MySQL header files), so Windows *compilation*
  works from a clean clone.
- `dep/windows/lib` does **not** exist in the repo, so Windows *linking* fails.
- `src/mangosd/mangosd.ico` does **not** exist, so the Windows resource compile fails.
  ADR-0019 pins it externally and states plainly: "A clone alone is intentionally
  insufficient for a Windows server build."

So a clean clone builds completely on Linux and cannot on Windows. Supporting Windows as
a deployment platform means carrying the ADR-0019 provisioning contract, the PowerShell
lifecycle scripts, console-title process control, and a second operational runbook — for
a platform the project does not need to deploy on.

## Decision

**Linux with Docker containers is the deployment platform.** All operational tooling,
CI gating, documentation and support target it.

**Windows is a compile target only.** It is kept because MSVC catches a class of errors
gcc and clang do not — the `M_PI` case documented in
`modules/mod-dungeon-clear/.github/workflows/windows-smoke.yml` is the forcing example —
and because contributors develop there.

Concretely:

- **CI Linux** is the complete gate: gcc and clang, full link, unit tests, integration
  tests, container build, smoke tests. Hermetic, works for pull requests from forks.
- **CI Windows** is a **compile-only** MSVC smoke job: Ninja generator, compile the
  object files, never link, never touch the `.rc`. It needs **no external inputs**, so it
  runs on every pull request including forks.
- **No Windows full-link CI job.** This was the only reason CI would have needed
  ADR-0019's pinned icon and import libraries, and dropping it removes that provisioning
  problem entirely.
- **No Wine.** Wine only helps when a Windows binary must run on Linux, which never
  applies because each target is compiled for itself. It cannot run MSVC meaningfully,
  so a Wine job would produce false confidence rather than coverage.
- **No Windows quality-of-life work.** `ops/windows/**` is retained as historical
  evidence and for the existing live server, but is not extended, not tested in CI, and
  not a support target. New operational tooling is written for Linux and containers only.

The release build baseline changes from `-march=native` to `-march=x86-64-v2`, exposed as
the `TW_ARCH` cache variable and skipped on non-x86 hosts. `native` bakes the build
host's exact CPU into the binary: correct for a hand-built server, fatal for a container
image.

## Consequences

- **Cuts scope substantially.** No provisioning of binary build inputs in CI, no
  PowerShell lifecycle library, no console-title process control, one deployment runbook
  instead of two.
- Several open items lose urgency or change shape. The graceful-shutdown-helper defect
  (WS40-001, LLM-007) is a Windows operations problem that the container entrypoint
  solves differently on Linux: a FIFO the server can always read, with SIGTERM translated
  into an in-game `saveall` plus `server shutdown 0`.
- ADR-0019 remains valid and unchanged for anyone doing a local Windows build; it simply
  stops being a CI concern.
- Windows link regressions are not caught at all. Accepted: nothing is deployed from a
  Windows build.
- Migrating the existing live Windows server to containers becomes a real task with a
  real cutover, not an incidental benefit. It needs its own plan.
- Removing `--no-warnings` will surface a backlog of existing warnings. Nothing is
  `-Werror`, so this is informational until triaged.

## Evidence

- `CMakeLists.txt` (`TW_ARCH`, build flags), `src/mangosd/CMakeLists.txt:33`
- `docs/adr/ADR-0019-external-windows-build-inputs.md`, `docs/BUILD-RESOURCES.md`
- `docs/FOOTGUNS.md` FG-071
- `INSTALL-LINUX.md`, `PLAYERBOTS_QUICKSTART.md`
- `deploy/docker/Dockerfile.core`, `deploy/docker/entrypoint-mangosd.sh`
- Verified container configure: CMake 3.31.6, gcc 14.2.0, ACE 8.0.2, Boost 1.83.0
