# Task 1 Report: Stable Local Workspace Identity

## Outcome

Local project workspace attestations now compare only stable directory identity:

- POSIX: `type`, `major_device`, `minor_device`, and `inode`.
- Windows: `type` and the native `windows_file_id` returned by `fsutil file queryfileid`.

The implementation no longer compares directory `size`, `mode`, `links`, or timestamps. Platform dispatch, non-directory results, `File.stat/2` failures, and native Windows file-ID failures all fail closed. Canonical-path equality and every existing effect-boundary revalidation remain unchanged.

No private-home or Task 2 behavior was changed.

## Files

- Modified `elixir/lib/symphony_elixir/workspace.ex`.
- Modified `elixir/test/symphony_elixir/workspace_and_config_test.exs`.
- Added this report.

## TDD Evidence

### Baseline

Command:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs
```

Output before edits:

```text
Finished in 5.6 seconds (0.00s async, 5.6s sync)

Result: 65 passed
```

### RED

The regression obtains a real project-workspace attestation, runs a real `after_create` Git clone into that same directory, creates and removes top-level hook/Codex-like content, and then exercises preflight, the local hook boundary, AppServer validation through its process-launch boundary, and attested cleanup. The existing rename/recreate test was selected in the same run.

Command:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:415 test/symphony_elixir/workspace_and_config_test.exs:453
```

Relevant output:

```text
1) test project workspace identity survives normal content mutation across local effect boundaries
   match (=) failed
   code:  assert :ok = Workspace.preflight(workspace, "ARO-286", nil, effect_opts)
   left:  :ok
   right: {:error,
           {:workspace_issue_identity_changed,
            %{identity: %{
                links: 1,
                size: 4096,
                type: :directory,
                mode: 16895,
                inode: 0,
                major_device: 3,
                minor_device: 0,
                windows_file_id: "0x0000000000000000000c0000001cde99"
              }},
            %{identity: %{
                links: 1,
                size: 0,
                type: :directory,
                mode: 16895,
                inode: 0,
                major_device: 3,
                minor_device: 0,
                windows_file_id: "0x0000000000000000000c0000001cde99"
              }}}}

Finished in 2.3 seconds (0.00s async, 2.3s sync)

Result: 1/2 passed, 64 excluded
Failed: 1 test
```

This is the intended failure: the native Windows file ID stayed identical while mutable directory size changed from `0` to `4096`. The rename/recreate replacement regression passed in the same RED run.

### GREEN

First GREEN command after the minimal identity implementation and hermetic test environment setup:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:415 test/symphony_elixir/workspace_and_config_test.exs:453
```

Output:

```text
Finished in 2.7 seconds (0.00s async, 2.7s sync)

Result: 2 passed, 64 excluded
```

Fresh final GREEN command after the Dialyzer-driven dispatch refactor and formatting (the new test moved to line 455):

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:415 test/symphony_elixir/workspace_and_config_test.exs:455
```

Output:

```text
Finished in 3.2 seconds (0.00s async, 3.2s sync)

Result: 2 passed, 64 excluded
```

The rename/recreate assertion now additionally proves the replacement's stable identity differs from the original attestation.

## Verification

### Focused regressions

Command:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/workspace_preflight_blocker_test.exs test/symphony_elixir/workspace_readiness_state_test.exs test/symphony_elixir/app_server_test.exs test/symphony_elixir/readiness_gate_test.exs test/symphony_elixir/readiness_gate_agent_runner_test.exs test/symphony_elixir/project_execution_context_test.exs test/symphony_elixir/multi_project_poll_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
```

Output:

```text
Finished in 153.5 seconds (1.8s async, 151.7s sync)

Result: 226 passed
```

Fresh isolated touched-suite command:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs
```

Output:

```text
Finished in 6.9 seconds (0.00s async, 6.9s sync)

Result: 66 passed
```

A final post-refactor rerun of the 226-test focused command completed `225/226 passed`; its only failure was the existing load-sensitive 10 ms `after_create` timeout. An immediate workspace-file rerun then encountered two unrelated Windows junction-helper collisions (`mklink` reported that the link already existed) caused by reused/persisted temporary test paths. The Task 1 line-selected lifecycle and replacement tests remained independently green at `2 passed, 64 excluded` on the final code tree.

