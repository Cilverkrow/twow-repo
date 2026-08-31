# Operations helpers

This directory separates project-owned helper scripts from the upstream server source without moving or modifying the live copies.

- `windows/build`: build launcher and prerequisite notes.
- `windows/source-sync`: source retrieval and transfer helpers.
- `windows/server`: start, stop, status, and graceful-shutdown helpers.
- `windows/database`: database launcher only; no database content is stored here.

The scripts are historical working copies from `C:\TW\ComTW`. Paths and assumptions must be reviewed before use in another checkout. Their presence does not authorize server, database, deployment, or rollback operations.
