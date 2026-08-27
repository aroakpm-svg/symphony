# ARO-287 Multi-Project Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Poll both approved Linear projects in one Symphony runtime and dispatch only refreshed issues exclusively routed to the current node through the unique approved repository profile.

**Architecture:** Keep the single orchestrator, node-wide capacity counter, and ARO-164 claim path. Add profile-scoped Linear reads, a pure aggregation/authorization boundary, and a read-only exclusive-routing check backed by the existing claim connection; pass the approved profile into the existing repository preflight before claim acquisition.

**Tech Stack:** Elixir 1.19, OTP 28, Ecto, Postgrex, Req, ExUnit, Mox-free injected function seams.

**Spec:** `docs/superpowers/specs/2026-08-27-aro-287-multi-project-dispatch-design.md`

## Global Constraints

- Keep exactly one scheduler, queue, claim path, and node-wide capacity contract.
- Use only the complete ARO-289 version-1 approved profile set.
- Require `exclusive` routing to the authenticated current node; all uncertainty fails closed.
- Do not add Production, deployment, schema, credential installation, or workspace-isolation behavior.
- Do not let one profile failure or one ineligible candidate block other profiles or candidates.
- Public `def` functions in `elixir/lib` require adjacent `@spec`; final gates are `mix specs.check` and `make all`.

---

### Task 1: Bind Linear issues to an exact approved profile

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_profiles.ex`
- Modify: `elixir/lib/symphony_elixir/linear/issue.ex`
- Modify: `elixir/lib/symphony_elixir/linear/client.ex`
- Test: `elixir/test/symphony_elixir/project_profiles_test.exs`
- Test: `elixir/test/symphony_elixir/linear_client_test.exs`

**Interfaces:**
- Produces: `ProjectProfiles.list/1 :: [profile()]`
- Produces: `ProjectProfiles.fetch_by_linear_project_id/2 :: {:ok, profile()} | :error`
- Produces: `Issue.project_id`, `Issue.project_slug`, `Issue.project_profile`, and `Issue.repository`

- [ ] **Step 1: Write failing exact-identity tests**

```elixir
assert Enum.map(ProjectProfiles.list(profiles), & &1.key) == ["central-brain", "project-management"]
assert {:ok, %{key: "central-brain"}} =
         ProjectProfiles.fetch_by_linear_project_id(profiles, "d0acfb71-f68c-4a9f-8a1a-477265d3c3ec")
assert :error = ProjectProfiles.fetch_by_linear_project_id(profiles, "unknown")
```

Add a Linear normalization test whose payload contains:

```elixir
"project" => %{"id" => "project-uuid", "slugId" => "central-brain"}
```

and assert the normalized issue stores both values while profile/repository remain `nil` until local authorization.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `cd elixir && mix test test/symphony_elixir/project_profiles_test.exs test/symphony_elixir/linear_client_test.exs`

Expected: FAIL because the lookup/list functions and issue project fields do not exist.

- [ ] **Step 3: Implement exact lookup and normalized project evidence**

Add stable enumeration and UUID lookup over the already validated map:

```elixir
@spec list(t()) :: [profile()]
def list(%{profiles: profiles}), do: profiles |> Map.values() |> Enum.sort_by(& &1.key)

@spec fetch_by_linear_project_id(t(), String.t()) :: {:ok, profile()} | :error
def fetch_by_linear_project_id(profiles, project_id) do
  case Enum.filter(list(profiles), &(&1.linear_project_id == project_id)) do
    [profile] -> {:ok, profile}
    _ -> :error
  end
end
```

Request `project { id slugId }` in candidate and ID refresh queries, normalize it into `Issue`, and never derive repository from Linear content.

- [ ] **Step 4: Run focused tests and verify pass**

Run: `cd elixir && mix test test/symphony_elixir/project_profiles_test.exs test/symphony_elixir/linear_client_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```text
git add elixir/lib/symphony_elixir/project_profiles.ex elixir/lib/symphony_elixir/linear/issue.ex elixir/lib/symphony_elixir/linear/client.ex elixir/test/symphony_elixir/project_profiles_test.exs elixir/test/symphony_elixir/linear_client_test.exs
git commit -m "Add exact project identity to Linear issues"
```

