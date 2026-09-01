# ARO-286 Acceptance Map

## Scope and ownership

ARO-286 binds an already-authorized multi-project issue to one approved workspace namespace,
repository/branch identity, opaque credential reference, subprocess environment, and secret-safe
runtime-health path. It adds no scheduler, claim service, capacity store, credential inventory,
credential installation, external notification service, deployment, Production access, or shared
database mutation.

ARO-195 owns the approved three-machine GitHub credential inventory and automation identity.
ARO-196 owns the canonical GitHub credential-source resolver and GitHub authority preflight.
`SymphonyElixir.ProjectCredentialProvider` is only their consuming seam; its built-in default
returns `{:error, :credential_provider_unconfigured}`. ARO-285 owns the live non-Production
end-to-end acceptance with the eventual approved adapter and operator resources. The deterministic
ARO-286 tests below do not claim that live E2E result.

The legacy single-project path remains `<workspace.root>/<issue_identifier>` and bypasses the
multi-project credential provider. It is preserved for workflows without `project_profiles`; it is
not silently migrated into a namespaced multi-project workspace.

For a local multi-project run, environment and path construction is side-effect free. Workspace
creates `<workspace.root>/<namespace>/.symphony-subprocess/<issue>-r<revision>` and its `gh`, XDG,
and Codex descendants only after exact namespace/workspace validation and stable local attestation.
Every existing component must be canonical, physically contained, and non-reparse; newly created
components are made and verified owner-private before the next component is created. A failed attempt
rolls back only the directories it created, in reverse identity-verified order. Windows retains
non-delete-sharing handles for the validated root, namespace, workspace, and private components until
creation and permission verification complete. POSIX requires mode `0700` and current effective-UID
ownership; its standard-library path operations retain the documented same-UID race limitation.

Context cleanup requires the supplied stable workspace attestation. It never creates a subprocess
home: a credential-bearing cleanup hook may use only a complete, already-private home held across the
hook validation boundary, while cleanup without such a hook does not inspect or create one. A rejected
local root/alias, unattested cleanup, and a remote credential environment create no local subprocess
home. On Windows, environment-key precedence and deduplication are case-insensitive, so one canonical
HOME, GH, XDG, Codex, runtime, or approved provider key reaches a child; POSIX key matching remains
case-sensitive. Readiness-state preparation errors carry the captured workspace attestation into the
`after_run` effect boundary, so a renamed/recreated workspace cannot receive the credential-bearing
hook.

## Operator contract

The only accepted multi-project environment is `local_non_production`. For the two approved
profiles, the same issue identifier maps to different paths:

```text
<workspace.root>/central-brain/ARO-286
<workspace.root>/project-management/ARO-286
```

Profiles store only `github-central-brain` or `github-project-management` as opaque
`credential_ref` values. Resolved values may reach only the selected worker's immediate Git,
readiness, hook, and Codex subprocess environment. They must not appear in command arguments,
application state, workspace state, runtime health, errors, logs, receipts, or notifications.

Startup uses the real read-only `query SymphonyLinearViewer { viewer { id } }` request and then
reads every configured profile's exact Linear project UUID before terminal cleanup or polling.
The approved design defines configured `linear_project_id` values—not a separate organization ID—as
the project-authority boundary; issue routing independently requires the same exact project UUID.
Runtime health then exposes `last_successful_poll_at`, `linear` and
`claim_store` dependency state, the fixed stages `candidate_fetch`, `issue_refresh`, `routing`,
`profile_resolution`, `preflight`, `claim`, and `dispatch`, `final_stop`, and bounded `history`.
The immutable final receipt is `stop-<runtime_epoch>.json` under the dedicated runtime-state
directory.

Restart notification is local and disabled only when both `observability.notification_command` and
`observability.notification_receiver` are absent. Partial configuration is invalid. Both are
operator-provided and must be nonblank and secret-free. The command receives one JSON object on
stdin with exactly these keys:

```text
runtime_identity, receiver, attempt_count, stop_category,
timestamp, runtime_epoch, receipt_path
```

