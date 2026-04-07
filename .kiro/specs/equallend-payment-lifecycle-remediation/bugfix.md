# Bugfix Requirements Document

## Introduction

Eight remediation items in the EqualLend Direct payment lifecycle require coordinated fixes. The scope covers rolling payment guard semantics (dead `minReceived` parameter), rolling arrears-trap state advancement, rolling default penalty basis, fixed-interest rounding, lender-ratio collateral rounding, rolling over-receive handling, rolling payment-cap enforcement, and pool AUM fee access-control normalization. Together these restore correct borrower protection, fair delinquency state transitions, economically sound default penalties, rounding safety across fixed and rolling products, and consistent admin policy.

Canonical Track: Track D. Payment Lifecycle and Delinquency State Machines
Phase: Phase 2. Product Lifecycle Fixes

Source report: `assets/findings/EdenFi-equallend-pashov-ai-audit-report-20260405-160000.md`
Library report: `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md`
Remediation plan: `assets/remediation/EqualLend-findings-3-5-6-8-remediation-plan.md`
Unified plan: `assets/remediation/EqualFi-unified-remediation-plan.md`

Depends on:
- Track A. Native Asset Tracking and Transfer Symmetry
- Track B. ACI / Encumbrance / Debt Tracker Consistency

Downstream reports closed:
- EqualLend facet findings 3, 5, 6, 8
- Libraries phase 2 finding 3 (rolling arrears trap root cause)
- Agreed leads: collateral rounding, over-receive handling, payment-cap enforcement, `setAumFee` access control

Non-remediation (reviewed, no fix planned):
- Finding 1: native repayment accounting — disagree (netted correctly through `pullAtLeast`)
- Finding 2: SSC repay native tracking — disagree (netted correctly through `pullAtLeast`)
- Finding 4: `callDirect` grace compression — disagree (intentional callable-loan product option)
- Finding 7: forced pool membership on cross-asset default — disagree (current settlement design)

## Bug Analysis

### Current Behavior (Defect)

**Finding 3 — Rolling payment `minReceived` is a dead parameter**

1.1 WHEN a borrower calls `makeRollingPayment(agreementId, amount, maxPayment, minReceived)` with a non-zero `minReceived` value THEN the system silently discards `minReceived` via a bare expression statement (`minReceived;`), providing zero protection against time-accrued interest drift between quote and inclusion

1.2 WHEN a borrower calls `repayRollingInFull(agreementId, maxPayment, minReceived)` with a non-zero `minReceived` value THEN the system silently discards `minReceived` via a bare expression statement, providing zero protection against interest growth during transaction delay

**Finding 5 — Rolling payment arrears trap**

1.3 WHEN a borrower pays all historical overdue arrears but current-period interest remains unpaid THEN the system folds unpaid current-period interest into `agreement.arrears` and does not advance `nextDue`, leaving the borrower in the stale overdue slot

1.4 WHEN a borrower is in the stale overdue slot after paying historical arrears and the grace period has passed THEN the system allows anyone to call `recoverRolling` to seize collateral despite the borrower having cured all past-due amounts

**Finding 6 — Rolling default penalty computed on inflated `totalDebt`**

1.5 WHEN `_settleRollingDefaultPath` computes the default penalty and `totalDebt` (principal + unbounded accrued interest) significantly exceeds collateral value THEN the system computes `penaltyPaid = (totalDebt * defaultPenaltyBps) / BPS_DENOMINATOR`, consuming a disproportionate share of seized collateral and reducing lender recovery

1.6 WHEN a rolling loan ages in default with growing accrued interest but flat collateral THEN the system produces a penalty that increases over time, paradoxically rewarding delayed default resolution and degrading lender recovery

**Finding 8 — Fixed interest truncates to zero for small loans**

1.7 WHEN `_quoteFixedFees` computes interest for a small principal, low APR, or short effective duration using floor rounding (`Math.mulDiv` default) THEN the system can produce zero interest for a valid nonzero loan configuration, enabling free borrowing

1.8 WHEN a fixed loan is originated with zero computed interest due to floor truncation THEN the system charges no interest to the borrower, creating an inconsistency with rolling loans which use `Math.Rounding.Ceil`

