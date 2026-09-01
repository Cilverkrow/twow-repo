# Canonical server-configuration contract

ADR-0038 makes the repository the authoritative source for shared server
configuration. The runtime `.conf` files are generated deployment artifacts;
they are never an editable source and remain ignored by Git.

The complete configuration is the combination of:

| Service | Complete base template | Reviewed Compose overlay |
| --- | --- | --- |
| world server | `src/mangosd/mangosd.conf.dist.in` | `compose/mangosd.overlay.conf` |
| realm server | `src/realmd/realmd.conf.dist.in` | `compose/realmd.overlay.conf` |
| PlayerBots | `modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in` | `compose/aiplayerbot.overlay.conf` |

The base templates are complete and move with the server source. The overlays
contain every verified non-secret semantic deviation needed to retain the
sanitized project baseline, plus reviewed Compose path changes. The complete
115-row classification is `compose/semantic-baseline.tsv`: 95 `KEEP`, 14
`INTENTIONAL_CHANGE`, no unproven removal, and 6 `MACHINE_SECRET` entries.

The protected machine input in `deploy/compose/.env` supplies database
credentials, the optional PlayerBot LLM API key, published ports, and the bot
range. The renderer replaces or inserts each secret key exactly once in its
private staging directory. Secret values never enter a tracked file, matrix, or
provenance record.

Run `make config` from a clean checkout to render the three files through a
private staging directory into `deploy/compose/config/` and write
`config-provenance.txt`. Publication is deliberately file-by-file rather than
claimed to be set-atomic: all configs publish first and provenance publishes
last. An interruption, missing file, or mixed generation therefore fails the
mandatory verifier before `make up` can consume it. Run `make config-verify`
before deployment or whenever drift is suspected. Rendering always replaces
generated files; preserving hand-edited output would make the runtime copy
authoritative again and is intentionally unsupported.

Every active key occurs exactly once in each final document. Three duplicated
Battleground keys inherited from the complete mangosd template are collapsed to
their single reviewed overlay value. LFT and LFT Bot Fill stay in the
mangosd/Core template and executable; this contract creates no separate service
or container for them.

To roll back, check out the approved earlier commit, render again with the same
protected machine inputs, verify the provenance record, and deploy through a
separately authorized operation. Exceptional direct runtime writes require the
archive-before-write evidence described by ADR-0038 and must be reconciled to Git.

The Helm chart follows the same base-template-plus-overlay model in
`deploy/helm/twow/templates/configmap.yaml`; credentials come only from an
existing Kubernetes Secret.
