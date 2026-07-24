# ARO-163 staging foundation

ARO-163 creates the private Postgres contract that later tickets use for node enrollment, routing,
lease ownership, and effect attribution. It does not implement leases, fallback, effect execution,
checkpoints, or production deployment.

## Environment boundary

- Project: `aroak-central-brain-staging`
- Writable schema: `symphony_staging`
- Reserved schema: `symphony_production`
- Added fixed-cost limit: USD 0

Every migration and runtime query is schema-qualified. The migration never creates, grants,
revokes, or otherwise changes `symphony_production`; denial is inherited from the approved
environment baseline and must be verified without changing its ACL. `anon`, `authenticated`, and
`service_role` receive no privileges on the foundation objects.

## Roles

The migration creates two `NOLOGIN`, `NOINHERIT`, non-admin permission roles:

- `symphony_staging_runtime` reads non-secret node, binding, routing, and contract data and appends
  masked audit events.
- `symphony_staging_provisioner` manages node, binding, routing, and contract rows and appends audit
  events.

They are deliberately `NOLOGIN`. A later approved provisioning flow can bind a login credential to
the appropriate permission role without putting a password in Git, Linear, Codex, migration output,
or logs. Permission verification uses `SET ROLE`, so no durable test password is required. The
migration grants both permission-role memberships to `postgres` with `SET TRUE`, repairing an
accepted pre-existing membership that had `SET FALSE`. Acceptance does not treat a successful
superuser `SET ROLE` as evidence of that repair: it inspects `pg_auth_members.set_option` directly.
The disposable behavior suite switches `current_user` to each permission role and to `anon` and
`authenticated` before exercising allowed and denied operations, so owner or superuser bypass
cannot satisfy runtime security assertions.

`ALTER ROLE ... SET search_path` is intentionally not used: PostgreSQL does not apply a `NOLOGIN`
permission role's role settings when a login session later runs `SET ROLE`. Every transaction must
use this connection contract:

```sql
begin;
set local role symphony_staging_runtime;
set local search_path = pg_catalog, symphony_staging;
-- Keep application SQL schema-qualified even with this defense in depth.
select * from symphony_staging.routing_assignments where issue_id = $1;
commit;
```

The migration fails closed when a same-name role has role-level configuration or memberships other
than the approved `postgres` administration membership. Pre-existing roles must have exactly the
approved schema capability: `USAGE` without `CREATE` or grant option. The migration re-hardens
accepted roles before any grant. Rollback drops only roles carrying an owner-only migration marker;
the runtime and provisioner cannot read those marker rows, the provisioner cannot mutate them, and
compatible roles that predated ARO-163 remain.

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

## Shared staging reconciliation

Shared staging originally received an earlier ARO-163 contract before the final PR #4 hardening.
ARO-168 reconciles only that exact legacy state:

- apply `priv/symphony_migrations/20260724000000_aro_168_staging_reconciliation.sql`;
- record contract version `2` and migration name
  `20260724000000_aro_168_staging_reconciliation`;
- reset only the legacy role-level `search_path`;
- isolate `aro-163-created-role:*` rows from runtime and provisioner policies;
- preserve both the explicit `postgres` `SET TRUE` membership and Supabase's managed PostgreSQL 17
  `ADMIN TRUE / INHERIT FALSE / SET FALSE` membership;
- do not add retrospective role-ownership markers.

The migration validates the complete approved legacy profile before its first write and aborts on
any role, membership, policy, foundation-data, schema-object, or production-boundary drift. The
exact gate compares effective RLS mode, complete policy semantics, trigger attachments, foundation
ownership, invariant indexes, direct table/column/sequence/function grants, grant options,
schema-scoped and global default ACLs, database-scoped role settings, and all supported
namespace-owned production object catalogs. The foundation tables are locked before the gate so
the checked snapshot cannot race a concurrent provisioner. Runtime access to
`node_bindings.credential_verifier` is an explicit hard failure. A disposable-superuser test
profile may have only the explicit `postgres SET TRUE` membership; managed shared staging must also
have the PostgreSQL 17/Supabase administration membership. Both profiles reject every outbound
membership or grantor edge from either managed role, so the roles cannot inherit or `SET ROLE` into
an unapproved privilege path.
Rollback is
`priv/symphony_migrations/20260724000000_aro_168_staging_reconciliation.down.sql`. It is allowed
only before provisioning data exists, after revalidating every ACL class and setting it preserves,
and restores only the two policies, two known role settings,
and the v1 contract row. It never drops roles, tables, schemas, or managed memberships.

PR review and merge do not authorize shared-staging apply. Preserve the separate human gate before
applying ARO-168 to `aroak-central-brain-staging`.

ARO-169 startup uses one worker-owned direct PostgreSQL connection for the
complete process lifetime. Supavisor/PgBouncer transaction and session pooler
endpoints are not accepted because pool-backend lifetime is not worker
lifetime. Each ARO-139–141 preflight must verify the direct
`db.<project-ref>.supabase.co:5432` endpoint and prove disconnect removes the
recorded backend before provisioning approval.

The suite also checks canonical role attributes, memberships, object and column grants, every RLS
policy's table, role set, command, permissive mode, `qual`, and `with_check`, rollback
ownership-marker isolation, and unchanged production-schema ACLs. Positive actor reads assert the
exact node, binding, routing, and revision returned; provisioner writes assert their persisted
effect instead of accepting only a successful command exit. The migration owner is used only for
setup, migration, catalog inspection, and teardown; runtime and provisioner behavior is verified
after switching to the exact non-admin actor.

### Acceptance evidence matrix

| Invariant | Canonical state | Actor and observed result | Lifecycle coverage |
| --- | --- | --- | --- |
| Hardened permission roles | `pg_roles` and `pg_auth_members.set_option` | Runtime and provisioner can be assumed only through the approved membership | apply, compatible legacy role, reapply, rollback/reapply |
| Exact object capabilities | schema, table, column, sequence, and function ACL catalogs | Provisioner writes persist; runtime returns exact node, binding, routing, revision, and audit values; forbidden operations return permission/RLS denial | apply, reapply, rollback/reapply |
| Canonical RLS | complete bidirectional `pg_policies` comparison, including table, role, command, mode, `qual`, and `with_check` | Routing reads and provisioner mutations exercise the policies; ownership markers remain hidden and immutable | apply and reapply |
| Shared and production isolation | normalized schema/object/default ACL snapshots | Runtime, provisioner, anon, and authenticated cannot create in production; unrelated staging sentinel access survives | apply, transactional failure, rollback, reapply |
| Credential secrecy | runtime column ACL excludes `credential_verifier` | Runtime verifier read returns a permission denial | apply and reapply |

The behavior-level Postgres regression suite is intentionally destructive and only runs against an
explicit disposable database:

```bash
ARO163_MIGRATION_TEST_DATABASE_URL=postgresql://... \
ARO163_ALLOW_DESTRUCTIVE_DB_TEST=1 \
mix test --no-start test/symphony_elixir/staging_foundation_postgres_test.exs
```

It snapshots an unrelated sentinel object's ACLs and default privileges, exercises the real
`SET ROLE` plus `SET LOCAL search_path` connection contract, verifies rollback preservation, and
proves an unsafe same-name role fails transactionally. Never point it at shared staging or
production.

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
