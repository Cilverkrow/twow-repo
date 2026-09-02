# ADR-0038: Version the shared server configuration and deploy it with provenance

- Status: Accepted
- Date: 2026-09-01
- Primary: WS-80
- References: OPS-009 (unexplained `mangosd.conf` drift); ADR-0023; ADR-0028

## Context

The active `C:\TW\ComTW\server\mangosd.conf` changed by 16 bytes on 2026-08-29 outside the migration harness. Its pre-change content and purpose remain unproven, yet its post-change hash was later cited as an approved baseline. The server directory itself is not a Git checkout, so a local in-place change has no inherent author, review, or history.

The project requires fast, broad collaboration on configuration. That requires a shared, reviewable source of truth rather than hidden per-workstation state.

## Decision

Treat shared server configuration as code:

- Store the complete canonical configuration (or a complete canonical template with a documented minimal machine overlay) in the project Git checkout.
- Make configuration changes through normal commits/reviews, with the diff, author, purpose, and rollback point visible in repository history.
- Deploy or render the approved configuration from the checkout into the runtime server directory; do not make the runtime copy the authoritative editable source.
- Record the deployed file's SHA-256 and source commit/revision as part of each deployment or verification package.
- Before any exceptional direct runtime write, archive the exact prior file and record before/after hash, byte diff, purpose, actor, and follow-up commit. Reconcile it to Git promptly.

The current project may version intentionally non-sensitive local development connection values to enable effective work by trusted collaborators. If the repository becomes public, is broadly forked, or uses credentials that grant access outside the shared local development environment, replace those values with injected local/secret configuration before publication. This condition does not prevent the shared configuration policy now.

## Drift resolution

Do not blindly restore the pre-drift configuration merely because it is older. Attempt to recover and diff it from an archive, snapshot, or other version source. If it is recovered, classify and explicitly accept or revert the semantic change. If recovery is impossible, make the current configuration the first controlled baseline only after a deliberate review and a committed canonical source; label older downstream packages as observed against the former unproven hash rather than retroactively approved.

## Consequences

Every collaborator can inspect, change, review, and reproduce server behaviour. A future 16-byte change becomes a visible Git diff and deployment record instead of an unexplained incident. Runtime configuration remains deployable without confusing the server folder with the project's source of truth.

## Required follow-up

1. Select the authoritative project checkout path and add the canonical configuration/template plus documented overlay contract.
2. Implement a deploy/render and hash-verification step for the runtime server directory.
3. Recover or formally close the 2026-08-29 drift investigation using the baseline rule above.
4. Add a config-change evidence entry to deployment/runbook verification.