### Static and build checks

- `mix format --check-formatted lib/symphony_elixir/workspace.ex test/symphony_elixir/workspace_and_config_test.exs`: passed with no output.
- `mix specs.check`: `specs.check: all public functions have @spec or exemption`.
- `mix dialyzer --format short`: `Total errors: 0, Skipped: 0, Unnecessary Skips: 0` and `done (passed successfully)`.
- `mix build`: `Generated escript bin/symphony with MIX_ENV=dev`.
- `git diff --check`: no whitespace errors; only Git's existing LF/CRLF conversion warnings for the two touched files.

### Repository-wide checks and environment limitations

The checkout documents Elixir 1.19.x, but the available environment is Elixir 1.20.2 on OTP 28.

- `make all` could not start because `make` is not installed in this Windows environment.
- `mix format --check-formatted` reports many untouched files as unformatted solely because their checked-out CRLF line endings would be rewritten to LF. Examples include `lib/symphony_elixir/readiness_gate.ex` and `lib/symphony_elixir/path_safety.ex`. Those unrelated files were not modified.
- `mix lint` completed `specs.check` but Credo 1.7.16 crashed in `Credo.Code.Token.position/1` while parsing Elixir 1.20 token tuples for existing sigils. The same crash occurs when limiting Credo to the touched files because `workspace_and_config_test.exs` already contains an unrelated sigil at line 1252.
- Full `mix test` completed with:

  ```text
  Finished in 408.0 seconds (8.7s async, 399.3s sync)

  Result: 1000/1016 passed, 13 skipped
  Failed: 16 tests
  ```

  The 16 failures were outside Task 1: four SQL migration assertions comparing LF literals with CRLF fixture files, one existing ScopeContract H5-heading case, ten related PR-body parser cases, and one load-sensitive 10 ms hook-timeout case. The hook-timeout test passes when the touched workspace/config file is rerun independently as shown above. No full-suite failure concerned stable workspace identity, replacement rejection, AppServer workspace validation, readiness, cleanup, or multi-project isolation.

## Self-Review

- Scope is limited to local workspace identity and its regression coverage; private-home logic is untouched.
- POSIX identity contains exactly directory type/device/inode fields.
- Windows identity contains exactly directory type/native file ID fields.
- There is no successful fallback when platform/native identity is unavailable.
- Mutable stat fields are absent from the attested identity.
- Existing canonical-path comparison is still part of whole-attestation equality.
- Existing immediate revalidation calls at preflight, hooks, AppServer launch, Git commands, readiness, and cleanup were not moved or weakened.
- The regression uses real filesystem and Git behavior. Only AppServer process creation is replaced, at the external process boundary, so reaching the opener proves both AppServer validations accepted the unchanged directory.
- Rename/recreate remains rejected and now asserts the actual and expected stable identities differ.
- `git diff --check` is clean, and no unrelated source files are modified.

## Concerns

- The current host exercises the Windows native-file-ID path directly. The cross-platform regression will exercise the POSIX type/device/inode path when run on POSIX CI, but this host cannot provide a POSIX runtime.
- Repository-wide formatter, Credo, and full-suite results need confirmation in the documented Elixir 1.19.x POSIX CI/toolchain because this Windows Elixir 1.20.2 checkout has the unrelated limitations recorded above.
- Repeated test VMs on this host reuse `System.unique_integer/1` values while many old `symphony-elixir-workspace-*` temporary directories persist, so later whole-file reruns can collide with pre-existing Windows junction paths. No broad temporary-directory deletion was performed.

## Fix Round 1

### Review Findings Addressed

