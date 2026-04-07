# EqualLend Payment Lifecycle Remediation — Bugfix Design

## Overview

Eight remediation items in the EqualLend Direct payment lifecycle require coordinated fixes across rolling payment guards, arrears state advancement, default penalty computation, fixed-interest rounding, lender-ratio collateral rounding, over-receive handling, payment-cap enforcement, and pool AUM fee access control. The fix strategy preserves the existing EqualFi rolling and fixed loan models while correcting guard semantics, state-machine transitions, penalty economics, rounding safety, and admin policy consistency.

Canonical Track: Track D. Payment Lifecycle and Delinquency State Machines
Phase: Phase 2. Product Lifecycle Fixes

Source report: `assets/findings/EdenFi-equallend-pashov-ai-audit-report-20260405-160000.md`
Library report: `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md`
Remediation plan: `assets/remediation/EqualLend-findings-3-5-6-8-remediation-plan.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across eight items that trigger incorrect guard behavior, stale state advancement, inflated penalties, truncated fees, under-collateralization, payment reverts, unenforced caps, or inconsistent access control
- **Property (P)**: The desired correct behavior for each item
- **Preservation**: Existing rolling payment allocation, full repay flow, recovery/default settlement, fixed origination, ratio-fill validation, AUM fee bounds, and offer acceptance that must remain unchanged
- **`minReceived`**: Dead parameter in `makeRollingPayment` and `repayRollingInFull` that is silently discarded via bare expression statement
- **`maxInterestDue`**: Replacement parameter that guards the time-accrued interest component against drift between quote and inclusion
- **`arrears`**: Rolling agreement field tracking unpaid interest from passed due checkpoints plus any rolled-over current-period interest
- **`nextDue`**: Rolling agreement field marking the next payment checkpoint; only advances when arrears reaches zero in current code
- **`paymentCount`**: Rolling agreement field tracking completed payment periods; saturates at `maxPaymentCount` without blocking further payments
- **`totalDebt`**: Sum of `outstandingPrincipal + interestDue` used as penalty base in current default settlement
- **`debtValueApplied`**: Realized recovery value (`min(availableForDebt, totalDebt)`) — the correct penalty base
- **`_quoteFixedFees`**: Internal function computing fixed-loan interest using floor rounding (`Math.mulDiv` default)
- **`_validateLenderRatioFill`**: Internal function computing collateral requirements using floor rounding
- **`enforceTimelockOrOwnerIfUnset()`**: Access guard that drops owner authority once a timelock is configured
- **`enforceOwnerOrTimelock()`**: Access guard that allows either owner or timelock at all times

## Bug Details

### Bug Condition

The bugs manifest across eight distinct conditions in the EqualLend Direct contracts. Together they represent misleading guard parameters, trapped delinquency states, inflated penalty economics, rounding-direction errors, input-overshoot reverts, unenforced lifecycle caps, and inconsistent admin policy.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 3: Rolling payment minReceived is silently discarded
  IF input.finding == 3 THEN
    RETURN input.context.isRollingPayment
           AND input.context.minReceivedParam != 0

  // Finding 5: Rolling arrears trap — nextDue stuck after catch-up
  IF input.finding == 5 THEN
    RETURN input.context.isRollingPayment
           AND input.context.historicalArrearsPaid >= input.context.historicalArrearsDue
           AND input.context.currentInterestRemaining > 0
           AND input.context.dueCountDelta > 0

  // Finding 6: Default penalty on inflated totalDebt
  IF input.finding == 6 THEN
    RETURN input.context.isRollingDefault
           AND input.context.applyPenalty == true
           AND input.context.totalDebt > input.context.collateralSeized

  // Finding 8: Fixed interest truncates to zero
  IF input.finding == 8 THEN
    RETURN input.context.isFixedOrigination
           AND input.context.principal > 0
           AND input.context.aprBps > 0
           AND input.context.effectiveDuration > 0
           AND Math.mulDiv(principal, aprBps * effectiveDuration, YEAR * BPS_DENOM) == 0

  // Lead: Lender-ratio collateral rounds down
  IF input.finding == 9 THEN
    RETURN input.context.isLenderRatioFill
           AND Math.mulDiv(principal, priceNum, priceDenom) < ceil(principal * priceNum / priceDenom)

  // Lead: Over-receive reverts amortization-disabled payment
  IF input.finding == 10 THEN
    RETURN input.context.isRollingPayment
           AND input.context.allowAmortization == false
           AND input.context.received > input.context.requestedAmount
           AND input.context.received - input.context.requestedAmount > 0

  // Lead: maxPaymentCount not enforced
  IF input.finding == 11 THEN
    RETURN input.context.isRollingPayment
           AND input.context.paymentCount >= input.context.maxPaymentCount

  // Lead: setAumFee drops owner after timelock
  IF input.finding == 12 THEN
    RETURN input.context.isSetAumFee
           AND input.context.callerIsOwner
           AND input.context.timelockConfigured == true

  RETURN false
END FUNCTION
```

