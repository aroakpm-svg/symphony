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
  - Result before the production change: `1 test, 1 failure (71 excluded)`.
  - The `same state pending cleanup` case expected `false` and received `true`.
- GREEN: the same command after the one-line production change.
  - Result: `1 test, 0 failures (71 excluded)`.
- Retained-owner regression: `mise exec -- mix test test/symphony_elixir/multi_project_dispatch_test.exs:1196 --seed 350817`
  - Result: `1 test, 0 failures (49 excluded)`.
- Targeted suite: `mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/multi_project_dispatch_test.exs test/symphony_elixir/project_profiles_test.exs --seed 350817`
  - Result: `132 tests, 0 failures`.

## Quality checks

- `mise exec -- mix format --check-formatted`: PASS.
- `mise exec -- mix specs.check`: PASS; all public functions have a spec or exemption.
- `mise exec -- mix lint`: PASS; no issues.
- `mise exec -- make dialyzer`: PASS; 0 errors, 0 skipped, 0 unnecessary skips.
  - Log SHA-256: `f4ee4a437557d089e363765d8b35d6bd2d582d65f9d4e553103588fb9d59bbd3`.
- `mise exec -- make all`: BLOCKED at the coverage stage by 13 failures also reproduced on the untouched fixed base.
  - Candidate: `1320 tests, 13 failures, 38 skipped`.
  - Fixed base: `1319 tests, 13 failures, 38 skipped`.
  - Both runs failed on the same two `ScopeContractTest` large-input timeouts and the same eleven `RuntimeNotifierTest` command-execution cases.
  - Candidate log SHA-256: `e3ab948464cec9a07ad4c59295ba759635cca629d14ae4f81abdc98e63551620`.
  - Fixed-base log SHA-256: `4a62e75da6cf6b69f53b0e365652aadf7e2da833f3bac93ee74300f2fef01fc7`.
  - Because coverage exits non-zero, `make all` does not reach Dialyzer; Dialyzer was run separately as recorded above.

## Remaining items

- Independent review must confirm the fixed scope and acceptance evidence.
- The pre-existing full-suite failures and dependency advisories remain outside T1-R1 scope.
- The full `make all` gate must not be represented as passing.
