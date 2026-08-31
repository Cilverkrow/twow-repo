# Smoke suite

Is the stack alive, and did it keep the bots?

These are POSIX shell scripts that talk to a **running compose stack**. They are
not CI-only: `.github/workflows/smoke.yml` runs exactly the same files with
exactly the same defaults, so a failure in CI reproduces locally with one
command.

## Running them

```sh
# bring the stack up first (deploy/compose)
docker compose -f deploy/compose/docker-compose.yml up -d

sh test/smoke/run-all.sh          # everything, in order, with a summary
sh test/smoke/30-bot-persistence.sh   # or one check on its own
```

Every script is standalone. `run-all.sh` only orders them and counts.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | PASS - the thing this script proves is true |
| `1` | FAIL - it is false |
| `77` | SKIP - it could not be proven here, and the reason is printed |

`run-all.sh` **fails when every check skipped**. A green run that tested nothing
is worse than a red one, because it gets believed.

## Configuration

All defaults are overridable by environment variable, so the suite works against
a stack on other ports, another host, or a differently named compose file.

| Variable | Default | |
|---|---|---|
| `TWOW_COMPOSE_FILE` | `deploy/compose/docker-compose.yml` | which stack |
| `TWOW_ENV_FILE` | `deploy/compose/.env` | passed to compose as `--env-file`; the compose file declares `DB_ROOT_PASSWORD` and `DB_PASSWORD` with `:?` and will not parse without it |
| `TWOW_DB_SERVICE` / `TWOW_WORLD_SERVICE` / `TWOW_REALM_SERVICE` | `db` / `mangosd` / `realmd` | service names |
| `TWOW_HOST` | `127.0.0.1` | where the published ports are |
| `TWOW_REALMD_PORT` / `TWOW_WORLD_PORT` | `3724` / `8090` | |
| `TWOW_DB_USER` / `TWOW_DB_PASSWORD` | `root` / `$DB_ROOT_PASSWORD` | falls back to `$MARIADB_ROOT_PASSWORD` |
| `TWOW_CHAR_SCHEMA` etc. | `tw_char`, `tw_world`, `tw_logon`, `tw_logs` | |
| `TWOW_FIFO` | `/opt/turtle/run/mangosd.in` | the console FIFO |
| `TWOW_DATA_DIR` | `/opt/turtle/data` | where the stack mounts client data inside the world container |
| `TWOW_CLIENT_DATA` | `auto` | `0`/`1` to override detection |
| `TWOW_STRICT_MIGRATION_HASHES` | `0` | `1` makes a `manual` ledger hash a failure instead of a warning |
| `TWOW_TIMEOUT` | `120` | seconds to wait for a restart |

## Client data

`dbc`, `maps`, `vmaps` and `mmaps` are extracted from a game client and are
never in an image or in Git (ADR-0023, ADR-0004). Without them the world server
cannot start, so every check that needs a running world **skips with an explicit
message** instead of passing. In CI that is normal and expected; on a developer
machine with data mounted, the same scripts run the full set.

Only `10-migrations.sh` and the realmd half of `00-ports.sh` need no client data.

## What each check proves

| Check | Proves | Needs client data |
|---|---|---|
| `00-ports.sh` | realmd accepts TCP on 3724; worldserver on 8090 | for the 8090 half |
| `10-migrations.sh` | all four schemas exist and every schema with migration files has a non-empty `migrations` ledger. Rows hashed with the literal `manual` are reported as a warning - see below | no |
| `20-console.sh` | the console FIFO exists **and is being read** - `server info` goes in, the answer appears in the log. This is the container failure the entrypoint exists to prevent (ADR-0023 blocker 3) | yes |
| `30-bot-persistence.sh` | **ADR-0024 invariant 1.** Records the roster, restarts the world server, requires identical GUIDs, names, levels, xp, money, inventory counts and the same roster version | yes |
| `40-shutdown.sh` | `docker stop` is a graceful in-game shutdown: exit code 0, the entrypoint's clean-shutdown line in the log, no character left flagged online, no rows lost | yes |

### On the `manual` migration hash

ADR-0024 invariant 3 and FG-033 say a ledger records real content hashes and
never the literal `manual`; it made 146 world migrations unverifiable (OPS-012).
`deploy/compose/db-init.sh` writes `manual` deliberately and argues its case in
its own header: `sql/base` is a mixed snapshot rather than "the first N
migrations applied", so there is no honest per-file digest to record, and the
tombstone is only safe while `Database.AutoUpdate.Enabled = 0`.

Both positions are defensible and a smoke script is the wrong place to settle
it. So the count is printed loudly on every run and fails only on request:

```sh
TWOW_STRICT_MIGRATION_HASHES=1 sh test/smoke/10-migrations.sh
```

### On `30-bot-persistence.sh`

This is the conformance test ADR-0024 names. It **fails rather than skips** when
the roster is empty, because "there were no bots to lose" is not evidence that
bots cannot be lost - and a same-sized but re-rolled cohort is exactly how
FG-044 stayed hidden. It compares member-by-member, not by count.

It restarts the world service and puts it back. So does `40-shutdown.sh`. Both
are safe to re-run, and neither touches the database except to read.
