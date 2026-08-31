# ZIP audit scope

The final deliverable ZIP is audited externally after it is closed.

- Outer ZIP SHA-256, byte length and entry count are stored in the adjacent file whose suffix is `.zip.metadata.json`.
- The external metadata is intentionally not embedded in the ZIP, because embedding the ZIP's own digest would be self-referential.
- `SHA256SUMS.txt` inside the ZIP covers every other payload file and excludes only itself.
- Verification reopens the finished ZIP, rejects duplicate or unsafe entry names, compares the entry set with the staged payload, and hashes every extracted entry stream against `SHA256SUMS.txt` without executing content.
