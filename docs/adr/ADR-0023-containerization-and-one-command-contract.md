# ADR-0023: Containerization and the one-command contract

- Status: Proposed; amended 2026-09-02 (stale bot-tree path corrected); **amended 2026-10-03** -- images are promoted, not rebuilt (owner-approved, #486; see amendment below)
- Date: 2026-09-01
- Primary: WS-40 / WS-50
- Relates to: ADR-0028 (Linux/Docker is the platform), ADR-0027 (MariaDB 11.8), ADR-0006 (graceful shutdown), ADR-0031 (tick budget, no lost bots)

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
  promoted between environments, never rebuilt per environment.** How: the tested CI
  image is the published one (amendment 2026-10-03 below).
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

## Amendment 2026-10-03: promote instead of rebuild (#486)

Owner decision 7 of 2026-10-03, relayed by OB-00 in #486 (comment 5962586221),
together with decisions 2b, 3b, 4, 10 and 13 of the same comment. Basis: the
Phase-A measurement and plan of #486 (evidence paths below).

**Why.** The decision above already said "built once, promoted, never rebuilt per
environment". That held *between environments*, but not *between test and
release*: `ci.yml` tested an image assembled from a staged install (`ci-staged`),
and `publish.yml` then compiled the same commit a second time, from source, into
`--target runtime`. So the binary that passed the smoke was never the binary that
shipped. The second compile cost ~58 min cold on every `main` push, because its
BuildKit cache mount does not survive an ephemeral runner. 68 successful publish
runs covered only 24 distinct core SHAs, so 65 % of them re-compiled a core that
had already been published. A hotfix took about 2 h from core merge to digest.

**Decision.** The image CI builds and tests on `main` is the image that is
published. Nothing is compiled a second time for publication.

1. **Promotion** lives in its own workflow, `.github/workflows/promote.yml`
   (decision 3b). It is triggered by `workflow_run` after the whole `ci.yml` run.
   A `workflow_run` workflow always runs from the default branch, whatever ref
   triggered the CI run, so **branch trust is enforced inside `promote.yml`**,
   not by the ref GitHub reports for the promote run. `promote.yml` acts only if
   all of these hold for the triggering run:
   - `workflow_run.path == '.github/workflows/ci.yml'`. `workflow_run` matches
     the triggering workflow by its `name:`, and any write collaborator can add a
     workflow named `ci` on another branch;
   - `workflow_run.event == 'push'`, `workflow_run.conclusion == 'success'` and
     `workflow_run.head_repository.full_name == 'Cilverkrow/twow-repo'`;
   - `workflow_run.head_sha` is the current `refs/heads/main` commit or an
     ancestor of it, checked through the API
     (`gh api repos/Cilverkrow/twow-repo/compare/<head_sha>...main`, status
     `identical` or `ahead`). The string `workflow_run.head_branch == main` is
     **not** sufficient: for a tag push it holds the tag name, so a tag named
     `main` would satisfy it.

   It pushes the tested CI
   image under `sha-<40>` to `ghcr.io/cilverkrow/{mangosd,realmd}`, signs it with
   `actions/attest-build-provenance` plus an SBOM attestation, and writes
   `publish-digest.json`. Before pushing it re-checks the core gitlink trust,
   the OCI labels (`revision`, `source`, `version`, `io.twow.core.revision`)
   and the tree comparison with the tested pin-PR merge ref. A permissions-
   bearing job therefore does not live in a file with a `pull_request` trigger.
2. **`publish.yml` becomes a fallback.** A `v*` tag retags the promoted digest of
   the tagged `main` commit (`docker buildx imagetools create`), with no compile.
   A build from source runs only by `workflow_dispatch` behind the environment
   `release-publish` (required reviewer: the owner). The db-init image and the
   Helm chart stay as they are. `nightly.yml` keeps building `--target runtime`
   from source as the proof that this target still builds.
3. **Debug symbols are split** (decision 2b): CI and the Dockerfile builder use
   the same build flags, symbols are separated with `objcopy --only-keep-debug` /
   `strip --strip-debug`, and they ship **only** as a separate artifact or OCI
   image (`mangosd-debug:sha-<40>`), never as a layer of the runtime image.
4. **Deploy rule** (decision 4): the digest is taken from the attestation subject
   or `publish-digest.json`, never resolved from a tag. Before the pull:
   `gh attestation verify oci://ghcr.io/cilverkrow/mangosd@<digest>
   --repo Cilverkrow/twow-repo --signer-workflow
   Cilverkrow/twow-repo/.github/workflows/promote.yml --source-ref refs/heads/main
   --deny-self-hosted-runners`. This check proves only "signed by the
   `promote.yml` of `main`, on a GitHub-hosted runner": because `promote.yml` is
   a `workflow_run` workflow, every attestation it signs carries
   `refs/heads/main`, whichever ref triggered the CI run. It rejects copies of
   `promote.yml` run from other branches, but not a promote run that was fed a
   foreign CI run; that is what the filter in point 1 prevents. The deploy
   therefore also checks that the image label `org.opencontainers.image.revision`
   (equal to the attested `publish-digest.json` revision) is a commit on `main`:
   `gh api repos/Cilverkrow/twow-repo/compare/<revision>...main` gives
   `identical` or `ahead`. For the `v*` fallback the signer is
   `publish.yml` with `--source-ref refs/tags/v…` (a tag-push run, so there the
   ref is the triggering one). Release requires a green
   `main` build+test **and** either a tree identical to the tested pin-PR merge
   ref with a green pin-PR smoke, or a green `main` smoke. If the `main` smoke
   turns red later, the deploy is stopped or rolled back.
5. **No self-hosted runner** (decisions V3 and 10). A local runner is
   reconsidered only if the Phase-C measurement misses its target, and then only
   in a dedicated VM.
6. **Documented exception: local main-train build** (decision 13). In a main-train
   window, when the live server is stopped anyway (announced by OB-00), or on the
   explicit owner order "Server aus, lokal bauen" for an urgent hotfix, the image
   may be built on the host with 12-14 cores. It uses the same toolchain
   (`Dockerfile.core`, `--target runtime`), a named, CPU-capped
   `docker-container` buildx builder, BuildKit provenance `mode=max` and an SBOM,
   the publish labels plus `io.twow.build.origin=local-maintrain`, the tag
   `local-sha-<40>`, and a `local-digest.json`. It builds only a clean clone of
   `Cilverkrow/twow-repo` whose HEAD is on a freshly fetched `origin/main`. The tool is
   `ops/build/local-maintrain-image.sh`, the procedure is
   `docs/runbooks/local-maintrain-image-build.md`. Such an image has **no**
   GitHub attestation. It is deployed by digest after its BuildKit provenance,
   labels and digest have been checked, and it is recorded in #319 and #486.
   It is not a routine path. With the live server running, the 4-CPU rule for
   host builds is unchanged.

**Consequences.**

- One compile per build input on the platform side for publication (pin-PR CI
  and `main` CI). `publish.yml` compiles nothing on the normal path. Phase-A
  estimate: core merge to digest ~95-100 min for a hotfix instead of ~120 min,
  measured in Phase C.
- The released image is the tested one: smoke, provenance and SBOM describe the
  same bytes. The target size is ~100 MB instead of 1.06 GB, which also shortens
  the deploy pull on the live host.
- Crash analysis needs the matching debug artifact, matched by build-id. It is
  kept with the same retention as the image.
- The trust boundary has two parts. Rulesets protect `main`, `release/**` and
  `v*`, but anyone with write access can run a workflow from another branch and
  push signed images under the same package names, and lhns keeps write access
  (decision 12). (a) Branch trust lives **inside `promote.yml`**: the filter in
  point 1 (workflow path, push event, success, same repository, `head_sha`
  contained in `main` via the API). (b) The deploy runs the `gh attestation
  verify` above, which binds the image to the `promote.yml` of `main` on a
  GitHub-hosted runner, plus the revision-on-`main` check. Neither part is
  optional; `--source-ref refs/heads/main` alone cannot tell a promote of a
  foreign CI run from a genuine one.
- Owner settings (set by the owner himself, with admin bypass, decision 5)
  therefore also include: a tag ruleset that blocks creating tags other than
  `v*` (at least a tag named `main`), and `.github/workflows/promote.yml` under
  CODEOWNERS and the `main` ruleset.
- Workflow changes take effect only when they are in `main` **and** in the active
  core `release/*.x`.
- Implementation is the set of #486 Phase-B PRs (image flags and split debug,
  promote and publish fallback, runner policy). Until they are merged, the
  current `publish.yml` path stays in force.

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
- Amendment 2026-10-03: owner decisions in #486, comment 5962586221; Phase-A plan,
  measurements and critique under
  `Y:\backup twwow\workspace-relocation-20260902\evidence\ws-40\cli486-build-runner\phaseA-20261002\`
  (`final.md` sections 1-5, `facts.md`, `crit.md`); `publish.yml` cache and rebuild
  behaviour as of `origin/main` 048788cf