**Lead — Lender-ratio collateral rounding favors borrower**

1.9 WHEN `_validateLenderRatioFill` computes `collateralRequired = Math.mulDiv(principalAmount, priceNumerator, priceDenominator)` using floor rounding THEN the system systematically under-collateralizes each lender-ratio tranche fill by up to 1 wei of collateral

**Lead — Rolling over-receive handling**

1.10 WHEN `_collectPayment` calls `pullAtLeast(borrowAsset, sender, amount, maxPayment)` and the transfer returns more than `amount` for an amortization-disabled agreement THEN the system allocates the surplus into the principal bucket and the subsequent amortization-disabled check reverts, blocking a valid interest-only payment

**Lead — Rolling `maxPaymentCount` not enforced**

1.11 WHEN a borrower calls `makeRollingPayment` after `agreement.paymentCount` has reached `agreement.maxPaymentCount` THEN the system allows the payment to proceed, treating the advertised payment cap as a soft saturation counter rather than a hard lifecycle rule

**Lead — `setAumFee` inconsistent access control**

1.12 WHEN the protocol owner calls `setAumFee` after a timelock has been configured THEN the system reverts because `enforceTimelockOrOwnerIfUnset()` drops owner authority once a timelock exists, unlike peer config writers that use `enforceOwnerOrTimelock()`

### Expected Behavior (Correct)

**Finding 3 — Replace `minReceived` with `maxInterestDue` guard**

2.1 WHEN a borrower calls `makeRollingPayment` with a `maxInterestDue` parameter and the computed total interest (arrears + current-period) exceeds `maxInterestDue` THEN the system SHALL revert, protecting the borrower against time-accrued interest drift

2.2 WHEN a borrower calls `repayRollingInFull` with a `maxInterestDue` parameter and the computed total interest exceeds `maxInterestDue` THEN the system SHALL revert, protecting the borrower against interest growth during transaction delay

2.3 WHEN both `maxPayment` and `maxInterestDue` are satisfied THEN the system SHALL process the rolling payment normally

**Finding 5 — Separate overdue arrears cure from current-period accrual**

2.4 WHEN a borrower pays all historical overdue arrears (the portion tied to passed due checkpoints) THEN the system SHALL advance `nextDue` to the next due checkpoint and increment `paymentCount` by the appropriate `dueCountDelta`, even if current-period interest remains unpaid

2.5 WHEN `nextDue` has been advanced after a catch-up payment THEN the system SHALL keep unpaid current-period interest in `agreement.arrears` as owed but SHALL NOT allow immediate `recoverRolling` based on the stale (now-advanced) checkpoint

2.6 WHEN a borrower has not cured historical overdue arrears THEN the system SHALL NOT advance `nextDue`, preserving the existing overdue semantics for genuinely delinquent positions

**Finding 6 — Rebase penalty onto realized recovery value**

2.7 WHEN `_settleRollingDefaultPath` computes the default penalty THEN the system SHALL compute `penaltyPaid` from `min(collateralSeized, totalDebt)` (the realized recovery base) instead of from unbounded `totalDebt`

2.8 WHEN collateral value is less than `totalDebt` THEN the system SHALL cap the penalty at a fraction of the actual seized collateral, preventing penalty from consuming disproportionate recovery value

**Finding 8 — Round fixed interest up**

2.9 WHEN `_quoteFixedFees` computes interest for any nonzero principal, APR, and effective duration THEN the system SHALL use `Math.Rounding.Ceil` to produce at least 1 wei of interest, preventing free-borrowing edge cases

2.10 WHEN fixed and rolling fee quotes are compared for equivalent parameters THEN the system SHALL produce directionally aligned rounding (both ceiling), eliminating the inconsistency

**Lead — Round lender-ratio collateral up**

2.11 WHEN `_validateLenderRatioFill` computes `collateralRequired` THEN the system SHALL use `Math.Rounding.Ceil` in the `Math.mulDiv` call, ensuring collateral requirements round in the protocol-safe direction

**Lead — Normalize over-receive for amortization-disabled paths**