All command output is discarded. Successful delivery requires a verified zero exit and an immutable
delivery receipt. Timeout, non-zero exit, unstable/malformed Task 5 receipt, crash-ambiguous claim,
or unsafe path records no delivery.

New claim/delivery filenames use SHA-256 of `<receiver_hash>:<runtime_epoch>`. Compatibility reads
the previous `receiver_hash-epoch` names only when the filename and joined path are representable
within the portable contract. A valid legacy delivery suppresses a duplicate, and a valid legacy
orphan claim remains ambiguous. An unsafe or unrepresentable legacy path is ambiguity/error, never
legacy-artifact absence; no command or delivery is allowed. Only a representable legacy path whose
entry is genuinely missing is treated as absent.

## Stable failure surface

- Execution context: `missing_project_profile`, `invalid_project_profile`, `invalid_issue_id`,
  `invalid_issue_identifier`, `invalid_project_id`, `project_id_mismatch`, `repository_mismatch`,
  `invalid_workspace_namespace`, `invalid_canonical_branch`, `invalid_credential_ref`,
  `environment_not_allowed`, `missing_routing_revision`.
- Workspace/context: `workspace_context_missing`, `workspace_context_identity_mismatch`,
  `workspace_issue_identity_mismatch`, `workspace_issue_identity_changed`, and
  `remote_credential_environment_unsupported`; private-home validation or creation exposes only
  `subprocess_home_unavailable`; existing typed path/readiness errors remain in force for collision,
  escape, repository/head drift, and unsafe cleanup targets.
- Credential provider: `credential_provider_unconfigured`, `credential_not_found`,
  `credential_ambiguous`, `credential_reference_mismatch`, `invalid_credential_environment`,
  `credential_provider_failed`.
- Linear startup: `linear_unauthorized`, `linear_forbidden`, `linear_identity_missing`,
  `linear_response_invalid`, `linear_unavailable`, `linear_workspace_mismatch`.
- Runtime health: `unknown_stage`, `unknown_dependency`, `invalid_status`, `invalid_field_value`,
  `invalid_clock`, `secret_bearing_value`, `unknown_field`, `invalid_field`,
  `unsafe_runtime_state_root`, `invalid_runtime_epoch`, `invalid_restart_attempt`,
  `receipt_write_failed`.
- Runtime notifier: `notification_not_configured`, `invalid_notification_config`,
  `invalid_notification_event`, `invalid_runtime_state_root`, `invalid_stop_receipt`,
  `invalid_delivery_receipt`, `notification_command_unavailable`, `notification_failed`,
  `notification_timeout`, `notification_delivery_ambiguous`, `delivery_receipt_write_failed`.
- Windows watchdog: exit `0` means child success, exit `1` means the restart limit was reached, and
  exit `2` means an invalid or unsafe configuration/state boundary. No exit status itself counts as
  human delivery; only the validated immutable delivery receipt does.

All diagnostics use fixed atoms or bounded safe metadata. They do not include submitted credential
references when doing so would disclose selection material, credential values, environment dumps,
raw Linear headers/bodies/errors, notifier output, or raw child output.

## Acceptance-to-evidence mapping

