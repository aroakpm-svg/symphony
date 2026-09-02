# Task 5 Report: Secret-Safe Runtime Health State

## Status

Complete. The runtime health owner starts before `CoreSupervisor`, records bounded typed evidence for all seven stages and both dependencies, persists a final secret-safe stop receipt atomically below a validated dedicated runtime-state directory, and exposes the snapshot through the orchestrator, terminal dashboard, and web presenter. Health reporting is observational only and is covered against authorization/retry changes when reporting raises.

## Commits

- `bedc656` — `feat: expose fail-closed runtime health`
- The report itself is committed separately after recording the implementation hash.

## Files

Created:

- `elixir/lib/symphony_elixir/runtime_health.ex`
- `elixir/test/symphony_elixir/runtime_health_test.exs`

Modified:

- `elixir/lib/symphony_elixir.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/status_dashboard.ex`
- `elixir/lib/symphony_elixir_web/presenter.ex`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`
- Five terminal dashboard snapshot fixtures and their five evidence files under `elixir/test/fixtures/status_dashboard_snapshots/`

## RED Evidence

Initial required RED command:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs
```

Observed result before production implementation:

```text
Result: 54/61 passed
Failed: 7 tests
```

Expected feature failures included the absent `SymphonyElixir.RuntimeHealth` module/API, no orchestration health transitions, and no terminal health rendering. One Windows root-path test setup error was corrected before implementation so it did not count as feature RED evidence.

The strengthened idempotence mutation was also demonstrated RED after replacing the fixed clock with an advancing deterministic clock:

```text
mix test test/symphony_elixir/runtime_health_test.exs
Result: 3/4 passed
Failed: 1 test
```

The failure was the expected duplicate history entry (`left: 2`, `right: 1`) and was fixed by treating an identical current transition as a no-op regardless of timestamp.

## GREEN Evidence

