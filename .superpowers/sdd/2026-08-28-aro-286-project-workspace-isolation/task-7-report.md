# Task 7 Report: Documentation, Acceptance Mapping, and Full Verification

## Status

The ruled Task 6 residual, Task 7 documentation, and deterministic acceptance mapping are complete.
An unsafe or unrepresentable legacy `receiver_hash-epoch` claim/delivery path is no longer treated as
legacy-artifact absence: Elixir returns `:notification_delivery_ambiguous`, and the Windows watchdog
suppresses the command and delivery. Representable missing legacy paths, valid legacy delivery
receipts, valid legacy orphan claims, and new SHA-256 paths retain their prior behavior.

The ARO-286-specific tests pass. The repository-wide gate is not reported as green: the full suite
completed with 42 Windows-sensitive failures, checkout-wide formatting remains non-green, Credo
crashes on the current Elixir toolchain, Elixir is 1.20.2 rather than the specified 1.19.x, and GNU
Make is unavailable. Coverage now starts and executes the suite, and Dialyzer reports zero errors.
Exact results are recorded below.

## Commits

- `9744242360360d18e6c88021f98e9a2289fa6104` — `fix: fail closed on unrepresentable legacy receipts`
- `7d2b058fb4a972db18ed3a8ad32fed844aea0027` — `docs: map ARO-286 isolation acceptance`
- `f1142b4238dae8e49b54e9e0bd6001b6f54d67a3` — `docs: report ARO-286 Task 7 verification`
- `3d7134b32f2857b37fbf6fd80a932011babc6300` — `fix: close ARO-286 verification gaps`
- This Fix Round 1 report amendment is committed separately after recording the exact verified
  implementation head.

## Files

Controller-ruled Task 6 residual:

- `elixir/lib/symphony_elixir/runtime_notifier.ex`
- `elixir/bin/symphony-watchdog.ps1`
- `elixir/test/symphony_elixir/runtime_notifier_test.exs`
- `elixir/test/bin/symphony_watchdog_test.exs`

Task 7 documentation:

- `README.md`
- `SPEC.md`
- `elixir/README.md`
- `elixir/WORKFLOW.md`
- `elixir/docs/aro_286_acceptance.md`

## Residual Fix: RED

The root cause was two collapsed states. `RuntimeNotifier.legacy_notification_path/4` and the
watchdog's `Get-LegacyNotificationName` correctly returned no path when the legacy component or
joined path could not be represented, but callers treated that result the same as a representable
path whose entry was genuinely absent. They could therefore reserve the new SHA claim and invoke
the operator command despite an uncheckable legacy location.

Before the production change:

- The targeted Elixir regression was `0/1`: notification returned `:ok` instead of
  `{:error, :notification_delivery_ambiguous}` and invoked the command.
- The targeted Windows PowerShell regression was `0/1`: it created a new SHA claim at the valid
  current-contract path instead of suppressing notification.
- The `pwsh` host returned exit `2` while assigning the approximately 3,900-byte current directory,
  before notifier evaluation. Its final regression therefore asserts the required fail-closed
  outcome at that host boundary, while Windows PowerShell exercises the shared script's explicit
  unrepresentable-legacy branch.

All fixtures use a valid 128-byte runtime epoch and a current-contract-valid long runtime root. The
Task 5 **Secret-Safe Runtime Health State** `stop-<epoch>.json` and new SHA claim/delivery paths fit
the 4,096-byte contract, while the legacy joined path does not.

## Residual Fix: GREEN

Minimal production change:

- Elixir's `claim_status(nil, ...)` and `delivery_status(nil, ...)` now return
  `{:error, :notification_delivery_ambiguous}`.
- The watchdog returns `$false` before checking/writing new idempotency state when either legacy
  name is unrepresentable.

Fresh exact-head residual command:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs:133 \
  test/bin/symphony_watchdog_test.exs:296 \
  test/bin/symphony_watchdog_test.exs:301

Finished in 8.2 seconds
Result: 3 passed, 47 excluded
```

Earlier complete residual suites after the fix:

```text
mix test test/symphony_elixir/runtime_notifier_test.exs \
  test/bin/symphony_watchdog_test.exs

