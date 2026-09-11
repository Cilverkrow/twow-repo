# Configuration as code and provenance

ADR-0038 makes the project checkout authoritative for shared server
configuration. A runtime `.conf` file is a generated deployment artifact, not a
place to preserve manual edits.

## Canonical inputs

The complete source for the Compose configuration is:

| Service | Complete versioned base | Reviewed non-secret overlay |
|---|---|---|
| Worldserver | `core/src/mangosd/mangosd.conf.dist.in` | `config/canonical/compose/mangosd.overlay.conf` |
| Realmserver | `core/src/realmd/realmd.conf.dist.in` | `config/canonical/compose/realmd.overlay.conf` |
| PlayerBots | `core/modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in` | `config/canonical/compose/aiplayerbot.overlay.conf` |
| Bot brain | `modules/mod-bot-brain/conf/mod_bot_brain.conf.dist` | `config/canonical/compose/bot-brain.overlay.conf` |
| Donation points | `modules/mod-donation/conf/mod_donation.conf.dist` | `config/canonical/compose/mod-donation.overlay.conf` |
| Leech | `modules/mod-leech/conf/mod_leech.conf.dist` | `config/canonical/compose/mod-leech.overlay.conf` |

[`semantic-baseline.tsv`](../config/canonical/compose/semantic-baseline.tsv)
classifies all 130 service-key differences: 89 preserve verified behaviour, 25
are reviewed Compose changes, 10 are removed from the obsolete mangosd owner,
and 6 are protected machine secrets.

The bot-brain, donation, and leech rows have complete versioned bases in this
repository's modules rather than the core submodule. Their rendered files are
bind-mounted onto their matching paths below `/opt/turtle/etc/modules/`, which
`Config::LoadModulesConfigs` derives from the main conf. AutoDonationPoints and
Leech are intentionally rendered only into their module documents after core
#97/#98 removed the duplicate Core owners. `BOT_BRAIN_ENABLE` in the protected
`.env` input renders `BotBrain.Enable` and defaults to 0.

The renderer rejects duplicate overlay definitions, replaces existing keys in
place, appends only source-supported keys absent from the complete template, and
collapses a template duplicate when that key has one reviewed overlay value.
Every active key must occur exactly once in its final file.
Published host ports and PlayerBot bounds come from the protected `.env` input;
Compose maps the host ports to fixed container ports 8090/3724. Database and
optional PlayerBot LLM credentials enter only the private staged output and
never Git, the semantic matrix, or the provenance record.

`config/examples/` remains historical sanitized evidence, not deployment input.
For OPS-009-R1 its non-secret semantics were verified against the selected
project configuration with zero mismatches and then classified into the tracked
overlay contract. No live configuration or secret was copied into Git.

## Render and verify

From a clean Linux/Docker deployment checkout:

```sh
cp deploy/compose/.env.example deploy/compose/.env
# Fill the protected local values, then:
make config
make config-verify
```

`make config` stages all six generated files, publishes them file by file,
publishes a secret-free `config-provenance.txt` last, and immediately verifies
the set. This is explicitly not a set-atomic rename. A partial or mixed publish
has missing or mismatched provenance and fails closed before `make up`. By
default rendering refuses a dirty checkout. The record binds the output to the
full Git commit and tree plus the byte count and SHA-256 of the semantic matrix,
every template and overlay, the renderer/verifier, and every rendered file.

The verifier fails closed when source identity, dirty state, hashes, file set,
or Linux permissions differ. Git Bash on Windows can still run the repository
test and all identity/hash checks, but NTFS does not expose enforceable POSIX
mode bits through this interface; Windows is compile-only under ADR-0028 and is
not an approved deployment target.

Run `bash ops/config/test-config-provenance.sh` for a repository-only test. It
uses synthetic credentials in a temporary directory; checks bot bounds 3/7,
matrix completeness, unique keys, KEEP semantics, Core-owned LFT Bot Fill,
token resolution, and credential exclusion; rejects drift, incomplete sets, and
mixed generations; and proves repeatability apart from `RENDERED_UTC`. It then
removes the temporary files without contacting a server or database.

## Optional Funserver test profile

Use `CONFIG_PROFILE=funserver-test make config` only to render the explicit
test profile. With `CONFIG_PROFILE` absent, the ordinary canonical profile is
unchanged. The profile's own semantic matrix records its XP, talent, nine
item/money values, and the `taxi` extension to the existing PlayerBot random
bot cheats; provenance binds those three profile inputs when selected.

The loot multipliers scale existing eligible chance rolls only. They do not
promise a four-item boss or rare result, an epic-to-blue ratio, additional
independent selections, or duplicate suppression. `Rate.Drop.Item.Referenced`
remains `1` because it scales referenced loot tables, not quest items. Core
loot semantics remain separately tracked by issue #288.

No recipe-drop key is guessed or rendered. The requested optional recipe rate
is `BLOCKED_BY_CORE_CONTRACT` pending the documented WS-10/Core contract; after
that contract merges, the profile may set its exact key to `0.65`.

## Deployment evidence

A separately authorized deployment or config verification package must record:

1. task/approval identifier, actor, UTC time, and exact target identity;
2. approved source commit/tree and clean-checkout result;
3. the generated `config-provenance.txt` and a passing verifier result;
4. pre-deployment runtime file hashes and protected archive identities;
5. post-deployment runtime file hashes matched to provenance;
6. semantic purpose, reviewed diff, validation result, and rollback commit;
7. process/database actions actually authorized and performed.

Do not include configuration contents or secret values in evidence. A direct
runtime write is exceptional: archive before writing, capture before/after
identity and purpose, and reconcile the change to a reviewed commit promptly.

## Rollback

Select the approved earlier commit, use the same protected machine inputs,
render and verify again, then deploy only under a new authorization. Restoring
an unexplained older runtime file is not rollback evidence.

The Helm chart already starts from complete image-matched `.dist` templates and
adds a Secret-backed overlay. A Helm deployment still needs its own approved
source/image revision and rendered-file hashes in the deployment evidence; the
Compose provenance record must not be presented as proof for a Kubernetes pod.
