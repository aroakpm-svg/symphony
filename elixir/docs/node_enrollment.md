# Node enrollment and authentication

ARO-169 adds the shared staging entrance required before ARO-139, ARO-140,
or ARO-141 may provision a physical computer.

## Security model

- `provision_node` generates a random node ID, binding ID, login role, and
  256-bit credential inside one PostgreSQL transaction.
- The plaintext credential is returned once. Only its SHA-256 verifier is
  stored in `node_bindings`.
- Each node connects with its own restricted PostgreSQL login. The login is
  not a member of `symphony_staging_runtime`, has no table privileges, and
  cannot access production.
- `authenticate_node` matches `session_user` to the requested node and active
  binding. A server-owned instance row records the PostgreSQL backend PID and
  backend start time; a second instance is rejected while that backend exists.
- Provisioning grants each login only staging schema usage and direct execution
  of `authenticate_node`.
  Future runtime entry points must repeat the active-node and current-instance gate;
  they must never grant direct table access to node logins.
- Rotation returns a new credential once, revokes the old binding, and advances
  the credential version atomically.
- Revocation changes the login to `NOLOGIN`, removes its authentication execute
  grant, and disables the node and active binding atomically. An already-open
  transport connection remains unprivileged and cannot use runtime tables.
- A client cannot clear the instance gate with advisory-lock functions. After
  the recorded PostgreSQL backend disappears, a restart can atomically replace
  the stale row with a new random `nodeInstanceId`. Instance history prevents
  reuse of an old ID.
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