### Examples

- **Finding 3**: Borrower calls `makeRollingPayment(id, 100e18, 110e18, 95e18)`. Between quote and inclusion, 2 hours pass and interest grows from 90e18 to 105e18. `minReceived` (95e18) is discarded. Borrower pays 105e18 interest with no protection. Expected: revert if interest > `maxInterestDue`.
- **Finding 5**: Borrower owes 100e18 arrears + 10e18 current interest. Pays 100e18. New `arrears = 10e18` (current interest folded in). `nextDue` not advanced. Grace period passed. `recoverRolling` callable immediately. Expected: `nextDue` advances, borrower not immediately recoverable.
- **Finding 6**: 1000e18 principal, 100% APR, 1 year overdue. `totalDebt = 2000e18`. Collateral = 1200e18. Penalty = `2000e18 * 10% = 200e18`. Lender gets 1000e18. After 2 years: `totalDebt = 3000e18`, penalty = 300e18, lender gets only 900e18. Expected: penalty based on `min(1200e18, totalDebt)`, lender recovery stable.
- **Finding 8**: 1 USDC (1e6), 0.01% APR (1 BPS), 1 day. `mulDiv(1e6, 1 * 86400, 365 days * 10000) = 0`. Free loan. Expected: ceiling rounding produces at least 1 wei.
- **Collateral rounding**: `mulDiv(1000e18, 3, 7) = 428571428571428571428` (floor). Ceil = `428571428571428571429`. Borrower under-collateralized by 1 wei per fill.
- **Over-receive**: Amortization-disabled agreement. Borrower requests 50e18 interest payment. `pullAtLeast` returns 51e18. 1e18 surplus falls into principal bucket. Amortization check reverts. Expected: cap allocatable at 50e18, refund 1e18.
- **Payment cap**: `paymentCount = 12`, `maxPaymentCount = 12`. Borrower calls `makeRollingPayment`. Succeeds. Expected: revert.
- **setAumFee**: Owner calls `setAumFee(1, 25)` after timelock configured. `enforceTimelockOrOwnerIfUnset()` reverts. Expected: `enforceOwnerOrTimelock()` allows owner.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Rolling payment allocation waterfall (arrears → current interest → principal → refund) must continue to work exactly as before for non-edge-case payments
- Rolling full repay total-due computation, fund pull, lender capital restoration, principal settlement, agreement finalization, and surplus refund must remain unchanged
- Rolling recovery and default settlement must continue to seize collateral, split recovered debt, apply recovered value, and finalize terminal state correctly (with corrected penalty base)
- Fixed agreement origination for normal (non-truncating) parameters must produce identical interest, platform fee, and due timestamp
- `_quoteFixedFees` with `aprBps == 0` or `principal == 0` must continue to produce zero interest
- Lender-ratio fill validation context, funding state, collateral state, and solvency checks must remain unchanged
- `setAumFee` bounds enforcement and event emission must remain unchanged
- Rolling offer acceptance, agreement storage, collateral locking, and principal funding must remain unchanged
- Rolling exercise (voluntary default) must continue to work correctly
- Early repay guard (`allowEarlyRepay == false && paymentCount < maxPaymentCount`) must continue to revert on `repayRollingInFull`

**Scope:**
All inputs that do NOT match any of the eight bug conditions should be completely unaffected by these fixes.

## Hypothesized Root Cause

