# Repository provenance

The server source was copied from the independent working tree `C:\TW\ComTW\source` without changing that tree.

## Source baseline

- Upstream remote: `https://github.com/Shyalya/tortoise-wow.git`
- Source branch: `playerbots-integration-gh`
- Source commit before filtering: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Filtered equivalent commit: `5a157e183e47cc5f892ef64ca69f02772118c940`
- Preserved rewritten commit count: 559

The history was rewritten only in the independent repository copy so that binary files are absent from every reachable commit. The rewrite removes compiled libraries, executables, symbols, archives, images, Warden binary modules, client/server data files, and any other blob detected as binary. Commit topology, authorship, dates, messages, and text changes are otherwise retained.

`docs/history/source-commit-map.tsv` records the original-to-filtered commit mapping produced by `git-filter-repo`.

Uncommitted PlayerBot/LLM changes from the live source tree are imported in a separate new commit after the cleaned baseline. Operations files and runbooks are likewise imported in later commits so their ownership remains visible.
