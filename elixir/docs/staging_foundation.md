# ARO-163 staging foundation

ARO-163 creates the private Postgres contract that later tickets use for node enrollment, routing,
lease ownership, and effect attribution. It does not implement leases, fallback, effect execution,
checkpoints, or production deployment.

## Environment boundary

- Project: `aroak-central-brain-staging`
- Writable schema: `symphony_staging`
- Reserved schema: `symphony_production`
- Added fixed-cost limit: USD 0

Every SQL reference is schema-qualified. The staging roles receive no `USAGE` or object privileges
on `symphony_production`. `anon`, `authenticated`, and `service_role` receive no privileges on the
foundation objects.

## Roles

The migration creates two `NOLOGIN`, `NOINHERIT`, non-admin permission roles:

- `symphony_staging_runtime` reads non-secret node, binding, routing, and contract data and appends
  masked audit events.
- `symphony_staging_provisioner` manages node, binding, routing, and contract rows and appends audit
  events.

They are deliberately `NOLOGIN`. A later approved provisioning flow can bind a login credential to
the appropriate permission role without putting a password in Git, Linear, Codex, migration output,
or logs. Permission verification uses `SET ROLE`, so no durable test password is required.

## Credential contract

The database stores only a SHA-256 verifier, never the node credential. Each node and environment
has versioned bindings with these states:

`pending -> active -> rotating -> revoked | retired`

The database enforces one `active` binding and one `rotating` binding per node and environment.
Database triggers reject invalid or backwards state changes and keep binding identity and verifier
fields immutable. The provisioning API must also record a masked audit event. That transition API
is part of node provisioning in ARO-139 through ARO-141.

The accepted clone protection is risk reduction, not hardware identity:

- each machine and environment uses a distinct node credential;
- one binding is active per node and environment;
- replacement or suspected cloning revokes the old binding before re-enrollment;
- a complete offline copy of software configuration and credentials may not be detected
  immediately.

Do not describe this contract as complete clone detection.

## Routing contract

`routing_assignments` provides:

- `unassigned`
- `preferred-with-fallback`
- `exclusive`
- target node
- monotonically increasing routing revision
- contract version

Invalid combinations are rejected by constraints. ARO-164 owns atomic claim, slot capacity,
fallback timing, generation, takeover, and Linear freshness. ARO-163 only supplies their durable
foundation. A database trigger rejects updates that do not increase `routing_revision`.

## Migration and rollback

Apply:

`priv/symphony_migrations/20260723000000_aro_163_staging_foundation.sql`

Rollback:

`priv/symphony_migrations/20260723000000_aro_163_staging_foundation.down.sql`

The rollback removes only named ARO-163 objects and permission roles. It does not drop or modify
`symphony_staging`, `symphony_production`, or the shared Supabase project.

Validation must prove:

1. clean apply;
2. idempotent re-apply;
3. transactional failure leaves no partial change;
4. rollback removes only ARO-163 objects;
5. re-apply after rollback;
6. runtime and provisioner positive permissions;
7. `symphony_production` access denied for both staging roles;
8. `anon` and `authenticated` remain denied;
9. migration checksum and exact implementation SHA are recorded.

## Secret handling

Never place node credentials, database passwords, GitHub tokens, or Linear tokens in:

- Git;
- issue descriptions or comments;
- Codex conversations;
- command output;
- audit event details;
- machine aliases, hostnames, or personal paths.

Evidence may contain role names, contract version, migration checksum, masked node identifiers,
reason codes, and operation results.
