# T1-R1 durable evidence

This directory contains the version-bound, secret-safe rerun receipts for the T1-R1 legacy retry capacity increment.

## Versions and safety

- Fixed base: `8066b60d1b2db390566925423619c04f8cf8319b`.
- Reviewed result: `078e3a767e9ecfe0396524389a6dbf3b1635ba15`.
- Reviewed result tree: `6776395ea983e83ee76e8a6e0d0ef404930d6d0b`.
- The RED state is the reviewed result plus the exact one-line inverse patch in `red-temporary-revert.patch.gz`.
- Every Elixir command removed `SYMPHONY_RUN_LIVE_E2E`, `LINEAR_API_KEY`, `GH_TOKEN`, `GITHUB_TOKEN`, `OPENAI_API_KEY`, `SUPABASE_DB_URL`, and `DATABASE_URL` at the process boundary.
- No environment value was printed. A credential-pattern scan of the evidence files returned zero matches.
- No live E2E, worker, service, scheduler, external write, push, PR, merge, or deploy was performed.

`commands.json` records each command, version binding, exit code, and complete output path. `SHA256SUMS` binds every raw receipt and patch; its SHA-256 is `5095f349988d98410193bf584fc387c0a2775cc38753fad6bc4442d59309f9e5`.

## RED to GREEN

- `red-temporary-revert.log.gz`: exit 1; one test, one assertion failure for `same state pending cleanup`.
- `green-result.log.gz`: exit 0; the identical test command passes on the reviewed result.
- `retained-owner.log.gz`: exit 0.
- `targeted.log.gz`: exit 0; 132 tests, zero failures.

## Full-gate diagnosis

The capacity change does not modify any failing module or test; see `failure-files-diff.txt`.

### RuntimeNotifier failures

Single root-cause hypothesis: on this WSL runtime, Linux `pwsh` is absent. `RuntimeNotifier.unix_command_shell/0` therefore selects `/usr/bin/sh`, while the eleven failing test fixtures are PowerShell command strings. The minimal line-12 reproduction failed three times out of three with `{:error, :notification_failed}`. The fixed-base GitHub Actions run used Ubuntu 24.04 and passed all 1,319 tests; its complete log and metadata are preserved as `base-github-ci.log.gz` and `base-github-ci.json`.

This is an environment/test-fixture portability blocker, not a regression in the T1-R1 capacity files. Fixing it would require either an exact-result run on the existing GitHub Actions environment or a separately authorized change to `test/symphony_elixir/runtime_notifier_test.exs`. Neither belongs in the fixed three-file T1-R1 implementation.

### ScopeContract timeouts

Single root-cause hypothesis: the fixed 2.5-second performance tests exceed their budget under the current WSL scheduler/load, not because of the T1-R1 diff.

- The two tests pass together under coverage in 1.3 seconds when isolated; the partial command exits 1 only because it cannot meet the repository-wide 100% coverage threshold.
- The result's full coverage run at `max_cases=1` has no ScopeContract timeout and retains the same eleven RuntimeNotifier failures; see `result-cover-max-cases-1.log.gz`.
- The local default is `max_cases=40`; the persisted result run had one ScopeContract timeout and the fixed-base run had two.
- The existing fixed-base GitHub Actions run used `max_cases=8` and passed. A local result run at eight still had one ScopeContract timeout, showing this WSL remains slower than that runner.

No timeout, assertion, coverage threshold, or skip was changed. If the exact result also fails on the canonical runner, any performance-test or implementation change must be a separate package, beginning with `test/symphony_elixir/scope_contract_test.exs` and the measured `ScopeContract` call path rather than weakening the budget.

## Gate status

- Targeted tests: PASS.
- Format: PASS.
- Specs: PASS.
- Lint: PASS.
- Dialyzer: PASS.
- Full `make all` on this WSL: BLOCKED at coverage.
- Fixed-base canonical GitHub Actions `make-all`: PASS.
- Exact-result canonical GitHub Actions `make-all`: NOT RUN because push/workflow publication is outside this task.

The full gate remains blocked; the baseline comparison proves no new failure class, but does not convert the result into a pass.
