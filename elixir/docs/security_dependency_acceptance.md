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

The previous accepted T1-R1 Ubuntu CI at the unchanged code baseline passed. It is not evidence that this candidate passes Ubuntu CI. The baseline WSL report had the same 13 failure classes; that comparison supports an environment explanation, but does not waive the current failure. New SHA CI, independent review and human acceptance remain separate gates.

## Test and operational limits

- Req 0.6.3 disables decompression by default but does not impose a general decompressed-body size cap when explicitly enabled. The new tests cover small compressed and malformed responses, not a compression-bomb workload.
- Solid 1.3.4 fixes bounded range handling; it has no global rendering-loop cap. The test uses a small range with explicit limit.
- Decimal 3.1.1 defaults to input/output bounds but does not turn arbitrary Decimal structs and every encoder protocol into a sandbox.
- No production credentials, Meta or product data were accessed. PostgreSQL, Windows ACL/broker and real deployed HTTP/WebSocket exposure were not tested in this change.
- No Linear issue, PR, merge, deployment or Symphony runtime service status is asserted by this document.

## Review and continuation

The next quality gate is an exact candidate commit tested by Ubuntu CI, followed by a fixed-range review that checks the lock, all old advisories, the audit outage behavior, normal API flows, the legacy retry capacity test and any skip changes. The local WSL failure stays visible in that handoff. If the code or lock changes after review, fix the SHA and rerun affected checks.
