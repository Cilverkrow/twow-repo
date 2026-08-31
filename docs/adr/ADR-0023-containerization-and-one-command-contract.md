# ADR-0023: Containerization and the one-command contract

- Status: Proposed
- Date: 2026-09-01
- Primary: WS-40 / WS-50
- Relates to: ADR-0028 (Linux/Docker is the platform), ADR-0027 (MariaDB 11.8), ADR-0006 (graceful shutdown)

## Context

The server could not be containerized as it stood. Four blockers were verified, not
assumed:

1. **`CMAKE_INSTALL_PREFIX` is compiled into the binary.** `CMakeLists.txt` defines
   `SYSCONFDIR="${CONF_DIR}/"` (line 656), consumed by `PlayerbotAIConfig.h:16`. A
   build-in-one-prefix, copy-to-another image silently ships a server whose playerbot
   config is never found — it starts, and has no bots.
2. **`-march=native`** baked the build host's exact CPU into the release binary: correct
   for a hand-built server, fatal for a portable image.
3. **`mangosd` exits on stdin EOF.** A container with no TTY shuts the world server down
   immediately.
4. **`AutoUpdater.cpp` blocked on `std::getline(std::cin, ...)`** when a migration failed,
   hanging a headless container forever instead of exiting non-zero.

Prior art exists and is directly reusable: `Nescabir/tortoise-docker` publishes images of
this same fork, using the same FIFO pattern for the console.

A container built from Debian trixie with gcc 14.2.0, CMake 3.31.6, ACE 8.0.2 and
Boost 1.83.0 configures and compiles this tree, and `realmd` links successfully.

## Decision

**The stack ships as containers, and the entry point is three commands.**

```
make up      # db, migrations, realmd, worldserver
make smoke   # all green, including bot persistence across a restart
make test    # unit + integration
```

Client data is the only manual prerequisite. `ops\*.ps1` mirrors the three on Windows.

Concretely:

- **`deploy/docker/Dockerfile.core`** — multi-stage Debian trixie, using the **same
  `CMAKE_INSTALL_PREFIX` in both stages**. This is the trap in blocker 1 and the reason
  the prefix is not a build argument to be varied per stage.
- **`TW_ARCH`**, defaulting to `x86-64-v2` and skipped on non-x86 hosts, replaces
  `-march=native` (blocker 2).
- **`deploy/docker/entrypoint-mangosd.sh`** holds a FIFO open read-write at
  `${PREFIX}/run/mangosd.in` so the server's console always has a reader (blocker 3), and
  translates `SIGTERM` into an in-game `saveall` followed by `server shutdown 0` — the
  container-native form of ADR-0006's graceful shutdown.
- The auto-updater's failure prompt is guarded by a TTY check, so a failed migration in a
  container logs and exits instead of blocking (blocker 4).
- **`deploy/compose/`** — `db`, `db-init`, `realmd`, `mangosd`, health checks on all four,
  a `dev` profile, and **MariaDB pinned to 11.8** per ADR-0027. Note the divergence to
  fix: `ops/windows/build/compile-tortoise-wow.ps1:49` pins 11.4.10.
- **Client data (`dbc`, `maps`, `vmaps`, `mmaps`) is never in an image** — legally and
  practically. It is volume-mounted. The extractors (`mapextractor`, `vmapextractor` +
  `vmap_assembler`, `MoveMapGen`) run from a `tools` profile against a mounted client;
  budget an hour or more for mmaps generation.
- **GHCR publishing** — `ghcr.io/cilverkrow/{mangosd,realmd,db-init}`, semver on release
  and commit SHA on `main`, with provenance attestation and an SBOM. **Built once,
  promoted between environments, never rebuilt per environment.**
- **Helm chart `deploy/helm/twow/`** — `mangosd` as a **StatefulSet** (one world server
  per realm, persistent volume for client data), `realmd` as a Deployment, MariaDB as a
  dependency chart or external, migrations as **pre-upgrade Jobs**, secrets via
  `existingSecret` only, and `values-dev.yaml` mirroring the compose file so the two
  cannot silently diverge. `helm lint` and `helm template` run in CI from the first
  commit; the chart is published to GHCR as an OCI artifact.

## Consequences

- The four blockers are fixed in the core build, so they also benefit non-container
  builds; blocker 1 in particular was a live footgun for any install-prefix change.
- `x86-64-v2` gives up host-specific vectorization. Acceptable: the image must run on
  more than one machine, and no measurement has shown the loss to matter here.
- The compose file becomes the contract for the Helm chart and the publish pipeline,
  which is why both can be built in parallel against a stub image before any module work
  finishes.
- Client data staying outside images means `make up` is not literally one command on a
  fresh machine — the extractor run is a documented, long, one-time prerequisite.
- **Known wart:** the build writes `revision.h` **into the source tree**
  (`CMakeLists.txt:384` configures to `${CMAKE_CURRENT_SOURCE_DIR}/src/shared/revision.h`),
  so a read-only source mount fails. The Dockerfile copies rather than mounts. Moving the
  generated header into the binary directory is an upstream-worthy fix, recorded here
  rather than done here.
- Migrating the existing live Windows server onto this stack is a real cutover with its
  own plan (ADR-0028), not a side effect of this decision.

## Evidence

- `deploy/docker/Dockerfile.core`, `deploy/docker/entrypoint-mangosd.sh`, `.dockerignore`
- `CMakeLists.txt:384` (`revision.h`), `:656` (`SYSCONFDIR`), `TW_ARCH` at `:66-70`, `:513`
- `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.h:16`
- `src/shared/Database/AutoUpdater.cpp` (`TW_STDIN_IS_TTY` guard around `std::getline`)
- `ops/windows/build/compile-tortoise-wow.ps1:49` (MariaDB 11.4.10 divergence)
- `Nescabir/tortoise-docker`; verified container toolchain: gcc 14.2.0, CMake 3.31.6,
  ACE 8.0.2, Boost 1.83.0 on Debian trixie
