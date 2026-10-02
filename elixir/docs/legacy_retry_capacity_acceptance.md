# Legacy retry capacity acceptance

Date: 2026-10-02

## Fixed scope

- Base commit: `8066b60d1b2db390566925423619c04f8cf8319b`
- Base tree: `fe7c765fd6305260e7b8a9098faea029b22755e4`
- Implementation commit: `95e90ef3461de8d10b8115f39736af92a0df4fb2`
- Implementation tree: `27516802fbae9ec8f6d3b31d074ff907ce2d6da2`
- Worktree: `/home/aroak-han/codex-projects/.worktrees/symphony-t1-r1`
- Branch: `codex/t1-r1-legacy-retry-capacity`
- Toolchain: Erlang/OTP 28.5, Elixir 1.19.5, mise 2026.7.17
- Secret-bearing environment variables were unset for every test command.
- No live E2E, service, scheduler, worker, external write, push, PR, merge, or deploy was performed.

## Root cause and fix

The legacy active-retry path called `dispatch_slots_available?/2`. Global capacity already counted `active_workers(state)`, which merges `running` and `pending_cleanup`, but its per-state capacity check counted only `state.running`. A worker awaiting cleanup could therefore free a legacy retry state slot too early.

The fix passes `active_workers(state)` to `state_slots_available?/2`. Existing map-merge behavior continues to deduplicate the same issue ID when it appears in both maps.

## Strict RED to GREEN evidence

The regression matrix covers same-state pending cleanup, different-state pending cleanup, cleanup completion, global saturation, duplicate issue IDs across maps, and ordinary running-worker state saturation.

- RED: `mise exec -- mix test test/symphony_elixir/core_test.exs:1999 --seed 350817`
  - Version: result `078e3a767e9ecfe0396524389a6dbf3b1635ba15` plus the exact one-line inverse patch saved as `docs/evidence/legacy-retry-capacity/2026-10-02/red-temporary-revert.patch`.
  - Exit code: `1`; result: `1 test, 1 failure (71 excluded)`.
  - The `same state pending cleanup` case expected `false` and received `true`.
  - Complete output: `docs/evidence/legacy-retry-capacity/2026-10-02/red-temporary-revert.log`.
- GREEN: the same command after the one-line production change.
  - Version: exact result `078e3a767e9ecfe0396524389a6dbf3b1635ba15`.
  - Exit code: `0`; result: `1 test, 0 failures (71 excluded)`.
  - Complete output: `docs/evidence/legacy-retry-capacity/2026-10-02/green-result.log`.
- Retained-owner regression: `mise exec -- mix test test/symphony_elixir/multi_project_dispatch_test.exs:1196 --seed 350817`
  - Exit code: `0`; result: `1 test, 0 failures (49 excluded)`.
  - Complete output: `docs/evidence/legacy-retry-capacity/2026-10-02/retained-owner.log`.
- Targeted suite: `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/multi_project_dispatch_test.exs test/symphony_elixir/project_profiles_test.exs --seed 350817`
  - Exit code: `0`; result: `132 tests, 0 failures`.
  - Complete output: `docs/evidence/legacy-retry-capacity/2026-10-02/targeted.log`.

## Quality checks

- `mise exec -- mix format --check-formatted`: exit `0`, PASS; `docs/evidence/legacy-retry-capacity/2026-10-02/format.log`.
- `mise exec -- mix specs.check`: exit `0`, PASS; `docs/evidence/legacy-retry-capacity/2026-10-02/specs.log`.
- `mise exec -- mix lint`: exit `0`, PASS; `docs/evidence/legacy-retry-capacity/2026-10-02/lint.log`.
- `mise exec -- make dialyzer`: exit `0`, PASS; 0 errors, 0 skipped, 0 unnecessary skips; `docs/evidence/legacy-retry-capacity/2026-10-02/dialyzer.log`.
- `mise exec -- make all`: BLOCKED at the coverage stage by eleven common RuntimeNotifier failures plus load-sensitive ScopeContract timeouts also present on the untouched fixed base.
  - Fresh result rerun: exit `1`; `1320 tests, 12 failures, 38 skipped` with the same eleven RuntimeNotifier failures and one ScopeContract timeout.
  - Fresh fixed-base rerun: exit `1`; `1319 tests, 13 failures, 38 skipped` with the same eleven RuntimeNotifier failures and two ScopeContract timeouts.
  - Complete outputs: `docs/evidence/legacy-retry-capacity/2026-10-02/result-make-all.log` and `docs/evidence/legacy-retry-capacity/2026-10-02/base-make-all.log`.
  - Reducing only local coverage concurrency to one removes both ScopeContract timeouts while retaining all eleven RuntimeNotifier failures; see `result-cover-max-cases-1.log`.
  - The fixed-base canonical GitHub Actions run passed `make all` with 1,319 tests, zero failures, and Dialyzer zero errors; see `base-github-ci.log`, `base-github-ci.json`, and <https://github.com/aroakpm-svg/symphony/actions/runs/35984520643>.
  - Because coverage exits non-zero, `make all` does not reach Dialyzer; Dialyzer was run separately as recorded above.

Every complete output, patch, command, exit code, and version binding is indexed by `docs/evidence/legacy-retry-capacity/2026-10-02/commands.json`. File hashes are in `docs/evidence/legacy-retry-capacity/2026-10-02/SHA256SUMS`; that manifest's SHA-256 is `990aedc7ba3e9ab91e930856f45d101b30176e8141cc37c3a7553041b471bd39`.

## Remaining items

- Independent review must confirm the fixed scope and durable acceptance evidence.
- The WSL environment lacks Linux `pwsh`, so PowerShell-only RuntimeNotifier fixtures execute through the `sh` fallback and fail. The ScopeContract performance tests also exceed their fixed budget under this WSL's full-suite load. These are outside the fixed T1-R1 files; the evidence package records the root-cause tests and proposed separation.
- An exact-result canonical GitHub Actions run remains unavailable without publishing a ref, which this task forbids.
- Existing dependency advisories remain outside T1-R1 scope.
- The full `make all` gate must not be represented as passing.
