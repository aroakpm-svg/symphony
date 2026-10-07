# Security dependency candidate — evidence and limits

2026-10-06. Implementation model preference: GPT-6 Sol (high). This is a candidate change in the isolated `codex/security-dependencies-2026-10-06` branch of `aroakpm-svg/symphony`, based on `314189f33344a66800ea17209fcaae1eabb9be4c`. It is not a production deployment receipt or a claim that shared dispatch is enabled.

## Changed files and fixed inputs

- `mix.exs` is byte-identical to the base: SHA256 `96f83ede1ff72bf422a34c7b2939be6c3cdf0abfc951f2d168cfd45b3d83d724`.
- The solver generated `mix.lock` with SHA256 `bda3ff24770d33baeaE942e0c865936f487cdd46a5bc0045b005a7f376a9b5c8` before any review changes. All 14 precise candidates in the social analysis project's 2026-10-06 Symphony security plan resolved. The individual release sources are recorded in that plan and the Hex registry.
- The only extra transitive upgrade kept by the narrowed solver was `thousand_island 1.4.3 → 1.5.0`, required by Bandit 1.12.5. Seven other transitive upgrades from the first solver pass were constrained back to their base versions. The temporary exact constraints were then removed; `mix deps.get` with the original manifest exited 0 without changing the lock.
- The CI workflow pins Hex 2.5.1, and `make all` now calls `make security` before building. The shell wrapper rejects offline, ignore and unsafe registry modes, then checks `mix hex.audit`. Hex 2.5.1 can fall back to cached package records after an online fetch error and still return 0; the wrapper detects that diagnostic and fails. [Hex audit source](https://github.com/hexpm/hex/blob/v2.5.1/lib/mix/tasks/hex.audit.ex), [registry fallback source](https://github.com/hexpm/hex/blob/v2.5.1/lib/hex/registry/server.ex).

## Evidence read back locally

| Check | Observed result | Boundary |
| --- | --- | --- |
| Old baseline `mix hex.audit` | exit 1, baseline 36 advisories | [Raw baseline output](evidence/security-dependencies-2026-10-06/baseline-hex-audit.log) |
| First solver | exit 0; seven unrelated transitives also upgraded | [Raw first pass](evidence/security-dependencies-2026-10-06/solver.log) |
| Narrowed solver | exit 0; only one required extra transitive | [Raw narrow pass](evidence/security-dependencies-2026-10-06/solver-narrow.log) |
| Original manifest + new lock `mix deps.get` | exit 0; all versions unchanged | [Raw output](evidence/security-dependencies-2026-10-06/verify-original-manifest.log) |
| New lock `mix hex.audit` / `make security` | exit 0; no retired or security-advisory package reported | [Raw audit output](evidence/security-dependencies-2026-10-06/candidate-hex-audit.log) |
| Old lock through new shell gate | exit 1; baseline advisories shown | Read-only command run from the original T1-R1 worktree |
| `HEX_OFFLINE=1 make security` | exit 1; wrapper refused offline mode | No registry scan claimed |
| Broken loopback proxy + cached registry | exit 1; Hex printed `using cache instead`; wrapper refused it | Simulated registry outage, no host network setting changed |
| Targeted existing compatibility files | 129 tests, 0 failures | Candidate lock, before adding new tests |
| Bounded package regression file | 11 tests, 0 failures | Loopback HTTP, Decimal, Solid; no oversized attack input |
| Seven-file combined test set | 139 tests, 0 failures | Candidate lock, before the final blank-comparison test |
| Final bounded regression plus capacity/profile routing files | 143 tests, 0 failures | After the final test edit |
| Local WSL `make all` | exit 1 at coverage: 1330 tests, 13 failures, 38 skipped | Ran before the final blank-comparison test. Two ScopeContract 2.5-second timeouts and 11 RuntimeNotifier failures; same failure groups recorded for the original WSL baseline. Format, lint, security and build passed; Dialyzer not reached. This is not a full-gate pass. |
| Separate local `make dialyzer` | exit 0; total errors 0, skipped 0 | Ran after the failed `make all` to verify this stage independently |

The [36-item baseline advisory reconciliation](evidence/security-dependencies-2026-10-06/advisory-reconciliation.json) maps each original ID to its candidate package version. Each was absent from the candidate audit; this does not prove that no future advisory will be published or that the current application exposure is safe.

The accepted T1-R1 Ubuntu CI at the unchanged code baseline was not evidence for this candidate. The initial candidate commit `f6c51a9` later passed [exact-commit Ubuntu CI](https://github.com/aroakpm-svg/symphony/actions/runs/37431380281), but the follow-up increment below needs its own fixed-SHA CI. The baseline WSL report had the same failure groups; that comparison does not waive the current local failure. Independent review and human acceptance remain separate gates.

## 2026-10-07 review-remediation increment

The first fixed-range review found missing application-boundary and process-containment proof. The follow-up adds three loopback tests that send the existing GitHub authority adapter through real Req transport: malformed JSON and compressed JSON stop at the first authority request with a controlled error; a redirect does not reach a second endpoint. The latter test was mutation-checked by temporarily removing `redirect: false`, observing a failure, and restoring the unchanged production code. No `lib/` changes remain. Workflow tests now cover small decimal arithmetic and strict unknown-filter rejection through `PromptBuilder`; a temporary `strict_filters: false` mutation caused the latter test to fail as intended. An independent BEAM worker test sets `max_heap_size` to 1,000,000 words with `kill: true`, uses a one-second work timeout and a bounded stop-confirmation wait, and proves a synthetic busy loop terminates. Its first version failed on unconfirmed termination; the monitored version passed. These are bounded compatibility tests, not a general resource sandbox.

The seven-file compatibility command returned **147 tests, 0 failures**. The core/profile/dispatch command returned **134 tests, 0 failures**; the pending-cleanup capacity cases remain in that suite. A fresh local WSL `make all` returned nonzero at coverage: **1338 tests, 11 failures, 38 skipped**. All 11 failures were in `RuntimeNotifierTest`; this result is retained in the social-analysis project's `docs/automation/evidence/symphony-security-local-followup-2026-10-07.log` (SHA256 `a63250a1424871be45f17836b273ee9491a7d69702d26e1bf45af13a95c82d8e`). A separate `make dialyzer` returned 0 errors, 0 skipped. None of these local results is a full-gate pass. A new-commit Ubuntu CI receipt is not yet available at the time of this increment.

Hex 2.5.1's default Hex package registry is `https://repo.hex.pm` ([fixed-version source](https://github.com/hexpm/hex/blob/v2.5.1/lib/hex/repo.ex)); `hex.audit` prefetches package records and a registry fetch failure emits a diagnostic even if an old cached record exists ([fixed-version registry source](https://github.com/hexpm/hex/blob/v2.5.1/lib/hex/registry/server.ex)). On 2026-10-07 UTC, an isolated `HEX_HOME` with no persisted files was verified using `mix hex.config cache_home`. With a broken loopback proxy, `make security` returned native exit 1 and printed `Failed to fetch record ...` followed by the wrapper's `security audit could not verify fresh, unignored registry findings`. Without the broken proxy, a fresh run between **04:05:31 and 04:05:47 UTC** returned native exit 0 and `No retired or security advisory packages found`. The repository default, query window and clean isolated cache are recorded; the registry's own last-publication timestamp was not exposed by Hex and is not claimed. A future advisory or a changed Hex diagnostic requires a new check, not reliance on this receipt.

| Original in-repo evidence file | SHA256 |
| --- | --- |
| `baseline-hex-audit.log` | `112554840883813fa67ac27cca4f39068c555d23a8028831e53144d17b213c2d` |
| `candidate-hex-audit.log` | `c0b302dc6ea87524276501e687c53e4ab4f7996a55426201bfceee62a43fe620` |
| `solver.log` | `ef661cd5b782dbf7bd08adc4090123d6c008e9b1294bd5e773cc65a640346c3` |
| `solver-narrow.log` | `6b0dc0f46d9e80f7b7bd7c47e64e2a4763ddff73d2fbe066af470932343caa48` |
| `verify-original-manifest.log` | `2d4dd01d1dfd454bc5b9eb0fce5f8e2cb8318b6c17c7a8c018f635b38031c4b1` |

The final commit, tree and binary-diff digest must be recorded in the social-analysis project's external immutable receipt after committing this file; embedding a digest of this file's own commit diff here would be self-referential. The draft PR remains unmerged and is not authorization to deploy or enable dispatch.

## Test and operational limits

- Req 0.6.3 disables decompression by default but does not impose a general decompressed-body size cap when explicitly enabled. The new tests cover small compressed and malformed responses, not a compression-bomb workload.
- Solid 1.3.4 fixes bounded range handling; it has no global rendering-loop cap. The test uses a small range with explicit limit.
- Decimal 3.1.1 defaults to input/output bounds but does not turn arbitrary Decimal structs and every encoder protocol into a sandbox.
- No production credentials, Meta or product data were accessed. PostgreSQL, Windows ACL/broker and real deployed HTTP/WebSocket exposure were not tested in this change.
- No Linear issue, merge, deployment or Symphony runtime service status is asserted by this document. The follow-up remains on an unmerged draft PR.

## Review and continuation

The next quality gate for the follow-up increment is an exact new commit tested by Ubuntu CI, followed by a fixed-range review that checks the lock, all old advisories, the audit outage behavior, normal API flows, the legacy retry capacity test and any skip changes. The local WSL failure stays visible in that handoff. If the code or lock changes after review, fix the SHA and rerun affected checks.