| ARO-286 acceptance bullet | Exact modules | Exact deterministic evidence |
| --- | --- | --- |
| Cross-repository workspace and credential isolation | `SymphonyElixir.ProjectExecutionContext`, `SymphonyElixir.Workspace`, `SymphonyElixir.PrivateHome.WindowsCapability`, `SymphonyElixir.ProjectCredentialProvider`, `SymphonyElixir.SubprocessEnvironment`, `SymphonyElixir.AgentRunner`, `SymphonyElixir.Codex.AppServer` | `test/symphony_elixir/project_execution_context_test.exs`; `test/symphony_elixir/workspace_and_config_test.exs` — exact local/remote issue-leaf identity, sibling aliases, stable replacement rejection, Production-root no-mutation, namespace/private-home alias rejection, atomic owner-only Windows creation, retained capability re-attestation before hook/Git/Codex, componentwise privacy, reverse identity-checked rollback, permission/commit/removal failure, orphan cleanup, POSIX UID/device/inode tracking, unsafe pre-existing permission rejection, attested no-create cleanup, strict Windows reparse classification, and owner-private canonical homes; `test/symphony_elixir/private_home_windows_capability_test.exs` — fresh correlation IDs plus timeout, malformed/mismatched reply, commit, and rollback retirement; `test/symphony_elixir/core_test.exs` — attested running/blocked/retry/terminal cleanup and identical identifiers in two profiles while the legacy target remains; `test/symphony_elixir/project_credential_provider_test.exs`; `test/symphony_elixir/subprocess_environment_test.exs` — deny-by-default pure construction, platform-specific key semantics, and an actual mixed-case Windows child; `test/symphony_elixir/workspace_preflight_blocker_test.exs` — readiness-error capability and attestation reject replacement before `after_run`; `test/symphony_elixir/readiness_gate_agent_runner_test.exs` — the opaque capability remains live across the attempt, selected credentials reach only the intended subprocess environment, and remote credential rejection creates no local home |
| Checkout, continuation, canonical-head evidence, wrong repository, and head drift stay bound and fail closed | `SymphonyElixir.ProjectExecutionContext`, `SymphonyElixir.Workspace.ReadinessState`, `SymphonyElixir.Workspace`, `SymphonyElixir.ReadinessGate` | `test/symphony_elixir/project_execution_context_test.exs` — repository/project mismatch cases; `test/symphony_elixir/workspace_readiness_state_test.exs` — durable project identity, exact reuse, legacy refusal, branch/HEAD drift, and SSH state cases; `test/symphony_elixir/readiness_gate_agent_runner_test.exs` — stale branch, canonical-branch collision, and continuation cases; `test/symphony_elixir/workspace_preflight_blocker_test.exs` |
| 401/403 and missing, ambiguous, or wrong credential mapping regressions | `SymphonyElixir.Linear.Client`, `SymphonyElixir.Tracker`, `SymphonyElixir.Orchestrator`, `SymphonyElixir.ProjectCredentialProvider` | `test/symphony_elixir/linear_startup_identity_test.exs`; `test/symphony_elixir/project_credential_provider_test.exs`; `test/symphony_elixir/readiness_gate_agent_runner_test.exs` — “credential provider failure reports a sanitized hard blocker before hooks or Codex” |
| Real Linear and configured-project authority is validated before startup effects | `SymphonyElixir.Linear.Client.validate_identity/1`, `SymphonyElixir.Tracker.validate_identity/0`, `SymphonyElixir.Orchestrator` | `test/symphony_elixir/linear_startup_identity_test.exs` — viewer request, an exact read-only lookup for every configured project UUID, wrong-project access rejection, and safe response classification; startup-gate cases in `test/symphony_elixir/core_test.exs` |
| Candidate fetch, refresh, routing, profile resolution, preflight, claim, and dispatch have an observable stop point | `SymphonyElixir.RuntimeHealth`, `SymphonyElixir.Orchestrator` | `test/symphony_elixir/runtime_health_test.exs` — all typed stages; `test/symphony_elixir/orchestrator_status_test.exs` — “multi-project dispatch emits one start and outcome for every health boundary” and “health reporting failure cannot change claim or dispatch authorization”; `test/symphony_elixir/multi_project_dispatch_test.exs` |
| Last successful poll and Linear/claim-store dependency state are observable | `SymphonyElixir.RuntimeHealth`, `SymphonyElixir.Orchestrator`, `SymphonyElixir.StatusDashboard`, `SymphonyElixirWeb.Presenter` | `test/symphony_elixir/runtime_health_test.exs` — poll/dependency/snapshot cases; `test/symphony_elixir/status_dashboard_snapshot_test.exs` — “runtime health renders explicit unknown evidence and observed dependency state”; `test/symphony_elixir/orchestrator_status_test.exs` |
| Runtime stop reason is explicit and durable | `SymphonyElixir.RuntimeHealth`, `SymphonyElixir.RuntimeReceiptContract`, `symphony_runtime_receipt_writer`, `SymphonyElixir` application lifecycle | `test/symphony_elixir/runtime_health_test.exs` — atomic final receipt, exact watchdog root/epoch/path/attempt, immutable epoch, directory rename/recreate with copied token, path replacement, maximum contract, and replay cases; `test/symphony_elixir/orchestrator_status_test.exs` — “application prep_stop records the final receipt while RuntimeHealth is alive” |
| Repeated Windows restart failure produces one idempotent receiver-bound human-notification attempt | `SymphonyElixir.RuntimeNotifier`, `elixir/bin/symphony-watchdog.ps1`, `SymphonyElixir.RuntimeReceiptContract` | `test/symphony_elixir/runtime_notifier_test.exs`; `test/bin/symphony_watchdog_test.exs`, including a real RuntimeHealth child crash through restart limit, watchdog-authored terminal receipt, exact notification attempt, bounded write failures, and `pwsh`/`powershell.exe` compatibility |
| No secrets in diagnostics or child process inheritance | `SymphonyElixir.ProjectExecutionContext.safe_metadata/1`, `SymphonyElixir.ProjectCredentialProvider`, `SymphonyElixir.SubprocessEnvironment`, `SymphonyElixir.Workspace`, `SymphonyElixir.Codex.AppServer`, `SymphonyElixir.RuntimeHealth`, `SymphonyElixir.RuntimeNotifier`, watchdog | Secret/error tests in `test/symphony_elixir/project_execution_context_test.exs`, `project_credential_provider_test.exs`, `subprocess_environment_test.exs`, `readiness_gate_agent_runner_test.exs`, `workspace_and_config_test.exs`, `workspace_preflight_blocker_test.exs`, `runtime_health_test.exs`, `runtime_notifier_test.exs`, and `test/bin/symphony_watchdog_test.exs`; malicious shell-profile, ambient SSH/Git/GH, Linear, npm, and Node values are absent from the child, and private-home failures expose one bounded atom |
| No deployment/Production/external resources | Project profile/config schema, `SymphonyElixir.ProjectExecutionContext`, `SymphonyElixir.Workspace`, `SymphonyElixir.RuntimeHealth`, `SymphonyElixir.RuntimeNotifier`, watchdog | Non-Production environment/path cases in `test/symphony_elixir/project_execution_context_test.exs`, `workspace_and_config_test.exs`, `runtime_health_test.exs`, `runtime_notifier_test.exs`, and `test/bin/symphony_watchdog_test.exs`; all fixtures are local and injected |