1. **Finding 3 — Dead `minReceived`**: Both `makeRollingPayment` and `repayRollingInFull` accept `minReceived` as a parameter but suppress the unused-variable warning with a bare expression statement (`minReceived;`). The parameter was likely intended as slippage protection but was never wired into any validation logic. The ABI communicates false safety.

2. **Finding 5 — Arrears trap**: `LibEqualLendDirectRolling.applyPaymentState` only advances `nextDue` when `agreement.arrears == 0 && snapshot.dueCountDelta != 0`. The function folds unpaid current-period interest into `arrears` before this check: `agreement.arrears = remainingArrears + unpaidCurrentInterest`. So even when all historical arrears are paid (`remainingArrears == 0`), any unpaid current-period interest makes `agreement.arrears > 0`, blocking `nextDue` advancement. The borrower remains in the stale overdue slot and is immediately recoverable.

3. **Finding 6 — Inflated penalty base**: `_settleRollingDefaultPath` computes `settlement.penaltyPaid = (totalDebt * store.rollingConfig.defaultPenaltyBps) / BPS_DENOMINATOR` where `totalDebt = interestDue + principalDue`. As interest accrues unboundedly while collateral stays flat, the penalty grows without bound relative to actual recovery value. The penalty should be based on `min(collateralSeized, totalDebt)` — the realized recovery base.

4. **Finding 8 — Floor rounding**: `_quoteFixedFees` uses `Math.mulDiv(principal, uint256(aprBps) * effectiveDuration, YEAR * BPS_DENOMINATOR)` which defaults to floor rounding. For small inputs, this truncates to zero. Rolling interest already uses `Math.Rounding.Ceil` in `LibEqualLendDirectRolling.rollingInterest`, creating an inconsistency.

5. **Collateral rounding**: `_validateLenderRatioFill` uses `Math.mulDiv(principalAmount, offer.priceNumerator, offer.priceDenominator)` which defaults to floor rounding. Each fill under-collateralizes by up to 1 wei. The rounding direction should favor the protocol.

6. **Over-receive revert**: `_collectPayment` checks `!agreement.allowAmortization && amount > interestDue` before pulling funds, using the requested `amount`. But `pullAtLeast` can return `received > amount`. The surplus falls into the principal allocation path, and the second amortization check (`if (!agreement.allowAmortization)`) reverts. The pre-pull guard uses `amount` but the post-pull allocation uses `received`.

7. **Payment cap unenforced**: `applyPaymentState` saturates `paymentCount` at `maxPaymentCount` but never blocks further payments. `makeRollingPayment` has no cap check. The advertised lifecycle cap is purely informational.

8. **`setAumFee` access control**: `setAumFee` uses `enforceTimelockOrOwnerIfUnset()` which allows owner only when no timelock is configured. Once a timelock is set, owner is locked out. Peer config writers use `enforceOwnerOrTimelock()` which allows either at all times.

## Correctness Properties

Property 1: Bug Condition — Rolling payment interest guard (Finding 3)

_For any_ rolling payment or rolling full repay where computed total interest (arrears + current-period) exceeds the caller-supplied `maxInterestDue`, the fixed functions SHALL revert, providing real time-accrued interest protection.

**Validates: Requirements 2.1, 2.2, 2.3**

Property 2: Bug Condition — Rolling arrears cure advances `nextDue` (Finding 5)

_For any_ rolling payment where all historical overdue arrears are cured but current-period interest remains unpaid, the fixed `applyPaymentState` SHALL advance `nextDue` to the next due checkpoint and increment `paymentCount`, preventing immediate recoverability on the stale checkpoint.

**Validates: Requirements 2.4, 2.5, 2.6**

Property 3: Bug Condition — Default penalty on realized recovery value (Finding 6)

_For any_ rolling default settlement where `applyPenalty == true`, the fixed `_settleRollingDefaultPath` SHALL compute `penaltyPaid` from `min(collateralSeized, totalDebt)` instead of from unbounded `totalDebt`, capping the penalty at a fraction of actual seized value.

**Validates: Requirements 2.7, 2.8**

Property 4: Bug Condition — Fixed interest ceiling rounding (Finding 8)

_For any_ fixed fee quote where `principal > 0`, `aprBps > 0`, and `effectiveDuration > 0`, the fixed `_quoteFixedFees` SHALL use `Math.Rounding.Ceil` and produce at least 1 wei of interest.

