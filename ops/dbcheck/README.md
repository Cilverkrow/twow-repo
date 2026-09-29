# dbcheck: expected-vs-actual checks of the world database

Tool for #437 under the tool principle of #409: general, data-driven, tested,
documented, maintainable across versions, usable locally and in a container.

**What it does.** It runs read-only SQL rules against the world database
(`tw_world`) and writes a report with a version and a hash. Two kinds of rule:

- **Self-consistency rules** need nothing but the database: quests without a
  starter or turn-in, broken quest chains, givers and bosses that are never
  spawned, rare items no source provides.
- **Expected-list rules** compare the database with a *Soll-Liste* kept in
  Git (`expected/*.toml`): bosses that do not exist, are never spawned or have
  the wrong rank, loot items missing on the boss, loot items attached to an NPC
  outside the instance (a wrong loot id), quests with the wrong giver or turn-in.

**What it never does.**

- It never writes to a database. Every query must be a single `SELECT` (or a
  `WITH ... SELECT`); the tool refuses anything else, twice: when the rules load
  and again in the runner.
- It never holds credentials. You give it a client command (`--mysql-cmd`).
- It never commits data from a reference site. Expected lists hold **ids,
  names and numbers only**, each with its source URL and date. No quotes, no
  lore, no images.
- It refuses to run against a real database unless you say so: see "Guards".

Python 3.11+ **standard library only**, like `ops/clientpatch`.

## Contents

| Path | What |
|---|---|
| `dbcheck/` | the tool (a Python package, `python -m dbcheck`) |
| `bindings/<id>.toml` | logical names -> physical tables and columns of one schema, plus constants |
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
        -v "<work dir>:/out" twow-dbcheck run --disposable \
        --mysql-cmd "mariadb -h127.0.0.1 -u <read-only user> tw_world" --out /out

Without a container, any Python 3.11+ and a `mariadb` client will do:

    cd ops/dbcheck
    python -m dbcheck check                               # validate the configuration, no database
    python -m dbcheck list-rules
    python -m dbcheck run --disposable --mysql-cmd "mariadb -u ro tw_world" --out ../../work/report

`--mysql-cmd` (or `DBCHECK_MYSQL`) is any command that reads SQL on stdin and
prints the answer in the client's batch format; `-B` is added when missing.
`docker exec -i <db> mariadb -u ro tw_world` works as well. Progress (one line
per query with its time) goes to stderr.

Options: `--only rule1,rule2`, `--expected <file or dir>` (repeatable),
`--max-rows N` (rows per finding in `report.md`; `report.json` has all),
`--statement-seconds N`.

**Exit codes.** `0` no `error` or `warn` findings (`info` never fails a run),
`1` findings, `2` configuration, schema or database problem.

## Guards (a run on the wrong database)

Some rules join large tables. A run on the live database could slow the world
thread, so the tool makes that hard to do by accident:

- `--disposable` is **required** with `--mysql-cmd`: you confirm the target is a
  copy. (SQLite test fixtures need no flag.)
- Before the first rule the tool reads the database user's privileges and
  **refuses** a user that holds anything beyond `SELECT` and `SHOW VIEW`
  (`--skip-grant-check` overrides, on your head).
- Every query runs with MariaDB `max_statement_time` (default 120 s,
  `--statement-seconds 0` turns it off), so one heavy rule cannot hold the server.
- Schema drift stops the run: if a bound table or column is missing the tool
  names it and exits with 2.

## The report

`report.md` and `report.json`, plus `SHA256SUMS`. There is no timestamp, so the
same database and the same inputs give the same bytes and the same hash. The
header records the tool version, the binding (sha256), the schema fingerprint
and every expected file (sha256, source, date). Attach it to the issue; do not
commit it (`out/` and `work/` are ignored).

## Rules

| Rule | Scope | Severity | Finds |
|---|---|---|---|
| `quest_no_giver` | global | error | nothing gives or starts the quest (creature, object, start item) |
| `quest_script_started` | global | warn | same, but `Method = 0`: normally started by a script; verify in code |
| `quest_no_ender` | global | error | no creature or object completes the quest (an area trigger is only the exploration goal) |
| `quest_giver_unspawned`, `quest_ender_unspawned` | global | warn | the giver or turn-in NPC has a template but no spawn (id, id2-4) |
| `quest_chain_broken` | global | warn | prev, next or chain id names a missing quest |
| `boss_no_spawn_any` | global | warn | boss-rank creature with loot, never spawned, not summoned by a database script or listed as `[[summoned_boss]]` |
| `item_no_source` | global | info | rare+ item no loot, vendor, quest reward or start item provides (crafted items appear: a lead, not a defect) |
| `reference_loot_nested` | global | info | reference loot groups that point at other groups (followed at any depth) |
| `quest_expected_missing` | quest | error | expected quest is not in the database |
| `quest_giver_mismatch`, `quest_ender_mismatch` | quest | error | expected giver or turn-in creature does not match |
| `boss_unknown` | boss | error | expected boss has no `creature_template` |
| `boss_no_spawn` | boss | error | expected boss is never spawned (`spawn_optional = true` skips this) |
| `boss_rank_mismatch` | boss | warn | `creature_template.rank` differs from the list |
| `boss_loot_missing` | boss | error | expected item exists but the boss does not drop it (direct rows and reference groups at any depth) |
| `boss_loot_item_unknown` | boss | error | no item has the expected name |
| `loot_foreign` | boss | warn | expected item is attached, directly or through a reference group, to an NPC outside the instance: the wrong-loot-id case |
| `boss_loot_extra` | boss | info | boss drops an item the list does not name |

