# Node enrollment and authentication

ARO-169 adds the shared staging entrance required before ARO-139, ARO-140,
or ARO-141 may provision a physical computer.

## Security model

- `provision_node` generates a random node ID, binding ID, login role, and
  256-bit credential inside one PostgreSQL transaction.
- The plaintext credential is returned once. Only its SHA-256 verifier is
  stored in `node_bindings`.
- Each node connects with its own restricted PostgreSQL login. The login
  inherits only `symphony_staging_runtime` and cannot access production.
- `authenticate_node` matches `session_user` to the requested node and active
  binding. A session advisory lock rejects a simultaneous duplicate or clone.
- Rotation returns a new credential once, terminates old sessions, revokes the
  old binding, and advances the credential version atomically.
- Revocation changes the login to `NOLOGIN`, terminates existing sessions, and
  disables the node and active binding atomically.
- PostgreSQL releases the session lock when the connection closes, so a clean
  restart or a restart after connection loss can authenticate with a new random
  `nodeInstanceId`.
- Neither function is callable by `PUBLIC`, Supabase API roles, or
  `service_role`.

The caller must save the returned credential directly into an approved
machine-local secret store. It must never be passed on a command line, written
to a workspace file, committed, logged, or copied to a synchronized location.

## Gates

The migration fails closed unless the reconciled ARO-168 contract v2 is
present. Applying this migration to shared staging requires separate human
approval. This repository change does not provision any physical computer.
Rollback also fails closed while any provisioned principal exists; it never
silently deletes a node identity or leaves an orphaned credential.

ARO-164 still owns routing claim, fallback, lease, and generation semantics.
