# Playable Docker candidate attestation

Date: 2026-09-06
Primary workstream: WS-50 (Build and server operation)
Dependent workstream: WS-60 (Reference server and backups)
Result: PASS

## Scope

This text-only attestation records the final bounded acceptance result for the
task-local Docker candidate. It contains no raw logs, credentials, database
content, binaries, client data, or protected machine configuration.

```text
BUILD_PLAN
CHANGE_CLASS=docs-only
SMALLEST_SUFFICIENT_TARGET=text, link, manifest, secret, binary and diff checks
BUILD_REQUIRED=NO
REUSE_CANDIDATE=NONE
COMPATIBILITY=not applicable; no runtime artifact is executed by this change
REUSE_DECISION=NOT_APPLICABLE: documentation-only change
FULL_BUILD_REQUIRED=NO
FULL_BUILD_REASON=the change cannot affect build or runtime behaviour
EXPENSIVE_LANE=NONE
```

## Provenance

- Platform commit: `59fa82cf673ca416d60049154511baec87866e47`
- Core commit: `cfbc69ce8106637f898e698093336cb362f29b15`
- Runtime image digest:
  `sha256:f04e5478014fdbf581989cd5613e5723b94a9f87a7d4ef5857692d934980f230`

These identifiers describe the validated candidate, not the branch tip on which
this attestation is reviewed.

## Acceptance result

The Windows game client connected to the Docker candidate and passed every
observed stage:

| Gate | Result |
| --- | --- |
| Login | PASS |
| Realm selection | PASS |
| Character list | PASS |
| World entry | PASS |
| Error screen | NONE |

During the live smoke, one human player and all 50 persistent-roster bots were
online. No non-roster bot was online.

The same candidate had already completed two graceful lifecycle cycles and a
674-second stability observation before the final real-client smoke. The final
controlled logout was observed, `saveall` completed through the supported
console path, and the world and authentication services exited cleanly with
exit code 0. The database service remained healthy for the backup checkpoint.

## Persistent roster identity

- Roster version: `1`
- Members: `50`
- Operation: `7c84fbfb-20ae-4f5a-a503-835e5e204c74`
- Ordered-set hash:
  `FF04A9D83DFA9B955BB0008AB355F1D502DF722E8C60EACEBDECB1C6364270CE`
- Canonical snapshot hash:
  `39A5849380115CCB176EC3ED34F2073F3D7275232B42633012D6D89CE9137860`
- GUID `4002`: included
- GUID `2951`: excluded

The Core character-name validator was not changed. GUID `2951` was correctly
rejected as `CHAR_NAME_PROFANE` and was replaced by GUID `4002`, whose name
passed the exact existing validator. This attestation makes no claim of a code
fix.

## Security and exclusions

The task-local raw server-log volume is deliberately excluded from the golden
backup. The temporary account-create command may have recorded a disposable
credential there. Credential rotation and bounded log sanitization are required
before any future archival of that log volume. Neither the credential nor raw
log content is reproduced here.

The golden dump, its restore result, and the no-rebuild continuity contract are
recorded in the [WS-60 golden-state record](../../WS-60-referenzserver-backups/ws60-rndbot-50-playable-golden-state-20260906/GOLDEN-STATE.md).

## Tracker retirement

This evidence completes
[OPS-021 / issue #177](https://github.com/Cilverkrow/twow-repo/issues/177).
The issue manifest is retired as `done`; the pull request carrying this
attestation uses `Fixes #177` so closure occurs only when the reviewed change is
merged.

Issue #2 is owned by another agent. Its historical cohort hashes are superseded
by the version-1 roster identifiers above, but closing or rewriting that issue
requires follow-up by its owner. This change does not mutate issue #2.
