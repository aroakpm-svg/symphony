# ARO-288 Node Capacity Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce one node-wide capacity of exactly three for each Symphony node and prove that three nodes admit nine active claims while a tenth waits.

**Architecture:** Keep `symphony_staging.nodes.claim_capacity` and ARO-164 `claim_issue` as the only capacity authority. Add a function-only read of the authenticated node's current capacity, validate exact capacity three during `ClaimConnection` startup, and extend the existing disposable PostgreSQL claims proof for mixed-project, three-node, and capacity-change behavior.

**Tech Stack:** Elixir 1.19, OTP 28, Postgrex, PostgreSQL PL/pgSQL, ExUnit, Bash, psql.

**Spec:** `docs/superpowers/specs/2026-08-27-aro-288-node-capacity-contract-design.md`

## Global Constraints

- `nodes.claim_capacity` remains the only capacity authority.
- Capacity is node-wide and must not appear in `project_profiles`.
- Every enabled runtime node must observe exact integer capacity `3` at startup.
- Claim acquisition continues to read capacity atomically inside ARO-164 `claim_issue`.
- Do not change `ClaimService` lifecycle or add a scheduler, queue, semaphore, slot table, or second claim path.
- Do not update Amy, Matt, or Han rows, a shared database, Production, deployment, credentials, permissions, or secrets.
- Every new public Elixir function requires an adjacent `@spec`.
- Test-first development is mandatory; each production change follows a witnessed RED then GREEN cycle.

---

### Task 1: Read-only node capacity database contract

**Files:**
- Create: `elixir/priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract.sql`
- Create: `elixir/priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract.down.sql`
- Create: `elixir/test/symphony_elixir/node_capacity_contract_migration_test.exs`

**Interfaces:**
- Consumes: `symphony_staging.nodes.claim_capacity`, `node_login_principals`, and the ARO-164 `grant_claim_api_to_node_login()` trigger helper.
- Produces: `symphony_staging.current_node_claim_capacity() returns integer` and contract version row `node-capacity-contract = 1`.

- [ ] **Step 1: Write the failing migration contract tests**

Create `node_capacity_contract_migration_test.exs` with literal assertions covering the forward and rollback files:

```elixir
defmodule SymphonyElixir.NodeCapacityContractMigrationTest do
  use ExUnit.Case, async: true

  @migration Path.expand(
               "../../priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract.sql",
               __DIR__
             )
  @rollback Path.expand(
              "../../priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract.down.sql",
              __DIR__
            )

  test "capacity API is function-only, session-bound, and staging-only" do
    sql = File.read!(@migration)

    assert sql =~ "function symphony_staging.current_node_claim_capacity()"
    assert sql =~ "principals.login_role = session_user"
    assert sql =~ "principals.revoked_at is null"
    assert sql =~ "nodes.status = 'active'"
    assert sql =~ "select nodes.claim_capacity"
    assert sql =~ "grant_claim_api_to_node_login"
    assert sql =~ "'node-capacity-contract', 1"
    refute sql =~ "symphony_production."
    refute sql =~ "grant select on symphony_staging.nodes"
  end

  test "rollback removes only ARO-288 objects and restores the claim grant helper" do
    sql = File.read!(@rollback)

    assert sql =~ "where contract_name = 'node-capacity-contract'"
    assert sql =~ "drop function if exists symphony_staging.current_node_claim_capacity()"
    assert sql =~ "create or replace function symphony_staging.grant_claim_api_to_node_login()"
    refute sql =~ "drop table"
    refute sql =~ "symphony_production."
  end
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
cd elixir
mix test test/symphony_elixir/node_capacity_contract_migration_test.exs
```

Expected: FAIL because both ARO-288 migration files are missing.

- [ ] **Step 3: Implement the forward migration**

Create a transactional migration that:

1. verifies the ARO-164 `cross-machine-claims` contract exists;
2. creates `current_node_claim_capacity()` as `security definer` with `set search_path = pg_catalog, pg_temp`;
3. selects exactly one active node capacity through `session_user` and non-revoked `node_login_principals`;
4. raises bounded SQL errors when identity is missing or ambiguous;
5. revokes execute from `public`, `anon`, `authenticated`, `service_role`, `symphony_staging_runtime`, and `symphony_staging_provisioner`;
6. replaces `grant_claim_api_to_node_login()` so its dynamic grant list contains the six existing ARO-164 functions plus `current_node_claim_capacity()`;
7. grants the new function to every existing non-revoked principal using identifier-safe `format('%I', principal.login_role)`;
8. inserts contract row `('node-capacity-contract', 1, '20260827000000_aro_288_node_capacity_contract')`.

