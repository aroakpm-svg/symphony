# ARO-289 Versioned Project Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fail-closed, versioned two-project configuration contract with exact approved identities and atomic last-known-good reload behavior.

**Architecture:** A new pure `SymphonyElixir.ProjectProfiles` module owns the wire contract, immutable approval manifest, validation, lookup, and reload result. `Config.Schema` treats the whole validated set as an optional custom Ecto field so absence preserves current single-project behavior, while any present malformed value rejects the entire workflow configuration. No runtime polling or dispatch consumer is added in this ticket.

**Tech Stack:** Elixir 1.19 / OTP 28, Ecto embedded schema, ExUnit, YAML workflow front matter.

**Spec:** `docs/superpowers/specs/2026-08-27-aro-289-versioned-project-profiles-design.md`

## Global Constraints

- Schema version is integer `1` only.
- The complete set contains exactly `central-brain` and `project-management`.
- Approval uses an in-code exact manifest; no signing or key lifecycle exists.
- Profiles never define node slots, claims, databases, deployment, or Production authority.
- Present invalid configuration fails closed; absent configuration leaves multi-project support disabled.
- Reload validates a complete replacement before returning it and preserves last-known-good on failure.
- No orchestrator, polling, claim, workspace creation, deployment, external state, or secret-value changes.

---

### Task 1: Pure project-profile contract

**Files:**
- Create: `elixir/lib/symphony_elixir/project_profiles.ex`
- Create: `elixir/test/symphony_elixir/project_profiles_test.exs`

**Interfaces:**
- Consumes: raw YAML-decoded maps with string or atom keys.
- Produces: `ProjectProfiles.parse/1`, `ProjectProfiles.fetch/2`, `ProjectProfiles.reload/2`, and public `t`, `profile`, and `reason` types.

- [ ] **Step 1: Write the exact happy-path and lookup tests**

Create a `valid_config/0` fixture containing version `1` and both approved profiles from the design spec. Assert:

```elixir
assert {:ok, profiles} = ProjectProfiles.parse(valid_config())
assert {:ok, central} = ProjectProfiles.fetch(profiles, "central-brain")
assert central.repository == "aroakpm-svg/aroak-central-brain"
assert {:ok, project_management} = ProjectProfiles.fetch(profiles, "project-management")
assert project_management.linear_project_id == "708053e0-f42c-4e93-bec4-7abbb37e74af"
assert :error = ProjectProfiles.fetch(profiles, "unknown")
```

- [ ] **Step 2: Run the focused test and verify it fails because the module is missing**

Run: `mix test test/symphony_elixir/project_profiles_test.exs`

Expected: compile failure for undefined `SymphonyElixir.ProjectProfiles`.

- [ ] **Step 3: Implement canonical types, manifest, parse, and fetch**

Create one focused module with these public shapes:

```elixir
@type profile :: %{
  key: String.t(),
  linear_project_id: String.t(),
  repository: String.t(),
  canonical_branch: "main",
  workspace_namespace: String.t(),
  credential_ref: String.t(),
  environment: "local_non_production"
}
@type t :: %{version: 1, profiles: %{required(String.t()) => profile()}}

@spec parse(term()) :: {:ok, t()} | {:error, reason()}
@spec fetch(t(), String.t()) :: {:ok, profile()} | :error
```

Normalize atom keys to strings without converting arbitrary input strings to atoms. Require exact top-level keys `version` and `profiles`, exact profile fields, two list entries, and exact manifest equality for both keys. Return stable errors such as `:invalid_project_profiles`, `{:unsupported_version, value}`, `{:unknown_fields, fields}`, `{:missing_profiles, keys}`, `{:unknown_profile, key}`, and `{:profile_mismatch, key, field}`. Never return the full raw map.

- [ ] **Step 4: Run the happy-path test**

Run: `mix test test/symphony_elixir/project_profiles_test.exs`

Expected: current tests pass.

- [ ] **Step 5: Add table-driven fail-closed tests**

Mutate the valid fixture one condition at a time and assert rejection for:

```elixir
[
  {:version, 2},
  {:unknown_top_level_field, "slots"},
  {:missing_profile, "project-management"},
  {:unknown_profile, "other"},
  {:duplicate_key, "central-brain"},
  {:repository_collision, "aroakpm-svg/aroak-central-brain"},
  {:workspace_collision, "central-brain"},
  {:credential_collision, "github-central-brain"},
  {:profile_field, "repository", "aroakpm-svg/wrong"},
  {:profile_field, "canonical_branch", "develop"},
  {:profile_field, "environment", "production"},
  {:profile_field, "workspace_namespace", "../escape"},
  {:unknown_profile_field, "total_slots", 3}
]
```

Also assert no returned error contains a sentinel credential secret.

- [ ] **Step 6: Implement uniqueness and safety validation**

Validate uniqueness across key, Linear project ID, repository, workspace namespace, and credential reference before manifest comparison. Accept workspace namespaces only when they match `~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/`. Require repository form `owner/name`, branch `main`, and environment `local_non_production`; exact manifest equality remains the final authority check.

- [ ] **Step 7: Add atomic reload tests**

Assert all three results:

```elixir
assert {:ok, first} = ProjectProfiles.reload(nil, valid_config())
assert {:ok, replacement} = ProjectProfiles.reload(first, valid_config())
assert replacement == first
assert {:error, {:unsupported_version, 2}, ^first} =
         ProjectProfiles.reload(first, put_in(valid_config(), ["version"], 2))
assert {:error, {:unsupported_version, 2}, nil} =
         ProjectProfiles.reload(nil, put_in(valid_config(), ["version"], 2))
```