Required focused health and multi-project regression command:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
```

Fresh final result:

```text
Result: 105 passed
Failed: 0 tests
```

Web presenter/API regression command:

```text
mix test test/symphony_elixir/extensions_test.exs
```

Fresh final result:

```text
Result: 12 passed
Failed: 0 tests
```

Earlier post-implementation run of the three required health/status files:

```text
Result: 61 passed
Failed: 0 tests
```

## Static Checks

- Focused formatter check over every changed Elixir source/test file: passed.
- `mix specs.check`: passed (`all public functions have @spec or exemption`).
- `git diff --check`: passed.
- `mix lint`: did not complete because Credo 1.7.16 crashed in untouched tests while parsing Elixir 1.20.2 sigil token shapes (`claim_service_test.exs` and `merge_ready_evidence_test.exs`). The repository specifies Elixir 1.19.x.
- Whole-repository `mix format --check-formatted`: blocked by existing CRLF formatting mismatches in untouched files on this Windows checkout; the focused formatter check for all Task 5 files passed.
- Whole-repository `mix test`: blocked outside Task 5 by an existing CRLF-sensitive assertion in `staging_foundation_migration_test.exs` and an existing `Workspace.ReadinessState` construction missing Task 1 fields in `readiness_gate_test.exs`. Neither file was changed by Task 5.

## Self-Review

- Fixed stage enum is exactly `candidate_fetch`, `issue_refresh`, `routing`, `profile_resolution`, `preflight`, `claim`, and `dispatch`.
- Unknown stages, unknown fields, invalid statuses, non-scalar values, credential fields, credential-like strings, and secrets appearing after the truncation boundary are rejected before state mutation.
- `ProjectExecutionContext.safe_metadata/1` is used once a fully authorized context can be constructed; earlier boundaries emit only the corresponding safe profile/issue identity subset. `credential_ref` is never accepted or stored.
- Current stage state and history are bounded; identical repeated stage transitions are timestamp-independent no-ops.
- Runtime-state and workspace paths are canonicalized, filesystem roots and workspace-contained targets are rejected, and the JSON stop receipt is written to a same-directory temporary file before rename.
- RuntimeHealth is supervised before `CoreSupervisor`, so Linear startup-gate failures can be recorded without joining CoreSupervisor's restart domain.
- Every issue-scoped transition includes `profile_key`, `issue_id`, and `issue_identifier`; candidate fetch includes profile context because no issue exists yet.
- Instrumentation is attached to the existing decision boundaries. The reporter wrapper catches return errors, raises, throws, and exits. Tests show a failed reporter leaves successful claim/dispatch results and transient routing retry classification unchanged.
- Missing health evidence is rendered as `unknown`; neither the dashboard nor web presenter infers success.

## Concerns

- The requested focused suites and presenter regression are all green. The repository-wide formatter, lint, and test gates remain blocked by the unrelated baseline/toolchain issues documented above.
- The checkout is running Elixir 1.20.2 although `elixir/AGENTS.md` specifies Elixir 1.19.x; this is the direct trigger for the Credo parser crash.
- Existing compilation emits an unrelated `HttpServer.normalize_host/1` unreachable-clause warning, and Phoenix LiveView emits an existing Windows symlink-permission warning.

## Fix round 1

### Status

Complete. All six review findings were fixed at their decision boundaries without changing claim authorization, release, retention, or retry behavior. The implementation commit is `40c4d06b759a08189adba77b2f157e26561dd4bc` (`fix: harden runtime health receipts`); this report update is committed separately so the implementation hash is recorded exactly.

### Files

Modified:

- `elixir/lib/symphony_elixir/runtime_health.ex`
- `elixir/lib/symphony_elixir.ex`
- `elixir/test/symphony_elixir/runtime_health_test.exs`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `.superpowers/sdd/2026-08-28-aro-286-project-workspace-isolation/task-5-report.md`

### Root causes and fixes

- Receipt containment previously trusted the startup-resolved `runtime-state` target without proving it remained a strict canonical descendant of the canonical configured receipt root. Startup now resolves the configured root, `runtime-state`, and workspace root; rejects filesystem roots, workspace targets, and canonical escapes; and stores both lexical and canonical identities. Every receipt write resolves the configured root and `runtime-state` again, rechecks containment, and requires both targets to match their startup canonical identities before publication. Deterministic injected path resolution covers preexisting escape/root targets and post-start target replacement without depending on host symlink privileges.
- Secret detection used a narrow prefix expression. Every accepted binary is now scanned before field-specific validation or truncation using conservative structural detection for OpenAI project keys, GitHub OAuth/classic/fine-grained tokens, AWS access-key IDs, Slack, Google, Stripe, GitLab, npm, PyPI, Hugging Face, JWT, private-key blocks, credential labels, and URL userinfo. Tests apply credential-shaped values across every accepted string field; no credential value is logged.
- `Application.stop/1` runs after supervised children terminate. Final stop recording now happens in `Application.prep_stop/1`; `stop/1` retains only offline dashboard rendering. The lifecycle integration invokes the callback with an injected live health server, verifies the server is alive at recording time, and verifies the durable receipt.
- The former scalar sanitizer did not type fields by key. Stage, dependency, context, and stop schemas now enforce status/category domains, an explicit failure-category domain, structured nonempty IDs/identifiers/profile/repository/branch/workspace strings, exact local environment, and a positive integer routing revision. Representative wrong strings, atoms, integers, nils, and domain values are rejected before mutation.
- Dependency transitions now compare timestamp-independent evidence and make unchanged replays no-ops. Stop calls always validate the submitted map before returning an idempotent success, so unknown and credential-bearing replay values remain rejected after a stop has already been recorded.
- A fixed `final-stop.json` rename could replace an existing Windows target. Each process now owns a validated `runtime_epoch` and publishes `stop-<runtime_epoch>.json` immutably: it writes a closed same-directory exclusive temporary file, atomically creates a no-clobber hard link at the final path, and then removes the temporary name. A forced epoch collision returns `:receipt_write_failed`, preserves the original bytes, and leaves no temporary file. The receipt and health snapshot expose both `runtime_epoch` and `receipt_path` for Task 6; no mutable latest pointer was added because the current contract does not require one.

### RED evidence

After correcting one test setup syntax error, the valid review-regression RED command was:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs
```

Observed result before production changes:

