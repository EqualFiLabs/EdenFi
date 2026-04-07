# Bugfix Requirements Document

## Introduction

Nine remediation items in the EqualFi EqualIndex contracts require coordinated fixes. The scope covers position-mode burn missing encumbrance check (finding 1), position-mode burn leaking index encumbrance over time (finding 2), burn fee rounding down with user-favorable asymmetric rounding (finding 6), fee-share parameters having no governance setter (finding 8), admin timelock fallback missing owner fallback when timelock is unset (lead), permissionless recovery racing honest repayment at maturity boundary (lead), maintenance eroding locked index collateral causing recovery revert (lead), ERC20 wallet-mode mint pulling user-supplied max bound instead of quoted total (lead), and position-mode mint fee routing reverting because tracked backing is credited too late (lead). Together these restore correct collateral gating, deterministic encumbrance release, protocol-safe burn rounding, governance flexibility, admin access continuity, maturity-boundary fairness, fixed-nominal collateral integrity, exact-pull mint accounting, and position-mint fee-routing reliability.

Canonical Track: Track G. EqualIndex Collateral and Mint/Burn Integrity
Phase: Phase 2. Product Lifecycle Fixes

Source report: `assets/findings/EdenFi-equalindex-pashov-ai-audit-report-20260405-020000.md`
Remediation plan: `assets/remediation/EqualIndex-findings-1-2-6-8-remediation-plan.md`
Unified plan: `assets/remediation/EqualFi-unified-remediation-plan.md`

Depends on:
- Track A. Native Asset Tracking and Transfer Symmetry
- Track B. ACI / Encumbrance / Debt Tracker Consistency
- Track C. Fee Routing, Backing Isolation, and Exotic Token Policy (for fee-routing and reserve-ownership expectations)

Downstream reports closed:
- `assets/findings/EdenFi-equalindex-pashov-ai-audit-report-20260405-020000.md` (findings 1, 2, 6, 8)
- `assets/findings/EdenFi-libraries-phase3-pashov-ai-audit-report-20260406-193000.md` (shared access-control and native-accounting context overlapping with EqualIndex)

Non-remediation (reviewed, no fix planned):
- Finding 3: Disagree — mint/burn pricing asymmetry is product model, not a bug
- Finding 4: Disagree — native repay pulls already handle `nativeTrackedTotal`
- Finding 5: Disagree — maturity-boundary race tracked as grace-period fix below
- Finding 7: Disagree — ERC20 mint already requires actual received >= quoted minimum

## Bug Analysis

### Current Behavior (Defect)

**Finding 1 — `burnFromPosition` missing encumbrance check**

1.1 WHEN a borrower calls `burnFromPosition` with `units <= positionIndexBalance` but `units > availableUnencumbered` (because some index-pool principal is encumbered by an active EqualIndex loan) THEN the system allows the burn, extracting vault assets for collateral that is still backing an active loan

1.2 WHEN `recoverExpiredIndexLoan` later runs after the borrower has burned away the collateral units THEN the system calls `burnIndexUnits(address(this), collateralUnits)` but the diamond holds insufficient tokens, causing recovery to revert and outstanding principal to become permanently unrecoverable

**Finding 2 — Position-mode burn leaks index encumbrance over time**

1.3 WHEN `_applyPositionBurnLeg` computes `navOut = mulDiv(payout, bundleOut, gross)` and unencumbers only `navOut` THEN the system leaves residual encumbrance equal to the burn-fee-proportional share of `bundleOut` that was not unencumbered

1.4 WHEN repeated mint/burn cycles with nonzero burn fees accumulate residual encumbrance THEN the system progressively reduces `availablePrincipal` for future withdrawals and can strand principal permanently, eventually preventing pool membership clearing

**Finding 6 — Burn fee rounds down with user-favorable asymmetric rounding**

1.5 WHEN `_quoteBurnLeg` in wallet-mode computes `leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000)` with default floor rounding THEN the system systematically underpays burn fees by 1 wei on non-exact divisions, favoring burners over the protocol