Finished in 195.4 seconds
Result: 50 passed
```

This includes real `pwsh` 7.6.4 and `powershell.exe` 5.1.26100.9168 execution. Existing valid
legacy and new SHA behavior remains green in the same suites. No command output, new claim, or new
delivery exists in the unrepresentable-path cases.

## Documentation and Acceptance Mapping

The operator/spec documents now state the exact approved profile namespaces and opaque references,
the fail-closed default credential provider, ARO-195/ARO-196 ownership, stable failure atoms, real
Linear viewer startup request, fixed runtime-health fields/stages, immutable final receipt, exact
notifier stdin keys, local Windows watchdog invocation/exit codes, legacy compatibility boundary,
command/receiver secret restrictions, and local non-Production-only boundary.

`elixir/docs/aro_286_acceptance.md` maps every design acceptance bullet to exact modules and test
files: cross-repository isolation; wrong repository/head drift; 401/missing mapping; observable
stages; last poll/dependencies; explicit stop receipt; Windows receiver-bound notification; no
secrets; and no deployment/Production/external resources. It explicitly records that ARO-195 owns
the machine credential inventory, ARO-196 owns the canonical credential resolver/authority
preflight, and ARO-285 owns live non-Production end-to-end acceptance.

## Focused Verification

Six ARO-286-specific files:

```text
mix test test/symphony_elixir/project_execution_context_test.exs \
  test/symphony_elixir/project_credential_provider_test.exs \
  test/symphony_elixir/linear_startup_identity_test.exs \
  test/symphony_elixir/runtime_health_test.exs \
  test/symphony_elixir/runtime_notifier_test.exs \
  test/bin/symphony_watchdog_test.exs

Finished in 215.1 seconds
Result: 86 passed
```

Exact Task 7 focused command:

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
  test/symphony_elixir/status_dashboard_snapshot_test.exs

Finished in 260.8 seconds
Result: 279/285 passed
Failed: 6 tests
```

All ARO-286-specific assertions passed. The six observed failures were host-specific failures:

1. Two `workspace_preflight_blocker_test.exs` remote/path cases received the Windows WSL
   installation message from `wsl.exe` instead of a shell result.
2. One `workspace_readiness_state_test.exs` SSH case received the same WSL host response.
3. One `readiness_gate_agent_runner_test.exs` continuation case returned `:epipe`.
4. One `workspace_and_config_test.exs` `after_create` timeout case returned `:ok` under the Windows
   shell behavior.
5. One `workspace_and_config_test.exs` default-root case observed a process TEMP versus
   compile-time TEMP mismatch.

No failure implicated the residual implementation or the six ARO-286-specific files.

## Repository Gates

| Command | Exact result | Classification |
| --- | --- | --- |
| `mix format --check-formatted` | Exit 1; checkout-wide LF/CRLF differences produce formatter changes | Non-green. The three Fix Round 1 Elixir files pass targeted formatter check. |
| `mix specs.check` | Exit 0; `all public functions have @spec or exemption` | Pass. |
| `mix credo --strict` | Exit 1 in Credo 1.7.16 `Credo.Code.Token.position/1` on Elixir 1.20.2 sigil tokens | Known toolchain sigil crash; no Credo finding was produced. |
| `mix dialyzer` | Exit 0; `Total errors: 0, Skipped: 0, Unnecessary Skips: 0` | Pass after Fix Round 1. |
| `make all` | Exit 127 / unavailable because GNU Make is not installed | Environment. Non-networked components were run directly. |
| `git diff --check origin/main...HEAD` | Exit 0 at exact implementation head `3d7134b32f2857b37fbf6fd80a932011babc6300` | Pass after removing the branch-owned plan EOF blank line. |

Additional safe direct component evidence:

- `mix build`: passed and generated the escript; only the existing `normalize_host/1` warning.
- `mix test --cover`: application startup succeeded and the full suite executed on the Round 1
  working tree before the final removal of exploratory semantics-preserving refactors; the coverage
  writer path was unchanged by that trim. It finished in
  439.2 seconds with 959/1001 passed, 13 skipped, and 42 failed; total coverage was 92.32%, below the
  configured 100% threshold, so the command exited 3. The failures were observed in Windows/CRLF,
  WSL, app-server/`:epipe`, PR-body, and process-TEMP-sensitive cases; this is not claimed as a pass.
- `mix test`: on that same Round 1 working tree, compiled all fixtures and finished in 427.0
  seconds with 959/1001 passed, 13 skipped, and 42 failed (exit 2). The previous `ReadinessState`
  missing-field compilation error is gone. The final exact-head focused fixture suite is recorded
  below.
- Exact-head targeted formatting over the two changed `.exs` files, notifier `.ex`, and watchdog
  test passed. `git show --check` passed for both Task 7 commits.

Environment versions were Erlang/OTP 28, Elixir 1.20.2 compiled with OTP 29, `pwsh` 7.6.4, and
Windows PowerShell 5.1.26100.9168. `elixir/AGENTS.md` specifies Elixir 1.19.x with OTP 28.

