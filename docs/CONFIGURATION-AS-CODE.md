# Configuration as code and provenance

ADR-0038 makes the project checkout authoritative for shared server
configuration. A runtime `.conf` file is a generated deployment artifact, not a
place to preserve manual edits.

## Canonical inputs

The complete source for the Compose configuration is:

| Service | Complete versioned base | Reviewed non-secret overlay |
|---|---|---|
| Worldserver | `src/mangosd/mangosd.conf.dist.in` | `config/canonical/compose/mangosd.overlay.conf` |
| Realmserver | `src/realmd/realmd.conf.dist.in` | `config/canonical/compose/realmd.overlay.conf` |
| PlayerBots | `modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in` | `config/canonical/compose/aiplayerbot.overlay.conf` |

The renderer refuses an overlay key that is absent or duplicated in its base
template. This catches template/config skew before a generated file can be
used. Published host ports and PlayerBot bounds come from the protected `.env`
input; Compose maps the host ports to fixed container ports 8090/3724. Database
credentials are appended only to the generated files and never to Git or the
provenance record.

`config/examples/` contains historical sanitized snapshots only. It is not a
deployment source, and no live configuration was copied into the canonical
contract.

## Render and verify

From a clean Linux/Docker deployment checkout:

```sh
cp deploy/compose/.env.example deploy/compose/.env
# Fill the protected local values, then:
make config
make config-verify
```

`make config` replaces all three generated files under
`deploy/compose/config/`, writes a secret-free `config-provenance.txt`, and
immediately verifies it. By default it refuses a dirty checkout. The record
binds the output to the full Git commit and tree plus the byte count and SHA-256
of every template, overlay, renderer, verifier, and rendered file.

The verifier fails closed when source identity, dirty state, hashes, file set,
or Linux permissions differ. Git Bash on Windows can still run the repository
test and all identity/hash checks, but NTFS does not expose enforceable POSIX
mode bits through this interface; Windows is compile-only under ADR-0028 and is
not an approved deployment target.

Run `bash ops/config/test-config-provenance.sh` for a repository-only test. It
uses synthetic credentials in a temporary directory, proves that credentials
do not enter provenance, proves that a one-file edit is rejected, rerenders,
and removes the temporary files. It does not contact a server or database.

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