1.6 WHEN `_quotePositionBurnLeg` in position-mode computes `leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000)` with default floor rounding THEN the system creates the same asymmetric rounding leak in position-mode burns

**Finding 8 — Fee-share parameters have no governance setter**

1.7 WHEN `poolFeeShareBps` is initialized once in `createIndex` (via `if (s().poolFeeShareBps == 0) { s().poolFeeShareBps = 1000; }`) THEN the system locks the value permanently with no governance setter to adapt fee distribution

1.8 WHEN `mintBurnFeeIndexShareBps` is never written to storage and always falls back to the hardcoded default of 4000 THEN the system locks fee-pot share distribution permanently with no governance recourse

**Lead — Admin timelock fallback**

1.9 WHEN `setPaused`, `configureLending`, and `configureBorrowFeeTiers` are gated by EqualIndex's local `onlyTimelock` modifier and the timelock address is unset (`address(0)`) THEN the system makes these functions permanently unreachable, even though other EqualFi modules fall back to owner access via `LibAccess.enforceTimelockOrOwnerIfUnset()`

**Lead — Recovery grace period**

1.10 WHEN `recoverExpiredIndexLoan` is permissionless and checks only `block.timestamp <= loan.maturity` THEN the system allows third parties to front-run a borrower's honest repayment at the exact maturity boundary

1.11 WHEN a borrower calls `repayFromPosition` at `block.timestamp == loan.maturity` and a third party simultaneously calls `recoverExpiredIndexLoan` at `block.timestamp == loan.maturity + 1` THEN the system creates a mempool race where the borrower can lose the ability to repay honestly

**Lead — Maintenance-exempt locked index collateral**

1.12 WHEN maintenance fees continue reducing a borrower's index-pool principal while an EqualIndex loan is active THEN the system can erode settled principal below the fixed nominal `collateralUnits` stored in the loan

1.13 WHEN `recoverExpiredIndexLoan` attempts to burn and reconcile the original fixed nominal `collateralUnits` but settled principal has fallen below that amount due to maintenance THEN the system reverts, making expired-loan recovery permanently impossible

**Lead — Exact-pull mint inputs**

1.14 WHEN ERC20 wallet-mode mint calls `LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.total, maxInputAmounts[i])` and `maxInputAmounts[i] > leg.total` THEN the system pulls the full `maxInputAmounts[i]` instead of only the quoted `leg.total`

1.15 WHEN the surplus tokens (`maxInputAmounts[i] - leg.total`) are transferred into the contract but only `leg.total` is booked into vault balances, fee pots, and fees THEN the system leaves the surplus as untracked contract balance

**Lead — Position mint fee routing**

1.16 WHEN position-mode mint calls `LibFeeRouter.routeManagedShare(leg.poolId, poolShare, ..., true, 0)` without pre-crediting `pool.trackedBalance` by `poolShare` THEN the system can revert during treasury routing if the pool lacks sufficient preexisting tracked balance

1.17 WHEN the pool has enough unencumbered principal for the mint but insufficient live tracked balance for the routed pool-share fee THEN the system creates a false liquidity failure path where minting depends on live tracked balance rather than the fee value being routed

### Expected Behavior (Correct)

**Finding 1 — Burn gated against active index-loan encumbrance**

2.1 WHEN a borrower calls `burnFromPosition` with `units > availableUnencumbered` (where `availableUnencumbered = positionIndexBalance - encumberedByActiveLoans`) THEN the system SHALL revert with `InsufficientUnencumberedPrincipal`, preventing burn of collateral backing active loans

2.2 WHEN a borrower calls `burnFromPosition` with `units <= availableUnencumbered` THEN the system SHALL allow the burn normally

**Finding 2 — Deterministic encumbrance release on position burn**

2.3 WHEN `_applyPositionBurnLeg` processes a position-mode burn THEN the system SHALL unencumber `leg.bundleOut` (the actual underlying principal being removed from the index vault on that leg) instead of the payout-derived `navOut`