## Scope and Secret Review

- The Task 7 delta includes the four controller-ruled notifier/watchdog files, five mapped
  documentation files, and the four Fix Round 1 files listed below; this report is the only
  additional artifact.
- Added-line searches found no Production path literal and no credential-like token/private-key
  literal. Document mentions of Production, headers/bodies, and credential references describe
  prohibitions and opaque handles only.
- Implementation-added-line searches found no environment dump, raw header/body logging, ambient
  credential lookup, deployment operation, SQL/database/role mutation, or ARO-195/ARO-196 resolver.
- No external resource, live notification provider, database, deployment, Production path, push,
  merge, or customer message was used.

## Fix Round 1 (2026-08-31)

### RED

- `mix dialyzer` originally exited 2 with one `pattern_match` warning reported at
  `RuntimeHealth`; investigation showed the remaining impossible arm was the false branch around
  `Port.command/2`, whose contract returns `true` or raises.
- `mix test --cover test/symphony_elixir/runtime_health_test.exs:32` originally stopped during
  application startup with `{:receipt_writer_unavailable, :writer_module_not_found}` because
  `:code.which/1` returns `:cover_compiled` under coverage.
- The plain full suite previously stopped compiling when three older `ReadinessState` fixtures
  omitted the six required project-identity fields.
- `git diff --check origin/main...HEAD` originally reported the branch-owned blank line at the end
  of the ARO-286 plan.

### GREEN

- Runtime-state identity revalidation now returns a tagged fail-closed path-drift error. The focused
  adversarial regression forces canonical identity to change specifically between `start_link`
  validation and `init`, asserts `{:unsafe_runtime_state_root, :path_changed}`, and proves the
  drifted directory is not created.
- Receipt-writer discovery accepts only the coverage sentinel or an exact regular
  `symphony_runtime_receipt_writer.beam`; the coverage sentinel resolves back to the application's
  trusted `ebin` directory. Release path validation remains fail closed.
- The impossible `Port.command/2` false arms were removed; exceptions still map to the existing
  writer-closed/forced-retirement behavior.
- All three older readiness fixtures now contain valid, non-secret project identity fields, and the
  plan EOF whitespace is removed.

Focused coverage GREEN before the final scope trim (the coverage path was unchanged by that trim):

```text
mix test --cover test/symphony_elixir/runtime_health_test.exs:32

Result: 1 passed
Coverage: 9.67%; threshold: 100.00%
Exit 3 solely because this intentionally partial run is below the global threshold
```

Fresh final-code evidence:

```text
mix test test/symphony_elixir/runtime_health_test.exs \
  test/symphony_elixir/readiness_gate_test.exs

Finished in 125.6 seconds
Result: 63 passed
```

```text
mix dialyzer
Total errors: 0, Skipped: 0, Unnecessary Skips: 0
done (passed successfully)
```

```text
mix specs.check
specs.check: all public functions have @spec or exemption
```

Targeted formatting of the three changed Elixir files exited 0. Full formatting exited 1 on the
checkout-wide LF/CRLF set. At exact implementation head
`3d7134b32f2857b37fbf6fd80a932011babc6300`,
`git diff --check origin/main...HEAD` exited 0.

### Latest-Head Self-Review

The review covered exact implementation head `3d7134b32f2857b37fbf6fd80a932011babc6300`.
The required independent reviewer was not dispatched because the controller explicitly prohibited
subagents; the `requesting-code-review` checklist was applied locally instead.

- The ambiguity check precedes new-claim creation and command invocation in both implementations.
- Representable-but-missing legacy paths still flow to the new SHA path; valid legacy delivery and
  orphan-claim semantics are unchanged and covered by the full notifier/watchdog suites.
- The long-root tests prove the Task 5 **Secret-Safe Runtime Health State** stop-receipt and SHA paths
  remain representable while the legacy joined path exceeds 4,096 bytes; they assert no command
  log, claim, or delivery.
- Both PowerShell variants are covered. The Windows PowerShell process reaches the explicit shared
  script branch; `pwsh` fails closed at its earlier long-current-directory host boundary.
- Documentation examples are secret-free, include both namespaces/credential refs, and do not imply
  Production, deployment, external notification, or live E2E acceptance.
- Coverage startup executes with the trusted writer fallback, the identity-drift arm has an
  adversarial transition test, the readiness fixtures compile, and Dialyzer has no warning.
- One wording ambiguity (`production default`) was corrected to `built-in default` before the docs
  commit. No unresolved actionable in-scope finding remains on the verified implementation head.