### Task 2: Poll approved profiles independently and aggregate safely

**Files:**
- Create: `elixir/lib/symphony_elixir/multi_project_poll.ex`
- Create: `elixir/test/symphony_elixir/multi_project_poll_test.exs`
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Modify: `elixir/lib/symphony_elixir/linear/client.ex`

**Interfaces:**
- Consumes: `ProjectProfiles.list/1`
- Produces: `Tracker.fetch_candidate_issues(profile())`
- Produces: `MultiProjectPoll.fetch(profiles, fetcher, opts) :: %{candidates: [Issue.t()], outcomes: map(), ambiguous_issue_ids: MapSet.t()}`

- [ ] **Step 1: Write failing aggregation and isolation tests**

```elixir
fetcher = fn
  %{key: "central-brain"} -> {:ok, [issue("one", "central-id")]}
  %{key: "project-management"} -> {:ok, [issue("two", "pm-id")]}
end

assert %{candidates: candidates, outcomes: outcomes} = MultiProjectPoll.fetch(profiles, fetcher)
assert Enum.map(candidates, & &1.id) == ["one", "two"]
assert outcomes["central-brain"].status == :ok
assert outcomes["project-management"].status == :ok
```

Add cases where Central-Brain times out but Project-Management succeeds, the same UUID appears in both profiles, and the error term contains a secret string. Assert successful candidates remain, duplicate UUID is excluded, and outcomes contain only stable categories/profile keys.

- [ ] **Step 2: Run the new test and verify failure**

Run: `cd elixir && mix test test/symphony_elixir/multi_project_poll_test.exs`

Expected: FAIL because `MultiProjectPoll` and profile-scoped tracker fetch do not exist.

- [ ] **Step 3: Implement profile-scoped polling**

Change Linear pagination to take `profile.linear_project_id` (query by project ID, not a global slug). Implement `MultiProjectPoll.fetch/3` with isolated `Task.async_stream` calls, finite per-profile timeout, stable profile ordering, UUID grouping, and secret-safe classifications:

```elixir
%{candidates: unique, outcomes: outcomes, ambiguous_issue_ids: MapSet.new(ambiguous_ids)}
```

Return successful candidates even when another task exits or times out. Do not sleep inside this module; emit retry metadata for the orchestrator's timer-driven backoff.

- [ ] **Step 4: Run focused polling and client tests**

