# Task 2 Report: Validated Context-Private Subprocess Home

## Outcome

`SubprocessEnvironment.build/2` is now a pure, deny-by-default environment builder. It computes an
explicit context-private path contract without touching the filesystem. For local project contexts,
`AgentRunner` passes that contract to Workspace, which creates the directories only after the exact
workspace and namespace have passed validation and the Task 1 stable workspace attestation exists.

Workspace rejects canonical escape, sibling identity, every existing symlink/reparse component,
and deterministic replacement between validation and creation. It creates one component at a time,
immediately captures and revalidates stable physical identity, then applies owner-private POSIX modes
or a protected current-owner Windows ACL. All private-home failures cross the public boundary only as
`{:error, :subprocess_home_unavailable}`. Remote credential environments still fail closed before SSH
and now cannot create a local private home because environment construction has no side effects.

The legacy context-free single-project path and its environment behavior are unchanged.

Commit: `2dff53c` (`fix: validate project subprocess homes`).

## TDD Evidence

### Baseline

Command:

```text
mix test test/symphony_elixir/subprocess_environment_test.exs test/symphony_elixir/readiness_gate_agent_runner_test.exs test/symphony_elixir/workspace_and_config_test.exs
```

The pre-change run completed `76/77 passed`. Its one failure was the already documented Windows
temporary-junction collision (`mklink` found a persisted path); it was unrelated to subprocess-home
behavior.

### RED

The seven required behavior tests were written before the implementation:

```text
mix test test/symphony_elixir/subprocess_environment_test.exs:6 \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs:125 \
  test/symphony_elixir/workspace_and_config_test.exs:347 \
  test/symphony_elixir/workspace_and_config_test.exs:378 \
  test/symphony_elixir/workspace_and_config_test.exs:416 \
  test/symphony_elixir/workspace_and_config_test.exs:460 \
  test/symphony_elixir/workspace_and_config_test.exs:506
```

Output:

```text
Result: 0/7 passed, 76 excluded
Failed: 7 tests
```

The failures proved the original defect at each boundary: construction created the local root;
Production-like and remote runs mutated that root before rejection; a namespace alias received
`.symphony-subprocess`; aliases at `.symphony-subprocess`, issue-home, `gh`, and `codex` were accepted;
the creation-replacement seam was ignored; and the normal case observed paths created before Workspace.

The alias test count represents six real filesystem alias scenarios: namespace-to-sibling,
namespace-to-outside, `.symphony-subprocess`, issue-home, `gh`, and `codex`. The remaining selected
tests cover pure construction, Production-root no-mutation, remote no-mutation, replacement, and the
normal canonical/private case.

### Reparse-classifier hardening RED

The Windows native-query classifier received a pure test seam after the real alias tests exposed its
boundary. A self-review regression then demonstrated that accepting any standalone `4390` substring
could misclassify an access-denied path or mixed output:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:552
```

Output before strict classification:

```text
Result: 0/1 passed, 73 excluded
Failed: 1 test
```

The classifier now accepts only exit status `1` with one complete `Error 4390: ...` line. Reparse
success, access denial, a path containing `4390`, unrelated/embedded numbers, mixed output, blank
output, and every other exit status fail closed.

### GREEN

Final selected command on the formatted implementation:

```text
mix test test/symphony_elixir/subprocess_environment_test.exs:6 \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs:125 \
  test/symphony_elixir/workspace_and_config_test.exs:347 \
  test/symphony_elixir/workspace_and_config_test.exs:378 \
  test/symphony_elixir/workspace_and_config_test.exs:416 \
  test/symphony_elixir/workspace_and_config_test.exs:460 \
  test/symphony_elixir/workspace_and_config_test.exs:506 \
  test/symphony_elixir/workspace_and_config_test.exs:552