- [ ] **Step 8: Implement `reload/2` as a pure whole-set swap**

```elixir
@spec reload(t() | nil, term()) :: {:ok, t()} | {:error, reason(), t() | nil}
def reload(last_known_good, candidate) do
  case parse(candidate) do
    {:ok, parsed} -> {:ok, parsed}
    {:error, reason} -> {:error, reason, last_known_good}
  end
end
```

- [ ] **Step 9: Verify and commit Task 1**

Run:

```bash
mix test test/symphony_elixir/project_profiles_test.exs
mix format --check-formatted lib/symphony_elixir/project_profiles.ex test/symphony_elixir/project_profiles_test.exs
mix specs.check
```

Commit: `Add versioned project profile contract`

---

### Task 2: Integrate profiles into workflow configuration

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Interfaces:**
- Consumes: `ProjectProfiles.parse/1` from Task 1.
- Produces: optional `settings.project_profiles`, equal to `nil` when absent and a validated `ProjectProfiles.t()` when present.

- [ ] **Step 1: Write Config.Schema integration tests**

Add tests that prove:

```elixir
assert {:ok, settings} = Schema.parse(%{})
assert settings.project_profiles == nil

assert {:ok, settings} =
         Schema.parse(%{"project_profiles" => valid_project_profiles_config()})
assert {:ok, _profile} = ProjectProfiles.fetch(settings.project_profiles, "central-brain")

assert {:error, {:invalid_workflow_config, message}} =
         Schema.parse(%{"project_profiles" => invalid_project_profiles_config()})
assert message =~ "project_profiles"
```

The invalid case must not produce a settings struct with one surviving profile.

- [ ] **Step 2: Run the focused integration tests and verify failure**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs`

Expected: `project_profiles` is not present on `Schema` yet.

- [ ] **Step 3: Add a custom Ecto type and optional field**

Add `ProjectProfilesType` inside `Config.Schema` implementing `Ecto.Type`. Its `cast/1` calls `ProjectProfiles.parse/1`; successful values cast to the canonical structure and failures return `{:error, message: safe_message}`. Add:

```elixir
field(:project_profiles, ProjectProfilesType)
```

to the root embedded schema and include `:project_profiles` in the root `cast/3`. Do not add a default. Do not resolve credentials or perform external reads during casting.

- [ ] **Step 4: Preserve stable secret-safe config errors**

Format `ProjectProfiles.reason()` into a bounded message prefixed with `project_profiles`. Include profile key and field names when safe; never inspect the raw map or credential value. Verify the sentinel secret from Task 1 is absent from `format_errors/1` output.

- [ ] **Step 5: Run Config and profile suites**

Run:

```bash
mix test test/symphony_elixir/project_profiles_test.exs
mix test test/symphony_elixir/workspace_and_config_test.exs
mix format --check-formatted lib/symphony_elixir/config/schema.ex test/symphony_elixir/workspace_and_config_test.exs
mix specs.check
```

Expected: both focused suites pass; existing `%{}` config remains valid.

- [ ] **Step 6: Commit Task 2**

Commit: `Integrate project profiles with workflow config`

---

### Task 3: Freeze the operator contract and verify the repository

**Files:**
- Modify: `README.md`
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md`
- Verify: `.github/pull_request_template.md`

**Interfaces:**
- Consumes: exact YAML and result shapes from Tasks 1–2.
- Produces: operator-facing conceptual boundary, implementation contract, and non-secret sample configuration.

- [ ] **Step 1: Update the root project concept**

Extend the existing project repository readiness section to state that approved profiles are
versioned, exact-manifest configuration evidence. State explicitly that profile loading does not
enable polling, dispatch, claims, workspace creation, deployment, or Production access.

- [ ] **Step 2: Document the exact Elixir YAML contract**

Add the two-profile YAML from the design spec to `elixir/README.md`, followed by these behaviors:

- absence disables multi-project capability;
- a present value must contain the full v1 pair;
- unknown fields and profile-level capacity reject;
- failed reload retains last-known-good, while failed initial load stops activation;
- credential references are non-secret identifiers and are not resolved by ARO-289.

- [ ] **Step 3: Add the disabled sample to WORKFLOW.md**

Add a commented or inactive non-secret `project_profiles` example. Do not change tracker polling,
workspace hooks, source repo, agent capacity, claims, or review convergence. The checked-in sample
must not activate multi-project runtime behavior.

- [ ] **Step 4: Run focused and repository-level verification**

Run:

```bash
mix test test/symphony_elixir/project_profiles_test.exs
mix test test/symphony_elixir/workspace_and_config_test.exs
mix format --check-formatted
mix specs.check
git diff --check
make all
```

Expected: every command passes. On Windows, if `make` is unavailable, record that environment limit,
run the equivalent local Mix checks, and rely on GitHub Actions using Elixir 1.19 for `make all`.

- [ ] **Step 5: Commit documentation and final verification evidence**

Commit: `Document approved project profile configuration`

- [ ] **Step 6: Create the ARO-289 PR and request exact-head review**

Push `codex/aro-289-multi-project-profiles`, create a PR using the repository template, link it to
ARO-289, move the issue to In Review, comment `@codex review`, and monitor until required checks
finish. Resolve only findings verified against the current head; do not merge the PR.

---

## Plan self-review

- Spec coverage: profile identity, collisions, non-Production boundary, node-capacity exclusion,
  atomic reload, downstream wire contract, documentation, and non-goals each map to a task.
- Placeholder scan: no deferred implementation or unspecified error-handling step remains.
- Type consistency: `ProjectProfiles.parse/1`, `fetch/2`, `reload/2`, `t`, `profile`, and `reason`
  retain the same names and result shapes across all tasks.
