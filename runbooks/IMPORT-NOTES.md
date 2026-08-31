# Runbook import notes

This directory is a curated, text-only copy of the local runbook history from `C:\TW\ComTW\runbooks`, plus safe text evidence from `C:\TW\evidence` under `external-evidence`.

It is not a byte-complete backup. The live runbook tree remains the authoritative source for payload packages and restricted evidence.

## Included

- Markdown reports, handoffs, plans, and decisions.
- JSON/JSONL/NDJSON metadata and redacted evidence that passed secret scanning.
- PowerShell, batch, JavaScript, SQL, C/C++, patch, diff, CSV, and TSV text artifacts.
- The canonical collaboration hub and its manifests, stored without line-ending conversion.

## Excluded

- Executables, libraries, symbols, object files, archives, database files, game/client assets, Base64 packages, PID files, and build output.
- The 17 MB `world-shutdown-smoke-evidence-20260828-160724-135/server.log.appended.txt` runtime log.
- Nine JSON evidence files flagged by Gitleaks for possible API-key values.
- `playerbot-discovery-matrix-preflight-02-20260830-173815/active-config-relevant-lines.csv`.
- `ssc-source-baseline-02a2-20260829-213222/evidence/source-excerpts.txt`.
- `ssc-source-baseline-01-20260829-193848/evidence/database-readonly-query-attempt.json`.

The last three files were excluded conservatively because they contain connection- or password-related context. No excluded source file was modified or deleted from the live workspace.