```

Output:

```text
Result: 8 passed, 76 excluded
```

## Design

- `SubprocessEnvironment.private_home_paths/1` returns the explicit root, issue-home, `gh`, XDG, and
  Codex paths. `build/2` only assembles environment values and keeps the existing provider/runtime
  allowlist plus ambient-variable unsets.
- `AgentRunner` adds the path contract only for a project execution context. A remote context reaches
  Workspace's existing `remote_credential_environment_unsupported` check first and cannot mutate the
  local filesystem.
- Workspace validates that the supplied contract and every private environment variable exactly
  match the current context-derived contract. Workspace—not the environment builder—is the security
  authority for configured-root identity, exact namespace/workspace identity, physical containment,
  stable identity, creation, and permissions.
- Containment uses normalized path components, not lexical `starts_with`. The configured root must be
  its own canonical non-reparse path; the namespace must be exact, non-reparse, and stably attested;
  every existing private component must be a canonical, contained, non-reparse directory.
- Creation is ordered root → issue-home → provider/XDG/Codex children. Workspace revalidates the Task 1
  workspace attestation, namespace attestation, and every already observed private identity before and
  after each `File.mkdir/1`. The deterministic seam proves a replacement made after the first check is
  rejected before creation follows it.
- POSIX directories are set to and verified as mode `0700`. Windows directories receive a protected
  DACL with only the current SID's inheritable `FullControl` allow rule; the real test reads the ACL
  back. Native reparse inspection accepts only the exact non-reparse result and otherwise fails closed.
- Local context cleanup obtains the same pure path/environment contract and validates/prepares it only
  after the existing workspace attestation check, preserving hook order without restoring builder
  mutation.

## Verification

### Directly affected suites

```text
mix test test/symphony_elixir/subprocess_environment_test.exs test/symphony_elixir/readiness_gate_agent_runner_test.exs test/symphony_elixir/workspace_and_config_test.exs
```

First complete GREEN output:

```text
Result: 84 passed
```

A post-format aggregate rerun reported `83/84 passed`; its sole failure was the unchanged
`workspace surfaces after_create hook timeouts` test whose 10 ms child happened to exit before the
timeout. The immediate isolated classification command passed:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:1272

Result: 1 passed, 73 excluded
```

### Credential and Workspace/AppServer focus

```text
mix test test/symphony_elixir/project_credential_provider_test.exs

Result: 5 passed
```

```text
mix test test/symphony_elixir/workspace_and_config_test.exs \
  test/symphony_elixir/workspace_preflight_blocker_test.exs \
  test/symphony_elixir/workspace_readiness_state_test.exs \
  test/symphony_elixir/app_server_test.exs \
  test/symphony_elixir/readiness_gate_test.exs \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs \
  test/symphony_elixir/project_execution_context_test.exs \
  test/symphony_elixir/multi_project_poll_test.exs \
  test/symphony_elixir/multi_project_dispatch_test.exs

Result: 235 passed
```

### Exact ARO-286 acceptance boundary and both watchdog runtimes

The exact 17-file command documented in `elixir/docs/aro_286_acceptance.md` completed with:

```text
Finished in 321.8 seconds (2.9s async, 318.9s sync)

Result: 401 passed
```

After the stricter reparse-output edge cases were added, the same command was run again on the final
implementation:

```text
Finished in 304.2 seconds (2.3s async, 301.8s sync)

Result: 400/401 passed
Failed: 1 test
```

Its only failure was the unchanged 10 ms `after_create` timing inversion. Final-tree classification:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:1275

