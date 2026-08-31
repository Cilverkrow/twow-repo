# Security and secret handling

No live configuration, credential file, database state, or secret-bearing evidence belongs in this repository.

Before the initial push, the working tree and all reachable Git history were scanned with Gitleaks. Possible secret-bearing runbook files were excluded from the repository rather than rewritten in place. Sanitized configuration examples use explicit placeholders.

`.gitleaksignore` contains one narrowly scoped, audited false-positive fingerprint for the standard `Sec-WebSocket-Key` HTTP header literal in vendored Crow source. It is not a credential.

Contributors should run a full-history secret scan before publishing rewritten history and a directory scan before each normal push. A new finding must be removed or explicitly audited; broad rule suppression is prohibited.