2.12 WHEN `_collectPayment` receives more than `amount` from `pullAtLeast` and `allowAmortization == false` THEN the system SHALL cap the allocatable amount at the requested `amount` (or refund the surplus before allocation), preventing the amortization-disabled check from reverting on benign input overshoot

2.13 WHEN a genuine principal reduction is attempted on an amortization-disabled agreement THEN the system SHALL CONTINUE TO revert with `RollingError_AmortizationDisabled`

**Lead — Enforce rolling `maxPaymentCount` as hard cap**

2.14 WHEN a borrower calls `makeRollingPayment` and `agreement.paymentCount >= agreement.maxPaymentCount` THEN the system SHALL revert, enforcing the payment cap as a real lifecycle rule

2.15 WHEN a borrower calls `repayRollingInFull` at or past the payment cap THEN the system SHALL CONTINUE TO allow terminal repayment under the intended closeout policy

**Lead — Normalize `setAumFee` access control**

2.16 WHEN the protocol owner calls `setAumFee` after a timelock has been configured THEN the system SHALL allow the call, matching the `enforceOwnerOrTimelock()` pattern used by peer config writers

2.17 WHEN a non-owner, non-timelock caller calls `setAumFee` THEN the system SHALL revert

### Unchanged Behavior (Regression Prevention)

**Rolling payment flow**

3.1 WHEN a borrower makes a valid rolling payment with satisfied guards and no edge conditions THEN the system SHALL CONTINUE TO accrue interest, allocate payment to arrears then current interest then principal, settle positions, restore lender capital, and emit the payment event correctly

3.2 WHEN a rolling payment includes principal amortization on an amortization-enabled agreement THEN the system SHALL CONTINUE TO reduce `outstandingPrincipal`, settle principal accounting, and release proportional collateral

**Rolling full repay flow**

3.3 WHEN a borrower repays a rolling agreement in full with valid parameters THEN the system SHALL CONTINUE TO compute total due, pull funds, restore lender capital, settle principal, clear agreement state, refund surplus, and emit the repaid event

3.4 WHEN early repay is disallowed and `paymentCount < maxPaymentCount` THEN the system SHALL CONTINUE TO revert on `repayRollingInFull`

**Rolling recovery and default flow**

3.5 WHEN a rolling agreement is genuinely overdue past the grace period with uncured arrears THEN the system SHALL CONTINUE TO allow `recoverRolling` to seize collateral and settle the default path

3.6 WHEN `_settleRollingDefaultPath` runs with `applyPenalty == false` THEN the system SHALL CONTINUE TO skip penalty computation entirely

3.7 WHEN `_settleRollingDefaultPath` splits recovered debt THEN the system SHALL CONTINUE TO route lender, treasury, active-credit, and fee-index shares correctly after the corrected penalty base

**Fixed agreement origination**

3.8 WHEN a fixed agreement is originated with normal (non-edge-case) parameters THEN the system SHALL CONTINUE TO compute interest, platform fee, and due timestamp identically to current behavior

3.9 WHEN `_quoteFixedFees` is called with `aprBps == 0` or `principal == 0` THEN the system SHALL CONTINUE TO produce zero interest

**Lender-ratio tranche fills**

3.10 WHEN a lender-ratio tranche fill proceeds with valid parameters THEN the system SHALL CONTINUE TO validate acceptance context, check funding state, check collateral state, and verify solvency

3.11 WHEN `collateralRequired` computes to zero after rounding THEN the system SHALL CONTINUE TO revert with `DirectError_InvalidRatio`

**Pool AUM fee management**

3.12 WHEN the timelock calls `setAumFee` THEN the system SHALL CONTINUE TO allow the call and enforce bounds checks

3.13 WHEN `setAumFee` is called with a fee outside the `[aumFeeMinBps, aumFeeMaxBps]` range THEN the system SHALL CONTINUE TO revert with `AumFeeOutOfBounds`

**Rolling exercise and offer flows**

3.14 WHEN `exerciseRolling` is called by the borrower on an active agreement THEN the system SHALL CONTINUE TO process voluntary default correctly

3.15 WHEN rolling offers are accepted with valid parameters THEN the system SHALL CONTINUE TO store agreements, lock collateral, fund principal, and emit events correctly