Result: 1 passed, 73 excluded
```

Neither acceptance run reported skips. The included `test/bin/symphony_watchdog_test.exs` therefore
exercised its paired `pwsh` and `powershell.exe` parser/runtime cases on this host. The first aggregate
run is the complete GREEN result; the final aggregate plus isolated rerun records the unchanged timing
baseline without describing it as passing.

### Static and build checks

- Targeted `mix format --check-formatted` for all six changed source/test files: passed with no output.
- `mix specs.check`: `specs.check: all public functions have @spec or exemption`.
- `mix dialyzer --format short`: `Total errors: 0, Skipped: 0, Unnecessary Skips: 0` and
  `done (passed successfully)`.
- `mix compile --warnings-as-errors`: passed with no output.
- `mix build`: `Generated escript bin/symphony with MIX_ENV=dev`.
- `git diff --check`: no whitespace errors; only the checkout's LF/CRLF conversion warnings for
  changed files.

## Files

- Modified `elixir/lib/symphony_elixir/subprocess_environment.ex`.
- Modified `elixir/lib/symphony_elixir/agent_runner.ex`.
- Modified `elixir/lib/symphony_elixir/workspace.ex`.
- Modified `elixir/test/symphony_elixir/subprocess_environment_test.exs`.
- Modified `elixir/test/symphony_elixir/readiness_gate_agent_runner_test.exs`.
- Modified `elixir/test/symphony_elixir/workspace_and_config_test.exs`.
- Updated `elixir/docs/aro_286_acceptance.md`.
- Added this report.

## Self-Review

- Environment/path construction performs no filesystem call.
- Production-like roots and remote credential rejection leave the configured local root absent.
- The namespace sibling/outside cases and all four required private descendant alias classes use real
  filesystem links/junctions and assert their targets remain unchanged.
- Workspace requires the exact path/environment contract and independently validates physical root,
  namespace, workspace, and private-component identity; the builder is not trusted as containment
  authority.
- No new private-home containment decision uses lexical `String.starts_with?/2`.
- Every existing private component is checked before creation begins; every created component receives
  an identity and is revalidated immediately with all prior identities.
- Task 1 stable workspace identity remains the creation and cleanup attestation boundary.
- Owner-private permissions are verified on all seven directories on the current Windows host; POSIX
  mode verification is in the same cross-platform regression.
- Private-home/native command output is discarded, and all internal failures reduce to one bounded atom.
- The provider deny-by-default contract, remote failure contract, hook ordering, context-free legacy
  behavior, and existing AppServer/Git/Codex effect ordering remain intact.
- The diff is limited to the six planned source/test files plus the required acceptance/report evidence.

## Concerns

- This host runs Elixir 1.20.2/OTP 28 while the repository documents Elixir 1.19.x. The focused runtime,
  compiler, spec, and Dialyzer gates pass here; documented-toolchain CI remains authoritative.
- The current host directly exercises Windows junction/reparse inspection and ACL readback. The POSIX
  canonical-symlink and mode-`0700` branches require POSIX CI for live integration coverage.
- Phoenix LiveView emits the existing non-fatal Windows `node_modules` symlink-permission warning when
  compilation is triggered. It does not affect the exit status or any Task 2 assertion.
- The known 10 ms hook-timeout case can invert under aggregate host load. The exact ARO boundary first
  completed 401/401; its final hardened-tree rerun completed 400/401 with only that case, which then
  passed immediately in isolation.

## Fix Round 1: Retained Capabilities, Rollback, and Attested Cleanup

### Outcome

The remediation now closes the review findings that remained after commit `2dff53c`:

- Private-home creation is componentwise. Every new component is made private and verified before the
  next component is created. Workspace tracks only directories created by the current attempt and, on
  a creation, permission, or validation failure, removes them in reverse order only after verifying
  their stable identity. Existing components are never repaired in place: unsafe permissions or
  ownership fail closed and remain untouched.
- Windows creation is coordinated by `SymphonyElixir.PrivateHome.WindowsCapability` and the fixed
  `priv/private_home_windows.ps1` helper. A long-lived helper process opens the configured root,
  namespace, workspace, and every existing private component with `FILE_SHARE_DELETE` omitted,
  verifies native file IDs and non-reparse directory attributes, creates one child at a time, applies
  and reads back the exact protected current-owner ACL, and retains the handles until commit or
  identity-verified rollback. Requests are newline JSON on stdin; the executable and script paths are
  fixed, user paths are never interpolated into a shell command, and replies contain only bounded
  protocol codes and created file IDs.
- POSIX creation uses a fixed `/usr/bin` or `/bin` `mkdir -m 700` executable without a shell, then
  verifies directory type, mode `0700`, effective-UID ownership, and stable device/inode identity.
  Rollback is reverse-order and identity checked. Public OTP provides no `openat`/directory-handle
  capability for this path, so a hostile process running as the same UID can still race pathname
  operations; the implementation does not claim atomic protection against that same-UID attacker.
- Context cleanup now requires the supplied stable workspace attestation before removal or any hook.
  It never creates a private home. A configured cleanup hook may use only a complete existing private
  home that passes the same identity/permission checks; Windows retains its handles through the hook.
  Cleanup without a hook does not inspect or create the home. The legacy nil-context cleanup path is
  unchanged.
- Readiness-state preparation errors returned to `AgentRunner` carry the preparation workspace
  attestation. The error `after_run` branch uses that attestation, so rename/recreate before the hook is
  rejected and the credential-bearing hook does not run.
- Windows environment layers are merged by a case-insensitive key identity. Ambient, runtime,
  deny-default, approved-provider, and private-home layers therefore produce exactly one effective
  HOME/GH/XDG/Codex/provider key. An unapproved mixed-case provider spelling cannot override a deny;
  an exact approved provider key can. POSIX merging remains case-sensitive.

### RED Evidence

The first creation/capability/ownership batch was added before implementation:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:574 \
  test/symphony_elixir/workspace_and_config_test.exs:606 \
  test/symphony_elixir/workspace_and_config_test.exs:634 \
  test/symphony_elixir/workspace_and_config_test.exs:665 \
  test/symphony_elixir/workspace_and_config_test.exs:725

Result: 0/5 passed, 74 excluded
Failed: 5 tests
```

