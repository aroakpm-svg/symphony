# ARO-169 catalog identity audit

This audit covers both ARO-169 migration directions at
`main@1e01e5871e6ae0273ea270520ea03e28634ea25f`. It was completed before
changing migration behavior.

## Live read-only facts

The shared-staging catalog was queried read-only on PostgreSQL 17.6. No DDL,
ACL, trigger, credential, node, or application data was read or changed.

All six enabled Supabase event triggers point to the expected
`extensions.<function>()`. Their function ACLs are explicit and contain three
`EXECUTE` rows each, with `supabase_admin` as grantor:

| Trigger functions | Grantee | Grant option |
| --- | --- | --- |
| `set_graphql_placeholder`, `grant_pg_graphql_access`, `pgrst_ddl_watch`, `pgrst_drop_watch` | `PUBLIC` | false |
| same four functions | `postgres` | true |
| same four functions | `supabase_admin` | false |
| `grant_pg_cron_access`, `grant_pg_net_access` | `PUBLIC` | false |
| same two functions | `dashboard_user` | false |
| same two functions | `supabase_admin` | true |

Each event trigger has one normal dependency on its corresponding
schema-qualified function. These are catalog facts, not credentials or
application data.

## Classification

The audit classifies identity rendering by whether it affects a safety
decision or survives into the apply/rollback fingerprint.

### Must be canonicalized symmetrically

- Managed-event-trigger preflight, apply snapshot, post-DDL stability check,
  stored manifest, and rollback recomputation:
  - `proacl` must be represented as sorted
    grantor/grantee/privilege/grant-option rows from `aclexplode`.
  - `pg_describe_object` dependency text must be replaced by catalog-derived,
    schema-qualified symbolic identities.
  - function return types must use catalog namespace/name, not
    `regtype::text`.
- Runtime pgcrypto and external procedure identities that enter the stored
  fingerprint must use catalog-derived schema-qualified function/type
  identities, not `regprocedure::text` or `regtype::text`.
- Managed-schema inventory identities that enter the stored fingerprint must
  be visibility independent:
  - functions and trigger functions;
  - conversion functions;
  - operator-class input/key types;
  - text-search parser/template functions;
  - sequence types;
  - production-function isolation.
- Raw ACL arrays in behavior-bearing fingerprints must be converted to sorted
  grantor/grantee/privilege/grant-option rows. Array storage order is not a
  contract.

### Safety decisions whose identity text is diagnostic only

- Cross-boundary rewrite, inheritance, constraint, and procedure checks fail
  on row existence. Their rendered edge ID is only a masked diagnostic.
- Constraint dependency OIDs are never accepted into an empty baseline: any
  cross-boundary row fails preflight and any later row changes the manifest.
  They are therefore not an accepted persistent identity.
- Fixed, schema-qualified `to_regclass`, `to_regprocedure`, and
  `'<literal>'::reg*` lookups are object resolution checks rather than
  rendered identities. They remain appropriate.

### Safe non-cross-session rendering

- Pure exception detail that is neither compared nor persisted does not need
  mechanical replacement.
- Catalog class comparisons such as
  `dependency.classid = 'pg_proc'::regclass` compare OIDs within one catalog
  snapshot and do not render an identity.

## Required regression matrix

- Exact six live ACL profiles and order-independent ACL aggregation.
- Grantor, grantee, privilege, and grant-option drift.
- Default, `extensions`-first, and shadow-object `search_path` settings.
- Same-name shadow functions/types and same-name managed trigger replacement.
- Trigger/function owner, source, config, cost, and dependency drift.
- Apply, reapply, rollback, and rollback-then-reapply using the same canonical
  model.

Unknown catalog object kinds or dependency classes remain fail closed rather
than falling back to OIDs or visibility-dependent text.
