# OPS-009 configuration drift closure and implementation evidence

- Task: `OPS-009-CONFIG-AS-CODE-IMPLEMENTATION-01`
- Decision: ADR-0038 (Accepted)
- Repository base: `refactor/modular-platform`
- Feature branch: `feat/ops-009-config-as-code`
- Scope: repository-only implementation; no deployment or runtime mutation

## 2026-08-29 drift recovery result

The incident evidence records an observed `mangosd.conf` change from 69,531
bytes and SHA-256
`90D6D7AE3CC7AF9216F8B17F21E5762C1ED9D39DCC329234832123BAB0D618FF`
to 69,515 bytes and SHA-256
`C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`.
The migration harness recorded no configuration write and found no referencing
process in its scoped evidence.

A read-only filename/size/hash inventory of the authorized local collaboration
and backup roots found six `mangosd.conf*` candidates. It found zero matches for
the pre-change byte count, zero matches for the pre-change hash, and one match
for the post-change hash at the already-known active observed file. No file
content or secret was copied into Git.

The pre-change bytes are therefore unrecovered in the scoped evidence set. A
semantic diff and actor attribution cannot be reconstructed. This formally
closes the recovery attempt under ADR-0038 without pretending that the
post-change file was reviewed or that the unexplained change was approved.
Older downstream packages remain described only as observed against the former
unproven hash.

## Controlled baseline

The first controlled repository baseline is independently constructed from the
complete source-matched `.dist.in` templates and reviewed non-secret Compose
overlays under `config/canonical/`. The active runtime file was not copied into
the repository. This baseline becomes deployable only after review/merge and a
separate deployment authorization; this task neither adopts it into a live
directory nor changes a process or database.

The renderer:

- refuses dirty source by default;
- replaces generated output instead of preserving manual edits;
- rejects missing or duplicated overlay keys;
- separates protected machine credentials from tracked inputs;
- records full source commit/tree, input/output hashes, and byte counts; and
- emits no credential values in provenance.

The verifier checks source identity, dirty state, inputs, outputs, and Linux
file modes without printing configuration content. The repository test uses
synthetic credentials in a temporary directory, verifies the complete set,
detects deliberate file drift, rerenders, and deletes the test output.

## Authorization boundary

No live configuration was read into Git or changed. No server process was
started, stopped, or controlled. No database operation and no deployment was
performed. Runtime adoption, Helm deployment evidence, or exceptional direct
writes each require their own authorization.
