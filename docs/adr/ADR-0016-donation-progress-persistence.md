# ADR-0016: Persist donation-point partial progress in `tw_logon`

- Status: Accepted and migrated
- Date: 2026-08-29
- Primary: WS-20 / WS-30

## Context

The AutoDonationPoints source reads and writes partial elapsed time, but the expected `tw_logon.donation_point_progress` table was initially missing. The first read could terminate the server through the database assertion path.

## Decision

Use the committed migration to create exactly:

```sql
donation_point_progress(
  account_id INT UNSIGNED PRIMARY KEY,
  accumulated_ms INT UNSIGNED NOT NULL DEFAULT 0
)
```

with InnoDB and utf8mb4 in `tw_logon`. The table persists partial interval progress across flushes and restarts. It is schema support, not an authorization to change the award amount or interval; those remain separately reviewed configuration policy.

Apply the migration only after exact schema preflight and a verified full `tw_logon` backup. Do not hand-invent the table, rewrite the code to hide the missing schema, or rerun the migration as a substitute for state verification.

## Consequences

- The source/schema contract is satisfied and partial progress survives restart.
- The migration passed and feature-specific persistence behavior passed.
- The broad runtime test remains strictly `FAIL` because an unrelated `ai_playerbot_random_bots` deadlock occurred during the window; this does not reverse the feature-specific result.
- Award amount, bot/GM/AFK eligibility, atomic grant semantics, and further hardening remain separate decisions.

## Evidence

- `runbooks/donation-point-migration-20260829-183829/migration-result.txt`
- `runbooks/donation-runtime-test-01-20260829-184426/final-report.md`
- `sql/logon/donation_point_progress.sql`
