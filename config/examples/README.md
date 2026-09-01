# Sanitized historical configuration examples

These files are retained as non-secret historical snapshots. They are useful for
review and reconstruction, but they are neither complete current configuration
nor deployment input.

The authoritative shared configuration contract is
[`config/canonical`](../canonical/README.md): complete version-matched `.dist.in`
templates plus reviewed non-secret overlays. Compose renders from that contract,
adds protected machine inputs, and records source and file hashes.

All database connection strings and API keys in this directory have been
replaced with explicit placeholders. Live and generated `.conf` files remain
ignored and must never be committed or copied back here.
