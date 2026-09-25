# Live smoke (read-only)

`live-smoke.sh` checks the **live** Docker stack without changing it. It is the
routine check after a deploy and the acceptance check after a roster reset.
Do not point `test/smoke` at live: `40-shutdown.sh` stops the server and
`20-console.sh` writes to the console.

## What it reads, and nothing else

| Check | Source |
|---|---|
| `container.*`, `stable.*` | `docker inspect`: running, `RestartCount`, `StartedAt` unchanged over the window |
| `digest.*` | the running image's `RepoDigests` contain `TWOW_LIVE_EXPECT_DIGEST` |
| `port.realmd`, `port.world` | exactly one published binding for 3724/8090, and a TCP connect succeeds |
| `run.log`, `run.same` | the `server_<UTC>.log` of *this* container start, identified by name and first-line hash; replaced or truncated in the window = FAIL |
| `world.up`, `bot_brain.handshake`, `roster.loaded` | lines in that server log |
| `world.loop`, `bots.active` | the server log and `bot_events.csv` grow; bots logged events in the window |
| `roster.members`, `roster.online`, `roster.max_level` | SELECTs through the database container (optional, see below) |
| `triage.fatal`, `triage.unknown` | every error marker of the run classified by `error-triage.tsv` |

Log files are identified per run, not by byte offset, so a new server log per
start or truncated csv logs are a new run, not "indeterminate" (#36).

## Running it

```sh
TWOW_LIVE_PROJECT=ws50-roster-v6-136-dccbe71d \
TWOW_LIVE_EXPECT_DIGEST=sha256:5b7de622... \
ops/live/live-smoke.sh
```

Exit codes as in `test/smoke`: `0` PASS, `1` FAIL, `77` SKIP (reason printed).
All options are documented at the top of the script.

**Roster online / level distribution** needs the database. Pass a MariaDB option
file with a read-only user; it is streamed to the client on stdin and never
printed or put on a command line:

```sh
TWOW_LIVE_DB_CONTAINER=<db container> \
TWOW_LIVE_DB_DEFAULTS_FILE=/path/to/readonly.cnf \
TWOW_LIVE_MAX_LEVEL=1 \
ops/live/live-smoke.sh
```

Or, without any separate file, let it use the credentials of the live server
itself (owner approval 2026-09-25, #36: SELECT only, never in output):

```sh
TWOW_LIVE_DB_CONTAINER=<db container> \
TWOW_LIVE_DB_FROM_LIVE_CONF=1 \
TWOW_LIVE_MAX_LEVEL=1 \
ops/live/live-smoke.sh
```

It reads `CharacterDatabase.Info` from the `mangosd.conf` mounted into the live
`mangosd` container and pipes a `[client]` block built in memory to the client
(`--defaults-extra-file=/dev/stdin`): no file, no command-line argument, no
environment variable. `TWOW_LIVE_DB_FROM_CONF=<path>` does the same for a given
conf.

Without database access the verdict is `SKIP` (the online count cannot be
proven from logs); `TWOW_LIVE_REQUIRE_ROSTER=0` accepts that for a routine check.

## Error triage

`error-triage.tsv` classifies every marker as `fatal`, `known-data` (world-DB
integrity reports while loading), `known-runtime` (content after world-up) or
`known-bot` (a bot finding with an open issue). Anything else is `unknown` and
fails the smoke. Classify a new pattern only after looking at it, and give a
bot finding an issue first. `ops/live/live-smoke.sh --classify <server.log>`
runs the triage alone; `test/contract/live-smoke-triage.contract.sh` tests it.
