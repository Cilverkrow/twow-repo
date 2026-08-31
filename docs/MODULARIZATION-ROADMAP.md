# Modularization roadmap

Deep modularization is intentionally not a prerequisite for the first safe repository import. Refactoring the live tree while other agents are working would create avoidable merge and runtime risk.

The initial repository uses boundaries that do not require modifying the live project:

1. Server source stays in its existing upstream-compatible layout.
2. PlayerBot and LLM bridge code stays under `src/modules/PlayerBots` until its interfaces and configuration contract are stable.
3. Project-owned server helper scripts live under `ops/windows` in this repository.
4. Only sanitized configuration examples live under `config/examples`.
5. Runbooks remain text evidence under `runbooks` and are not executable deployment input by default.

## Recommended next extraction

After the initial repository is stable, extract custom behavior behind explicit seams rather than moving files wholesale:

- Define a narrow LLM transport interface inside PlayerBots, with endpoint and model configuration passed through validated settings.
- Put prompt/personality assets in a dedicated data-only package whose schema is versioned independently from C++.
- Give server lifecycle scripts a small shared PowerShell module for paths, process discovery, logging, and dry-run behavior.
- Make deployment consume a declared manifest of source, configuration templates, migrations, and scripts.
- Keep database migrations append-only and independent from runtime backups.

Each extraction should be its own reviewed commit or pull request with build, dry-run, and rollback evidence. The live workspace should only adopt it after explicit authorization.
