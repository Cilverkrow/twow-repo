# OPS-001 read-only bot-population matrix — blocked capture

- Issue: `OPS-001` / GitHub issue `#23`
- Workstream: `WS-30`
- Capture time: `2026-09-01T11:09:28.535Z`
- Result: `BLOCKED`

## Confirmed state

The collaboration-hub preflight passed: the canonical registry, global hub README,
WS-30 README, and all 11 hub-manifest payloads were read and verified.

Immediately before the planned database capture, the host state was observed without
starting or stopping anything:

| Object | State |
|---|---|
| `mysqld` | stopped |
| `mariadbd` | stopped |
| TCP listener `3307` | absent |
| `mangosd` | stopped |
| `realmd` | stopped |

The issue authorizes a read-only capture, not process control. Starting MariaDB would
be a new mutation and is therefore outside this task. No credential was requested or
loaded, no database connection was attempted, and no SQL was executed.

## Semantic boundary

A MariaDB-only capture can prove the persisted RandomBot event rows, group membership,
account category, stored `characters.online` flags, and `specNo` distribution. It cannot
prove the in-memory `AddOfflineGroupBots()` runtime candidate set while `mangosd` is
stopped. The future capture must report these separately:

- `CURRENT_GROUP_LOGIN_CANDIDATE_COUNT`: distinct persisted eligible RNDBOT group
  members under an eligible non-RNDBOT leader;
- `DB_FLAG_ONLINE_GROUP_LOGIN_CANDIDATE_COUNT`: the subset implied by stored online
  flags;
- `RUNTIME_GROUP_LOGIN_CANDIDATE_COUNT=NOT_OBSERVABLE_SERVER_STOPPED`.

The runtime count must not be guessed as zero.

## Blocker and required continuation

OPS-001 remains open. A follow-up may run only after all of the following are explicit:

1. MariaDB is already running, or MariaDB-only start/stop is separately authorized;
2. the actual endpoint and schema names are confirmed (historical values are not proof);
3. an existing SELECT-only credential path is available without exposing a secret;
4. evidence-only file creation and read-only database access are authorized;
5. `mangosd` and `realmd` remain stopped and forbidden.

The prepared capture contract is in `READONLY-CAPTURE-PLAN.md`. Any schema mismatch,
duplicate event row, A/B drift, unexpected online flag, or changed DML/DDL counter must
fail closed.

## Mutations

No database, configuration, server process, production binary, hub metadata, or
`twow-core` file was changed. This directory is new task evidence only.