What counts, and what does not:

- **Starter:** a creature or object giver row, or an item with `start_quest`.
  `NextQuestInChain` does **not** replace a giver: the follow-up offer only works
  when the turn-in NPC also has the quest in its own `creature_questrelation`.
- **Turn-in:** a creature or object turn-in row. `areatrigger_involvedrelation`
  is the exploration goal, not a turn-in.
- **Retired quests** are skipped by title. The patterns live in the binding
  (`quest_ignore_title_like`, a list of SQL `LIKE` patterns, for example
  `[CANCELLED]%`). Single quests go in an expected list as `[[scripted_quest]]`
  with a reason (`expected/quest-exceptions.toml`).
- Items are matched **by name** (case-insensitive), because that is what a wiki
  gives you. Two items with one name are treated as one: the rule passes if any
  of them is in the loot.

## Expected lists

    [instance]
    id = "tower-of-karazhan"
    name = "Tower of Karazhan"
    source = "<URL or a description of the snapshot>"   # required
    source_date = "2026-09-29"                          # required
    allow_elsewhere = []       # items that may drop from other NPCs (badges, shared crafting items)

    [[boss]]
    entry = 61939              # creature_template.entry
    name = "Keeper Gnarlmoon"
    rank = 3                   # optional: expected creature_template.rank
    spawn_optional = false     # true for bosses that are summoned
    loot = ["Item name", "Other item"]

    [[quest]]
    entry = 42023
    title = "Guile of Nature"
    giver = 62631              # optional creature entry
    ender = 62631              # optional creature entry

    [[scripted_quest]]         # started or turned in by a script, not by a giver row
    entry = 12345
    via = "eluna"              # script | event | eluna | ...  (required)
    starts = true              # skip the starter check (default true)
    ends = true                # skip the turn-in check (default true)
    note = "why"               # optional

    [[summoned_boss]]          # a script summons it: no spawn row on purpose
    entry = 11502
    via = "cpp"                # cpp | eluna | eventai | ...  (required)

Rules of the road: ids, names and numbers only; the source and date on every
file; a list that only exists in someone's memory does not go in. A list built
from our own database (`expected/timbermaw-hold.toml`) says so in its header:
it protects against regressions, it does not prove the data right.

## Extend

- **A new rule.** Add a `[rule.<name>]` to a file in `rules/`. Write it
  against logical names: `{creature_template}` is the table,
  `{creature_template.loot_id}` a column, `{const.boss_rank}` a constant,
  `{list.quest_ignore_title_like}` a list constant as a one-column table
  `pattern`, `{%boss_loot_cte}` a macro from `[macro]`, `{@entry}`/`{@names}`/...
  the values of the current expected boss or quest. Add a case to
  `tests/test_rules.py` (one row that must be found, one that must not).
  Write portable SQL: the tests run it on SQLite, production on MariaDB
  (`SELECT ... FROM (SELECT 1) d`, not `SELECT ... WHERE`; never `NOT IN (NULL)`;
  no `NOT IN (SELECT ...)` over big tables: MariaDB runs it row by row, use a
  `LEFT JOIN ... IS NULL` on a derived table, see `{%spawned_ids}`).
- **Another schema or a renamed column.** Copy `bindings/tw-world.toml`,
  change the physical names, pass `--binding`. The rules stay.
- **Another topic.** Add an `expected/<topic>.toml`.

## Limits

- A rule sees the tables it is bound to. Behaviour in scripts (Eluna, C++
  AI, EventAI) is invisible: name such quests and bosses in an expected list
  (`[[scripted_quest]]`, `[[summoned_boss]]`) or they are reported.
- The check for items and bosses is presence, not balance: it says nothing
  about drop chances or stats.
- `item_no_source` is the slowest rule (about a minute on the full world). Keep
  it to a disposable database.
- The binding fingerprint covers the bound columns only, not the whole schema.

## Tests

    docker run --rm --cpus=2 -v "<repo>:/src:ro" -w /src/ops/dbcheck \
        -e PYTHONDONTWRITEBYTECODE=1 python:3.12-slim-trixie \
        python3 -m unittest discover -s tests

The tests use an in-memory SQLite database built from the binding with
invented data (`tests/synth.py`), and a stand-in client command for the
runner and the guards. They need no server and no game data.
