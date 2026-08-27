# ARO-289 Versioned Project Profiles Design

## Goal

Allow one Symphony runtime to load exactly two approved project profiles—Central-Brain and
Project-Management—without enabling multi-project polling or dispatch. The contract must reject
ambiguous, colliding, Production-like, or partially valid configuration and must preserve the last
known good profile set when a reload fails.

## Scope boundary

ARO-289 defines parsing, validation, lookup, and reload behavior only. It does not change the
orchestrator, tracker polling, claims, capacity, workspace creation, worker startup, review
automation, deployment, shared databases, or Production authority. A parsed profile is configuration
evidence for ARO-288, ARO-287, and ARO-286; it is not dispatch authorization.

Profiles are versioned and checked against an in-code approval manifest. They are not
cryptographically signed. The runtime stores no signing key, verification key, or profile secret.

## Configuration contract

`WORKFLOW.md` front matter may contain one `project_profiles` object:

```yaml
project_profiles:
  version: 1
  profiles:
    - key: central-brain
      linear_project_id: d0acfb71-f68c-4a9f-8a1a-477265d3c3ec
      repository: aroakpm-svg/aroak-central-brain
      canonical_branch: main
      workspace_namespace: central-brain
      credential_ref: github-central-brain
      environment: local_non_production
    - key: project-management
      linear_project_id: 708053e0-f42c-4e93-bec4-7abbb37e74af
      repository: aroakpm-svg/aroak-project-management
      canonical_branch: main
      workspace_namespace: project-management
      credential_ref: github-project-management
      environment: local_non_production
```

The top-level object accepts only `version` and `profiles`. A profile accepts only the seven fields
shown above. Unknown fields fail closed, including any project-level slot or capacity field.

`version` must equal integer `1`. `profiles` must contain both approved profiles exactly once; a
subset is not a valid replacement set. Every value is a non-empty string after trimming, and raw
values must already be canonical rather than being silently repaired.

## Approval manifest

The implementation owns a small immutable manifest keyed by `central-brain` and
`project-management`. For each key it binds the approved Linear project UUID, GitHub repository,
canonical branch, workspace namespace, credential reference, and environment. Candidate fields must
match the manifest exactly.

This explicit manifest is the approval mechanism selected for ARO-289. Changing an identity or
authority boundary requires a reviewed code change. It prevents one profile from inheriting or
impersonating the other profile without introducing key management.

## Validation rules

Validation is whole-set and fail closed:

- reject a missing, non-map, or unknown-version `project_profiles` value;
- reject unknown or missing fields and malformed values;
- reject unknown, missing, or duplicate profile keys;
- reject duplicate Linear project IDs, repositories, workspace namespaces, or credential references;
- reject any value that differs from its approved manifest entry;
- reject repositories outside `aroakpm-svg/owner-name` form or canonical branches other than `main`;
- reject absolute, parent-traversing, drive-qualified, or separator-containing workspace namespaces;
- reject any environment other than `local_non_production`;
- reject all `slots`, `total_slots`, database URL, deployment, and Production authority fields.

Errors are stable atoms or tuples containing only field names and non-secret identity values. Raw
profile maps and credential values are never included in errors or logs.

## Interfaces and ownership

Create `SymphonyElixir.ProjectProfiles` as the sole owner of the wire contract:

```elixir
@spec parse(term()) :: {:ok, t()} | {:error, reason()}
@spec fetch(t(), String.t()) :: {:ok, profile()} | :error
@spec reload(t() | nil, term()) ::
        {:ok, t()} | {:error, reason(), t() | nil}
```

`parse/1` returns a canonical structure indexed by profile key. `fetch/2` performs exact lookup only.
`reload/2` parses the complete candidate first; success returns the new set, while failure returns
the original last-known-good set unchanged. If no last-known-good set exists, failure returns `nil`,
which requires startup to stop.

`SymphonyElixir.Config.Schema` gains a `project_profiles` field parsed through this module. Existing
single-project configuration remains valid only when the field is absent; absence means the new
multi-project capability is disabled. Once present, the entire v1 contract is mandatory.

## Data flow

1. `Workflow` reads YAML front matter without side effects.
2. `Config.Schema` passes `project_profiles` to `ProjectProfiles.parse/1`.
3. Parsing validates exact keys, canonical values, uniqueness, and manifest approval.
4. A successful complete set becomes configuration evidence available to later tickets.
5. Reload validates a complete replacement before returning it; no partial profile becomes visible.

No external API, filesystem mutation, credential resolution, workspace creation, or worker action
occurs in this flow.

## Testing

Focused tests cover:

- the exact two-profile v1 configuration;
- missing and unknown projects;
- duplicate key, Linear identity, repository, workspace, and credential reference;
- manifest mismatch for every authority-bearing field;
- malformed version and unknown fields, including profile-level slots;
- Production-like environment and unsafe workspace namespace;
- exact lookup behavior;
- successful atomic reload;
- failed reload retaining last-known-good;
- failed initial load returning no active configuration;
- existing configuration with no `project_profiles` remaining valid and disabled.

Repository gates remain `make all`, PR-description validation, exact-head review, and zero unresolved
review threads.

## Documentation

The root README describes the versioned approved-profile boundary and states that it does not enable
dispatch. `elixir/README.md` documents the exact YAML contract, validation behavior, reload result,
and absence-as-disabled migration behavior. `WORKFLOW.md` receives a non-secret example only if the
repository uses it as the canonical configuration sample.

## Acceptance mapping

- Two profiles parse and validate: exact v1 happy-path tests.
- Unknown, duplicate, colliding, mismatched, or Production-like values reject: table-driven negative
  tests for every rule above.
- Node capacity stays singular: project-level capacity keys are unknown and rejected; no capacity
  implementation changes.
- Reload is atomic: `reload/2` never returns a partially parsed set and returns last-known-good on
  failure.
- Downstream contract is fixed: public types, stable result shapes, documentation, and sample YAML.
- Non-goals remain enforced: no orchestrator, polling, claim, workspace, deployment, database, or
  secret-handling changes.
