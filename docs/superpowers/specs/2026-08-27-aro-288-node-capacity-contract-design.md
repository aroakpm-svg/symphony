# ARO-288 Node Capacity Contract Design

## Goal

Make Amy, Matt, and Han each enforce one node-wide claim capacity of exactly three across the
Central-Brain and Project-Management profiles. Three nodes therefore admit at most nine concurrent
active claims, and a tenth candidate waits without creating a claim, workspace, or partial effect.

## Scope boundary

ARO-288 extends the existing ARO-164 staging claim contract. It does not add a scheduler, queue,
semaphore, slot table, project-level capacity, or second claim path. It does not alter the
`ClaimService` lifecycle, enable multi-project polling or dispatch, create a workspace, resolve a
credential, deploy code, or change Production or a shared database.

The repository change makes a node capacity of three an explicit startup requirement and proves
the existing database enforcement under cross-project and three-node contention. Setting the Amy,
Matt, and Han staging node rows to three is rollout data and remains outside this pull request.

## Existing authority and invariant

`symphony_staging.nodes.claim_capacity` remains the only capacity authority. ARO-164's
`claim_issue` function already locks the selected node row, counts unexpired active claims for that
node, and raises SQLSTATE `53300` before inserting when `active_count >= node_capacity`.

The count is deliberately independent of project identity. Issues selected from either approved
profile consume the same node-wide capacity. `project_profiles` continues to reject all capacity
fields, so no project can reserve or multiply slots.

## Read-only node-capacity contract

Add one claim-API function:

```sql
symphony_staging.current_node_claim_capacity() returns integer
```

The security-definer function resolves exactly one active node through `session_user`,
`node_login_principals`, and the active node row. It returns that row's `claim_capacity`. Missing,
revoked, inactive, or ambiguous identity fails closed. It exposes no credential or unrelated node
data.

The ARO-164 grant helper is replaced in a new forward migration so existing and future node login
roles receive execute access through the same claim API provisioning path. Direct reads or writes
to `nodes` remain unavailable to runtime roles. The rollback removes the read function and restores
the prior claim-API grant helper without changing node rows, claims, or Production objects.

## Runtime startup gate

`SymphonyElixir.ClaimConnection.connect/2` keeps its current order:

1. establish verified TLS;
2. authenticate the configured node and instance;
3. read `current_node_claim_capacity()` on the authenticated connection;
4. return the connection only when the value is exactly integer `3`.

Any other value, empty or multi-row result, database error, or malformed response stops the
connection and returns a bounded error. Errors never contain connection strings, credentials, raw
rows, or attacker-controlled database values.

This read is a startup assertion, not a local capacity cache. Every claim continues to use the
current database value inside the ARO-164 atomic transaction. A capacity change therefore takes
effect on the next claim without restarting `ClaimService`.

## Capacity changes

Increasing capacity permits later claims up to the new limit. Decreasing capacity below the number
of active claims does not terminate, release, rewrite, or reassign those claims. It only prevents a
new claim until active unexpired claims fall below the new limit.

Lease expiry, release, completion, takeover, routing revision, Linear revision, and generation
fencing remain owned by ARO-164. ARO-288 changes none of their ordering or semantics.

## Failure and side-effect boundary

Capacity exhaustion is a normal wait result at the orchestration boundary. The failed database
transaction inserts no claim and advances no generation. Since workspace creation and effects are
downstream of successful claim acquisition, an over-capacity candidate cannot create either.

Database unavailability and uncertain claim outcomes retain the existing fail-closed behavior;
ARO-288 does not convert them into available capacity or introduce fallback execution.

## Interfaces and files

The implementation is limited to:

- a forward and rollback staging migration for the read-only capacity API and grants;
- `SymphonyElixir.ClaimConnection` startup validation;
- focused connection, migration, and disposable PostgreSQL capacity tests;
- concise documentation of the node-wide three-slot contract.

No project-profile shape, `ClaimService` public function, scheduler state, workspace path, or
Production migration changes.

## Testing

### Unit and static contract tests

- exact integer `3` succeeds;
- every other integer, missing row, duplicate row, malformed result, and database error fails with a
  bounded reason;
- the connection is stopped after either authentication or capacity validation fails;
- migration and rollback remain staging-only, function-only, and scoped to ARO-288 objects;
- the grant helper covers existing and future node login roles without granting table access.

### Disposable PostgreSQL proof

Reuse the existing cross-machine claims harness and ARO-164 claim function. Do not create a second
capacity fixture or store. Prove:

- one node accepts three active claims whose issue fixtures represent both projects and rejects the
  fourth;
- Amy, Matt, and Han together accept nine active claims and reject a tenth routed to a full node;
- rejected claims create no claim row and no later workspace/effect callback is eligible;
- expiry, release, completion, takeover, and stale generation behavior is unchanged;
- lowering capacity preserves legal active claims but blocks new claims;
- raising capacity admits later claims up to the new value;
- restart and re-authentication reject any node whose capacity is not exactly three.

The repository gates remain `make all`, PR-description validation, exact-head Codex review, and zero
unresolved P1-P4 threads.

## Acceptance mapping

- Node-level only: the sole authority is `nodes.claim_capacity`; project profiles still reject slot
  fields.
- Two projects share three slots: the database counts all active node claims without project
  partitioning, with mixed-profile contention tests.
- Fleet maximum nine: the disposable three-node proof admits nine and rejects the tenth.
- No partial work: exhaustion occurs atomically before claim insert, generation advance, workspace,
  or effects.
- Safe reload/change: the claim transaction reads capacity on every acquisition; reductions retain
  existing claims and block only new claims.
- Existing lifecycle: ARO-164 owns lease, generation, heartbeat, takeover, and release behavior;
  `ClaimService` lifecycle is unchanged.
- No external mutation: this pull request does not update Amy, Matt, or Han rows, shared databases,
  Production, deployment, credentials, permissions, or secrets.

## Downstream handoff

ARO-287 may consume successful claim acquisition as its only capacity authorization after profile
resolution, routing, and preflight. ARO-286 may expose the bounded capacity/startup failure stage in
secret-safe diagnostics. ARO-285 may count the disposable proof as code-level evidence, but final
acceptance still requires the three rollout nodes to report capacity three and pass the live fleet
test.
