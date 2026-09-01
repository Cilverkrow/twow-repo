# Operations helpers

This directory separates project-owned helper scripts from the upstream server source without moving or modifying the live copies.

- `windows/build`: build launcher and prerequisite notes.
- `windows/source-sync`: source retrieval and transfer helpers.
- `windows/server`: historical Windows lifecycle copies. The former graceful-shutdown
  wrapper is retired and fails closed; it is not a supported operations path.
- `windows/database`: database launcher only; no database content is stored here.

The scripts are historical working copies from `C:\TW\ComTW`. Paths and assumptions must be reviewed before use in another checkout. Their presence does not authorize server, database, deployment, or rollback operations. Linux/Docker is the supported runtime path; see [ADR-0028](../docs/adr/ADR-0028-platform-and-ci-strategy.md).
