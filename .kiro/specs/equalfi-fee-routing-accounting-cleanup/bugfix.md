# Bugfix Requirements Document

## Introduction

Four root-cause defects across the EqualFi shared library layer break maintenance fee fairness, curve fee-split consistency, treasury transfer accounting hardening, and EDEN reward reserve integrity. Finding 1 (Libraries Phase 1 [95]): `LibMaintenance._accrue` correctly computes maintenance fees on `chargeableTvl` (excluding encumbered capital), but `_applyMaintenanceToIndex` divides the index delta by full `totalDeposits` — when `LibFeeIndex.settle` applies this delta to full principal instead of chargeable principal, index-encumbered users are overcharged and non-encumbered users are undercharged. Finding 2 (Libraries Phase 1 [93]): `LibEqualXCurveEngine._applyQuoteSide` hardcodes `makerFee = fee * 7000 / 10_000` instead of using the same canonical EqualX maker-share source that the AMM fee-split path should consume, leaving curve routing on a curve-only constant. Finding 3 (Libraries Phase 1 [82]): `LibFeeRouter._transferTreasury` relies on nominal transfer amounts rather than explicitly anchoring accounting to the actual amount debited from the pool balance, leaving the FoT/exotic-token policy ambiguous at the substrate layer. Finding 4 (Libraries Phase 2 [88]): `LibEdenRewardsEngine._previewAccrual` deducts reserve for tentative reward accrual before confirming how much reward actually entered `globalRewardIndex`; when index math truncates, reserve is consumed without creating claimable rewards, and there is no remainder tracking to recover the lost liability.

These four library-level defects are the shared accounting substrate fixes for Track C Phase 1. The broader EDEN reward-backing redesign (per-program isolation, rebasing support, fail-closed claims) belongs in a separate Phase 3 spec.

Canonical Track: Track C. Fee Routing, Backing Isolation, and Exotic Token Policy
Phase: Phase 1. Shared Accounting Substrate

Source reports:
- `assets/findings/EdenFi-libraries-phase1-pashov-ai-audit-report-20260406-150000.md` (findings 1, 2, 7)
- `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md` (finding 4)

Remediation plan: `assets/remediation/EqualFi-unified-remediation-plan.md` (Track C)

Downstream reports affected:
- EqualX curve fee-backing and canonical fee-split consistency concerns
- EqualIndex fee routing and tracked-balance concerns
- EDEN reward gross/net mismatch
- Options FoT payment policy questions

Dependencies:
- Track A (Native Asset Tracking) should land first or concurrently
- Track B (ACI/Encumbrance) should land first or concurrently
- This spec is a prerequisite for downstream product specs and the Phase 3 EDEN redesign

Non-goals:
- EDEN per-program backing isolation (Phase 3)
- EDEN rebasing reward token support (Phase 3)
- EDEN fail-closed claim redesign (Phase 3)
- EDEN target-program array cleanup (Phase 3)
- EDEN manager rotation (Phase 3)

## Bug Analysis

### Current Behavior (Defect)

**Finding 1 — Maintenance fee charged to encumbered users who should be exempt**

1.1 WHEN `LibMaintenance._accrue` computes maintenance fee on `chargeableTvl` (totalDeposits minus encumbered capital) and `_applyMaintenanceToIndex` divides the index delta by full `totalDeposits` instead of `chargeableTvl` THEN the system distributes the maintenance fee across ALL user principals including encumbered users, causing encumbered users to pay maintenance they should be exempt from

1.2 WHEN `LibFeeIndex.settle` applies the maintenance index delta to a user's full principal instead of only the user's chargeable principal (`principal - indexEncumbered`) THEN the system charges maintenance on capital that was excluded from `chargeableTvl`, resulting in over-charging for index-encumbered positions and under-charging for free capital

1.3 WHEN the pool has significant encumbered capital (e.g., 50% of totalDeposits) THEN the system under-charges non-encumbered users (they pay only their share of the diluted delta) and over-charges encumbered users (they pay a share they should be exempt from), creating a cross-subsidy from encumbered to non-encumbered depositors

**Finding 2 — Curve engine hardcodes a curve-local 70/30 fee split**

1.4 WHEN `LibEqualXCurveEngine._applyQuoteSide` executes a curve swap THEN the system computes `makerFee = fee * 7000 / 10_000` using a hardcoded 70/30 split instead of using the configurable `makerBps` parameter from `LibEqualXSwapMath.splitFeeWithRouter`

