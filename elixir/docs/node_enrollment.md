# Node enrollment and authentication

ARO-169 adds the shared staging entrance required before ARO-139, ARO-140,
or ARO-141 may provision a physical computer.

## Security model

- `provision_node` generates a random node ID, binding ID, login role, and
  256-bit credential inside one PostgreSQL transaction.
- The plaintext credential is returned once. Only its SHA-256 verifier is
  stored in `node_bindings`.
- Each node login is not a member of `symphony_staging_runtime`, has no table
  privileges, and cannot access production.
- `authenticate_node` matches `session_user` to the requested node and active
  binding. Authentication, rotation, revocation, and instance retirement
  serialize on the same node lifecycle rows.
- The server-owned active-instance row remains authoritative until the
  bootstrap provisioner explicitly retires that exact instance after trusted
  confirmation that its worker stopped. A second instance is rejected
  regardless of connection pooling, disconnect, or backend lifetime.
- Provisioning grants each login only staging schema usage and direct execution
  of `authenticate_node`. Future runtime entry points must repeat the active
  node/current-instance gate; node logins must never receive table access.
- Rotation creates a fresh login principal and credential, disables and strips
  the old login, revokes the old binding, and advances the credential version
  atomically. An already-open old session may change its own password, but it
  cannot restore `LOGIN`, schema usage, or authentication execution.
- Revocation changes the current login to `NOLOGIN`, removes its authentication
  execution and schema usage, and disables the node and active binding.
- A node cannot clear the instance gate by disconnecting, using a pooler, or
  calling advisory-lock functions. Instance history permanently rejects reuse
  of an old `nodeInstanceId`.
- The entry points are not callable by `PUBLIC`, Supabase API roles, or
  `service_role`.

## Required startup contract

Connection transport is deliberately not treated as worker identity.
`authenticate_node` never infers restart authorization from a direct backend,
Supavisor, PgBouncer, PID, disconnect, or timeout. If an active instance row
exists, every new instance fails closed.

The bootstrap caller—not the node login—may call `retire_node_instance` for the
exact old instance only after an out-of-band, trusted confirmation that the old
worker stopped. An unknown stop result, registry timeout, or unavailable
registry leaves the row intact, so a worker must not poll, claim, or produce an
external effect. ARO-139–141 must define their approved machine-local stop
confirmation before provisioning.

The caller must save a returned credential directly into an approved
machine-local secret store. It must never be passed on a command line, written
to a workspace file, committed, logged, or copied to a synchronized location.

## Gates

The migration fails closed unless the reconciled ARO-168 contract v2 is
present. Applying it to shared staging requires separate human approval. This
repository change does not provision any physical computer.

Rollback locks and verifies the exact v3 marker plus the recorded object,
function, ownership, and ACL fingerprint before its first destructive
statement. It fails closed on future-contract, object, or ACL drift, requires
exactly one downgrade row, and refuses while any provisioned principal exists.
ARO-169 up/down migrations also acquire the shared staging migration advisory
lock before inspection or DDL. Every future contract migration or
administrative DDL path must acquire the same lock.

ARO-164 still owns routing claim, fallback, lease, heartbeat, and generation
semantics.