## Deterministic verification boundary

The focused acceptance command runs the six ARO-286-specific files plus the related dispatch,
workspace, readiness, health, and status regressions:

```text
mix test test/symphony_elixir/project_execution_context_test.exs \
  test/symphony_elixir/project_credential_provider_test.exs \
  test/symphony_elixir/linear_startup_identity_test.exs \
  test/symphony_elixir/runtime_health_test.exs \
  test/symphony_elixir/runtime_notifier_test.exs \
  test/bin/symphony_watchdog_test.exs \
  test/symphony_elixir/multi_project_dispatch_test.exs \
  test/symphony_elixir/workspace_readiness_state_test.exs \
  test/symphony_elixir/workspace_and_config_test.exs \
  test/symphony_elixir/workspace_preflight_blocker_test.exs \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/status_dashboard_snapshot_test.exs \
  test/symphony_elixir/core_test.exs \
  test/symphony_elixir/app_server_test.exs \
  test/symphony_elixir/subprocess_environment_test.exs \
  test/symphony_elixir/ssh_test.exs
```

Repository formatter, public-spec, Credo, Dialyzer, available `make all`, and diff checks remain
separate gates. Environmental failures must be reported as such and never described as passing.
No deterministic result substitutes for ARO-285's live non-Production E2E.

Final retained-capability remediation evidence on 2026-08-31: the 16-test private-home security
batch passed with 106 unrelated tests excluded; the exact 17-file command above passed all 422 tests
with no skips, including both `pwsh` and Windows PowerShell watchdog cases. Dialyzer reported zero
errors and the warning-free compile, public-spec, formatter, escript-build, and diff gates passed.
