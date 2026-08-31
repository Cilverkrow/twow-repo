# Read-only inventory assessment

- Snapshot UTC: `2026-08-31 15:23:05.007923`
- Query SHA-256: `B9CA0D9359EC4339D8DE9222DA64CEEAF6F4ADE8801B6CD217B409E3012A93CC`
- Successful raw output: 702,698 bytes, SHA-256 `B7368DC8B39C1667B149EA3DCAC266A63149B8D7D134B54B1F701663F7B98530`
- Successful stderr: 0 bytes
- Session transaction mode: read only
- Database writes: none

The initial client attempt reached no SQL: TLS negotiation failed, stdout was empty, and its error evidence is preserved. The deliberate second attempt retained the identical SELECT-only query and used loopback with TLS disabled because the existing local server did not present usable Windows TLS credentials. Credentials were passed through a newly created ACL-restricted temporary option file, never in the command line; that file was removed in the runner's `finally` block.

Counts: active add rows 0; distinct active add GUIDs 0; active RNDBOTs 0; eligible active RNDBOTs 0; historical add rows 86; historical add duplicates 0; expired add rows 86; full RNDBOT stock 4,500; base-eligible stock 4,500.

The result is insufficient for automatic initialization. Target 50 minus active 0 leaves 50 explicit choices. Historical and full-stock inventories are evidence, not rankings or implicit proposals.

