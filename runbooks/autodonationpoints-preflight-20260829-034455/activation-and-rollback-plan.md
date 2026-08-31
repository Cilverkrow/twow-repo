# Proposed activation and rollback plan — DO NOT RUN

## Minimal config patch for the recommended conservative policy

The feature is already enabled in the current file. The minimal policy correction
is therefore only:

```diff
 AutoDonationPoints.Enable = 1
 AutoDonationPoints.IntervalMs = 3600000
-AutoDonationPoints.Amount = 100
+AutoDonationPoints.Amount = 1
 AutoDonationPoints.FlushIntervalMs = 300000
```

Do not apply this patch until the live LOGIN-schema gate passes and the targeted
backup is verified.

## Exact proposed SQL operation

Select `tw_logon` explicitly in the reviewed MariaDB client invocation and execute
the committed file bytes whose SHA-256 is
`EDD4D4BCD78AA8DA96179797C54B375477DBEA4DCA6CF06ECB3925F122248103`:

```sql
CREATE TABLE IF NOT EXISTS `donation_point_progress` (
  `account_id`     INT UNSIGNED NOT NULL PRIMARY KEY,
  `accumulated_ms` INT UNSIGNED NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Execute it only if the live preflight proves the table absent. If the table exists,
compare exact schema and abort on any drift rather than relying on `IF NOT EXISTS`.

## Controlled procedure

1. Require a clean maintenance window. Confirm mangosd and realmd stopped before
   backup. Start only the reviewed MariaDB instance for the live read-only gate.
2. Reverify production binary, config, SQL, client/server, launcher, and shutdown
   helper identities. Confirm LOGIN database is exactly `tw_logon`.
3. Create a timestamped, targeted logical backup of the complete `tw_logon`
   database with routines, triggers, events, hex blobs, and a consistent InnoDB
   snapshot. Do not place credentials in command history or evidence.
4. Verify dump exit code, nonzero reasonable size, SHA-256, and presence of
   `account` and `shop_coins` definitions/data and shop triggers. Preserve all
   existing `shop_coins` values.
5. Archive the exact current `mangosd.conf`; record size, hash, encoding, and ACL.
6. Run the live read-only schema gate. If the progress table is absent, execute
   only the committed DDL above. If present, execute no DDL.
7. Verify exact table definition, zero or reviewed row count, engine, charset,
   primary key, and account/shop schema. Abort on drift.
8. Apply only the selected config diff. Rehash the config and verify no unrelated
   bytes changed.
9. Start the Worldserver in the normal controlled path. Do not start realmd unless
   the test requires an actual client login and that start is separately approved.
10. Use one ordinary, non-GM, non-RNDBOT, non-DISCORD test account. Record only
    redacted/account-scoped before values. Do not grant starting credits.
11. Verify progress appears after the first flush and advances by elapsed online
    time. Confirm AFK is avoided during the functional test even though source
    semantics count it.
12. Remain online for one full selected interval. Require exactly one-point
    increase and a corresponding progress remainder. Verify no unrelated
    `shop_coins` values were changed.
13. For persistence, accumulate a partial interval, wait for a confirmed flush,
    perform controlled Worldserver shutdown, then controlled database shutdown.
    Restart and prove the same account resumes from the persisted remainder.
14. Stop cleanly and archive test logs and redacted query results. Do not leave
    realmd or the Worldserver running unless separately authorized.

## Rollback

1. Stop Worldserver first through the controlled helper; confirm it exited before
   stopping MariaDB.
2. Restore the archived config byte-for-byte and verify its original hash.
3. If only feature disablement is required, retain the harmless progress table and
   set `Enable=0` in a separately reviewed patch; do not touch `shop_coins`.
4. If database restoration is required, preserve the failed current LOGIN state,
   restore the verified full `tw_logon` dump during a cold maintenance window, and
   verify every table/trigger plus the exact pre-test `shop_coins` dataset hash.
5. Never compensate by manually decrementing balances. A verified database backup
   is the rollback authority.
6. Restart with the restored config, verify the feature disabled, then perform a
   final controlled stop and evidence check.

## Unresolved risks

- Current live schema is unknown because MariaDB is stopped.
- Current config enables a 100-point hourly grant while progress-table physical
  files appear absent. Do not start the Worldserver before resolving this gate.
- No logout/shutdown flush exists.
- Grant and progress reset are non-atomic and async outcomes are ignored.
- A synchronous first-seen progress query can stall the World thread.
- Bot exclusion relies on account naming, not an actual PlayerBot type check.
- GM and AFK sessions accrue.
- Integer inputs have inadequate validation and unsigned conversion hazards.