2.4 WHEN a full position-mode exit with nonzero burn fees completes THEN the system SHALL leave no residual index-related encumbrance behind

**Finding 6 — Protocol-safe burn fee rounding**

2.5 WHEN `_quoteBurnLeg` in wallet-mode computes the burn fee THEN the system SHALL use `Math.Rounding.Ceil` so that `leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000, Math.Rounding.Ceil)`

2.6 WHEN `_quotePositionBurnLeg` in position-mode computes the burn fee THEN the system SHALL use `Math.Rounding.Ceil` so that `leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000, Math.Rounding.Ceil)`

**Finding 8 — Governance setters for fee-share parameters**

2.7 WHEN the timelock or fallback owner calls `setEqualIndexPoolFeeShareBps(newBps)` with `newBps` in `0..10_000` THEN the system SHALL update `poolFeeShareBps` and emit `EqualIndexPoolFeeShareBpsUpdated(oldBps, newBps)`

2.8 WHEN the timelock or fallback owner calls `setEqualIndexMintBurnFeeIndexShareBps(newBps)` with `newBps` in `0..10_000` THEN the system SHALL update `mintBurnFeeIndexShareBps` and emit `EqualIndexMintBurnFeeIndexShareBpsUpdated(oldBps, newBps)`

2.9 WHEN a caller that is neither the configured timelock nor the fallback owner attempts to call either fee-share setter THEN the system SHALL revert

2.10 WHEN either setter is called with `newBps > 10_000` THEN the system SHALL revert

**Lead — Admin timelock fallback**

2.11 WHEN `setPaused`, `configureLending`, and `configureBorrowFeeTiers` are called and the timelock is unset (`address(0)`) THEN the system SHALL allow the owner to call these functions via `LibAccess.enforceTimelockOrOwnerIfUnset()`

2.12 WHEN the timelock is configured THEN the system SHALL require the timelock for these functions and reject owner-only calls

**Lead — Recovery grace period**

2.13 WHEN `recoverExpiredIndexLoan` is called and `block.timestamp <= loan.maturity + RECOVERY_GRACE_PERIOD` THEN the system SHALL revert with `LoanNotExpired`

2.14 WHEN `block.timestamp > loan.maturity + RECOVERY_GRACE_PERIOD` THEN the system SHALL allow recovery to proceed normally

2.15 WHEN `repayFromPosition` is called during the grace period (`loan.maturity < block.timestamp <= loan.maturity + RECOVERY_GRACE_PERIOD`) THEN the system SHALL allow repayment to succeed

**Lead — Maintenance-exempt locked index collateral**

2.16 WHEN `borrowFromPosition` encumbers index-pool collateral THEN the system SHALL track the locked collateral both in the existing pool-level `indexEncumberedTotal` aggregate and in a per-user maintenance-exempt principal record for the borrowing `positionKey`

2.17 WHEN maintenance settlement runs on the index-token pool THEN the system SHALL apply maintenance only to unlocked index-pool principal, preserving the fixed nominal collateral amount for each affected borrower rather than only at pool aggregate level

2.18 WHEN `repayFromPosition` or `recoverExpiredIndexLoan` releases collateral THEN the system SHALL remove both the pool-level and per-user maintenance exemption for the released `collateralUnits`

2.19 WHEN an expired loan is recovered after long maintenance accrual periods THEN the system SHALL succeed because locked collateral has not been eroded

**Lead — Exact-pull mint inputs**

2.20 WHEN ERC20 wallet-mode mint processes a leg THEN the system SHALL pull only the quoted `leg.total` from the user, not the user-supplied `maxInputAmounts[i]`

2.21 WHEN `maxInputAmounts[i] > leg.total` THEN the system SHALL use `maxInputAmounts[i]` only as a user protection bound (revert if `maxInputAmounts[i] < leg.total`) and not as the transfer amount

