# Bugfix Requirements Document

## Introduction

Four root-cause defects in the shared EqualFi accounting libraries break `userCount` tracking and pool membership consistency across the protocol substrate. Finding 6 (Libraries Phase 3, [83]): `_creditPrincipal` in both `EqualLendDirectLifecycleFacet` and `EqualLendDirectRollingLifecycleFacet` increments `userCount` when `principalBefore == 0` but never checks `maxUserCount` — default settlements and capital restoration via `restoreLenderCapital` can push `userCount` past the configured cap. Finding 7 (Libraries Phase 3, [80]): pool membership (`joined` flag in `LibPoolMembership`) and `userCount` are tracked independently through different code paths — this decoupling is acceptable by design, but it exposes stale-count bugs whenever principal transitions to zero without a matching `userCount` decrement. Lead (Libraries Phase 2): `departLenderCapital` decrements `userCount` only when `principalBefore == amount` (full withdrawal), while `restoreLenderCapital` increments unconditionally when `principalBefore == 0` — asymmetric conditions allow count drift. Options remediation plan: maintenance settlement via `LibFeeIndex.settle` can zero `userPrincipal` without decrementing `pool.userCount`, and later principal credit paths then increment `userCount` again for the same logical user, inflating the count.

These library-level defects are the root cause of downstream `userCount` inflation in Options (maintenance/settle interaction), EqualLend (`_creditPrincipal` paths that bypass `maxUserCount`), and any pool that uses `maxUserCount` as a capacity limiter. Fixing the shared substrate first prevents downstream product specs from baking in compensating logic.

Canonical Track: Track B. ACI / Encumbrance / Debt Tracker Consistency (userCount/membership portion)
Phase: Phase 1. Shared Accounting Substrate

Source reports:
- `assets/findings/EdenFi-libraries-phase3-pashov-ai-audit-report-20260406-193000.md` (findings 6, 7)
- `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md` (lead: `departLenderCapital` asymmetric `userCount` tracking)
- `assets/remediation/Options-findings-3-8-remediation-plan.md` (`userCount` inflation via maintenance fee interaction)
Remediation plan: `assets/remediation/EqualFi-unified-remediation-plan.md` (Track B)

Downstream reports affected:
- `assets/findings/EdenFi-options-pashov-ai-audit-report-20260405-033500.md` (finding 8 — deposit cap blocks option exercise, depends on correct `userCount`)
- `assets/remediation/Options-findings-3-8-remediation-plan.md` (`userCount` inflation via maintenance/settle interaction)
- Any pool using `maxUserCount` as a capacity limiter across EqualLend, EqualIndex, Options

Dependencies:
- Track A (Native Asset Tracking) should land first or concurrently
- `equalfi-aci-encumbrance-consistency` should land first or concurrently (shared Track B substrate)
- This spec is a prerequisite for downstream product specs that depend on correct `userCount` behavior

EqualFi policy choice for this spec:
- All principal-from-zero credit paths in this shared substrate SHALL enforce `maxUserCount`
- No implicit settlement/restoration carveout exists in this spec; any future carveout must be explicit in a downstream product spec

## Bug Analysis

### Current Behavior (Defect)

**Finding 6 — `maxUserCount` Bypass via Default Settlement Credit Paths**

1.1 WHEN `_creditPrincipal` in `EqualLendDirectLifecycleFacet` is called during default settlement with `principalBefore == 0` for the credited position THEN the system increments `pool.userCount` without checking `pool.poolConfig.maxUserCount`, allowing the pool to exceed its configured user cap

1.2 WHEN `_creditPrincipal` in `EqualLendDirectRollingLifecycleFacet` is called during rolling lifecycle settlement with `principalBefore == 0` for the credited position THEN the system increments `pool.userCount` without checking `pool.poolConfig.maxUserCount`, allowing the pool to exceed its configured user cap

1.3 WHEN `restoreLenderCapital` in `LibEqualLendDirectAccounting` is called during capital restoration with `principalBefore == 0` for the lender position THEN the system increments `pool.userCount` without checking `pool.poolConfig.maxUserCount`, allowing the pool to exceed its configured user cap

**Finding 7 — Pool Membership / `userCount` Decoupling**

1.4 WHEN `_ensurePoolMembership` sets `joined = true` for a position that has no principal in the pool THEN the system creates a ghost member — the position is marked as a pool member but is not reflected in `userCount`, and `maxUserCount` does not account for this membership

1.5 WHEN `_leavePool` deletes the `joined` flag for a position THEN the system does not touch `userCount`, so a position that was counted (had principal) but leaves the pool can leave `userCount` stale if the principal-to-zero transition was not properly handled

**Lead — `departLenderCapital` Asymmetric `userCount` Tracking**

1.6 WHEN `departLenderCapital` is called and `principalBefore == amount` (full departure) THEN the system decrements `userCount`, but WHEN `restoreLenderCapital` is called and `principalBefore == 0` THEN the system increments `userCount` unconditionally — the asymmetric conditions mean that partial departure followed by full restoration can inflate `userCount` if intermediate maintenance settlement zeroed the principal

**Options — `userCount` Inflation via Maintenance Fee Interaction**

1.7 WHEN `LibFeeIndex.settle` is called and maintenance fees reduce `userPrincipal` to zero THEN the system does not decrement `pool.userCount`, leaving a stale count for a user with zero principal

