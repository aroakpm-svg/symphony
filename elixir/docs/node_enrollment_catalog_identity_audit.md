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
  - Every ACL-bearing fingerprint, including enforcement trigger functions,
    must preserve the distinction between catalog-default `NULL`, an explicit
    empty ACL, and an explicit non-empty ACL.
  - Role and privilege fields use lowercase UTF-8 hex before joining, making
    delimiters unambiguous for quoted, Unicode, comma, quote, and backslash
    role names.
  - ACL rows sort the same encoded fields with explicit `C` collation, so
    canonical order is independent of the database locale.
  - Grantees include a `pseudo` versus `role:` discriminator before encoding,
    so PostgreSQL's pseudo-role `PUBLIC` cannot collide with a quoted role
    named `"PUBLIC"`.
  - `pg_describe_object` dependency text must be replaced by catalog-derived,
    schema-qualified symbolic identities.
  - function return types must use catalog namespace/name, not
    `regtype::text`.
- Runtime pgcrypto and external procedure identities that enter the stored
  fingerprint must use catalog-derived schema-qualified function/type
  identities, not `regprocedure::text` or `regtype::text`.
- The two pgcrypto 1.3 runtime functions must carry the exact Supabase-managed
  explicit ACL recorded by read-only staging inspection: pseudo-PUBLIC
  EXECUTE, `dashboard_user` EXECUTE, and grantable `postgres` EXECUTE, all
  granted by `postgres`. Apply preflight, post-DDL stability, the stored
  manifest, rollback recomputation, and reapply use the same injective,
  C-collated ACL representation. Function ACLs only admit the `EXECUTE`
  privilege, so privilege drift is represented by a missing or extra EXECUTE
  row rather than a second valid privilege kind.
- Managed-schema inventory identities that enter the stored fingerprint must
  be visibility independent:
  - functions and trigger functions;
  - conversion functions;
  - operator-class input/key types;
  - text-search parser/template functions, including explicit `<none>`
    sentinels for zero-valued optional function/type OIDs;
  - sequence types;
  - production-function isolation.
- Raw ACL arrays in behavior-bearing fingerprints must be converted to sorted
  grantor/grantee/privilege/grant-option rows, including schema and default
  ACLs. Array storage order is not a contract.

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
  `dependency.classid = 'pg_catalog.pg_proc'::regclass` compare OIDs within
  one catalog snapshot. Up and down also pin the local migration search path
  to `pg_catalog`, so a caller-provided path cannot redirect catalog reads.

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
