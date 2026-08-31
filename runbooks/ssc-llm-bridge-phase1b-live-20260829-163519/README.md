# SSC LLM Bridge — Phase 1B isolated live proof

`PHASE1B_LIVE_INFERENCE=PASS`

This directory is the complete evidence-bearing worktree for one approved live Ollama inference through the verified external Phase-1A bridge. The live workflow is complete. **Do not run `tools/phase1b-one-shot.mjs` again.** Its exclusive `evidence/phase1b-one-shot.guard.json` also prevents reuse.

## Immutable source chain

- `source-package/` contains the unchanged independently reviewed Phase-1A ZIP.
- `bridge/` is the 50-file extraction used for the run.
- Before execution, the ZIP size/SHA-256, safe entry set, embedded entry list, and all 49 self-excluding manifest hashes passed.
- After execution, the extracted payload still contains exactly those 50 files, all 49 manifest hashes pass, and its transient instance lock is absent.
- The original Phase-1A hardening directory passed a 52-file before/after comparison with zero differences.

## Evidence map

- `phase1b-report.md`: human-readable result and scope report.
- `evidence/bridge-transcript.json`: timestamped correlated controller/stdin/stdout/stderr transcript.
- `evidence/bridge-stdin.ndjson`, `bridge-stdout.ndjson`, `bridge-stderr.txt`: raw bridge streams.
- `evidence/request-envelope.json`, `completion-envelope.json`: exact request and delivered completion.
- `evidence/consume-first-response.json`, `consume-second-response.json`: consume-once proof.
- `evidence/metrics-before-shutdown.json`, `shutdown-response.json`: single-attempt and joined-worker proof.
- `evidence/boundary-observation-before.json`, `boundary-observation-after.json`: read-only listener/presence and cold/warm observations.
- `evidence/source-package-verification.json`, `extracted-payload-verification.json`: pre-execution package proofs.
- `evidence/phase1a-integrity-*.json`: immutable original Phase-1A before/after proof.
- `evidence/offline-verification.json`: independent post-run cross-check of all critical evidence.
- `evidence/action-audit.json`: explicit prohibited-action accounting.

The outer Phase-1B ZIP has a separate entry list and self-excluding SHA-256 manifest. Its own size and SHA-256 are recorded externally in `evidence/phase1b-package-evidence.json` to avoid circular self-hashing.