Run: `cd elixir && mix test test/symphony_elixir/multi_project_poll_test.exs test/symphony_elixir/linear_client_test.exs test/symphony_elixir/extensions_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```text
git add elixir/lib/symphony_elixir/multi_project_poll.ex elixir/lib/symphony_elixir/tracker.ex elixir/lib/symphony_elixir/linear/adapter.ex elixir/lib/symphony_elixir/linear/client.ex elixir/test/symphony_elixir/multi_project_poll_test.exs elixir/test/symphony_elixir/linear_client_test.exs elixir/test/symphony_elixir/extensions_test.exs
git commit -m "Aggregate approved project polls independently"
```

### Task 3: Add read-only exclusive-routing eligibility on the existing claim connection

**Files:**
- Modify: `elixir/lib/symphony_elixir/claim_service.ex`
- Test: `elixir/test/symphony_elixir/claim_service_test.exs`
- Test: `elixir/test/symphony_elixir/claim_config_test.exs`

**Interfaces:**
- Produces: `ClaimService.exclusive_route(Issue.t()) :: {:ok, %{routing_revision: pos_integer()}} | {:ineligible, atom()} | {:error, atom()}`
- Constraint: this call uses the claim service's existing Postgrex connection and performs no write or claim.

- [ ] **Step 1: Write failing routing matrix tests**

Using the existing fake/query seam, cover these rows:

```elixir
assert {:ok, %{routing_revision: 7}} = exclusive_route("exclusive", current_node_id, 7)
assert {:ineligible, :wrong_node} = exclusive_route("exclusive", other_node_id, 7)
assert {:ineligible, :missing_routing} = exclusive_route(nil, nil, nil)
assert {:ineligible, :non_exclusive_routing} = exclusive_route("unassigned", nil, 3)
assert {:ineligible, :non_exclusive_routing} = exclusive_route("preferred-with-fallback", current_node_id, 4)
```

Also assert disconnected/query errors return a stable atom without connection strings.

- [ ] **Step 2: Run the claim tests and verify failure**

Run: `cd elixir && mix test test/symphony_elixir/claim_service_test.exs test/symphony_elixir/claim_config_test.exs`

Expected: FAIL because `exclusive_route/1` is undefined.

- [ ] **Step 3: Implement read-only routing lookup**

Add a GenServer call that executes a parameterized select by `issue.id`, compares policy and target against `state.settings.node_id`, and returns only stable results. It must not add a process, connection, schema, or mutation. Preserve `claim_query/2` as the final atomic routing and capacity authority.

- [ ] **Step 4: Run focused claim tests and verify pass**

Run: `cd elixir && mix test test/symphony_elixir/claim_service_test.exs test/symphony_elixir/claim_config_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```text
git add elixir/lib/symphony_elixir/claim_service.ex elixir/test/symphony_elixir/claim_service_test.exs elixir/test/symphony_elixir/claim_config_test.exs
git commit -m "Check exclusive routing before claims"
```

### Task 4: Authorize refreshed candidates and continue past failures

**Files:**
- Create: `elixir/lib/symphony_elixir/dispatch_candidate.ex`
- Create: `elixir/test/symphony_elixir/dispatch_candidate_test.exs`
- Modify: `elixir/lib/symphony_elixir/project_repo_preflight.ex`
- Modify: `elixir/test/symphony_elixir/project_repo_preflight_test.exs`

**Interfaces:**
- Consumes: refreshed `Issue`, ARO-289 profiles, `ClaimService.exclusive_route/1`
- Produces: `DispatchCandidate.authorize(issue, profiles, opts) :: {:ok, Issue.t()} | {:skip, atom()} | {:retry, atom()}`
- Produces: `ProjectRepoPreflight.check(profile(), command_runner())`

- [ ] **Step 1: Write failing authorization matrix tests**

Build one valid issue and vary a single condition per test. Assert valid authorization binds the approved profile and repository:

```elixir
assert {:ok, authorized} = DispatchCandidate.authorize(issue, profiles, route_reader: route_reader)
assert authorized.project_profile.key == "central-brain"
assert authorized.repository == "aroakpm-svg/aroak-central-brain"
```

Assert `{:skip, reason}` for inactive state, missing `symphony-worker`, unknown/changed project, missing/non-exclusive/wrong-node routing, and `{:retry, :routing_unavailable}` for transient routing failure. Add profile-driven preflight tests for both repositories and mismatched GitHub metadata.

- [ ] **Step 2: Run focused tests and verify failure**

Run: `cd elixir && mix test test/symphony_elixir/dispatch_candidate_test.exs test/symphony_elixir/project_repo_preflight_test.exs`

Expected: FAIL because authorization and profile-parameterized preflight do not exist.

- [ ] **Step 3: Implement the pure authorization pipeline**

Implement checks in the ticket order: refreshed active state and label, unique UUID lookup, polled/refreshed identity agreement, exclusive routing, then approved profile binding. Parameterize `ProjectRepoPreflight` from `profile.repository` and `profile.canonical_branch`; retain required-script policy by approved profile key and reject unknown profile structs.

- [ ] **Step 4: Run focused tests and verify pass**

