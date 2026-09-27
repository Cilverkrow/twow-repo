# Talent reset per class and path (twow-repo#366, #357)

After a deploy that changes a class's premade links or adds path auras (OB-10 SpecAura and
premade trims, #357), the roster bots on those paths have to re-learn their talents. Otherwise
they keep their full old talents and also get the new auras. The tool sets
`at_login |= 4` (AT_LOGIN_RESET_TALENTS) for every member of the **current roster version** of
one class whose `specNo` event is in a list.

Nothing else changes: level, XP, money, position, items, spells, the specNo and profession
events all stay. The operation is idempotent.

| File | Content |
|---|---|
| `talent-reset.sql` | target list, 4 guards before the mutation, 4 asserts afterwards |
| `run-talent-reset.sh` | wrapper: `--dry-run` (read-only) and `--apply` with the count and hash of the dry run |
| `test-talent-reset.sh` | disposable-DB matrix (13 checks) |

## Use (world stopped)

```sh
# 1. read-only: count, GUID hash and ordinals of the targets
bash run-talent-reset.sh --container $C --class 7 --spec-nos 2,4 --conf $CONF --dry-run
#    -> TARGETS=<n> GUID_SHA256=<h> ORDINALS=...
# 2. apply exactly that set
bash run-talent-reset.sh --container $C --class 7 --spec-nos 2,4 --expected <n> \
    --expect-guid-sha256 <h> --conf $CONF --apply
#    -> RESULT=PASS guards=4 asserts_pass=4
```

- **Shaman after train 7:** `--class 7 --spec-nos 2,4`, for 7.1 enhancement (specNo 2) and 7.3
  shaman tank (specNo 4).
- **Rogue later:** `--class 4 --spec-nos <the affected paths>`.

**Guards** (a failure changes nothing):
- target count and GUID hash as in the dry run, count > 0;
- all targets offline;
- all targets on rndbot accounts.

**Asserts:**
- all targets carry bit 4;
- the targets are otherwise unchanged (name, level, XP, money, position);
- every other character is unchanged, including every player and every other bot, with
  `at_login` included in the comparison;
- the event table is unchanged.

## Evidence

Disposable DB `ob40-334-reset-dryrun` (`--network none`), 2026-09-27: matrix **13/13 PASS**.
- Dry run read-only; the count matches an independent query.
- An apply without a hash is refused; a wrong hash or an online target → guard abort, nothing
  changed.
- Apply PASS; exactly the targets carry the bit; a repeat is idempotent.

Evidence: `evidence\ws-60\ob40-366-probe-w1\talent-reset-test\matrix.txt`.
