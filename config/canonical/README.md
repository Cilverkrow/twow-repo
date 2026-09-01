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
contain every non-secret Compose-specific deviation. The only machine overlay is
the documented environment input in `deploy/compose/.env`: database credentials,
published ports, and the initial bot range. Credentials are appended in memory by
the renderer and never enter a tracked file or the provenance record.

Run `make config` from a clean checkout to render the three files through a
private staging directory into `deploy/compose/config/` and write
`config-provenance.txt`. Run
`make config-verify` before deployment or whenever drift is suspected. Rendering
always replaces generated files; preserving hand-edited output would make the
runtime copy authoritative again and is intentionally unsupported.

To roll back, check out the approved earlier commit, render again with the same
protected machine inputs, verify the provenance record, and deploy through a
separately authorized operation. Exceptional direct runtime writes require the
archive-before-write evidence described by ADR-0038 and must be reconciled to Git.

The Helm chart follows the same base-template-plus-overlay model in
`deploy/helm/twow/templates/configmap.yaml`; credentials come only from an
existing Kubernetes Secret.
