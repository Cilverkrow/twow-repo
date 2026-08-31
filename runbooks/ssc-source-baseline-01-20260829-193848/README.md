# SSC-SOURCE-BASELINE-01 evidence package

Final result: `STABLE_REVISION_RESULT=BLOCKED`.

Start with `stable-source-baseline-report.md`. The `evidence` directory contains the raw or normalized read-only captures used by the report. `SHA256SUMS.txt` covers every packaged file except itself.

Interpretation notes:

- `database-readonly-query-result.json` is the authoritative, correctly quoted database result. It records a finite connection refusal and no SQL execution. `database-readonly-query-attempt.json` is retained only as audit evidence of an earlier local argument-format error that printed client help and did not reach MariaDB.
- `integration-points-path-correction.json` supersedes the three entries marked `exists_at_head=false` in `integration-points.json`; the initial paths had extra directory components. All other entries remain valid.
- `exe-evidence.json` and `pdb-identity-verification.json` are the authoritative manual PE/CodeView/PDB inspection. The two `production-exe-*` text files record that `dumpbin.exe` was unavailable and are not negative evidence about the binary.
- SQL literals, account/database credentials, LLM endpoint and API key are excluded or redacted.
- The scripts under `tools` are the exact collection/audit scripts used during this gate. The evidence JSON/TXT files, report and manifest are the review artifacts; rerunning collection is not required to verify the ZIP.

No Phase 1B artifact or original source/config/database file is included or modified.