1.5 WHEN the canonical EqualX maker/protocol fee split ratio changes (e.g., to 50/50 or 60/40) THEN the system continues to use 70/30 for curve markets while other EqualX paths use the updated ratio, creating an incentive misalignment where makers capture up to 40% more fee share via curves vs swaps

1.6 WHEN `previewCurveQuote` is called to preview a curve swap THEN the system does not include the fee split in the preview, so quoted fees may diverge from actual execution when the hardcoded split differs from the configured split

**Finding 3 — `_transferTreasury` fee-on-transfer accounting drift**

1.7 WHEN `LibFeeRouter._transferTreasury` transfers treasury fees for an exotic token THEN the system relies on nominal `amount` rather than explicitly measuring the pool-side balance delta, leaving the sender-side accounting policy implicit and easy to misapply in future treasury-routing variants

1.8 WHEN treasury transfer helpers are duplicated or extended without an explicit "debit by pool balance delta" rule THEN future routing paths can drift `trackedBalance` away from actual pool backing for exotic tokens, creating inconsistent treasury accounting across the substrate

**Finding 4 — Reward engine deducts reserve before indexed liability is known**

1.9 WHEN `LibEdenRewardsEngine._previewAccrual` accrues rewards THEN the system computes a tentative `allocatedGross` / `allocatedNet` pair and deducts reserve immediately, before confirming how much net reward actually enters `globalRewardIndex`, so reserve can be consumed for reward value that never becomes claimable

1.10 WHEN users later claim rewards via `grossUpNetAmount(accruedRewards)` THEN the system pays gross tokens for the net rewards that actually entered the index, but the earlier reserve deduction may have been based on a larger tentative allocation than the amount that was truly indexed

1.11 WHEN `_previewAccrual` computes a reward index delta that truncates to zero due to `Math.mulDiv(allocatedNet, REWARD_INDEX_SCALE, eligibleSupply)` flooring THEN the system still deducts `allocatedGross` from `fundedReserve` but produces zero claimable rewards for users, permanently destroying reserve value with no remainder tracking (unlike `LibFeeIndex` which carries forward remainders)

### Expected Behavior (Correct)

**Finding 1 — Maintenance index delta divided by chargeableTvl, and applied only to chargeable principal**

2.1 WHEN `LibMaintenance._applyMaintenanceToIndex` computes the maintenance index delta THEN the system SHALL divide the scaled fee amount by `chargeableTvl` (totalDeposits minus encumbered capital) instead of `totalDeposits`, so that the delta correctly represents the per-unit fee for non-encumbered depositors only

2.2 WHEN `LibFeeIndex.settle` applies the maintenance index delta to a user's principal THEN the system SHALL apply the deduction only to the user's chargeable principal (`principal - indexEncumbered`, floored at zero), ensuring partially or fully index-encumbered users are charged only on non-encumbered capital

2.3 WHEN the pool has significant encumbered capital THEN the system SHALL charge the full maintenance fee only to non-encumbered depositors, with no cross-subsidy from encumbered positions

**Finding 2 — Curve engine uses the same canonical EqualX maker-share source as other EqualX paths**

2.4 WHEN `LibEqualXCurveEngine._applyQuoteSide` executes a curve swap THEN the system SHALL compute the maker/protocol fee split using `LibEqualXSwapMath.splitFeeWithRouter(fee, makerBps)` with the same canonical EqualX maker-share source used by the AMM execution and preview paths, instead of the curve-local hardcoded `fee * 7000 / 10_000`

2.5 WHEN the canonical EqualX maker/protocol fee split changes THEN the system SHALL apply the updated ratio to both AMM swaps and curve markets uniformly, and route only the returned `protocolFee` leg through `routeSamePool`

**Finding 3 — Treasury transfer accounting is defined by pool-side balance delta**

2.6 WHEN `LibFeeRouter._transferTreasury` transfers treasury fees THEN the system SHALL debit `trackedBalance` according to the actual amount that left the pool balance (sender-side balance delta), not according to a loosely described treasury-side receive amount

2.7 WHEN multiple treasury transfer helpers exist THEN the system SHALL use the same pool-balance-delta rule in every path, preventing treasury-routing inconsistencies for exotic tokens

**Finding 4 — Reward engine debits reserve only for rewards actually indexed, and carries forward truncation remainder**

