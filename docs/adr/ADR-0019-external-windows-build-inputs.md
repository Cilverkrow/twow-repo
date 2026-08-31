# ADR-0019: Keep binary Windows build inputs external and pinned

- Status: Accepted
- Date: 2026-08-31
- Primary: WS-10 / WS-50

## Context

The project repository deliberately excludes binaries. The inherited Windows resource script nevertheless requires `src/mangosd/mangosd.ico`, and the linker requires compiled libraries below `dep/windows/lib`. Omitting these inputs without an explicit contract made a source-complete integration look build-broken at resource and link stages. Tracking the inputs would contradict the approved source-only repository boundary and could introduce provenance or licensing ambiguity.

The required icon was identified independently by byte count, SHA-256, and historical blob identity. The external compiled-library hierarchy was already present in the controlled local build environment. A clean Release build succeeded after both were exposed only temporarily to the isolated feature worktree.

## Decision

- Keep `mangosd.ico` and all compiled dependency libraries outside this repository.
- Pin the required icon by relative destination, byte count, SHA-256, and historical blob identity in `docs/BUILD-RESOURCES.md`.
- Expose external compiled libraries only through a verified temporary path or junction in an isolated worktree.
- Remove the temporary icon copy and dependency junction after every build.
- Record candidate EXE/PDB identities in text evidence, but never commit the artifacts.
- Treat missing or mismatched external inputs as a visible build-preflight failure, not as permission to bypass resources or weaken repository filters.
- Add a complete consumed-dependency manifest under OT-014 before claiming a portable or hermetic Windows build.

## Consequences

- The repository remains free of binary build inputs and outputs.
- A clone alone is intentionally insufficient for a Windows server build; the external build-input contract is mandatory.
- Build agents must provision and verify the pinned inputs explicitly.
- License and distribution decisions for binary assets remain outside the source repository.
- The successful 2026-08-31 OT-001 build closes the immediate resource gate but not the broader reproducible-build work.

## Evidence

- `docs/BUILD-RESOURCES.md`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-20260831T192201Z/`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-recovery-20260831T220000Z/`