```text
Result: 52/60 passed
Failed: 8 tests
```

The eight expected failures demonstrated the missed credential shapes, missing per-key type errors, duplicate dependency history, stop replay bypassing validation, missing epoch/path receipt contract, preexisting and post-validation path escapes, and absent pre-termination callback recording.

### GREEN evidence

Focused fix suite:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs
```

Fresh result:

```text
Finished in 17.3 seconds
Result: 60 passed
Failed: 0 tests
```

Required health/status/multi-project regression suite:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
```

Fresh result:

```text
Finished in 19.4 seconds
Result: 111 passed
Failed: 0 tests
```

Presenter/API regression suite:

```text
mix test test/symphony_elixir/extensions_test.exs
```

Fresh result:

```text
Finished in 3.7 seconds
Result: 12 passed
Failed: 0 tests
```

### Static checks

Focused formatter check:

```text
mix format --check-formatted lib/symphony_elixir.ex lib/symphony_elixir/runtime_health.ex test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs
```

Result: exit status 0 with no formatter findings.

Public-spec check:

```text
mix specs.check
```

Result:

```text
specs.check: all public functions have @spec or exemption
```

Diff check:

```text
git diff --check
```

Result: exit status 0 with no whitespace errors. Git emitted only the checkout's existing LF-to-CRLF conversion notices.

### Self-review

- Canonical containment is established beneath the canonical configured root, not merely against the lexical path. The write path also rejects root/workspace targets and canonical target changes before creating a receipt.
- Event validation scans secrets before truncation, validates every allowed key by its own type/domain, never accepts `credential_ref`, and does not add any logging of submitted values.
- Immutable epoch filenames eliminate replacement of a prior final receipt. Same-directory hard-link publication is no-clobber on Windows and Unix; collision and cleanup behavior are exercised on this Windows host.
- `prep_stop/1` records while `RuntimeHealth` is alive and returns the unchanged application state. Existing instrumentation failure containment remains intact, so health remains observational.
- Stage, dependency, and stop replay behavior is idempotent only after validating the incoming evidence. Unknown evidence continues to render `unknown`.

### Concerns

- All Task 5 focused suites, presenter tests, multi-project regressions, formatter checks, spec checks, and diff checks are green.
- The repository-wide baseline issues from the original report remain unchanged: the checkout uses Elixir 1.20.2 instead of the specified 1.19.x, Credo crashes on untouched sigils, whole-repository formatting encounters untouched CRLF differences, and unrelated full-suite tests fail in staging/readiness coverage.
- Compilation still emits the unrelated `HttpServer.normalize_host/1` warning and the existing Phoenix LiveView Windows symlink-permission warning.

## Fix round 2

### Status

Complete within the enforceable OTP capability boundary requested by the review. The implementation commit is `16f1d3ee3fa101765aea3cc0d6c94490719b8e34` (`fix: pin runtime receipt publication`); this report update is committed separately so the implementation hash is recorded exactly.

### Files

Created:

- `elixir/src/symphony_runtime_receipt_writer.erl`

Modified:

- `elixir/lib/symphony_elixir/runtime_health.ex`
- `elixir/test/symphony_elixir/runtime_health_test.exs`
- `.superpowers/sdd/2026-08-28-aro-286-project-workspace-isolation/task-5-report.md`

### Root cause and capability design

The round-1 implementation performed its final canonical/identity validation and then called `File.write/3` and `File.ln/2` with ordinary absolute pathnames. A concurrent directory replacement between those operations could redirect both names through a new `runtime-state` symlink. Repeating pathname validation cannot remove that check/use race.

OTP 28's `file:open/2` supports `directory` handles, but OTP exposes no public `openat`/relative-create/link API against such a handle. Direct probes on this Windows host established the relevant behavior:

```text
file:open(RuntimeState, [read, raw, directory])
rename_while_open=ok

file:open(GuardInsideRuntimeState, [read, raw])
rename_with_open_child={error,einval}
```

The smallest cross-platform capability boundary is therefore a narrowly isolated OTP writer process, launched from the same bundled Erlang runtime when `RuntimeHealth` initializes:

