# Design 3 causal patch authorization acceptance mapping

Issue: ARO-244. Base: merged `main` at `956dff3f715c6767dc3f6f512bb0e723ae46d268`.

## Ownership boundary

- `PatchAuthorization.authorize/5` is the sole causal authorization owner.
- It consumes Design 2 canonical finding and lineage keys and opaque managed-effect readback.
- It performs no GitHub, Linear, ledger, claim, merge, deployment, or settlement mutation.
- `ReviewMonitor` remains the coordinator and invokes authorization only after a newly acquired claim is bound and effect readback succeeds.

## Acceptance evidence

| Requirement | Evidence |
| --- | --- |
| New causal evidence can grant | `PatchAuthorizationTest`: new causal evidence grants exactly one bounded mutation |
| Same lineage/fingerprint without progress blocks | `PatchAuthorizationTest`: same lineage, root-cause fingerprint, and evidence cannot grant again |
| Missing/malformed/conflicting receipt fails closed | malformed receipt cases and canonical identity validation tests |
| Green pre-mutation evidence cannot grant | pre-mutation regression phase/status tests |
| Exact head, active claim, and generation required | head/claim/generation transition tests |
| Pending/unknown effect reconciles | effect readback transition tests |
| Old-generation readback cannot authorize old writes | old-generation terminal readback test |
| Circuit breaker is a safety stop, not quota | `:safety_stopped` transition test; no slot/round/human approval input exists |
| Repeated bypass escalates | recurrence and architecture escalation test |
| Monitor invokes once per transition | `ReviewConvergenceTest`: autonomous monitor invokes Design 3 once |

## Explicit exclusions

No worker was started, no shared staging credential was used, and no deployment, Production access,
GitHub mutation, Linear mutation, review settlement, merge authorization, or human permission capability
was added. A grant authorizes only one bounded managed mutation intent; technical convergence and human
merge authorization remain separate downstream decisions.