**Validates: Requirements 2.9, 2.10**

Property 5: Bug Condition — Lender-ratio collateral ceiling rounding (Lead)

_For any_ lender-ratio tranche fill, the fixed `_validateLenderRatioFill` SHALL use `Math.mulDiv(..., Math.Rounding.Ceil)` for `collateralRequired`, ensuring protocol-safe rounding direction.

**Validates: Requirements 2.11**

Property 6: Bug Condition — Over-receive normalization (Lead)

_For any_ rolling payment on an amortization-disabled agreement where `pullAtLeast` returns more than the requested amount, the fixed `_collectPayment` SHALL cap the allocatable amount at the requested `amount` or refund the surplus before allocation, preventing the amortization check from reverting on benign overshoot.

**Validates: Requirements 2.12, 2.13**

Property 7: Bug Condition — Payment cap enforcement (Lead)

_For any_ call to `makeRollingPayment` where `paymentCount >= maxPaymentCount`, the fixed function SHALL revert. `repayRollingInFull` SHALL continue to follow the intended closeout policy.

**Validates: Requirements 2.14, 2.15**

Property 8: Bug Condition — `setAumFee` access control normalization (Lead)

_For any_ call to `setAumFee` by the protocol owner after a timelock is configured, the fixed function SHALL allow the call. Non-owner, non-timelock callers SHALL continue to revert.

**Validates: Requirements 2.16, 2.17**

Property 9: Preservation — Rolling payment mechanics

_For any_ rolling payment that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code, preserving payment allocation, position settlement, lender capital restoration, principal settlement, and event emission.

**Validates: Requirements 3.1, 3.2**

Property 10: Preservation — Rolling full repay and lifecycle

_For any_ rolling full repay, recovery, default settlement, exercise, or offer acceptance that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.3, 3.4, 3.5, 3.6, 3.7, 3.14, 3.15**

Property 11: Preservation — Fixed origination and ratio fills

_For any_ fixed agreement origination or lender-ratio fill that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.8, 3.9, 3.10, 3.11**

Property 12: Preservation — AUM fee management

_For any_ `setAumFee` call that does NOT trigger the bug condition (timelock calls, bounds checks), the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.12, 3.13**


## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

---

**File**: `src/equallend/EqualLendDirectRollingPaymentFacet.sol`

**Function**: `makeRollingPayment`

**Specific Changes**:
1. **Replace `minReceived` with `maxInterestDue` (Finding 3)**: Change the function signature from `makeRollingPayment(uint256 agreementId, uint256 amount, uint256 maxPayment, uint256 minReceived)` to `makeRollingPayment(uint256 agreementId, uint256 amount, uint256 maxPayment, uint256 maxInterestDue)`. Remove the bare `minReceived;` statement. After computing the accrual snapshot, add: `uint256 totalInterest = snapshot.arrearsDue + snapshot.currentInterestDue; if (totalInterest > maxInterestDue) revert RollingError_InterestExceedsMax(totalInterest, maxInterestDue);`

2. **Add payment cap check (Lead)**: Before accrual computation, add: `if (agreement.paymentCount >= agreement.maxPaymentCount) revert RollingError_PaymentCapReached();`

**Function**: `_collectPayment`

**Specific Changes**:
3. **Normalize over-receive for amortization-disabled paths (Lead)**: After `pullAtLeast` returns `allocation.received`, when `!agreement.allowAmortization`, cap the allocatable amount: `uint256 allocatable = !agreement.allowAmortization && allocation.received > amount ? amount : allocation.received;`. Use `allocatable` instead of `allocation.received` for the waterfall allocation. Set `allocation.refund` to include `allocation.received - allocatable` surplus. Remove the pre-pull amortization guard (`if (!agreement.allowAmortization && amount > interestDue)`) since the post-allocation logic handles it correctly with the capped amount.

---

**File**: `src/equallend/EqualLendDirectRollingLifecycleFacet.sol`

**Function**: `repayRollingInFull`

**Specific Changes**:
4. **Replace `minReceived` with `maxInterestDue` (Finding 3)**: Change the function signature from `repayRollingInFull(uint256 agreementId, uint256 maxPayment, uint256 minReceived)` to `repayRollingInFull(uint256 agreementId, uint256 maxPayment, uint256 maxInterestDue)`. Remove the bare `minReceived;` statement. After computing `interestDue`, add: `if (interestDue > maxInterestDue) revert RollingError_InterestExceedsMax(interestDue, maxInterestDue);`