- The writer process starts with the validated `runtime-state` directory as its operating-system working directory, creates and syncs a unique ownership guard, and keeps that guard handle open for its lifetime. RuntimeHealth completes a token identity handshake before accepting the writer.
- On Windows, the open child handle prevents the containing directory from being renamed or replaced. The adversarial regression asserts the replacement attempt is blocked on this Windows host.
- On POSIX systems, the writer's working-directory reference remains pinned to the originally validated directory inode if the pathname is renamed and replaced by a symlink. The writer also refuses publication when its ownership guard is no longer reachable at the validated consumer path.
- After the final parent-side canonical/identity validation, all temp creation, sync, no-clobber hard-link publication, cleanup, and bounded pruning use validated relative basenames inside the pinned writer. No write/link/delete operation uses the replaceable absolute `runtime-state` pathname.
- Immutable `stop-<runtime_epoch>.json` naming, collision refusal, the receipt's `runtime_epoch`/`receipt_path`, and Task 6's normal consumption contract remain unchanged.

The ownership-guard reachability test is not claimed as the security primitive and does not make a repeated pathname check close TOCTOU. It is a fail-closed consumer-path check before the capability-relative operation. The containment property comes from the pinned writer and its relative-only filesystem operations; on Windows it is additionally enforced by the non-share-delete guard handle.

### Adversarial regression

The injected `before_receipt_publish` hook runs after the final parent canonical/identity validation and immediately before the capability command. It attempts to rename `runtime-state` and replace it with a symlink to a workspace directory. The test proves:

- Windows rejects the rename while the ownership guard is open, after which normal immutable publication succeeds.
- On a platform where replacement succeeds, the writer refuses publication and final health remains `unknown`.
- No epoch receipt is created in the workspace/external target, the displaced directory, or the filesystem root.

### RED evidence

Command:

```text
mix test test/symphony_elixir/runtime_health_test.exs
```

Observed before production changes:

```text
Finished in 0.3 seconds
Result: 9/10 passed
Failed: 1 test
```

The expected failure was `attack != :not_called`: the new final-boundary hook was not invoked by the pathname-based publisher, so the regression proved the missing boundary rather than failing from test setup.

### GREEN evidence

Focused runtime-health suite:

```text
mix test test/symphony_elixir/runtime_health_test.exs
```

Fresh result:

```text
Finished in 2.2 seconds
Result: 10 passed
Failed: 0 tests
```

Focused runtime-health/status suite:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs
```

Fresh result:

```text
Finished in 19.1 seconds
Result: 61 passed
Failed: 0 tests
```

Required health/status/multi-project regression suite:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
```

Fresh final result:

```text
Finished in 21.4 seconds
Result: 112 passed
Failed: 0 tests
```

Presenter/API regression suite:

```text
mix test test/symphony_elixir/extensions_test.exs
```

Fresh final result:

```text
Finished in 3.6 seconds
Result: 12 passed
Failed: 0 tests
```

### Static checks

Focused formatter:

```text
mix format --check-formatted lib/symphony_elixir/runtime_health.ex test/symphony_elixir/runtime_health_test.exs
```

Result: exit status 0 with no formatter findings.

Public-spec check:

```text
mix specs.check
```

Result:

```text
specs.check: all public functions have @spec or exemption
```

Forced compiler check, including the new Erlang writer:

```text
mix compile --force
```

Result: exit status 0; `Compiling 1 file (.erl)`, `Compiling 63 files (.ex)`, and `Generated symphony_elixir app`. Only the pre-existing `HttpServer.normalize_host/1` and Phoenix LiveView Windows symlink warnings were emitted.

Diff check:

```text
git diff --check
```

Result: exit status 0 with no whitespace errors. Git emitted only the checkout's existing LF-to-CRLF conversion notices.

### Self-review