The read function's body must use this cardinality pattern rather than `limit 1`:

```sql
select count(*), min(nodes.claim_capacity)
  into matching_nodes, capacity
from symphony_staging.node_login_principals principals
join symphony_staging.nodes nodes on nodes.node_id = principals.node_id
where principals.login_role = session_user
  and principals.revoked_at is null
  and nodes.status = 'active';

if matching_nodes <> 1 then
  raise exception using errcode = '28000', message = 'node capacity identity rejected';
end if;

return capacity;
```

- [ ] **Step 4: Implement the rollback migration**

The rollback must:

1. delete only the `node-capacity-contract` row;
2. revoke `current_node_claim_capacity()` from every current node login role;
3. replace `grant_claim_api_to_node_login()` with the exact pre-ARO-288 six-function grant list;
4. drop only `current_node_claim_capacity()`;
5. leave node rows, `claim_capacity`, claims, routes, and all ARO-164 functions intact.

- [ ] **Step 5: Run migration tests and format checks**

Run:

```bash
mix test test/symphony_elixir/node_capacity_contract_migration_test.exs
mix format --check-formatted test/symphony_elixir/node_capacity_contract_migration_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit Task 1**

```bash
git add elixir/priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract.sql \
  elixir/priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract.down.sql \
  elixir/test/symphony_elixir/node_capacity_contract_migration_test.exs
git commit -m "Add node-wide capacity contract"
```

---

### Task 2: Exact-three startup gate

**Files:**
- Modify: `elixir/lib/symphony_elixir/claim_connection.ex`
- Modify: `elixir/test/symphony_elixir/claim_connection_test.exs`

**Interfaces:**
- Consumes: `symphony_staging.authenticate_node(uuid, uuid)` and `current_node_claim_capacity()` from Task 1.
- Produces: `ClaimConnection.capacity_result/1 :: :ok | {:error, atom()}` for bounded exact-three validation; `connect/2` checks capacity before the stateful authentication call and returns a connection only after both pass.

- [ ] **Step 1: Extend the adapter fixture and write failing tests**

Keep authentication behavior real within the fake adapter and distinguish SQL by matching the query text. Add adapter capacity responses for hosts or node IDs representing `3`, `2`, empty, malformed, duplicate, and database-error results. Add these tests:

```elixir
test "connect validates exact node capacity before stateful authentication", %{ca_path: ca_path} do
  settings = connection_settings(ca_path, "accepted-capacity-3")
  assert {:ok, connection} = ClaimConnection.connect(settings, Adapter)
  assert Process.alive?(connection)
  GenServer.stop(connection)
end

test "connect stops the connection for non-three or unverifiable capacity", %{ca_path: ca_path} do
  for node_id <- ["capacity-2", "capacity-empty", "capacity-malformed", "capacity-duplicate", "capacity-error"] do
    assert {:error, reason} = ClaimConnection.connect(connection_settings(ca_path, node_id), Adapter)
    assert reason in [:node_capacity_mismatch, :node_capacity_unavailable]
  end
end

test "accepts only the exact node capacity contract" do
  assert :ok = ClaimConnection.capacity_result({:ok, %Postgrex.Result{rows: [[3]], num_rows: 1}})

  for result <- [
        {:ok, %Postgrex.Result{rows: [[2]], num_rows: 1}},
        {:ok, %Postgrex.Result{rows: [], num_rows: 0}},
        {:ok, %Postgrex.Result{rows: [["3"]], num_rows: 1}},
        {:ok, %Postgrex.Result{rows: [[3], [3]], num_rows: 2}}
      ] do
    assert {:error, :node_capacity_mismatch} = ClaimConnection.capacity_result(result)
  end

  assert {:error, :node_capacity_unavailable} =
           ClaimConnection.capacity_result({:error, {:unsafe_database_text, "secret"}})
end
```

The mutation caught by these tests is removing the post-auth capacity query or accepting any positive capacity.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
mix test test/symphony_elixir/claim_connection_test.exs
```

Expected: FAIL because `capacity_result/1` and the capacity query do not exist.

