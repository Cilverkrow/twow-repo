# dbcheck: expected-vs-actual checks of the world database

Tool for #437 under the tool principle of #409: general, data-driven, tested,
documented, maintainable across versions, usable locally and in a container.

**What it does.** It runs read-only SQL rules against the world database
(`tw_world`) and writes a report with a version and a hash. Two kinds of rule:

- **Self-consistency rules** need nothing but the database: quests without a
  starter or turn-in, broken quest chains, world bosses with loot that are
  never spawned, rare items no source provides.
- **Expected-list rules** compare the database with a *Soll-Liste* kept in
  Git (`expected/*.toml`): bosses that do not exist or are never spawned,
  loot items missing on the boss, loot items attached to an NPC outside the
  instance (a wrong loot id), quests with the wrong giver or turn-in.

**What it never does.**

- It never writes to a database. Every query must be a single `SELECT`
  (the tool refuses anything else, twice: when the rules load and again in the
  runner). Use a database user that has only `SELECT`.
- It never holds credentials. You give it a client command (`--mysql-cmd`).
- It never commits data from a reference site. Expected lists hold **ids,
  names and numbers only**, each with its source URL and date. No quotes, no
  lore, no images. Run it against a disposable database, never live: some rules
  join large tables.

Python 3.11+ **standard library only**, like `ops/clientpatch`.

## Contents

| Path | What |
|---|---|
| `dbcheck/` | the tool (a Python package, `python -m dbcheck`) |
| `bindings/<id>.toml` | logical names -> physical tables and columns of one schema |
| `rules/*.toml` | the SQL rules, written against the logical names |
| `expected/*.toml` | expected lists (Soll-Listen), one per instance or topic |
| `tests/` | unit and end-to-end tests on a **synthetic** mini database |
| `Dockerfile` | Python + the MariaDB command-line client |

## Run

Container (recommended). The database needs to be reachable from the
container; the example joins the network namespace of a disposable database
container and reads the password from the environment, not from the command
line:

    docker build -t twow-dbcheck ops/dbcheck
    export MYSQL_PWD=...                       # never on the command line
    docker run --rm --cpus=2 --name ob50-dbcheck-run \
        --network container:<db-container> -e MYSQL_PWD \
        -v "<work dir>:/out" twow-dbcheck run \
        --mysql-cmd "mariadb -h127.0.0.1 -u <read-only user> tw_world" --out /out

Without a container, any Python 3.11+ and a `mariadb` client will do:

    cd ops/dbcheck
    python -m dbcheck check                               # validate the configuration
    python -m dbcheck list-rules
    python -m dbcheck run --mysql-cmd "mariadb -u ro tw_world" --out ../../work/report

`--mysql-cmd` (or `DBCHECK_MYSQL`) is any command that reads SQL on stdin and
prints the answer in the client's batch format; `-B` is added when missing.
`docker exec -i <db> mariadb -u ro tw_world` works as well.

Options: `--only rule1,rule2`, `--expected <file or dir>` (repeatable),
`--max-rows N` (rows per finding in `report.md`; `report.json` has all).

**Exit codes.** `0` no `error` or `warn` findings (`info` never fails a run),
`1` findings, `2` configuration, schema or database problem.

## The report

`report.md` and `report.json`, plus `SHA256SUMS`. There is no timestamp, so the
same database and the same inputs give the same bytes and the same hash. The
header records the tool version, the binding (sha256), the schema fingerprint
and every expected file (sha256, source, date). Attach it to the issue; do not
commit it (`out/` and `work/` are ignored).

## Rules

| Rule | Scope | Severity | Finds |
|---|---|---|---|
| `quest_no_giver` | global | error | no creature, object or item starts the quest |
| `quest_no_ender` | global | error | no creature, object or area trigger completes it |
| `quest_chain_broken` | global | warn | prev, next or chain id names a missing quest |
| `boss_no_spawn_any` | global | warn | boss-rank creature with loot that is never spawned |
| `item_no_source` | global | info | rare+ item no loot, vendor or quest reward provides (crafted items appear: a lead, not a defect) |
| `quest_expected_missing` | quest | error | expected quest is not in the database |
| `quest_giver_mismatch`, `quest_ender_mismatch` | quest | error | expected giver or turn-in creature does not match |
| `boss_unknown` | boss | error | expected boss has no `creature_template` |
| `boss_no_spawn` | boss | error | expected boss is never spawned (`spawn_optional = true` skips this) |
| `boss_loot_missing` | boss | error | expected item exists but the boss does not drop it (direct rows and reference groups) |
| `boss_loot_item_unknown` | boss | error | no item has the expected name |
| `loot_foreign` | boss | warn | expected item is attached to an NPC outside the instance: the wrong-loot-id case |
| `boss_loot_extra` | boss | info | boss drops an item the list does not name |

Items are matched **by name** (case-insensitive), because that is what a wiki
gives you. Two items with one name are treated as one: the rule passes if any
of them is in the loot.

## Expected lists

    [instance]
    id = "tower-of-karazhan"
    name = "Tower of Karazhan"
    source = "<URL>"            # required
    source_date = "2026-09-29"  # required
    allow_elsewhere = []        # optional: items that may drop from other NPCs

    [[boss]]
    entry = 61939               # creature_template.entry
    name = "Keeper Gnarlmoon"
    spawn_optional = false      # true for summoned bosses
    loot = ["Item name", "Other item"]

    [[quest]]
    entry = 42023
    title = "Guile of Nature"
    giver = 62631               # optional creature entry
    ender = 62631               # optional creature entry

Rules of the road: ids, names and numbers only; the source and date on every
file; a list that only exists in someone's memory does not go in.

## Extend

- **A new rule.** Add a `[rule.<name>]` to a file in `rules/`. Write it
  against logical names: `{creature_template}` is the table,
  `{creature_template.loot_id}` a column, `{const.boss_rank}` a constant,
  `{%boss_loot_items}` a macro from `[macro]`, `{@entry}`/`{@names}`/... the
  values of the current expected boss or quest. Add a case to
  `tests/test_rules.py` (one row that must be found, one that must not).
  Write portable SQL: the tests run it on SQLite, production on MariaDB
  (`SELECT ... FROM (SELECT 1) d`, not `SELECT ... WHERE`; never `NOT IN (NULL)`).
- **Another schema or a renamed column.** Copy `bindings/tw-world.toml`,
  change the physical names, pass `--binding`. The rules stay.
- **Another topic.** Add an `expected/<topic>.toml`.

## Limits

- A rule sees the tables it is bound to. Behaviour in scripts (Eluna, C++
  AI) is invisible: a boss with `spawn_optional = false` that is summoned by a
  script is reported, and the list must say so.
- The check for items and bosses is presence, not balance: it says nothing
  about drop chances or stats.
- Schema drift stops the run with a clear error (`SchemaError`, exit 2) and
  names the missing tables or columns.
- The binding fingerprint covers the bound columns only, not the whole schema.

## Tests

    docker run --rm --cpus=2 -v "<repo>:/src:ro" -w /src/ops/dbcheck \
        -e PYTHONDONTWRITEBYTECODE=1 python:3.12-slim-trixie \
        python3 -m unittest discover -s tests

The tests use an in-memory SQLite database built from the binding with
invented data (`tests/synth.py`), and a stand-in client command for the
runner. They need no server and no game data.