- POSIX `File.Stat` coordinates can be `:undefined` or otherwise unusable even when `type` is `:directory`. The identity builder now returns the bounded reason `:invalid_posix_file_identity` unless `major_device`, `minor_device`, and `inode` are all non-negative integers.
- The Windows `fsutil` parser previously accepted the first matching substring. It now accepts exactly one whitespace-delimited `0x` plus 32-hex token, normalizes it to lowercase, and returns the bounded parser reason `:invalid_windows_file_id_output` for zero, short, embedded, punctuated, extended, or multiple tokens. The production boundary continues to mask every parser/native-command failure as `:windows_file_identity_unavailable`.
- The successful identity shapes remain unchanged: POSIX returns only type/device/inode; Windows returns only type/native file ID.

### RED

Pure test seams were first added with the existing unsafe semantics so the regressions failed on behavior rather than source inspection.

Command:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:524 test/symphony_elixir/workspace_and_config_test.exs:554
```

Relevant output:

```text
1) test Windows file identity parser accepts exactly one standalone native ID token
   match (=) failed
   left:  {:error, :invalid_windows_file_id_output}
   right: {:ok, "0x0123456789abcdefabcdef0123456789"}

2) test POSIX workspace identity rejects unavailable or invalid directory coordinates
   match (=) failed
   left:  {:error, :invalid_posix_file_identity}
   right: {:ok,
           %{
             type: :directory,
             inode: 11,
             major_device: :undefined,
             minor_device: 7
           }}

Finished in 1.4 seconds (0.00s async, 1.4s sync)

Result: 0/2 passed, 66 excluded
Failed: 2 tests
```

### GREEN

Parser/identity-focused command:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:524 test/symphony_elixir/workspace_and_config_test.exs:554
```

Output:

```text
Finished in 1.4 seconds (0.00s async, 1.4s sync)

Result: 2 passed, 66 excluded
```

Final selected command covering replacement rejection, real content mutation and Windows native parsing, POSIX validation, and parser edge cases:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:415 test/symphony_elixir/workspace_and_config_test.exs:453 test/symphony_elixir/workspace_and_config_test.exs:524 test/symphony_elixir/workspace_and_config_test.exs:554
```

Output:

```text
Finished in 2.9 seconds (0.00s async, 2.9s sync)

Result: 4 passed, 64 excluded
```

### Focused and Static Verification

The full workspace/AppServer/readiness/execution-context/multi-project command listed earlier in this report was rerun after Fix round 1:

```text
Finished in 150.3 seconds (1.9s async, 148.3s sync)

Result: 227/228 passed
Failed: 1 test
```

The sole failure was the existing load-sensitive `workspace surfaces after_create hook timeouts` case with a 10 ms threshold. Its isolated rerun was green:

```text
mix test test/symphony_elixir/workspace_and_config_test.exs:1049

Finished in 1.4 seconds (0.00s async, 1.4s sync)

Result: 1 passed, 67 excluded
```

Final static results:

- `mix format --check-formatted lib/symphony_elixir/workspace.ex test/symphony_elixir/workspace_and_config_test.exs`: passed with no output.
- `mix specs.check`: `specs.check: all public functions have @spec or exemption`.
- `mix dialyzer --format short`: `Total errors: 0, Skipped: 0, Unnecessary Skips: 0` and `done (passed successfully)`.
- `git diff --check`: no whitespace errors; only the checkout's existing LF/CRLF conversion warnings.

### Fix Round 1 Self-Review

- The pure POSIX helper is used by production code and tests the real identity construction path; it rejects `:undefined`, strings, floats, `nil`, negative values, and non-directory types with one bounded atom.
- The Windows parser is used by production code and tests the real parser path. Its success output is lowercase and contains no extra fields.
- Parser tests cover zero tokens, short tokens, prefix/suffix embedding, punctuation, 33-hex extension, and duplicate standalone tokens.
- The real lifecycle regression still obtains a Windows ID through `fsutil`, proving the stricter parser accepts actual command output on this host.
- Canonical path equality, replacement rejection, and all effect-boundary revalidation remain unchanged.
- No private-home or Task 2 behavior was touched.

### Fix Round 1 Concerns

- POSIX invalid-value behavior is proven through the production pure identity builder on this Windows host; live POSIX `File.stat/2` integration still requires POSIX CI.
- The pre-existing Windows/Elixir 1.20.2 formatter, Credo, temp-directory, and aggregate-load limitations documented above remain unchanged.
