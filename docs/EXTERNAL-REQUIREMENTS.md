# What is required besides this repository

The repository intentionally cannot build, run, test, or deploy the complete private server by itself. This document names the missing classes of material without recording credentials or licensed game data.

## Capability matrix

| Goal | Required outside Git | Notes |
|---|---|---|
| Read/analyze source | Git client and a text/code toolchain | No runtime access is needed. Historical absolute paths are optional evidence only. |
| Build the server | Windows x64 build toolchain, CMake, Windows SDK, compiled dependencies, and every required resource input | A known-good evidence run used Visual Studio 2022, MSVC 19.44, CMake 4.4.2, Windows SDK 10.0.26100.0, and ACE/Boost from vcpkg. `mangosd.ico` and `dep/windows/lib` are pinned external prerequisites under [the build-resource contract](BUILD-RESOURCES.md); they must not be committed. |
| Run unit/integration tests | Build environment plus disposable test directories and, for DB adapter tests, an isolated MariaDB instance | Never point isolated adapter tests at the production datadir or port. |
| Run Worldserver/Realmd | Built `mangosd`/`realmd`, required runtime DLLs, extracted game data, active configs, and populated databases | None of the production binaries or data is committed. |
| Run the client | A legally obtained compatible TWoW client, client configuration, approved AddOns, and any separately managed patches | MPQs, cache, screenshots, and large client binaries remain outside Git. |
| Run the LLM bridge tests | Node.js 24 or newer and the exact extracted bridge payload | The known bridge uses no third-party npm install for its deterministic harness. |
| Run live LLM inference | The approved bridge package, Node runtime, loopback Ollama service, and pinned model | The verified model contract used `qwen2.5:7b` with an exact digest recorded in the runbook. Do not rely on the tag alone and do not auto-pull. |
| Deploy | A selected live target, verified backups, approved payload manifest, process ownership, credentials, and explicit authorization | The repository has no implicit deployment target. |
| Restore | Verified database/config/binary backups and a disposable restore proof | A backup file existing is not proof that it restores. |

## Server runtime assets

The operator must supply outside the repository:

- `mangosd` and `realmd` executables built from an approved source state;
- all required runtime DLLs;
- maps, vmaps, mmaps, DBC files, and other extracted client-derived server data;
- any Warden or platform modules required by the chosen runtime, where legally and operationally appropriate;
- writable log, crash-dump, cache, and temporary directories;
- a controlled service/process account and filesystem permissions;
- network/firewall configuration for the chosen local or private endpoints.

PDBs are optional for running but strongly recommended for private crash diagnosis. They are large binaries and are intentionally not stored in Git; keep their hash and CodeView identity with the matching executable.

The Windows resource icon is different from generated build output: it is an input referenced by source. The current repository intentionally does not supply it. A future build contract must either include a provenance- and license-reviewed tracked asset or name an immutable external file identity and staging procedure. Do not create a dummy icon or remove the resource reference merely to make a build pass.

## Evidence and runbooks

“Separate evidence” means that every task or revision receives its own immutable directory. It does not currently mean a separate Git repository. Relevant sanitized text reports, handoffs, matrices, scripts, and manifests are retained under `runbooks/`; excluded binaries, symbols, archives, raw logs, dumps, credentials, and private account data remain outside Git and are referenced only by safe identity metadata.

A later evidence-repository split is intentionally deferred until stable evidence IDs, link migration, access control, retention, synchronization, and secret-review rules exist. See [ADR-0018](adr/ADR-0018-runbook-evidence-retention-before-restructuring.md).

## Databases

The runtime needs a compatible MariaDB installation and populated logical schemas corresponding to login, world, characters, and logs. The captured local names were `tw_logon`, `tw_world`, `tw_char`, and `tw_logs`, but names, ports, users, and paths are environment configuration rather than repository constants.

Outside Git, maintain:

- database server binaries and an owned datadir;
- credentials delivered through a secret-safe mechanism;
- the current schema/data set;
- verified logical/physical backups and retention policy;
- enough storage for disposable restore and migration tests;
- a client invocation that can connect safely on the selected host.

The source includes migrations, not a current private database snapshot. Historic `manual` tracker values cannot reconstruct the exact bytes previously applied.

## Active configuration and secrets

Files under `config/examples` are sanitized examples. A real environment needs separately managed active versions of at least:

- Worldserver configuration;
- PlayerBot configuration;
- Realmserver configuration where applicable;
- database connection descriptors;
- network/realm addresses and ports;
- optional LLM enablement, package, model, and limit settings.

Do not store database passwords, API keys, access tokens, private hostnames, personal paths, or live account data in Git. Generate active configuration from reviewed templates plus a secret store or protected local input. Hash active files in deployment evidence without printing secret values.

## LLM runtime and package

The repository contains historical bridge source and tests under runbooks, but the production package is not installed by cloning. A live deployment needs:

1. a reviewed bridge payload built from the approved source;
2. outer package hash and root manifest verification by deployment tooling;
3. safe extraction into a new package root with no traversal, symlink, or reparse escape;
4. the pinned `bridge/src/cli.mjs`, config, personality file, and payload manifest;
5. Node.js 24+;
6. a loopback-only Ollama endpoint unless a new architecture decision says otherwise;
7. the exact allowed model and digest already present locally — no automatic pull or fallback;
8. bounded stdout/stderr pipes and an owned child-process lifecycle.

The Core must not receive Ollama credentials or database credentials. The validated production C++ adapter is not currently integrated into main `src/`; see OT-003 in [open threads](OPEN-THREADS.md).

## Client-side material

The private client workspace is separate. To reproduce client behavior, maintain an external manifest for:

- client version/build identity;
- executable and relevant patch hashes;
- `realmlist`/client configuration without private credentials;
- enabled AddOns and their versions;
- approved Lua/XML customizations;
- any required patch files;
- extraction source used to produce server maps/DBC/vmaps/mmaps.

Do not commit MPQs, cache, WDB contents, screenshots, or the whole game installation. The repository's `patches/` directory is not a complete client deployment.

## Backups and reference systems

The historical environment referenced a separate backup/reference location, but that path is host-specific and not portable. A new operator needs:

- an off-repository backup destination;
- access and retention rules;
- encryption policy where appropriate;
- manifests/hashes for configs, binaries, and database dumps;
- periodic disposable restore tests;
- a clearly identified reference server or snapshot, never used as an accidental write target.

Do not treat `runbooks/` as a backup of private databases, binaries, or client data; those payloads were deliberately excluded.

## Human and service access

Some actions require authority that cannot be encoded in the repository:

- GitHub credentials for the private project remote;
- Windows elevation for approved service, ACL, backup, or process operations;
- database administrative credentials for approved backup/migration work;
- local Worldserver console access for roster administration;
- access to the online project chats or archived local sessions when full conversational provenance is needed.

Possessing access does not authorize use. The task must still explicitly permit the mutation.

## Minimum post-clone bootstrap

Before claiming the environment is ready:

1. Read `AGENTS.md`, the collaboration hub, [open threads](OPEN-THREADS.md), and [footguns](FOOTGUNS.md).
2. Select a new build/work directory; do not point tools at a live workspace by accident.
3. Install and record the build toolchain and dependency versions.
4. Supply game-derived server data and runtime binaries outside Git.
5. Create active configuration from sanitized examples and protected secrets.
6. Provision or restore compatible databases and verify schema/migration state read-only.
7. Configure backup and disposable restore locations.
8. Build in isolation and record full provenance.
9. Run tests against disposable services only.
10. Obtain separate authorization before any deployment, active config change, database mutation, process control, or live inference.
