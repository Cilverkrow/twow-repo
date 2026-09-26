# 7-day measurement report — template (scaling gate Ä10)

Copy this file per run to `docs/measurements/<YYYY-MM-DD>-7day-<deploy>.md` and fill it in.
It is the evidence that has to exist before more than 136 bots may be active (local overlay §7,
Ä10): **≥ 7 days, 0 lost bots, tick latency within budget, plausible progress, no loops**,
followed by an individual owner approval. A green report is necessary, not sufficient.

Everything below is **read-only**: log files, `docker inspect`, and SELECTs. Nothing here
may restart, reconfigure or write to the live stack.

## 0. Thresholds (owner decision 2026-09-26, via OB-00)

| # | Decision | Value |
|---|---|---|
| D1 | Tick budget | **interim:** no logged `Update map system` > **3000 ms**, plus the **count of slow updates (> 100 ms) per day** as a trend. `perf.log` only records updates above `PerformanceLog.Slow*Update` (default 100 ms), so a real p99 cannot be computed from it. **Target p99 ≤ 1000 ms/day** becomes measurable with the tick statistics from #351, a prerequisite before scaling beyond 136 |
| D2 | Plausible progress | roster **median level rises every day until level 20**; no roster bot online **≥ 24 h without XP** |
| D3 | No loops | no bot with **≥ 10 deaths in one hour** at the same killer and place (≤ 30 yd); no bot with **≥ 5× `no destination`** as death reason per day |
| D4 | Snapshot collection | **OB-00 takes the daily snapshot** (csv/log copies plus the DB queries in section 3) to `Y:\backup twwow\workspace-relocation-20260902\evidence\ws-60\longrun-7d\<YYYY-MM-DD>\`. Needed because mangosd **truncates the csv logs on every start** (`ops/live/live-smoke.sh`, header) |

A changed threshold is a new owner decision and a change to this file, never an edit in a
filled-in report.

## 1. Run identity

| Field | Value |
|---|---|
| Window | `<start UTC>` → `<end UTC>` (≥ 7 × 24 h) |
| Start event | deploy of release train `<n>` (#319), announced in `<issue link>` |
| Compose project | `<ws50-roster-…>` (find it by label, never by a remembered name: `docker ps --filter label=com.docker.compose.service=mangosd`) |
| Image / digest | `<twow/core:…>` / `<sha256:…>` |
| Platform / core commit | `<twow-repo sha>` / `<twow-core sha>` |
| Runtime config | path + SHA-256 of `mangosd.conf`, `aiplayerbot.conf`, `mod_bot_brain.conf` |
| Roster | version `<n>`, `<n>` GUIDs, roster hash from `ai_playerbot_roster_version` |
| Restarts in window | `docker inspect -f '{{.RestartCount}} {{.State.StartedAt}}'` + list of `server_*.log` files in the window |

**A restart inside the window is recorded, not hidden.** Each restart starts a new server log
and truncates `bot_events.csv`, `deaths.csv`, `levelup.log`, `loot.log`; the daily snapshot
before it is the only copy of that data.

## 2. Gate table

| Gate | Metric | Source | Threshold | Result |
|---|---|---|---|---|
| G1 0 lost bots | roster GUIDs present in `characters`, roster version unchanged or changed only through an audited operation, no `SNAPSHOT_HASH_MISMATCH`/`INVALID_FAIL_CLOSED` in the server log | DB (3.1), server log | 0 lost, 0 invalid | |
| G2 tick budget | per day: max of `Update map system: <n>ms`, count of slow updates (> 100 ms); p99 once #351 exists | `perf.log` (slow updates only), later #351 | D1 | |
| G3 progress | roster level distribution per day, level-ups per day, bots without progress ≥ 24 h online | DB (3.2), `levelup.log` | D2 | |
| G4 no loops | deaths per bot and hour, repeated killer+position, `no destination` count | `deaths.csv` (3.4) | D3 | |
| G5 stability | server restarts, crashes (exit code ≠ 0, OOMKilled), MariaDB "marked as crashed" | `docker inspect`, `docker logs <db>` | 0 unplanned | |

Supporting metrics (reported, not gating): quest turn-ins (3.3), profession skills (3.3),
equipped item level (3.3), loot units (`loot.log`), BotBrain intents and handshake
(server log), active bots in a 60 s window (live smoke).

## 3. Daily snapshot (read-only)

Take once per day at a fixed UTC time and after any restart. Store under
`Y:\backup twwow\workspace-relocation-20260902\evidence\ws-60\longrun-7d\<YYYY-MM-DD>\` (D4) with `SHA256SUMS`:
copies of the csv/log files, `docker inspect` of the stack, and the query results below.
Credentials only in-process (runtime `mangosd.conf`, `MYSQL_PWD`), never printed.

All queries start with the active roster:

```sql
CREATE TEMPORARY TABLE t (guid INT UNSIGNED PRIMARY KEY)
SELECT rm.character_guid AS guid FROM ai_playerbot_roster_current rc
JOIN ai_playerbot_roster_member rm ON rm.version_id = rc.version_id
WHERE rc.singleton_id = 1;
```

### 3.1 Persistence (G1)

```sql
SELECT (SELECT version_id FROM ai_playerbot_roster_current WHERE singleton_id = 1) AS roster_version,
       (SELECT COUNT(*) FROM t) AS roster_guids,
       (SELECT COUNT(*) FROM characters c JOIN t USING (guid)) AS characters_present,
       (SELECT SUM(c.online) FROM characters c JOIN t USING (guid)) AS online;