- [ ] **Step 3: Implement bounded capacity decoding**

Add adjacent public spec and clauses:

```elixir
@doc false
@spec capacity_result(term()) :: :ok | {:error, :node_capacity_mismatch | :node_capacity_unavailable}
def capacity_result({:ok, %Postgrex.Result{rows: [[3]], num_rows: 1}}), do: :ok
def capacity_result({:ok, %Postgrex.Result{}}), do: {:error, :node_capacity_mismatch}
def capacity_result({:error, _reason}), do: {:error, :node_capacity_unavailable}
```

- [ ] **Step 4: Gate connection return after capacity validation**

Before stateful authentication and instance registration, issue exactly:

```elixir
select symphony_staging.current_node_claim_capacity()
```

with the existing 12-second boundary. Invoke `authenticate_node` only after
`capacity_result/1 == :ok`, so a capacity failure cannot commit a phantom instance. Return the
connection only after both checks pass. On either authentication or capacity failure, stop the live
connection before returning the bounded error. Do not inspect or interpolate the adapter response.

- [ ] **Step 5: Run focused tests and quality checks**

Run:

```bash
mix format lib/symphony_elixir/claim_connection.ex test/symphony_elixir/claim_connection_test.exs
mix test test/symphony_elixir/claim_connection_test.exs test/symphony_elixir/claim_service_test.exs
mix specs.check
mix credo lib/symphony_elixir/claim_connection.ex test/symphony_elixir/claim_connection_test.exs --strict
```

Expected: PASS. On Windows, if Credo fails only because unrelated files were converted to CRLF,
record that local environment limitation and rely on the Linux `make all` gate; do not rewrite
unrelated files.

- [ ] **Step 6: Commit Task 2**

```bash
git add elixir/lib/symphony_elixir/claim_connection.ex \
  elixir/test/symphony_elixir/claim_connection_test.exs
git commit -m "Require three claim slots at node startup"
```

---

### Task 3: Mixed-project and fleet capacity proof

**Files:**
- Modify: `.github/scripts/test-cross-machine-claims.sh`
- Modify: `elixir/test/symphony_elixir/cross_machine_claims_migration_test.exs`

**Interfaces:**
- Consumes: ARO-164 `claim_issue`, claim leases/generations/routes, and Task 1 capacity read function.
- Produces: disposable PostgreSQL proof for mixed-project three-slot contention, fleet nine-slot maximum, tenth-candidate wait, and capacity changes.

- [ ] **Step 1: Write failing static assertions for the disposable proof**

Add a test that reads `.github/scripts/test-cross-machine-claims.sh` and requires literal proof labels:

```elixir
test "disposable proof covers mixed-project node and three-node fleet capacity" do
  script = File.read!(Path.expand("../../../.github/scripts/test-cross-machine-claims.sh", __DIR__))

  for marker <- [
        "ARO288-MIXED-CB-1",
        "ARO288-MIXED-PM-1",
        "ARO288-FLEET-09",
        "ARO288-FLEET-10",
        "ARO288-CAPACITY-LOWER",
        "ARO288-CAPACITY-RAISE"
      ] do
    assert script =~ marker
  end

  assert script =~ "20260827000000_aro_288_node_capacity_contract.sql"
  assert script =~ "current_node_claim_capacity()"
end
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
mix test test/symphony_elixir/cross_machine_claims_migration_test.exs
```

Expected: FAIL because the ARO-288 proof markers are absent.

- [ ] **Step 3: Apply ARO-288 migration in the disposable harness**

Add forward and rollback variables beside the ARO-164 migration variables. After creating three
node roles, set all disposable node capacities to `3`, apply the ARO-288 migration, and assert each
node role reads exactly `3` from `current_node_claim_capacity()` while direct table reads remain
denied.

- [ ] **Step 4: Prove one-node mixed-project contention**

Insert four exclusive routes to node A with issue identifiers alternating `ARO288-MIXED-CB-*` and
`ARO288-MIXED-PM-*`. Acquire the first three. Assert the fourth command fails with capacity
exhaustion, then assert:

```sql
select count(*) = 3
from symphony_staging.issue_claims
where issue_id like 'ARO288-MIXED-%'
  and completed_at is null
  and released_at is null;
```

Also assert no generation row exists for the rejected fourth issue. Release the three claims before
the fleet proof.

- [ ] **Step 5: Prove fleet nine and tenth wait**