The failures were exact: a mid-creation callback left `.symphony-subprocess`; the permission failure
option was ignored; an unsafe pre-existing directory was accepted and changed; the namespace could be
renamed after validation; and the production POSIX owner/mode validator did not exist.

Cleanup regressions were then run before the cleanup refactor:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:746 \
  test/symphony_elixir/workspace_and_config_test.exs:780 \
  test/symphony_elixir/workspace_and_config_test.exs:820

Result: 1/3 passed, 79 excluded
Failed: 2 tests
```

The two failing cases proved that attested cleanup created a missing private home for a hook and that
cleanup without a hook still created one. The no-attestation case already happened to stop after the
old creation path dereferenced a missing attestation; the implementation now makes that fail-closed
boundary explicit before path resolution, removal, or hook execution.

The readiness-error and environment regressions also failed before their production seams existed:

```text
mix test test/symphony_elixir/workspace_preflight_blocker_test.exs:495

Result: 0/1 passed, 17 excluded
Failed: 1 test
```

```text
mix test test/symphony_elixir/subprocess_environment_test.exs:83 \
  test/symphony_elixir/subprocess_environment_test.exs:102

Result: 0/2 passed, 1 excluded
Failed: 2 tests
```

The readiness helper was undefined. The environment builder emitted two case aliases to its map and
had no platform-aware merge contract.

### GREEN Evidence

The final formatted tree passes all eleven new security regressions:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:576 \
  test/symphony_elixir/workspace_and_config_test.exs:621 \
  test/symphony_elixir/workspace_and_config_test.exs:649 \
  test/symphony_elixir/workspace_and_config_test.exs:680 \
  test/symphony_elixir/workspace_and_config_test.exs:740 \
  test/symphony_elixir/workspace_and_config_test.exs:759 \
  test/symphony_elixir/workspace_and_config_test.exs:790 \
  test/symphony_elixir/workspace_and_config_test.exs:824 \
  test/symphony_elixir/workspace_preflight_blocker_test.exs:495 \
  test/symphony_elixir/subprocess_environment_test.exs:82 \
  test/symphony_elixir/subprocess_environment_test.exs:101

Finished in 13.0 seconds (0.00s async, 13.0s sync)

Result: 11 passed, 92 excluded
```

The first rollback test additionally inspects all previously created components at the next creation
seam and proves they are already owner-private before injecting the failure. The Windows environment
case spawns a real Windows PowerShell child and counts effective case-insensitive keys.

### Affected and Acceptance Verification

```text
mix test test/symphony_elixir/subprocess_environment_test.exs \
  test/symphony_elixir/workspace_and_config_test.exs \
  test/symphony_elixir/workspace_preflight_blocker_test.exs \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs \
  test/symphony_elixir/project_credential_provider_test.exs \
  test/symphony_elixir/app_server_test.exs

Finished in 60.3 seconds (2.2s async, 58.1s sync)

Result: 140 passed
```