```

### 3.2 Progress (G3)

```sql
SELECT c.level, COUNT(*) FROM characters c JOIN t USING (guid) GROUP BY c.level ORDER BY c.level;
SELECT c.guid, c.level, c.xp, c.totaltime FROM characters c JOIN t USING (guid) ORDER BY c.guid;
```

Day-over-day diff of the second query gives "no progress ≥ 24 h" (same level and XP while
`totaltime` grew).

### 3.3 Supporting metrics

```sql
-- quest turn-ins
SELECT COUNT(*) AS rewarded, COUNT(DISTINCT q.guid) AS bots
FROM character_queststatus q JOIN t USING (guid) WHERE q.rewarded = 1;
-- professions (primary + secondary skill ids)
SELECT s.skill, COUNT(*) AS bots, MAX(s.value) AS max_value
FROM character_skills s JOIN t USING (guid)
WHERE s.skill IN (129, 164, 165, 171, 182, 185, 186, 197, 202, 333, 356, 393)
GROUP BY s.skill;
-- equipped item level (slots 0-18)
SELECT ROUND(AVG(it.item_level), 1) AS avg_equipped_ilvl
FROM character_inventory ci JOIN t USING (guid)
JOIN tw_world.item_template it ON it.entry = ci.item_template
WHERE ci.bag = 0 AND ci.slot < 19;
```

### 3.4 Logs (G2, G4)

- `perf.log`: lines `YYYY-MM-DD HH:MM:SS Update map system: <n>ms`.
- `deaths.csv`: `time, name, class, level, …, killer, …, reason`.
- `levelup.log`: `… Character <name>:<guid> … reaches level <n>`.
- `bot_events.csv`: `time, name, action, position, …`.

## 4. Daily table

| Day | Date | Restarts | Roster present | Online | Median level | Level-ups | Slow updates (> 100 ms) | Max tick | Deaths | Loop hits | Quest turn-ins | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | | | /136 | | | | | | | | | |
| 2 | | | | | | | | | | | | |
| 3 | | | | | | | | | | | | |
| 4 | | | | | | | | | | | | |
| 5 | | | | | | | | | | | | |
| 6 | | | | | | | | | | | | |
| 7 | | | | | | | | | | | | |

## 5. Verdict

`GATE=PASS|FAIL|OPEN` with one line per gate. `OPEN` whenever a day's snapshot is missing or a restart
lost data that no snapshot covers. The report goes to OB-00; the scaling decision itself
is an individual owner approval (overlay §5).