Create three exclusive routes per node named `ARO288-FLEET-01` through `ARO288-FLEET-09`, acquire
all nine, and assert exactly three active claims per node. Route `ARO288-FLEET-10` to node C and
assert the claim call fails. Verify no claim or generation row exists for issue 10.

- [ ] **Step 6: Prove capacity lowering and raising**

With three active node-A claims, lower its capacity to `2`; verify all three remain active and
renewable while `ARO288-CAPACITY-LOWER` cannot claim. Release two claims, verify one remains, raise
capacity to `3`, and verify `ARO288-CAPACITY-RAISE` can claim. Retain the existing expiry, takeover,
and stale-generation assertions unchanged.

- [ ] **Step 7: Run static and disposable PostgreSQL tests**

Run:

```bash
mix test test/symphony_elixir/cross_machine_claims_migration_test.exs
TEST_DATABASE_URL="$TEST_DATABASE_URL" bash .github/scripts/test-cross-machine-claims.sh
```

Expected: both PASS. If no disposable PostgreSQL URL exists locally, the static test must pass and
the GitHub Linux job must execute the script before completion is claimed.

- [ ] **Step 8: Commit Task 3**

```bash
git add .github/scripts/test-cross-machine-claims.sh \
  elixir/test/symphony_elixir/cross_machine_claims_migration_test.exs
git commit -m "Prove three-node nine-slot claim capacity"
```

---

### Task 4: Contract documentation and final verification

**Files:**
- Modify: `elixir/README.md`
- Modify: `SPEC.md`

**Interfaces:**
- Consumes: the exact-three startup gate and disposable database proof from Tasks 1-3.
- Produces: operator-facing node-capacity contract and the ARO-287 handoff boundary.

- [ ] **Step 1: Document the node-wide contract**

Add a concise section stating:

- `claim_capacity` belongs to the node and must equal three for an enabled runtime;
- Central-Brain and Project-Management share those three claims;
- project profiles cannot define capacity;
- the database claim transaction, not an Elixir semaphore, authorizes a slot;
- lowering capacity preserves existing active claims and blocks only new claims;
- code installation does not update the Amy, Matt, or Han node rows.

Update the relevant SPEC capacity paragraphs without changing unrelated host-selection behavior.

- [ ] **Step 2: Run the focused suite**

```bash
cd elixir
mix test test/symphony_elixir/node_capacity_contract_migration_test.exs \
  test/symphony_elixir/claim_connection_test.exs \
  test/symphony_elixir/claim_service_test.exs \
  test/symphony_elixir/cross_machine_claims_migration_test.exs \
  test/symphony_elixir/project_profiles_test.exs
mix format --check-formatted
mix specs.check
```

Expected: PASS.

- [ ] **Step 3: Run the complete repository gate**

From `elixir/` run:

```bash
make all
```

Expected: PASS. Preserve complete output as evidence. Do not claim completion from focused tests
alone.

- [ ] **Step 4: Review the final diff for forbidden scope**

Run:

```bash
git diff origin/main...HEAD --name-only
git diff origin/main...HEAD --check
rg -n "symphony_production|project.*slots|total_slots" \
  priv/symphony_migrations/20260827000000_aro_288_node_capacity_contract*.sql \
  lib/symphony_elixir/claim_connection.ex
```

Expected: only the planned files appear; no Production reference or project-level slot authority is
introduced.

- [ ] **Step 5: Commit documentation**

```bash
git add elixir/README.md SPEC.md
git commit -m "Document node-wide three-slot capacity"
```

- [ ] **Step 6: Push, open the ARO-288 PR, and request review**

Push `codex/aro-288-node-capacity`, open one PR using the repository template and ARO-288 scope
contract, then request `@codex review`. Do not merge. Monitor the exact head until required checks
finish and resolve only threads whose root causes are fixed and verified.

## Plan self-review

- Spec coverage: sole node authority, exact-three startup, mixed-project contention, fleet nine,
  tenth wait, capacity changes, unchanged lease/generation lifecycle, and no external mutation each
  map to a task above.
- Placeholder scan: the plan contains no deferred implementation markers or unspecified error
  handling.
- Type consistency: `current_node_claim_capacity()` returns one integer;
  `capacity_result/1` accepts the Postgrex query result and returns only `:ok`,
  `:node_capacity_mismatch`, or `:node_capacity_unavailable` as defined in Task 2.