Context running/blocked/retry cleanup fixtures now supply the same stable attestation that production
runtime metadata carries:

```text
mix test test/symphony_elixir/core_test.exs

Finished in 15.6 seconds (0.00s async, 15.6s sync)

Result: 58 passed
```

The exact 17-file command in `elixir/docs/aro_286_acceptance.md` completed:

```text
Finished in 307.4 seconds (2.9s async, 304.5s sync)

Result: 411/412 passed
Failed: 1 test
```

The only failure was the unchanged reused-temporary-path junction collision in `workspace
canonicalizes symlinked workspace roots before creating issue directories`: `mklink` reported that
the link already existed. Its immediate final-tree classification passed:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:1495

Finished in 1.9 seconds (0.00s async, 1.9s sync)

Result: 1 passed, 81 excluded
```

The acceptance output reported no skipped tests, so the paired `pwsh` and `powershell.exe` watchdog
cases both ran. A direct final parser check also passed:

```text
mix test test/bin/symphony_watchdog_test.exs:13 \
  test/bin/symphony_watchdog_test.exs:18

Result: 2 passed, 27 excluded
```

### Static and Build Verification

- Targeted `mix format --check-formatted` for all eight changed source/test files: passed with no
  output.
- `mix specs.check`: `specs.check: all public functions have @spec or exemption`.
- `mix compile --warnings-as-errors`: passed with no output on the already compiled final tree.
- `mix dialyzer --format short`: `Total errors: 0, Skipped: 0, Unnecessary Skips: 0` and `done
  (passed successfully)`.
- `mix build`: `Generated escript bin/symphony with MIX_ENV=dev`.
- `git diff --check`: no whitespace errors; only the checkout's LF/CRLF conversion warnings.

### Files

- Added `elixir/lib/symphony_elixir/private_home/windows_capability.ex`.
- Added `elixir/priv/private_home_windows.ps1`.
- Modified `elixir/lib/symphony_elixir/workspace.ex`.
- Modified `elixir/lib/symphony_elixir/agent_runner.ex`.
- Modified `elixir/lib/symphony_elixir/subprocess_environment.ex`.
- Modified `elixir/test/symphony_elixir/workspace_and_config_test.exs`.
- Modified `elixir/test/symphony_elixir/workspace_preflight_blocker_test.exs`.
- Modified `elixir/test/symphony_elixir/subprocess_environment_test.exs`.
- Modified `elixir/test/symphony_elixir/core_test.exs` to supply production-equivalent cleanup
  attestations.
- Updated `elixir/docs/aro_286_acceptance.md` and this report.

### Self-Review

- The Windows helper owns no policy decision: Workspace validates exact context, root, namespace,
  workspace, contract, and expected identities before opening the narrow filesystem capability.
- Existing unsafe components are validation-only and never chmod/ACL repair targets. Only components
  created by the current attempt have delete-capable handles or enter the POSIX rollback list.
- Every successful Windows command verifies all retained handles again. Commit validates the complete
  component set; rollback marks only identity-verified created handles for deletion in reverse order.
- Every helper failure, malformed/oversized response, timeout, native failure, and internal path or ACL
  failure maps to a fixed bounded atom at the Elixir boundary. Native output and exception text are not
  logged or returned.
- Cleanup no longer calls the creation function. It requires an attestation before any context cleanup
  effect, opens existing homes only for a configured hook, and leaves both workspace and home untouched
  when the attestation/home contract is absent.
- The readiness-error wrapper is opt-in to AgentRunner's preparation call, preserving existing public
  Workspace error shapes for other callers while giving the error `after_run` branch the captured
  attestation.
- Windows key identity is case-insensitive across every environment layer; POSIX uses exact keys.
  Provider values remain restricted to the existing approved key contract.
- The legacy nil-context workspace and cleanup branches are unchanged.

### Remaining Concern

POSIX CI still needs to exercise the live `File.mkdir/1`, immediate `chmod`, effective-UID, mode, and
device/inode integration. The production ledger and validator are covered by injected production-core
and pure owner/mode tests on this Windows host, but public OTP exposes no `openat`-style directory
capability. Consequently the POSIX implementation can detect and fail closed around identity changes
but cannot make every pathname operation atomic against a malicious process already running as the
same effective UID.

## Fix Round 2 — Atomic Creation and Attempt-Lifetime Capability

### RED Evidence

The atomic creation/protocol batch failed before the native creation and correlated protocol were
implemented:

```text
mix test test/symphony_elixir/private_home_windows_capability_test.exs \
  test/symphony_elixir/workspace_and_config_test.exs:740