2.8 WHEN `LibEdenRewardsEngine._previewAccrual` accrues rewards THEN the system SHALL deduct reserve only for the gross backing associated with the net reward amount that actually entered `globalRewardIndex` in that accrual step, rather than for a larger tentative pre-round allocation

2.9 WHEN the reward index delta truncates to zero due to small `allocatedNet` relative to `eligibleSupply` THEN the system SHALL carry forward the undistributed scaled net remainder (similar to `LibFeeIndex.feeIndexRemainder`) instead of discarding it, and SHALL NOT debit `fundedReserve` for that unindexed remainder

2.10 WHEN users claim rewards THEN the system SHALL continue to gross up the net `accruedRewards` via `grossUpNetAmount` for the actual token transfer, and cumulative `fundedReserve` deductions SHALL match the cumulative gross claim liability created by indexed rewards

### Unchanged Behavior (Regression Prevention)

**Maintenance fee accrual flow**

3.1 WHEN `LibMaintenance._accrue` computes the maintenance fee amount on `chargeableTvl` THEN the system SHALL CONTINUE TO compute `amountAccrued = (chargeableTvl * rateBps * epochs) / (365 * 10_000)` and reduce `totalDeposits` by `amountAccrued`

3.2 WHEN `LibMaintenance._pay` transfers accrued maintenance to the foundation receiver THEN the system SHALL CONTINUE TO transfer from `trackedBalance` and decrement pool accounting correctly

3.3 WHEN `LibMaintenance.enforce` is called on a pool with no encumbered capital THEN the system SHALL CONTINUE TO charge maintenance to all depositors identically to current behavior (since `chargeableTvl == totalDeposits`)

**Fee index settle flow**

3.4 WHEN `LibFeeIndex.settle` applies fee index yield to a user's principal THEN the system SHALL CONTINUE TO compute yield as `feeBase * (globalIndex - prevIndex) / INDEX_SCALE` and credit `userAccruedYield` and `userClaimableFeeYield`

3.5 WHEN `LibFeeIndex.settle` is called for a user with zero principal THEN the system SHALL CONTINUE TO snap the user's fee index and maintenance index to current values without computing yield

**Curve engine execution flow**

3.6 WHEN `LibEqualXCurveEngine.executeCurveSwap` executes a curve swap THEN the system SHALL CONTINUE TO compute price, fill volume, track remaining volume, update commitment, and settle position state identically

3.7 WHEN `LibEqualXCurveEngine._applyQuoteSide` routes protocol fees THEN the system SHALL CONTINUE TO call `LibFeeRouter.routeSamePool` with the protocol fee portion and update `trackedBalance`, `userPrincipal`, `totalDeposits`, and fee/maintenance indexes

3.8 WHEN `LibEqualXCurveEngine._applyBaseSide` processes the base side of a curve fill THEN the system SHALL CONTINUE TO decrease maker principal, decrease totalDeposits, and unlock collateral identically

**Fee router flow**

3.9 WHEN `LibFeeRouter.routeSamePool` splits protocol fees into treasury, active credit, and fee index portions THEN the system SHALL CONTINUE TO use `previewSplit` for the split ratios and route each portion to its destination

3.10 WHEN `LibFeeRouter._transferTreasury` is called for a standard token path where pool-side balance delta equals the nominal amount THEN the system SHALL CONTINUE TO decrement `trackedBalance` by the full nominal amount

**EDEN reward engine flow**

3.11 WHEN `LibEdenRewardsEngine.accrueProgram` is called THEN the system SHALL CONTINUE TO compute eligible supply, preview accrual, and store updated program state

3.12 WHEN `LibEdenRewardsEngine.settleProgramPosition` is called THEN the system SHALL CONTINUE TO compute claimable rewards as `eligibleBalance * (globalRewardIndex - checkpoint) / REWARD_INDEX_SCALE` and accumulate into `accruedRewards`

3.13 WHEN `LibEdenRewardsEngine._previewAccrual` is called for a program with zero `eligibleSupply` or zero `fundedReserve` THEN the system SHALL CONTINUE TO advance `lastRewardUpdate` without accruing rewards

3.14 WHEN `LibEdenRewardsEngine._previewAccrual` is called for a closed, disabled, or paused program THEN the system SHALL CONTINUE TO advance `lastRewardUpdate` without accruing rewards

3.15 WHEN `LibEdenRewardsEngine.grossUpNetAmount` and `netFromGross` are called THEN the system SHALL CONTINUE TO compute the gross/net conversion identically
