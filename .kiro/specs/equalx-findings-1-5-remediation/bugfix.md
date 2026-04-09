# Bugfix Requirements Document

## Introduction

Five audit findings in the EqualX AMM contracts require remediation. The findings span Solo AMM swap-time pool accounting (finding 1), Solo AMM close-time fee subtraction (finding 3), Community AMM share minting economics (finding 4), and Solo AMM cancel lifecycle semantics (finding 5). Together they address stale pool state during live trading, phantom backing at close, share dilution on join, and missing cancellation guards.

Note: the original Solo Finding 2 in this track, which required per-swap `LibActiveCreditIndex` synchronization inside `_applyReserveDelta`, has been superseded by the dedicated boundary-synced redesign in `.kiro/specs/equalx-solo-hot-path-rollback`. Solo AMM is no longer intended to keep `activeCreditPrincipalTotal` synchronized with live reserve on every swap.

Source report: `assets/findings/EdenFi-equalx-pashov-ai-audit-report-20260405-002000.md`
Remediation plan: `assets/remediation/EqualX-findings-1-5-remediation-plan.md`

## Bug Analysis

### Current Behavior (Defect)

**Finding 1 — Solo AMM missing `trackedBalance` increment during swaps**

1.1 WHEN a swap executes on a Solo AMM market and `LibFeeRouter.routeSamePool()` routes non-treasury protocol fees (`toActive + toFeeIndex > 0`) THEN the system does not increment the fee-pool `trackedBalance`, leaving pool accounting stale while the market is live

1.2 WHEN `_closeMarket` runs after swaps have accrued protocol fees THEN the system defers the full `trackedBalance` top-up to close time via `protocolYieldA`/`protocolYieldB`, meaning yield is operationally unclaimable until finalization

**Finding 3 — Solo AMM `_closeMarket` conditional fee subtraction inflates `trackedBalance`**

1.3 WHEN `_closeMarket` subtracts protocol fees from `reserveForPrincipal` using per-fee conditional checks (`if feeAccrued > 0 && reserve >= feeAccrued`) and cumulative protocol fees on one side exceed the remaining reserve THEN the system skips the second fee subtraction, leaving protocol-fee amounts inside maker principal and inflating `trackedBalance`

**Finding 4 — Community AMM share inflation via join math**

1.4 WHEN a new maker joins a Community AMM market after swaps have grown reserves through retained fees THEN the system mints shares using `sqrt(amountA * amountB)` instead of a proportional formula, granting excess ownership relative to current pool state and diluting existing makers

**Finding 5 — Solo AMM cancel missing time guard**

1.5 WHEN the maker calls `cancelEqualXSoloAmmMarket` at or after `market.startTime` THEN the system allows cancellation of a live market, enabling the maker to pull liquidity after trading has opened

### Expected Behavior (Correct)

**Finding 1 — Live fee-backing accounting**

2.1 WHEN a swap executes on a Solo AMM market and `LibFeeRouter.routeSamePool()` routes non-treasury protocol fees (`toActive + toFeeIndex > 0`) THEN the system SHALL increment the fee-pool `trackedBalance` by `toActive + toFeeIndex` (and `nativeTrackedTotal` when the fee pool underlying is native) immediately at swap time

2.2 WHEN `_closeMarket` runs after swaps have already incremented `trackedBalance` live THEN the system SHALL NOT re-credit protocol fee backing that was already recognized during swaps, avoiding double-counting

**Finding 3 — Deterministic close-time fee subtraction**

2.3 WHEN `_closeMarket` computes `reserveForPrincipal` THEN the system SHALL subtract total protocol fees per side (`feeIndexFeeAccrued + activeCreditFeeAccrued`) in a single operation and clamp to zero when cumulative fees exceed the remaining reserve, using `reserveForPrincipal = reserve > totalProtocol ? reserve - totalProtocol : 0`

**Finding 4 — Proportional share minting**

2.4 WHEN a maker joins a Community AMM market that already has `totalShares > 0` THEN the system SHALL mint shares using the proportional formula `share = min(amountA * totalShares / reserveA, amountB * totalShares / reserveB)` instead of `sqrt(amountA * amountB)`

**Finding 5 — Cancel time guard**

2.5 WHEN the maker calls `cancelEqualXSoloAmmMarket` at or after `market.startTime` THEN the system SHALL revert, preventing cancellation of a market once trading can occur

### Unchanged Behavior (Regression Prevention)

**Solo AMM swap flow**

3.1 WHEN a Solo AMM swap executes with valid parameters and the market is active THEN the system SHALL CONTINUE TO compute swap output, split fees, route protocol fees, accrue maker fees, and pay the recipient correctly

3.2 WHEN a Solo AMM swap routes treasury fees THEN the system SHALL CONTINUE TO accrue treasury fees to the market without incrementing `trackedBalance` for the treasury portion

**Solo AMM close/finalize flow**

3.3 WHEN `_closeMarket` runs on a market with no accrued protocol fees THEN the system SHALL CONTINUE TO settle ACI, unlock reserve backing, decrease encumbrance, and reconcile principal identically to current behavior

3.4 WHEN `finalizeEqualXSoloAmmMarket` is called after `endTime` THEN the system SHALL CONTINUE TO close the market normally

**Solo AMM cancel flow**

3.5 WHEN the maker calls `cancelEqualXSoloAmmMarket` before `market.startTime` THEN the system SHALL CONTINUE TO allow cancellation and close the market

3.6 WHEN a non-owner calls `cancelEqualXSoloAmmMarket` THEN the system SHALL CONTINUE TO revert with an ownership error

**Solo AMM rebalance flow**

3.7 WHEN a rebalance is scheduled and executed on a live Solo AMM market THEN the system SHALL CONTINUE TO apply reserve and baseline deltas correctly under the boundary-synced ACI model defined in `.kiro/specs/equalx-solo-hot-path-rollback`

**Community AMM swap flow**

3.8 WHEN a Community AMM swap executes THEN the system SHALL CONTINUE TO compute output, split fees, route protocol fees with live `trackedBalance` increments, and pay the recipient correctly

**Community AMM join flow**

3.9 WHEN the first maker joins a Community AMM market (initial liquidity, `totalShares == 0`) THEN the system SHALL CONTINUE TO mint shares using `sqrt(amountA * amountB)` as the bootstrap formula

3.10 WHEN a maker joins a Community AMM market with valid ratio-matching amounts THEN the system SHALL CONTINUE TO lock reserve backing, update reserves, snapshot fee indexes, and emit the join event

**Community AMM leave flow**

3.11 WHEN a maker leaves a Community AMM market THEN the system SHALL CONTINUE TO burn shares, unlock backing, settle fees, and return capital correctly