Run: `cd elixir && mix test test/symphony_elixir/dispatch_candidate_test.exs test/symphony_elixir/project_repo_preflight_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```text
git add elixir/lib/symphony_elixir/dispatch_candidate.ex elixir/lib/symphony_elixir/project_repo_preflight.ex elixir/test/symphony_elixir/dispatch_candidate_test.exs elixir/test/symphony_elixir/project_repo_preflight_test.exs
git commit -m "Authorize project dispatch candidates fail closed"
```

### Task 5: Integrate with the single orchestrator and existing claim/capacity path

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Create: `elixir/test/symphony_elixir/multi_project_dispatch_test.exs`

**Interfaces:**
- Consumes: `MultiProjectPoll.fetch/3`, `DispatchCandidate.authorize/3`, existing `ClaimService.claim/2`
- Produces: one poll cycle that keeps per-profile retry state and invokes the unchanged worker dispatch path only for authorized issues.

- [ ] **Step 1: Write failing end-to-end orchestrator tests**

Use injected fetch/refresh/route/preflight/claim functions to prove:

```elixir
assert dispatched_ids == ["later-eligible"]
assert claim_calls == ["later-eligible"]
```

when the first candidate belongs to the wrong node. Add Amy/Matt/Han parameterized cases across two projects, one-profile timeout with other-profile dispatch, duplicate UUID with zero claims, stale refresh with zero claims, wrong repo with zero claims, and transient Linear/routing failure followed by recovery without process exit.

- [ ] **Step 2: Run orchestrator tests and verify failure**

Run: `cd elixir && mix test test/symphony_elixir/multi_project_dispatch_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs`

Expected: FAIL because the orchestrator still performs one global fetch and lacks per-profile retry state.

- [ ] **Step 3: Integrate without creating a second scheduler**

Extend the existing state with per-profile retry metadata, call the aggregate fetch from the existing `:run_poll_cycle`, iterate all sorted candidates with skip-and-continue semantics, refresh before authorization, run profile repo preflight before `ClaimService.claim/2`, and pass the authorized issue through the existing capacity/worker functions. Use timer scheduling for bounded exponential backoff with jitter; never call blocking sleep.

- [ ] **Step 4: Run integration and regression tests**

Run: `cd elixir && mix test test/symphony_elixir/multi_project_dispatch_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/claim_service_test.exs`

Expected: PASS, with claim calls occurring only after refresh, route authorization, repository preflight, and capacity checks.

- [ ] **Step 5: Commit**

```text
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/core_test.exs elixir/test/symphony_elixir/orchestrator_status_test.exs elixir/test/symphony_elixir/multi_project_dispatch_test.exs
git commit -m "Dispatch exclusive multi-project candidates"
```

### Task 6: Documentation, contract validation, and full quality gate

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md`
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md` only if its canonical sample needs the approved profile set
- Test: all Elixir tests and repository quality gates

**Interfaces:**
- Documents: approved projects, exclusive-only routing, partial poll failure, legacy fallback, and ARO-286 non-goals.

- [ ] **Step 1: Update behavior documentation**

Document this exact order: aggregate enabled profiles, filter/refetch, unique profile resolution,
exclusive current-node routing, repo preflight, node capacity, ARO-164 claim, existing dispatch. State
that one project failure does not substitute evidence or stop another project and that credentials/workspace isolation remain ARO-286.

- [ ] **Step 2: Run formatter/spec checks**

Run: `cd elixir && mix format --check-formatted && mix specs.check`

Expected: PASS.

- [ ] **Step 3: Run the full gate**

Run: `cd elixir && make all`

Expected: PASS with zero failures.

- [ ] **Step 4: Inspect exact diff and secret safety**

Run: `git diff origin/main...HEAD --check` and search changed code/tests for raw API tokens, database URLs, credential values, `Production`, a second scheduler, or a second claim path. Any appearance must be documentation/test-safe or removed.

- [ ] **Step 5: Commit documentation and final fixes**

```text
git add README.md SPEC.md elixir/README.md elixir/WORKFLOW.md
git commit -m "Document exclusive multi-project dispatch"
```

- [ ] **Step 6: Final verification**

Run: `cd elixir && make all`

Expected: PASS on the final exact HEAD.
