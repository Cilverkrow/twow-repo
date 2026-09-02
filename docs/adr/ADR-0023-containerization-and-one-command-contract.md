# ADR-0023: Containerization and the one-command contract

- Status: Proposed; amended 2026-09-02 (stale bot-tree path corrected)
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

### A fifth blocker, found the first time CI actually ran the stack

Everything below was originally written against a stack that had never come up.
The `compose up + smoke` job is what proves the one-command contract, and it had
been *skipped* in every run since it was written — something upstream in the DAG
failed first each time — so its first real execution was also its first failure:
`twow-realmd-1 ... Restarting (1)`, with three copies of
`Could not find configuration file /opt/turtle/etc/realmd.conf` in the compose
log.

The file was there. `render-config.sh` writes it and the compose file mounts it
read-only at exactly that path. What was wrong is that the file was mode 600
owned by whichever account ran the render step (uid 1001 on the GitHub runner,
the developer's own uid on a workstation), while the container process was
`turtle` — a uid `useradd --system` picked at image build time, which nothing on
the host had ever heard of and which no host-side command had granted anything.
Mangos opens its config and, on any failure, prints that it could not *find* it:
a permission error wearing a missing-file message, which sends you looking for a
broken bind mount instead of a mode bit. The same trap applied to `mangosd.conf`
and `aiplayerbot.conf`; realmd was only the first container to hit it, because
it is the only one CI starts.

So the honest statement of the position before this ADR was amended: the
containerization work was sound, the one-command run described below did not
work as written, and no test had ever said so.

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
- **The container user and the rendered configs are a single contract.** `turtle`
  is uid **10001**, gid 10001, pinned in `Dockerfile.core`, and
  `render-config.sh` grants that uid read access to every file it renders. The
  uid has to be a fixed, known number precisely because host-side code must be
  able to name it before the container exists; 10001 sits above both Debian's
  system range and the 1000-1999 band that logins and CI runners occupy.
  Credentials stay off other accounts: the rendered directory is 0700, and
  within it the files stay 0600 with an ACL entry for uid 10001 (a file's owner
  may grant an ACL to a foreign uid without being root, which is what makes this
  work unprivileged for both the CI runner and a developer). Where ACLs are
  unavailable — a filesystem mounted without them, a host with no `setfacl` —
  the files fall back to 0644, still inside the 0700 directory, so nothing but
  root and the owner can reach them. World-readable password files were rejected
  as the fix; so was `chown`, which neither environment can perform.
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
- **Pinning the uid orphans an existing `server-logs` volume.** Docker takes a named
  volume's ownership from the image directory the first time it is mounted, so a volume
  created by an image whose `turtle` was uid 999 stays owned by 999 and uid 10001 cannot
  write logs into it. `docker volume rm twow_server-logs`, or `make clean`, is the fix and
  costs only logs. In practice this bites nobody yet, because the stack it would bite has
  never successfully come up.
- `deploy/helm/twow/values.yaml` still carries a `podSecurityContext` comment saying no
  `runAsUser` may be pinned because the image's uid is assigned at build time. That
  reasoning no longer holds — the uid is now a fixed 10001 and pinning it is safe. The
  chart never had the config-permission problem (its init container renders into an
  `emptyDir` inside the pod, so no host file is ever mounted), which is why nothing there
  is broken; the comment is simply out of date and should be corrected the next time the
  chart is touched.
- The one-command contract is now claimed on evidence rather than on construction. The
  standing rule this cost us: a job that has only ever been *skipped* has proved nothing,
  and a green pipeline containing one is not the same as a green pipeline.

## Evidence

- `deploy/docker/Dockerfile.core`, `deploy/docker/entrypoint-mangosd.sh`, `.dockerignore`
- `CMakeLists.txt:384` (`revision.h`), `:656` (`SYSCONFDIR`), `TW_ARCH` at `:66-70`, `:513`
- `modules/mod-playerbots/src/playerbot/PlayerbotAIConfig.h:16`
- `src/shared/Database/AutoUpdater.cpp` (`TW_STDIN_IS_TTY` guard around `std::getline`)
- `ops/windows/build/compile-tortoise-wow.ps1:49` (MariaDB 11.4.10 divergence)
- `Nescabir/tortoise-docker`; verified container toolchain: gcc 14.2.0, CMake 3.31.6,
  ACE 8.0.2, Boost 1.83.0 on Debian trixie
- Blocker 5: the `compose up + smoke` job's first non-skipped run — `twow-realmd-1 ...
  Restarting (1)` and three `Could not find configuration file
  /opt/turtle/etc/realmd.conf` lines in `smoke-logs/compose.log`
- Blocker 5, reproduced and fixed under Docker outside CI: with the rendered config at
  0600 owned by uid 1000, `/opt/turtle/bin/realmd -c /opt/turtle/etc/realmd.conf` prints
  exactly `Could not find configuration file /opt/turtle/etc/realmd.conf.`; with the same
  file at 0600 plus `setfacl -m u:10001:r`, the same binary parses it and proceeds to the
  database. The mode bits and the owner are identical in both runs — the ACL is the only
  difference, which is what identifies the failure as a permission one.
