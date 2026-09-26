# Roster rename (twow-repo#366 A5)

Renames roster bots from an **owner-approved** mapping, e.g. the creative names for the
new ordinals 137–272 of the expansion. Run only in a maintenance window with the world
server stopped, from a merge commit, after a cold backup.

```bash
deploy/roster/rename/run-rename-roster.sh --container <db-container> \
    --map name-draft.tsv --expect-map-sha256 <approved sha256> --expected 136 \
    [--conf <runtime mangosd.conf>] --apply
```

Mapping: tab-separated, no header, `ordinal guid old_name race class gender new_name`
(the format of the name draft in #366). Its SHA-256 must be the approved one.

## Safety model

`characters` is MyISAM and `characters.name` has **no unique index** (`idx_name` is
non-unique), so the database would accept duplicates. Nine guards run before the only
`UPDATE` and abort through a `CHECK` violation:

- exact row count, unique GUIDs; every row is a member of the **active roster version at
  the given ordinal**; all offline; all on `RNDBOT%` accounts;
- the current name is the listed old name (a stale list aborts) or already the new name
  (so a second run is harmless: `RENAMED=0 ALREADY=n`);
- new names: client format `^[A-Z][a-z]{1,11}$`, no letter three times in a row, unique
  within the list, not used by any other character, and not in `ai_playerbot_names` (the
  pool random bots draw names from).

Comparisons use the column collation (`utf8mb3_general_ci`), i.e. case-insensitively,
like the server. Four asserts afterwards: all rows carry the new name, changed + already
= rows, every other character's name unchanged (CRC), no duplicates.

**Rollback:** the original bot names come from `ai_playerbot_names`, so a reverse mapping
is refused by the pool guard by design. Undoing a rename means the cold backup.

## Test

`test-rename-roster.sh --container <disposable-db> --ordinals A-B` builds letters-only test
names for those ordinals and runs: wrong mapping hash, non-letter name, name taken by
another character, stale old name, bot online (each: abort, names unchanged), rename,
repeat (idempotent), and restores the original names. It refuses containers that are not
labelled `twow.purpose=*disposable*`.