- No file creation, hard-link, pruning, or cleanup operation after final validation receives the replaceable absolute directory path. The helper accepts relative basenames only and rejects empty, dot, parent, slash, and backslash names.
- Publication still writes a closed, synced, exclusive temporary file before an atomic no-clobber hard link. Epoch collisions preserve the original receipt and remove the temporary file.
- The writer uses the `erl` executable from the running OTP root first, avoiding shell parsing and PATH substitution; the normal PATH lookup is only a development fallback. Missing writer capability fails RuntimeHealth startup rather than falling back to unsafe pathname publication.
- The adversarial hook is test-only injection at the exact final validation/use boundary. Runtime instrumentation remains observational and does not change claim authorization, release, retention, or retry decisions.
- The guard token is ephemeral non-credential ownership evidence, is never logged or presented, and is deleted when the writer closes. Receipt payload validation and secret rejection are unchanged.

### Exact portable limitation

Public OTP provides neither `openat`-style child creation/linking against its directory handle nor a portable mandatory directory lock. The helper closes the symlink-redirection race by operating relative to a pinned working-directory capability, and the Windows guard handle prevents replacement outright. On POSIX, however, a same-privilege malicious actor can rename the already-pinned directory inode itself to a different namespace location. If that relocation happens after the ownership-guard reachability check but before the relative write, POSIX keeps the working-directory capability valid at the relocated inode. OTP alone cannot prove that the inode's namespace location remained below the configured root at that instant. This is not represented as fully portable protection against an actively malicious same-user namespace relocation; eliminating that residual limitation requires a native OS-specific helper/privilege boundary or stronger filesystem ownership outside public OTP.

### Concerns

- All requested focused suites and static checks are green. The exact POSIX same-user inode-relocation limitation is documented above; the Windows platform used for this task enforces replacement blocking and passes the final-boundary adversarial regression.
- RuntimeHealth now requires the `erl` launcher from the running OTP installation so it can establish the isolated writer capability. If a future stripped release omits that launcher, startup fails closed with `receipt_writer_unavailable` rather than using unsafe pathnames.
- The inherited repository/toolchain warnings and unrelated full-suite blockers recorded in Fix round 1 remain unchanged.

## Fix round 3

### Status and commits

Complete. The implementation and adversarial regressions are committed as `098eb6f916aa80c11d2162bca3b1a84939657b16` (`fix: attest runtime receipt writer lifecycle`). This report update is committed separately so the implementation hash is recorded exactly.

### Files

Modified:

- `elixir/lib/symphony_elixir/runtime_health.ex`
- `elixir/src/symphony_runtime_receipt_writer.erl`
- `elixir/test/symphony_elixir/runtime_health_test.exs`
- `.superpowers/sdd/2026-08-28-aro-286-project-workspace-isolation/task-5-report.md`

### Root causes and fixes

The round-2 writer was capability-relative only after `Port.open/2`. Parent validation happened before acquisition, and the init handshake proved only a random guard token reachable through the same replaceable pathname. A replacement between validation and acquisition could therefore make both the writer and the parent observe the same escaped directory.

The writer now attests the capability it actually acquired after its operating-system working directory and open guard handle exist. Its tagged init response reports the pinned current directory, the OS file identity of `.` and the open guard handle, and the exact ephemeral guard token. RuntimeHealth then freshly re-resolves the configured receipt root and runtime-state path, re-runs strict containment/root/workspace rejection, canonicalizes the helper's actual current directory independently, and compares parent-side directory/guard identities and guard bytes. Any mismatch closes and retires the writer before RuntimeHealth startup completes. The deterministic acquisition-boundary test performs a real rename/symlink replacement where supported and otherwise injects the escaped resolved directory at the same pre-`Port.open` boundary; both paths prove that no external guard or receipt survives.

Launcher discovery no longer searches `PATH`. It considers only fixed candidates below the canonical running OTP root: `bin/erl[.exe]` for development installations and `erts-<version>/bin/erl[.exe]` for standard bundled releases. Candidate canonical containment and regular-file existence are required. A release-layout resolver/opener regression proves the bundled ERTS candidate is selected, and a stripped-layout regression proves absence fails closed with `:erl_not_found`.

