# ADR-0030: Explicit plaintext transport for the legacy local MariaDB endpoint

- Status: Accepted
- Date: 2026-09-01
- Primary: WS-30
- Dependent: WS-20
- Relates to: ADR-0027 (database platform), ADR-0028 (Linux/Docker deployment), FG-034, FG-035

## Context

The legacy local Windows MariaDB endpoint is bound to `127.0.0.1:3307`. The installed
MariaDB 11.4.10 client attempted TLS by default, but the server did not present usable
Windows TLS credentials. The verified first connection failed during Schannel
negotiation, before authentication and before any SQL ran.

A later read-only inventory succeeded by using TCP loopback with TLS disabled. It kept
the credentials out of the command line in an ACL-restricted ephemeral option file and
set the SQL session read-only. That was a safe task-specific workaround, but without a
decision every database tool has to rediscover whether to repeat it.

Provisioning a certificate would change the active server TLS policy. It is not selected:
the project now deploys on Linux/Docker, Windows runtime tooling is historical, and no
requirement justifies mutating the legacy local server for encrypted traffic that never
leaves the host.

## Decision

The legacy local endpoint has one explicit plaintext transport profile. A client may use
it only when every gate below passes:

1. The endpoint is the literal IPv4 loopback address `127.0.0.1` on port `3307`.
   `localhost`, a hostname, another address, a container bridge and a forwarded port are
   not equivalent.
2. The listener PID, process name and full executable path are verified as the intended
   MariaDB instance before connecting.
3. The task separately authorizes the database operation and the selected credential has
   only the privileges required by that task.
4. Credentials exist only in a newly created ACL-restricted ephemeral option file. They
   never appear in arguments, environment variables, logs, reports or Git, and the file
   is removed in a `finally` path.
5. The client selects plaintext deliberately with `--protocol=tcp --skip-ssl`. There is
   no automatic TLS failure retry and no server TLS setting is weakened.
6. Evidence records the endpoint, client version, TLS mode, credential transport,
   listener identity and option-file removal without recording the principal or secret.

The pinned MariaDB client form for a read-only evidence task is:

```powershell
& $mariaClient `
  "--defaults-extra-file=$credentialFile" `
  "--host=127.0.0.1" `
  "--port=3307" `
  "--protocol=tcp" `
  "--skip-ssl" `
  "--skip-auto-rehash" `
  "--init-command=SET SESSION TRANSACTION READ ONLY" `
  "--database=$confirmedSchema" `
  "--batch" `
  "--raw" `
  "--column-names"
```

`--defaults-extra-file` is the first client option. The file contains only the protected
`[client]` credentials; host, port, protocol and TLS mode remain visible in the invocation
so review does not depend on hidden defaults. The query itself must be statically limited
to the authorized read-only statements. Session read-only mode is an additional guard,
not a substitute for a SELECT-only principal.

This profile is not a general exemption from TLS. Connections outside the exact verified
loopback endpoint must use the environment's approved encrypted transport. Supported
Linux/Docker operations follow ADR-0028 and receive their own deployment configuration;
they do not inherit this Windows-local exception.

## Consequences

- Local tools stop probing TLS and silently retrying. They select the reviewed profile or
  fail closed.
- The legacy MariaDB server, its certificate state and `my.ini` remain unchanged.
- Loopback traffic is unencrypted on the host. This is accepted only with the endpoint,
  listener-identity and credential-handling gates above.
- A future certificate rollout, non-loopback endpoint or supported container transport
  requires a new review and supersedes this exception for that environment.
- This decision authorizes no database query, process start/stop, migration or deployment.

## Evidence

- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/evidence/DB-READONLY-ASSESSMENT.md`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/evidence/DB-READONLY-INVENTORY-ATTEMPT-2-RUN.txt`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/rndbot-persistent-active-roster-implementation-01-phase-c0-20260831-135717/queries/run-readonly-inventory.ps1`
- `runbooks/workstreams/WS-30-serverkonfiguration/ops-001-readonly-bot-population-matrix-20260901T110928Z/READONLY-CAPTURE-PLAN.md`
