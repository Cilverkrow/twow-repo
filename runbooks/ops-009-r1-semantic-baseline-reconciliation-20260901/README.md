# OPS-009-R1 semantic-baseline reconciliation evidence

- Task: `OPS-009-R1-SEMANTIC-BASELINE-RECONCILIATION-01`
- Decision: ADR-0038 (Accepted), informed by accepted ADRs 0034-0039
- Repository base: `refactor/modular-platform`
- Feature branch: `feat/ops-009-config-as-code`
- Starting head: `deff51474d08a11c10cf302741996e878a9a9e0e`
- GitHub issue: 31
- GitHub pull request: 140
- Scope: repository-only correction; no deployment or runtime mutation

## Preflight and reproduced finding

Repository identity, branch/head, clean worktree, collaboration-hub manifest,
accepted ADRs, open issue state and required `agent-codex` label, and open pull
request state were verified before mutation.

The reviewed candidate was compared with the verified sanitized project
configuration. The original finding reproduced exactly:

| Service | Differences | Not explicitly overlaid |
| --- | ---: | ---: |
| mangosd | 74 | 67 |
| realmd | 4 | 1 |
| aiplayerbot | 37 | 35 |
| Total | 115 | 103 |

One of the 103 raw non-overlay rows is the protected
`AiPlayerbot.LLMApiKey`; excluding that machine secret leaves the required 102
unclassified non-secret deviations. The old append renderer also produced 22
duplicate active keys: 14 in mangosd, 5 in realmd, and 3 in aiplayerbot.

## Sanitized semantic disposition

`config/canonical/compose/semantic-baseline.tsv` is the complete value-free
matrix. Every original service-key deviation has exactly one disposition:

| Disposition | Rows | Meaning |
| --- | ---: | --- |
| `KEEP` | 95 | Preserve the verified sanitized non-secret behaviour. |
| `INTENTIONAL_CHANGE` | 14 | Reviewed Compose path/parameter or accepted disabled-source change. |
| `DEPRECATED_OR_REMOVED` | 0 | No observed key was removed without repository evidence. |
| `MACHINE_SECRET` | 6 | Five database connection values and one PlayerBot LLM API key. |
| Total | 115 | Complete original difference set. |

All observed-only non-secret keys were corroborated by the repository source.
Gameplay and bot values were not inferred. Sanitized examples remain evidence,
not deployment input, and no personal secret or live configuration was copied
into Git.

## Corrected contract

The canonical overlays now contain all intended non-secret deviations. The
renderer replaces an existing key in place, inserts an absent supported key,
collapses reviewed template duplicates, and rejects any final document with a
duplicate active key or unresolved token. Connection and optional LLM secret
values enter only the private machine-overlay stage and remain absent from
tracked files and provenance.

Publication is explicitly file-by-file, with provenance last; it is not claimed
to be set-atomic. Missing, mixed, interrupted, drifted, or source-mismatched
sets fail closed in the verifier before Compose startup can consume them.

PlayerBot bounds are tested exactly at 3/7. LFT and LFT Bot Fill remain in the
mangosd/Core configuration and executable; no service or container was added.

## Verification contract

The repository-only synthetic test verifies matrix completeness and counts,
all KEEP values, global active-key uniqueness, exact bot bounds, token
resolution, credential exclusion from Git and provenance, Core-owned LFT Bot
Fill, deliberate drift rejection, incomplete- and mixed-generation rejection,
and byte-stable repeated rendering apart from `RENDERED_UTC`.

Shell syntax, diff hygiene, documentation links, targeted secret scanning, and
added-binary scanning are required before commit. This package records no
deployment result.

## Authorization boundary

No active configuration was changed. No server or database operation, process
control, deployment, or merge was performed. The earlier
`runbooks/ops-009-config-as-code-20260901/` package remains immutable
point-in-time evidence; this R1 package supersedes only its semantic-
completeness and append-renderer claims.
