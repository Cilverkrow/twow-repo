# OPS-001 read-only capture contract

This is a plan, not evidence that SQL ran. It deliberately excludes character names,
account names, account IDs, credentials, and free-form `data` values from output.

## Safety gates

- Use an existing principal limited to `USAGE`, `SELECT`, and `SHOW VIEW`.
- Put credentials only in an ACL-restricted ephemeral option file; never use `-p...`.
- Set the session read-only and statically reject any statement other than `SELECT`,
  `SHOW`, or session-local variable assignment.
- Prefer TLS. A no-TLS loopback retry is allowed only after reproducing and documenting
  the known client-side TLS negotiation failure; never weaken server policy.
- Capture relevant global DML/DDL counters before and after. Any increase blocks closure.
- Run deterministic A/B captures no more than 60 seconds apart; normalized projections
  must be byte-identical.

## Required projections

1. Capture UTC time and epoch in the session.
2. Fingerprint tables, columns, and indexes for the configured character/auth schemas:
   `ai_playerbot_random_bots`, `characters`, `group_member`, `groups`, and `account`.
3. Select `owner=0` events `add`, `login`, and `specNo`, ordered by event, bot, and row ID.
   Output only row ID, event, character GUID, value, time, validity, and computed
   effective-at-capture state.
4. Group by bot/event and block if any count differs from one. Duplicate `specNo` rows
   are non-deterministic under the current cache-loading contract.
5. Report `specNo` distribution by sanitized account category (`RNDBOT`, `NON_RNDBOT`,
   `MISSING_ACCOUNT`), class ID, and spec number.
6. Report RNDBOT stock with and without a stored `specNo` row.
7. Report sanitized group membership and summary counts. Include GUIDs, group IDs,
   account category, active/deleted state, and online flags, but no names or account IDs.
8. Report RNDBOT and group-leader/member online-flag counts. With both daemons stopped,
   any nonzero online flag is an anomaly and blocks strict closure.
9. Report missing group/member/leader references separately; do not silently discard them.

## Completion evidence

Create a new immutable WS-30 evidence directory containing the reviewed query, runner,
sanitized A/B projections, schema/counter gates, hashes, report, result block, and a
non-self-referential manifest. No prior runbook is overwritten.