**Function**: `_settleRollingDefaultPath`

**Specific Changes**:
5. **Rebase penalty onto realized recovery value (Finding 6)**: Replace `settlement.penaltyPaid = (totalDebt * store.rollingConfig.defaultPenaltyBps) / LibEqualLendDirectStorage.BPS_DENOMINATOR;` with:
   ```
   uint256 penaltyBase = settlement.collateralSeized < totalDebt ? settlement.collateralSeized : totalDebt;
   settlement.penaltyPaid = (penaltyBase * store.rollingConfig.defaultPenaltyBps) / LibEqualLendDirectStorage.BPS_DENOMINATOR;
   ```
   Keep the existing `if (settlement.penaltyPaid > settlement.collateralSeized)` clamp.

---

**File**: `src/libraries/LibEqualLendDirectRolling.sol`

**Function**: `applyPaymentState`

**Specific Changes**:
6. **Separate overdue arrears cure from current-period accrual (Finding 5)**: Change the `nextDue` advancement condition from `if (agreement.arrears == 0 && snapshot.dueCountDelta != 0)` to `if (remainingArrears == 0 && snapshot.dueCountDelta != 0)`. This advances `nextDue` when historical overdue arrears are fully paid, regardless of whether current-period interest remains unpaid. The unpaid current-period interest is still folded into `agreement.arrears` for tracking, but it no longer blocks checkpoint advancement.

---

**File**: `src/equallend/EqualLendDirectFixedAgreementFacet.sol`

**Function**: `_quoteFixedFees`

**Specific Changes**:
7. **Round fixed interest up (Finding 8)**: Replace `quote.interestAmount = Math.mulDiv(principal, uint256(aprBps) * effectiveDuration, YEAR * BPS_DENOMINATOR);` with `quote.interestAmount = Math.mulDiv(principal, uint256(aprBps) * effectiveDuration, YEAR * BPS_DENOMINATOR, Math.Rounding.Ceil);`

**Function**: `_validateLenderRatioFill`

**Specific Changes**:
8. **Round collateral up (Lead)**: Replace `collateralRequired = Math.mulDiv(principalAmount, offer.priceNumerator, offer.priceDenominator);` with `collateralRequired = Math.mulDiv(principalAmount, offer.priceNumerator, offer.priceDenominator, Math.Rounding.Ceil);`

---

**File**: `src/equallend/PoolManagementFacet.sol`

**Function**: `setAumFee`

**Specific Changes**:
9. **Normalize access control (Lead)**: Replace `LibAccess.enforceTimelockOrOwnerIfUnset();` with `LibAccess.enforceOwnerOrTimelock();`

---

**New Error Declarations** (in `src/libraries/Errors.sol` or inline):
- `RollingError_InterestExceedsMax(uint256 actual, uint256 max)` — for the `maxInterestDue` guard
- `RollingError_PaymentCapReached()` — for the `maxPaymentCount` enforcement

## Testing Strategy

### Validation Approach

The testing strategy follows the bug-condition methodology: first surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real deposits, real offers, real agreement origination, real payments, real defaults, and real finalization per workspace guidelines.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures. Finding 3 is the one intentional exception: that test demonstrates the bug by succeeding when the dead guard should have protected the borrower.

**Test Cases**:
1. **Dead `minReceived` test**: Create rolling agreement, make payment with `minReceived` set, verify `minReceived` has no effect (payment succeeds regardless of interest growth). This is the intentional positive-control test that passes on unfixed code to prove the guard is dead.
2. **Arrears trap test**: Create rolling agreement, let multiple periods pass, pay exactly historical arrears, verify `nextDue` does NOT advance and `recoverRolling` is callable
3. **Inflated penalty test**: Create rolling agreement, let it default with large accrued interest, verify penalty is computed from `totalDebt` not `min(collateral, totalDebt)`
4. **Fixed zero interest test**: Create fixed offer with small principal/APR/duration, verify interest truncates to zero
5. **Collateral rounding test**: Create lender-ratio offer with parameters that produce fractional collateral, verify floor rounding
6. **Over-receive revert test**: Create amortization-disabled rolling agreement, mock `pullAtLeast` over-delivery, verify revert
7. **Payment cap bypass test**: Create rolling agreement, advance to `maxPaymentCount`, verify `makeRollingPayment` still succeeds
8. **`setAumFee` owner lockout test**: Configure timelock, call `setAumFee` as owner, verify revert