2.22 WHEN a fee-on-transfer ERC20 is used THEN the system SHALL CONTINUE TO revert if actual received is below the quoted requirement

**Lead — Position mint fee routing**

2.23 WHEN position-mode mint routes the pool-share fee via `LibFeeRouter.routeManagedShare` THEN the system SHALL pre-credit `pool.trackedBalance` by `poolShare` before calling the router

2.24 WHEN the position has sufficient unencumbered principal for the mint THEN the system SHALL NOT revert solely because the pool lacked preexisting tracked balance for the routed fee share

### Unchanged Behavior (Regression Prevention)

**Position-mode mint flow**

3.1 WHEN `mintFromPosition` is called with valid parameters, sufficient unencumbered underlying principal, and the index is active THEN the system SHALL CONTINUE TO validate inputs, encumber underlying principal, credit vault balances, deduct fee-pot buy-in and fees from user principal, route pool-share fees, mint index tokens, and credit index-pool principal correctly

3.2 WHEN `mintFromPosition` is called and the position lacks sufficient unencumbered principal THEN the system SHALL CONTINUE TO revert with `InsufficientUnencumberedPrincipal`

**Position-mode burn flow**

3.3 WHEN `burnFromPosition` is called with valid parameters and sufficient unencumbered index-pool principal THEN the system SHALL CONTINUE TO validate inputs, compute burn legs, burn index tokens, release vault assets, route pool-share fees, credit fee-pot share to user principal, and update index-pool accounting correctly

3.4 WHEN `burnFromPosition` is called with `units > positionIndexBalance` THEN the system SHALL CONTINUE TO revert with `InsufficientIndexTokens`

**Wallet-mode mint flow**

3.5 WHEN wallet-mode `mint` is called with valid parameters and sufficient `maxInputAmounts` THEN the system SHALL CONTINUE TO pull assets, credit vault balances, charge fees, mint index tokens, and transfer tokens to the recipient correctly

3.6 WHEN native wallet-mode mint is called THEN the system SHALL CONTINUE TO require exact `msg.value`

**Wallet-mode burn flow**

3.7 WHEN wallet-mode `burn` is called with valid parameters THEN the system SHALL CONTINUE TO compute burn legs, burn index tokens, distribute fees, and transfer payout to the recipient correctly

**Lending flow**

3.8 WHEN `borrowFromPosition` is called with valid parameters and sufficient unencumbered index-pool principal THEN the system SHALL CONTINUE TO validate collateral, encumber index-pool principal, create the loan, disburse borrowed assets, and emit events correctly

3.9 WHEN `repayFromPosition` is called for an active loan THEN the system SHALL CONTINUE TO collect repayment, restore vault balances, unencumber index-pool principal, and delete the loan correctly

3.10 WHEN `recoverExpiredIndexLoan` is called after the grace period for a legitimately expired loan THEN the system SHALL CONTINUE TO write off outstanding principal, release recovered collateral, and delete the loan correctly

**Admin and governance flow**

3.11 WHEN `setPaused` is called by an authorized caller (timelock when set, owner when unset) THEN the system SHALL CONTINUE TO toggle the paused state

3.12 WHEN `configureLending` is called by an authorized caller THEN the system SHALL CONTINUE TO update lending configuration

3.13 WHEN `configureBorrowFeeTiers` is called by an authorized caller THEN the system SHALL CONTINUE TO update borrow fee tiers

**Fee routing and distribution**

3.14 WHEN wallet-mode mint or burn distributes fees THEN the system SHALL CONTINUE TO split fees between pool share and fee-pot share using the configured `poolFeeShareBps` and `mintBurnFeeIndexShareBps`

3.15 WHEN position-mode mint or burn routes pool-share fees THEN the system SHALL CONTINUE TO route fees through `LibFeeRouter.routeManagedShare` correctly

**Flash loan flow**

3.16 WHEN `flashLoan` is called with valid parameters THEN the system SHALL CONTINUE TO execute the flash loan, validate repayment, settle fees, and finalize correctly
