# Sanitized configuration examples

These files preserve the non-secret local configuration choices needed to reproduce the private-server setup.

All database connection strings and API keys have been replaced with explicit placeholders. Live `.conf` files remain ignored and must never be committed. Supply credentials through local, untracked configuration or a dedicated secret manager.

Before deployment, compare an example with the matching `.dist` template from the selected server build. Do not assume that an old example contains every option introduced by a newer binary.
