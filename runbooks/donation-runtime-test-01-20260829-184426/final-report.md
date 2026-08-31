# DONATION-RUNTIME-TEST-01

## Result

`DONATION_RUNTIME_TEST_RESULT=FAIL`

`DONATION_RUNTIME_FUNCTIONAL_RESULT=PASS`

The AutoDonationPoints progress and persistence path passed every feature-specific check. The strict overall result is FAIL because one unrelated MariaDB error 1213 occurred in `ai_playerbot_random_bots` during the test window. The assignment's PASS criteria require no SQL errors during startup or operation, so this error cannot be omitted or reclassified as an overall pass.

## Verified prerequisites

- The complete `tw_logon` backup remained at 205,586 bytes with SHA-256 `40EF25844685305615DA1BC47D168E1048392118C1417B6D3B1BE6ACEB62AB02`.
- The migration evidence manifest remained at 429 bytes with SHA-256 `81C38E3FE83D56737D525E7F6E880BDB815FF47856C22F89DB522FE64B4FAC4C`.
- All five migration-evidence manifest entries matched.
- The approved migration source remained at 630 bytes with SHA-256 `EDD4D4BCD78AA8DA96179797C54B375477DBEA4DCA6CF06ECB3925F122248103`.
- The migration was not executed again.
- The approved configuration remained at 69,515 bytes with SHA-256 `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`.

## Functional observations

- The manifest-anchored migration baseline contained zero rows.
- A live read-only pre-login query also returned zero rows.
- Exactly one eligible real account was observed online; only its numeric account ID was recorded.
- Account 505 was first persisted at 298,887 ms.
- It increased to 598,900 ms, a persisted increase of 300,013 ms and therefore greater than the configured 300,000 ms flush interval.
- A later normal flush persisted 898,929 ms.
- After a controlled shutdown and a clean restart without logging in, a read-only query returned exactly one table row and `505|898929`.
- No write to `shop_coins` occurred for account 505 because the configured 3,600,000 ms award interval was not reached.
- No AutoDonationPoints, `donation_point_progress`, missing-table, missing-column, schema-version, or DDL error occurred.

Read-only client probes used local TCP to `127.0.0.1:3307`. The reviewed TLS-default invocation failed in the non-elevated inspection session with Windows Schannel `SEC_E_NO_CREDENTIALS`; subsequent probes used the ephemeral client option `--skip-ssl`. This changed no server setting, credential, configuration file, source file, or schema.

## Strict failure

At 2026-08-29 19:09:19, the server logged MariaDB error 1213 (`Deadlock found when trying to get lock; try restarting transaction`) for a DELETE against `ai_playerbot_random_bots`. It was unrelated to AutoDonationPoints and did not alter the verified donation progress value, but it violates the explicit no-SQL-errors PASS criterion.

Normal Worldserver activity changed ordinary runtime tables as expected. No unexpected change attributable to AutoDonationPoints was observed outside `donation_point_progress`; specifically, no `shop_coins` write occurred. An exhaustive equality comparison of every unrelated runtime table was not attempted because normal server operation necessarily modifies gameplay data.

## Shutdown and final state

Both Worldserver runs reached `Shutting down world...` and `Halting process...`. The final state contains zero MariaDB, mangosd, and realmd processes, zero matching running services, and no active entries on ports 3307, 3724, or 8090.

No manual INSERT, UPDATE, DELETE, DDL, dump import, migration rerun, configuration change, source change, or schema repair was performed by this test.