### Fix Checking

**Goal**: Verify that for all inputs where each bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Finding 3
FOR ALL rollingPayment WHERE totalInterest > maxInterestDue DO
  ASSERT REVERTS makeRollingPayment_fixed(payment)
END FOR

// Finding 5
FOR ALL rollingPayment WHERE historicalArrearsPaid >= historicalArrearsDue AND currentInterestRemaining > 0 DO
  result := makeRollingPayment_fixed(payment)
  ASSERT agreement.nextDue advanced to next checkpoint
  ASSERT recoverRolling REVERTS (not yet past new grace period)
END FOR

// Finding 6
FOR ALL rollingDefault WHERE applyPenalty AND totalDebt > collateralSeized DO
  result := _settleRollingDefaultPath_fixed(default)
  ASSERT penaltyPaid == (min(collateralSeized, totalDebt) * penaltyBps) / BPS_DENOM
END FOR

// Finding 8
FOR ALL fixedQuote WHERE principal > 0 AND aprBps > 0 AND effectiveDuration > 0 DO
  result := _quoteFixedFees_fixed(quote)
  ASSERT result.interestAmount >= 1
END FOR

// Collateral rounding
FOR ALL lenderRatioFill DO
  result := _validateLenderRatioFill_fixed(fill)
  ASSERT collateralRequired >= ceil(principal * priceNum / priceDenom)
END FOR

// Over-receive
FOR ALL rollingPayment WHERE !allowAmortization AND received > amount DO
  result := makeRollingPayment_fixed(payment)
  ASSERT no revert AND surplus refunded
END FOR

// Payment cap
FOR ALL rollingPayment WHERE paymentCount >= maxPaymentCount DO
  ASSERT REVERTS makeRollingPayment_fixed(payment)
END FOR

// setAumFee
FOR ALL setAumFee WHERE callerIsOwner AND timelockConfigured DO
  ASSERT succeeds setAumFee_fixed(call)
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug conditions do NOT hold, the fixed functions produce the same result as the original functions.

**Test Cases**:
1. **Rolling payment preservation**: Valid payment with satisfied guards, verify allocation waterfall, position settlement, lender capital restoration, event emission unchanged
2. **Rolling full repay preservation**: Valid full repay, verify total-due computation, fund pull, settlement, finalization unchanged
3. **Rolling recovery preservation**: Genuinely overdue agreement past grace, verify `recoverRolling` still works
4. **Rolling default settlement preservation**: Default with `applyPenalty == false`, verify penalty skipped entirely
5. **Fixed origination preservation**: Normal fixed agreement, verify interest, platform fee, due timestamp unchanged
6. **Fixed zero-APR preservation**: `aprBps == 0`, verify zero interest still produced
7. **Ratio fill preservation**: Valid lender-ratio fill, verify validation unchanged
8. **AUM fee timelock preservation**: Timelock calls `setAumFee`, verify still works
9. **AUM fee bounds preservation**: Out-of-bounds fee, verify revert unchanged
10. **Early repay guard preservation**: `allowEarlyRepay == false`, verify `repayRollingInFull` still reverts

### Integration Tests

- Full rolling lifecycle: originate → make payments → repay in full — proves guard and payment-state fixes end-to-end
- Rolling catch-up lifecycle: originate → miss payments → pay historical arrears → verify not immediately recoverable → make current payment → verify clean state
- Rolling default lifecycle: originate → let default → recover → verify penalty based on realized value
- Fixed small-loan lifecycle: originate with small parameters → verify nonzero interest charged
- Lender-ratio fill lifecycle: create ratio offer → fill → verify collateral rounded up
- Payment cap lifecycle: originate → make `maxPaymentCount` payments → verify next payment reverts → repay in full succeeds
- AUM fee admin lifecycle: configure timelock → owner sets fee → verify success