Result: 0/4 passed
Failed: 4 tests
```

The first lifetime batch failed before preparation returned an opaque capability and AgentRunner
retained it across effect boundaries:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:784 \
  test/symphony_elixir/workspace_and_config_test.exs:840 \
  test/symphony_elixir/workspace_and_config_test.exs:890 \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs:277

Result: 0/4 passed
Failed: 4 tests
```

The readiness error branch initially lacked the preparation capability, and a workspace ancestor
rename was observed to succeed on this Windows host:

```text
mix test test/symphony_elixir/workspace_preflight_blocker_test.exs:495

Result: 0/1 passed
Failed: 1 test
```

The public preparation failure regression then proved that the successful private-home creation was
left behind after a failing `after_create` hook:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:784

Result: 0/1 passed, 86 excluded
Failed: 1 test
```

The platform-independent POSIX ledger tests were added before their production core existed:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:1124 \
  test/symphony_elixir/workspace_and_config_test.exs:1166

Result: 0/2 passed, 90 excluded
Failed: 2 tests
```

A final self-review assertion made the post-`mkdir` exception distinction explicit before its fix:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:1124

Result: 0/1 passed, 91 excluded
Failed: 1 test
```

The observed result was `private_home_create_failed`; the required result was
`private_home_rollback_failed`, because `File.mkdir/1` had already returned `:ok` before identity
capture raised.

### Design

- Windows child creation now uses relative `NtCreateFile(FILE_CREATE)` against the retained exact
  parent handle. The syscall receives a protected current-owner-only security descriptor, returns the
  exact no-share-delete handle, and captures its file ID before any observer or fallible follow-up.
  Constructor failure marks that held object for deletion before releasing the handle.
- Workspace returns an opaque private-home capability in preparation. AgentRunner carries it through
  readiness, `after_create`, every Git/preflight command, `before_run`, Codex AppServer startup,
  `after_run`, and readiness-error paths. Workspace combines Task 1 workspace/namespace attestations,
  every private-component identity/permission check, and the helper-held IDs immediately before each
  credential-bearing process boundary. AgentRunner finalizes it only after all attempt effects.
- Each helper request has a fresh numeric correlation ID; reused IDs, timeouts, partial/oversized,
  malformed, or mismatched replies retire the port permanently. Commit and rollback rejection also
  retire it. Rollback reports success only after every current-attempt object was identity verified and
  deleted; Workspace surfaces rollback/finalization failure as bounded atoms.
- POSIX creation calls `File.mkdir/1` one component at a time and records a component only after that
  call returns `:ok` and UID/device/inode/type identity is captured. `EEXIST` and pre-mkdir failures do
  not enter the ledger. Rollback processes the newest-first ledger, revalidates the complete identity,
  continues safe cleanup after an individual failure, and reports failure if any identity or `rmdir`
  operation fails.
- Cleanup remains separate: it never creates a private home and opens an existing-home guard only for
  a configured credential-bearing cleanup hook.

### GREEN Evidence

The final security batch on the formatted final tree covers atomic ACL observation, protocol
retirement, preparation/commit/rollback/orphan failure paths, hook/Git/Codex replacement, AgentRunner
success/error lifetimes, and POSIX tracking/identity rollback:

```text
mix test test/symphony_elixir/private_home_windows_capability_test.exs \
  test/symphony_elixir/workspace_and_config_test.exs:740 \
  test/symphony_elixir/workspace_and_config_test.exs:784 \
  test/symphony_elixir/workspace_and_config_test.exs:817 \
  test/symphony_elixir/workspace_and_config_test.exs:856 \
  test/symphony_elixir/workspace_and_config_test.exs:898 \
  test/symphony_elixir/workspace_and_config_test.exs:940 \
  test/symphony_elixir/workspace_and_config_test.exs:996 \
  test/symphony_elixir/workspace_and_config_test.exs:1046 \
  test/symphony_elixir/workspace_and_config_test.exs:1124 \
  test/symphony_elixir/workspace_and_config_test.exs:1174 \
  test/symphony_elixir/workspace_and_config_test.exs:1524 \
  test/symphony_elixir/workspace_preflight_blocker_test.exs:495 \
  test/symphony_elixir/readiness_gate_agent_runner_test.exs:277