1.8 WHEN a subsequent principal credit path (e.g., `restoreLenderCapital`, `_creditPrincipal`, or Options `_increasePrincipal`) is called for the same position after maintenance zeroed the principal THEN the system increments `userCount` again because `principalBefore == 0`, double-counting the same logical user and inflating `userCount`

### Expected Behavior (Correct)

**Finding 6 — Enforce `maxUserCount` on all principal credit paths**

2.1 WHEN `_creditPrincipal` in `EqualLendDirectLifecycleFacet` is called with `principalBefore == 0` and `pool.poolConfig.maxUserCount > 0` and `pool.userCount >= pool.poolConfig.maxUserCount` THEN the system SHALL revert with `MaxUserCountExceeded`, preventing the pool from exceeding its configured user cap through default settlement

2.2 WHEN `_creditPrincipal` in `EqualLendDirectRollingLifecycleFacet` is called with `principalBefore == 0` and `pool.poolConfig.maxUserCount > 0` and `pool.userCount >= pool.poolConfig.maxUserCount` THEN the system SHALL revert with `MaxUserCountExceeded`, preventing the pool from exceeding its configured user cap through rolling lifecycle settlement

2.3 WHEN `restoreLenderCapital` in `LibEqualLendDirectAccounting` is called with `principalBefore == 0` and `pool.poolConfig.maxUserCount > 0` and `pool.userCount >= pool.poolConfig.maxUserCount` THEN the system SHALL revert with `MaxUserCountExceeded`, preventing the pool from exceeding its configured user cap through capital restoration

**Finding 7 — Reconcile membership and `userCount`**

2.4 WHEN `_ensurePoolMembership` sets `joined = true` for a new member THEN the system SHALL CONTINUE TO treat membership as separate from capacity accounting — `joined` alone does not consume `maxUserCount`, and `userCount` remains governed by nonzero-principal transitions

2.5 WHEN a position's principal transitions to zero through any path (withdrawal, maintenance settlement, departure) THEN the system SHALL ensure `userCount` is decremented exactly once for that transition, regardless of which code path caused the zero-principal state

**Lead — Symmetric `userCount` tracking in depart/restore**

2.6 WHEN `departLenderCapital` reduces principal to zero THEN the system SHALL decrement `userCount` exactly once, and WHEN `restoreLenderCapital` increases principal from zero THEN the system SHALL increment `userCount` exactly once and enforce `maxUserCount`, maintaining symmetric tracking

**Options — Maintenance-driven `userCount` reconciliation**

2.7 WHEN `LibFeeIndex.settle` reduces `userPrincipal` to zero via maintenance fees THEN the system SHALL decrement `pool.userCount`, preventing stale counts for zero-principal positions

2.8 WHEN a subsequent principal credit path is called for a position whose principal was zeroed by maintenance THEN the system SHALL increment `userCount` only once (because the maintenance path already decremented it), and SHALL enforce `maxUserCount` on the re-entry, preventing double-counting

### Unchanged Behavior (Regression Prevention)

**Normal deposit/withdraw `userCount` tracking**

3.1 WHEN a user deposits into a pool for the first time (voluntary deposit via `PositionManagementFacet`) THEN the system SHALL CONTINUE TO increment `userCount` and enforce `maxUserCount` as it does today

3.2 WHEN a user withdraws all principal from a pool (voluntary withdrawal) THEN the system SHALL CONTINUE TO decrement `userCount` exactly once

3.3 WHEN a user makes a partial withdrawal (principal remains nonzero) THEN the system SHALL CONTINUE TO leave `userCount` unchanged

**Pool membership lifecycle**

3.4 WHEN `_ensurePoolMembership` is called for a position that is already a member THEN the system SHALL CONTINUE TO return `true` without modifying any state

3.5 WHEN `_leavePool` is called for a position that has cleared all obligations THEN the system SHALL CONTINUE TO delete the `joined` flag

3.6 WHEN `canClearMembership` is called THEN the system SHALL CONTINUE TO check principal, same-asset debt, active fixed loans, rolling loans, and encumbrance before allowing membership clearance

**EqualLend Direct lending lifecycle**

3.7 WHEN `departLenderCapital` is called for a partial departure (principal remains nonzero) THEN the system SHALL CONTINUE TO leave `userCount` unchanged

3.8 WHEN `restoreLenderCapital` is called for a position that already has nonzero principal THEN the system SHALL CONTINUE TO leave `userCount` unchanged (no double-increment)

3.9 WHEN `settlePrincipal` is called and `restoreLenderCapital` credits principal to a lender who already has nonzero principal in that pool THEN the system SHALL CONTINUE TO leave `userCount` unchanged

**Options exercise settlement**

3.10 WHEN Options `_increasePrincipal` credits principal to a maker position that already has nonzero principal THEN the system SHALL CONTINUE TO leave `userCount` unchanged

**EqualScale recovery**

3.11 WHEN `recoverBorrowerCollateral` reduces borrower principal to zero THEN the system SHALL CONTINUE TO decrement `userCount` exactly once

**Fee index settlement**

3.12 WHEN `LibFeeIndex.settle` is called and maintenance fees do NOT reduce principal to zero THEN the system SHALL CONTINUE TO leave `userCount` unchanged

3.13 WHEN `LibFeeIndex.settle` is called and the user has zero principal before settlement THEN the system SHALL CONTINUE TO skip maintenance fee computation and leave `userCount` unchanged
