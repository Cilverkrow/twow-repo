# Evidence index

Authoritative closure evidence:

- `REPORT.md`
- `RESULT.txt`
- `SOURCE-MATRIX.tsv`
- `TEST-MATRIX.tsv`
- `evidence/final-evidence-package.json`
- `evidence/static-gate-post-build.json`
- `evidence/disposable-db-test.json`
- `evidence/disposable-db-test.stdout.txt`
- `evidence/disposable-db-test.stderr.txt`
- `logs/tests-authoritative-run-1.log`
- `logs/tests-authoritative-run-2.log`
- `logs/clean-5/configure.stdout.log`
- `logs/clean-5/configure.stderr.log`
- `logs/clean-5/build.stdout.log`
- `logs/clean-5/build.stderr.log`
- `artifacts/mangosd.exe`
- `artifacts/mangosd.pdb`
- `evidence/CMakeCache.txt`
- `evidence/tracked-changes.patch`
- `evidence/isolated-git-status.txt`
- `source-copies/`

Files whose names contain `final`, `final2`, `final3`, `final4`, `closure`, or `authoritative` but are not listed above are preserved intermediate evidence from earlier closure passes. They are included for audit continuity but are not the authoritative candidate metadata.

The outer ZIP SHA-256 cannot be embedded in the ZIP without self-reference. It is therefore recorded in the adjacent sidecar `*.zip.audit.json`. `PACKAGE-CONTENTS.json` inside the ZIP records the expected entry count and SHA-manifest construction rule.