Finished in 62.7 seconds (0.00s async, 62.7s sync)

Result: 16 passed, 106 excluded
```

The affected seven-file boundary completed with 151/153 passing. Its only two failures were the
unchanged reused-temporary-name Windows junction collisions in `workspace rejects symlink escapes
under the configured root` and `workspace canonicalizes symlinked workspace roots before creating
issue directories`; both failed in fixture `mklink` setup before Task 2 code. The one fixture corrected
for the new production capability contract passed in isolation (`1 passed, 91 excluded`).

The exact 17-file command in `elixir/docs/aro_286_acceptance.md` completed on the final behavior:

```text
Finished in 381.2 seconds (3.3s async, 377.8s sync)

Result: 422 passed
```

No skips were reported, so both the `pwsh` and Windows PowerShell watchdog cases ran.

### Static and Build Verification

- Targeted `mix format --check-formatted`: passed.
- `mix specs.check`: `specs.check: all public functions have @spec or exemption`.
- `mix compile --warnings-as-errors`: passed; the only printed warning is the unchanged Phoenix
  dependency symlink advisory from the non-elevated Windows host.
- `mix dialyzer --format short`: `Total errors: 0, Skipped: 0, Unnecessary Skips: 0`; passed.
- `mix build`: `Generated escript bin/symphony with MIX_ENV=dev`.
- `git diff --check`: passed; only LF/CRLF checkout advisories were printed.

### Files

- Modified `elixir/lib/symphony_elixir/agent_runner.ex`.
- Modified `elixir/lib/symphony_elixir/codex/app_server.ex`.
- Modified `elixir/lib/symphony_elixir/private_home/windows_capability.ex`.
- Modified `elixir/lib/symphony_elixir/workspace.ex`.
- Modified `elixir/priv/private_home_windows.ps1`.
- Added `elixir/test/support/private_home_protocol_fixture.ps1`.
- Added `elixir/test/symphony_elixir/private_home_windows_capability_test.exs`.
- Modified `elixir/test/symphony_elixir/readiness_gate_agent_runner_test.exs`.
- Modified `elixir/test/symphony_elixir/workspace_and_config_test.exs`.
- Modified `elixir/test/symphony_elixir/workspace_preflight_blocker_test.exs`.
- Updated `elixir/docs/aro_286_acceptance.md` and this report.

### Self-Review and Remaining Concern

- Native helper output and exceptions never cross the bounded protocol; environment or credential
  values are neither logged nor returned.
- Existing directories are validation-only. Windows delete access and the POSIX ledger cover only
  objects created by the current attempt; identity mismatch never deletes a concurrent/pre-existing
  object.
- A workspace ancestor rename can succeed on this Windows host even while private child/namespace
  handles are retained. This does not authorize a subprocess: Task 1 stable workspace and namespace
  attestations are rechecked before every use and at finalization, and the regression proves the
  replacement fails before a credential-bearing hook. Atomic private-directory creation and
  replacement blocking remain handle-based.
- Public OTP still exposes no `openat`-style POSIX directory capability. The implementation detects
  path/identity changes, uses owner UID plus device/inode/type, and never claims atomic protection
  against a malicious process already running as the same UID. Deployment-level user isolation is
  still required for that threat.