Every valid writer command and response now carries a fresh correlation ID. A timeout, malformed response, wrong ID, oversized response, writer exit, or closed port immediately changes the writer capability to `usable: false`, closes and monitors the port for bounded termination, and prevents all reuse. The helper's input reader remains responsive while a publication worker is delayed: stream closure cancels and joins that worker before guard cleanup and VM exit. Thus a timed-out publication cannot wake later and publish or acknowledge a later close/retry. The regression observes the retired state, waits beyond the injected delay, proves no receipt/guard appears, and proves retry remains failed without reusing the port.

### RED evidence

Command before implementation:

```text
mix test test/symphony_elixir/runtime_health_test.exs
```

Observed:

```text
Finished in 2.8 seconds
Result: 10/13 passed
Failed: 3 tests
```

The three expected failures were the acquisition-boundary attestation regression, bundled ERTS launcher discovery regression, and delayed writer retirement regression. The old implementation ignored all three new writer lifecycle options, started against the injected escaped acquisition, did not select the release launcher, and returned successful stop before the injected delay could take effect.

### GREEN evidence

Focused RuntimeHealth suite:

```text
mix test test/symphony_elixir/runtime_health_test.exs
```

Fresh result:

```text
Finished in 3.0 seconds
Result: 14 passed
Failed: 0 tests
```

Required RuntimeHealth/status/multi-project suite:

```text
mix test test/symphony_elixir/runtime_health_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/multi_project_dispatch_test.exs
```

Fresh result:

```text
Finished in 22.3 seconds
Result: 116 passed
Failed: 0 tests
```

Presenter/API regression suite:

```text
mix test test/symphony_elixir/extensions_test.exs
```

Fresh result:

```text
Finished in 3.6 seconds
Result: 12 passed
Failed: 0 tests
```

### Static checks

Focused formatter:

```text
mix format --check-formatted lib/symphony_elixir/runtime_health.ex test/symphony_elixir/runtime_health_test.exs
```

Result: exit status 0 with no formatter findings.

Public-spec check:

```text
mix specs.check
```

Result:

```text
specs.check: all public functions have @spec or exemption
```

Forced compiler check:

```text
mix compile --force
```

Result: exit status 0; `Compiling 1 file (.erl)`, `Compiling 63 files (.ex)`, and `Generated symphony_elixir app`.

Diff check:

```text
git diff --check
```

Result: exit status 0 with no whitespace errors. Git emitted only the checkout's existing LF-to-CRLF conversion notices.

### Self-review

- Acquisition acceptance is based on fresh post-acquisition canonical containment plus two OS-backed identity comparisons, not on a token read through the same pre-acquisition pathname.
- Windows replacement is closed across the full lifecycle: post-acquisition the non-share-delete guard handle blocks directory replacement; acquisition-time replacement is detected by the post-acquisition attestation before startup succeeds, and the helper deletes its relative guard before acknowledging graceful retirement.
- Writer publication remains relative-only, immutable, exclusive, synced, and no-clobber. Stop retry behavior is unchanged except that an ambiguous writer is permanently unavailable rather than reusable.
- The helper never accepts an executable or shell command. RuntimeHealth passes a fixed argument vector to a canonical, fixed-layout OTP launcher candidate and fails closed when neither trusted candidate exists.
- Correlation matching is exact, and no protocol failure path returns the old usable writer to GenServer state. The asynchronous helper reader cancels delayed publication on stream EOF, so bounded port retirement also retires the helper's pending work.
- Health instrumentation and presentation interfaces are unchanged; no claim authorization, release, retain, or retry decision depends on the writer outcome.

### Exact portable limitation and concerns

The round-2 POSIX limitation remains: public OTP still has no `openat`/handle-relative child creation and link API or portable mandatory directory lock. After successful attestation, a same-privilege POSIX actor may rename the pinned directory inode after the guard reachability check but before a relative write; the writer capability remains valid at that relocated inode. The new attestation closes the acquisition-time validation gap, and Windows is closed by the open guard handle, but this is not claimed as complete protection against a same-user POSIX namespace relocation after attestation.

All requested focused suites, presenter regressions, formatter/spec/compiler/diff checks are green. Compilation continues to emit only the pre-existing `HttpServer.normalize_host/1` warning and Phoenix LiveView Windows symlink-permission warning. The inherited toolchain/baseline concerns recorded in Fix round 1 remain unchanged.
