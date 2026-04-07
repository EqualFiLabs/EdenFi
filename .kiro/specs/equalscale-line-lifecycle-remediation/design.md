# EqualScale Line Lifecycle Remediation — Bugfix Design

## Overview

Eleven remediation items in the EqualScale credit-line lifecycle require coordinated fixes across charge-off debt cleanup, payment checkpoint guardrails, interest-loss recognition, runoff cure enforcement, reentrancy hardening, telemetry overflow, lifecycle-control bypass, allocation fairness, view cleanup, and borrower-profile mutability. The fix strategy preserves the existing EqualFi credit-line model while correcting debt-state leaks, state-machine inconsistencies, allocation stranding, and lifecycle-policy gaps.

Canonical Track: Track D. Payment Lifecycle and Delinquency State Machines (EqualScale portion)
Phase: Phase 2. Product Lifecycle Fixes

Source report: `assets/findings/EdenFi-equalscale-pashov-ai-audit-report-20260405-011500.md`
Remediation plan: `assets/remediation/EqualScale-findings-1-7-remediation-plan.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across eleven items that trigger phantom debt, aggressive checkpoint rollforward, silent interest-loss discard, sub-floor cure, reentrancy surface, counter overflow, freeze bypass, value stranding, stale views, mutable treasury, or deterministic remainder bias
- **Property (P)**: The desired correct behavior for each item
- **Preservation**: Existing charge-off flow, repayment allocation, draw mechanics, delinquency/cure transitions, refinancing flow, activation/commitment flow, collateral recovery, and view functions that must remain unchanged
- **`reduceBorrowerDebt`**: Shared helper in `LibEqualScaleAlphaShared` that decrements `userSameAssetDebt`, `userActiveCreditStateDebt`, and `activeCreditPrincipalTotal` for a borrower position
- **`finalizeClosedLine`**: Shared helper that settles lender positions, releases commitment reservations, unlocks collateral, zeroes line state, and sets `Closed` status
- **`finalizeChargedOffLine`**: Thin wrapper that calls `finalizeClosedLine` with `ChargedOff` as the previous status
- **`advanceDueCheckpoint`**: Helper that increments `nextDueAt` by `paymentIntervalSecs` and resets per-period counters
- **`cureLineIfCovered`**: Helper that transitions `Delinquent` lines to `Active`/`Runoff` and `Runoff` lines back to `Active` via `restartLineTerm`
- **`restartLineTerm`**: Helper that resets a line to `Active` with fresh term timestamps
- **`minimumViableLine`**: Per-line proposal term defining the economic floor for line activation and restart
- **`missedPayments`**: `uint8` counter on `CreditLine` tracking delinquency events
- **`allocateRecovery`**: Helper distributing recovered collateral value across lender commitments pro-rata by `principalExposed`
- **`allocateWriteDown`**: Helper distributing principal write-down across lender commitments pro-rata by `principalExposed`
- **`allocateDrawExposure`**: Helper distributing draw exposure across lender commitments pro-rata by `committedAmount`
- **`allocateRepayment`**: Helper distributing repayment across lender commitments pro-rata by `principalExposed`

## Bug Details

### Bug Condition

The bugs manifest across eleven distinct conditions in the EqualScale contracts. Together they represent phantom debt leaks, aggressive state advancement, silent loss discard, sub-floor state transitions, unnecessary callback surface, counter overflow, governance bypass, allocation stranding, stale views, mutable payout routing, and deterministic remainder bias.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 1: chargeOffLine never clears borrower debt
  IF input.finding == 1 THEN
    RETURN input.context.isChargeOff
           AND input.context.lineOutstandingPrincipal > 0

  // Finding 5: Checkpoint advancement too aggressive
  IF input.finding == 5 THEN
    RETURN input.context.isRepayLine
           AND input.context.repeatedMinimumPaymentsInSameBlock > 1

  // Finding 5b: nextDueAt overshoots termEndAt
  IF input.finding == 5 THEN
    RETURN input.context.isAdvanceDueCheckpoint
           AND input.context.nextDueAt + paymentIntervalSecs > input.context.termEndAt

  // Finding 6: Charge-off drops accrued interest
  IF input.finding == 6 THEN
    RETURN input.context.isChargeOff
           AND input.context.accruedInterest > 0

  // Finding 7: Runoff cure below minimumViableLine
  IF input.finding == 7 THEN
    RETURN input.context.isRunoffCure
           AND input.context.currentCommittedAmount < input.context.minimumViableLine
           AND input.context.outstandingPrincipal <= input.context.currentCommittedAmount

  // Finding 4: Native draw without nonReentrant
  IF input.finding == 4 THEN
    RETURN input.context.isDraw
           AND input.context.isNativeSettlement

  // Lead: missedPayments overflow
  IF input.finding == 8 THEN
    RETURN input.context.isMarkDelinquent
           AND input.context.missedPayments == 255

  // Lead: Frozen -> Refinancing bypass
  IF input.finding == 9 THEN
    RETURN input.context.isEnterRefinancing
           AND input.context.lineStatus == Frozen

  // Lead: allocateRecovery value stranding
  IF input.finding == 10 THEN
    RETURN input.context.isAllocateRecovery
           AND input.context.commitmentSetSkewed
           AND input.context.lastCommitmentCapReached

  // Lead: Treasury wallet mutable during live lines
  IF input.finding == 11 THEN
    RETURN input.context.isUpdateBorrowerProfile
           AND input.context.treasuryWalletChanged
           AND input.context.hasNonClosedLines

  // Lead: Pro-rata remainder always favors last commitment
  IF input.finding == 12 THEN
    RETURN input.context.isProRataAllocation
           AND input.context.remainderDust > 0

  RETURN false
END FUNCTION
```

### Examples

- **Finding 1**: Borrower draws 100e18, line goes delinquent, charge-off fires. `finalizeClosedLine` zeroes `line.outstandingPrincipal` but `settlementPool.userSameAssetDebt[borrowerKey]` still shows 100e18. Borrower cannot withdraw or clean up membership. Expected: `reduceBorrowerDebt` called before finalization, debt state zeroed.
- **Finding 5**: Borrower makes 3 minimum payments in one block. Each triggers `advanceDueCheckpoint`. `nextDueAt` advances by 3 periods. Expected: at most 1 period advancement per due window.
- **Finding 5b**: `nextDueAt = termEndAt - 1 day`, `paymentIntervalSecs = 30 days`. After checkpoint: `nextDueAt = termEndAt + 29 days`. Expected: capped at `termEndAt`.
- **Finding 6**: Line has 100e18 principal, 15e18 accrued interest. Charge-off recovers 80e18 collateral, writes down 20e18 principal. 15e18 interest loss silently zeroed. Expected: 15e18 recorded as lender interest loss.
- **Finding 7**: `minimumViableLine = 50e18`, `currentCommittedAmount = 30e18`, `outstandingPrincipal = 25e18`. `cureLineIfCovered` calls `restartLineTerm(line, 30e18)`. Line returns to `Active` at 30e18 below the 50e18 floor. Expected: line stays in `Runoff`.
- **Finding 4**: Native-asset draw to a reentering treasury wallet contract. No `nonReentrant` guard. Callback can reenter `draw` or `repayLine`. Expected: `nonReentrant` blocks reentry.
- **`missedPayments` overflow**: 256th delinquency event. `unchecked { ++line.missedPayments; }` wraps `uint8` from 255 to 0. Expected: checked arithmetic reverts or counter widened.
- **Freeze bypass**: Governance freezes line. Term expires. Anyone calls `enterRefinancing`. `Frozen` is in the allowed set. Line moves to `Refinancing`. Expected: revert for `Frozen` lines.
- **`allocateRecovery` stranding**: 3 lenders with exposures [10e18, 10e18, 80e18]. Recovery = 50e18. Early shares computed against total 100e18: lender1 gets 5e18, lender2 gets 5e18. Remaining = 40e18. Last lender capped at 80e18 exposure, gets 40e18. Total credited = 50e18. But with skewed sets where early rounding leaves dust, the last lender's cap can strand value. Expected: remaining-amount/remaining-exposure pattern prevents stranding.
- **Treasury wallet lock**: Borrower has active line. Calls `updateBorrowerProfile` with new treasury. Draw proceeds now go to new address. Expected: revert while any line is non-closed.
- **Pro-rata remainder**: 3 lenders, repayment = 100e18. Pro-rata shares: 33e18, 33e18, 34e18 (last gets remainder). Over many allocations, last commitment accumulates dust advantage. Expected: lightweight fairness improvement.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Charge-off flow (interest accrual, collateral recovery, recovery allocation, principal write-down, status transition, finalization) must continue to work correctly with the addition of debt cleanup and interest-loss recognition
- Repayment allocation waterfall (interest → principal), borrower debt reduction, position settlement, checkpoint advancement (when legitimately earned), and cure logic must remain unchanged for normal single-payment flows
- Draw capacity checks, principal updates, debt increases, exposure allocation, fund transfer, and event emission must remain unchanged (only the reentrancy guard is added)
- Delinquency eligibility, grace period enforcement, status transition, and event emission must remain unchanged (only the counter arithmetic changes)
- Refinancing entry for `Active` lines past term expiry, commitment roll/exit, and resolution must remain unchanged
- Activation, commitment, and cancellation flows must remain unchanged
- Collateral recovery `trackedBalance` updates without `totalDeposits` minting must remain unchanged
- `getBorrowerLineIds` raw historical view must remain unchanged
- `updateBorrowerProfile` for `bankrToken` and `metadataHash` must remain unchanged regardless of line status

**Scope:**
All inputs that do NOT match any of the eleven bug conditions should be completely unaffected by these fixes.

## Hypothesized Root Cause

1. **Finding 1 — Missing `reduceBorrowerDebt` in charge-off path**: `chargeOffLine` calls `finalizeChargedOffLine` → `finalizeClosedLine` which zeroes `line.outstandingPrincipal` directly. The normal repayment path calls `reduceBorrowerDebt` when principal is reduced, but the charge-off path skips this because it writes down principal via `allocateWriteDown` (which only touches commitment-level state) and then zeroes the line field. The settlement-pool debt state (`userSameAssetDebt`, `userActiveCreditStateDebt`, `activeCreditPrincipalTotal`) created at draw time is never decremented.

2. **Finding 5 — Unbounded checkpoint advancement**: `advanceDueCheckpoint` unconditionally adds `paymentIntervalSecs` to `nextDueAt` without capping at `termEndAt`. Additionally, `repayLine` calls `advanceDueCheckpoint` every time `minimumDueSatisfied` is true. Multiple repayments in the same block can each satisfy the minimum due (since `paidSinceLastDue` accumulates and `advanceDueCheckpoint` resets it), allowing multi-period rollforward.

3. **Finding 6 — Silent interest zeroing**: `chargeOffLine` calls `accrueInterest` to bring interest current, then allocates recovery and write-down against `principalExposed` only. `finalizeClosedLine` then zeroes `line.accruedInterest` without recording the interest component as a lender loss. The interest is simply discarded.

4. **Finding 7 — Missing `minimumViableLine` check in runoff cure**: `cureLineIfCovered` checks `outstandingPrincipal <= currentCommittedAmount` for `Runoff` lines but does not check `currentCommittedAmount >= minimumViableLine`. The refinancing resolution path (`resolveRefinancing`) does enforce this floor, creating an inconsistency.

5. **Finding 4 — Missing reentrancy guard**: `EqualScaleAlphaFacet` does not inherit `ReentrancyGuardModifiers`. The `draw` function transfers native ETH to a borrower-controlled address via `LibCurrency.transfer` which uses a raw `.call{value}`. State is committed before transfer (CEI), but the callback surface is unnecessarily wide without the guard.

6. **`missedPayments` overflow**: `markDelinquent` uses `unchecked { ++line.missedPayments; }` where `missedPayments` is `uint8`. After 255 delinquency events, the counter wraps to 0.

7. **Freeze bypass**: `enterRefinancing` allows both `Active` and `Frozen` statuses. A governance freeze is meant to halt lifecycle progression, but the `Frozen` allowance lets anyone bypass it once term expires.

8. **`allocateRecovery` stranding**: The allocator computes early shares against the original `totalExposed` using `Math.mulDiv(recoveryAmount, commitment.principalExposed, totalExposed)`. The final commitment receives the whole `remainingRecovery`, capped by its `principalExposed`. In skewed sets, rounding on early shares can leave `remainingRecovery` larger than the last commitment's cap, stranding the excess.

9. **Treasury wallet mutability**: `updateBorrowerProfile` has no lifecycle guard. It directly sets `profile.treasuryWallet` without checking whether any line is active.

10. **Pro-rata remainder bias**: All four allocation helpers (`allocateRepayment`, `allocateRecovery`, `allocateWriteDown`, `allocateDrawExposure`) use the same pattern: compute pro-rata shares for all but the last commitment, give the last commitment the full remainder. This deterministically favors the last commitment.

## Correctness Properties

Property 1: Bug Condition — Charge-off borrower debt cleanup (Finding 1)

_For any_ charge-off where `line.outstandingPrincipal > 0`, the fixed `chargeOffLine` SHALL call `reduceBorrowerDebt` before `finalizeClosedLine`, leaving `userSameAssetDebt` and `activeCreditPrincipalTotal` reduced by the written-down principal.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — Checkpoint advancement guardrails (Finding 5)

_For any_ `advanceDueCheckpoint` call, the fixed function SHALL cap `nextDueAt` at `termEndAt`. _For any_ sequence of repayments in the same block, the fixed `repayLine` SHALL advance `nextDueAt` by at most one period per due window.

**Validates: Requirements 2.3, 2.4**

Property 3: Bug Condition — Charge-off interest-loss recognition (Finding 6)

_For any_ charge-off where `accruedInterest > 0`, the fixed `chargeOffLine` SHALL record the accrued interest as lender-side interest loss before finalization zeroes line state.

**Validates: Requirements 2.5, 2.6**

Property 4: Bug Condition — Runoff cure `minimumViableLine` enforcement (Finding 7)

_For any_ `Runoff` line where `currentCommittedAmount < minimumViableLine`, the fixed `cureLineIfCovered` SHALL NOT call `restartLineTerm`, leaving the line in `Runoff`.

**Validates: Requirements 2.7, 2.8**

Property 5: Bug Condition — Native draw reentrancy guard (Finding 4)

_For any_ `draw` call on a native-asset settlement pool, the fixed function SHALL apply `nonReentrant`, preventing reentrant calls through the borrower treasury callback.

**Validates: Requirements 2.9**

Property 6: Bug Condition — `missedPayments` checked arithmetic (Lead)

_For any_ `markDelinquent` call where `missedPayments == 255`, the fixed function SHALL revert (checked overflow) instead of wrapping to 0.

**Validates: Requirements 2.10**

Property 7: Bug Condition — Freeze-to-refinancing block (Lead)

_For any_ `enterRefinancing` call on a `Frozen` line, the fixed function SHALL revert.

**Validates: Requirements 2.11**

Property 8: Bug Condition — `allocateRecovery` remaining-amount pattern (Lead)

_For any_ recovery allocation across commitments, the fixed `allocateRecovery` SHALL use a remaining-amount / remaining-exposure pattern, fully crediting all recoverable value with no stranded remainder.

**Validates: Requirements 2.12, 2.13**

Property 9: Bug Condition — Treasury wallet lock (Lead)

_For any_ `updateBorrowerProfile` call that changes `treasuryWallet` while any borrower line is non-closed, the fixed function SHALL revert.

**Validates: Requirements 2.16, 2.17**

Property 10: Bug Condition — Filtered borrower line view (Lead)

_For any_ call to the new filtered view, the fixed function SHALL return only non-closed, non-canceled line IDs.

**Validates: Requirements 2.14, 2.15**

Property 11: Bug Condition — Pro-rata remainder fairness (Lead)

_For any_ pro-rata allocation, the fixed helpers SHALL use a remaining-amount / remaining-exposure pattern that avoids deterministic last-commitment favoritism.

**Validates: Requirements 2.18**

Property 12: Preservation — Charge-off, repayment, draw, delinquency, refinancing, activation, collateral recovery, views, and profile flows

_For any_ input that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.1–3.14**

## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

---

**File**: `src/equalscale/LibEqualScaleAlphaLifecycle.sol`

**Function**: `chargeOffLine`

**Specific Changes**:
1. **Borrower debt cleanup (Finding 1)**: Before calling `finalizeChargedOffLine`, add:
   ```
   if (line.outstandingPrincipal != 0) {
       Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
       LibEqualScaleAlphaShared.settleSettlementPosition(line.settlementPoolId, line.borrowerPositionKey);
       LibEqualScaleAlphaShared.reduceBorrowerDebt(
           settlementPool, line.settlementPoolId, line.borrowerPositionKey, line.outstandingPrincipal
       );
   }
   ```

2. **Interest-loss recognition (Finding 6)**: After `accrueInterest` and before finalization, snapshot `line.accruedInterest`. If nonzero, allocate interest loss across commitments as telemetry (add `interestLoss` field to `Commitment` struct or emit event-level telemetry). The simplest approach: add a `uint256 interestLossAllocated` field to `Commitment` and distribute `accruedInterest` pro-rata by `principalExposed` before write-down.

---

**Function**: `enterRefinancing`

**Specific Changes**:
3. **Block `Frozen -> Refinancing` (Lead)**: Remove `Frozen` from the allowed status set:
   ```diff
   - if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active
   -     && line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Frozen) {
   + if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active) {
   ```

---

**Function**: `markDelinquent`

**Specific Changes**:
4. **Checked `missedPayments` increment (Lead)**: Remove the `unchecked` block:
   ```diff
   - unchecked {
   -     ++line.missedPayments;
   - }
   + ++line.missedPayments;
   ```

---

**File**: `src/equalscale/LibEqualScaleAlphaShared.sol`

**Function**: `advanceDueCheckpoint`

**Specific Changes**:
5. **Cap `nextDueAt` at `termEndAt` (Finding 5)**: Add cap after increment:
   ```
   uint40 newDueAt = line.nextDueAt + line.paymentIntervalSecs;
   if (newDueAt > line.termEndAt) newDueAt = line.termEndAt;
   line.nextDueAt = newDueAt;
   ```

6. **One-period-per-window guard (Finding 5)**: Add the guard in `repayLine`, not as an ambiguous helper-side alternative. `repayLine` SHALL snapshot the due checkpoint before allocation and allow at most one `advanceDueCheckpoint` call per transaction / due window satisfaction event. Do not rely solely on `block.timestamp < line.nextDueAt`, because a deeply overdue line can remain behind wall-clock time even after one advancement. The invariant is: once the currently due window has been satisfied and advanced, repeated same-block repayments cannot advance a second time until a later checkpoint becomes newly due.

---

**Function**: `cureLineIfCovered`

**Specific Changes**:
7. **Enforce `minimumViableLine` on runoff cure (Finding 7)**: Add floor check before `restartLineTerm`:
   ```diff
     if (
         line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff
             && line.outstandingPrincipal <= line.currentCommittedAmount
   +         && line.currentCommittedAmount >= line.minimumViableLine
     ) {
         restartLineTerm(line, line.currentCommittedAmount);
     }
   ```

---

**Function**: `allocateRecovery`

**Specific Changes**:
8. **Remaining-amount / remaining-exposure pattern (Lead)**: Replace the current allocator with:
   ```
   uint256 remainingRecovery = recoveryAmount > totalExposed ? totalExposed : recoveryAmount;
   uint256 remainingExposed = totalExposed;
   for (uint256 i = 0; i < len; i++) {
       // ... skip inactive commitments ...
       uint256 recoveryShare;
       if (remainingExposed == commitment.principalExposed) {
           recoveryShare = remainingRecovery; // last active commitment
       } else {
           recoveryShare = Math.mulDiv(remainingRecovery, commitment.principalExposed, remainingExposed);
       }
       if (recoveryShare > commitment.principalExposed) {
           recoveryShare = commitment.principalExposed;
       }
       commitment.recoveryReceived += recoveryShare;
       commitment.principalExposed -= recoveryShare;
       remainingRecovery -= recoveryShare;
       remainingExposed -= (commitment.principalExposed + recoveryShare); // pre-deduction exposure
   }
   ```
   The loop bookkeeping is part of the remediation, not an open question: snapshot `exposureBefore = commitment.principalExposed` before any mutation and decrement `remainingExposed` by `exposureBefore` after the share is computed. This keeps the denominator aligned with the unreconciled exposure set and prevents stranding.

---

**Function**: `allocateWriteDown`, `allocateRepayment`, `allocateDrawExposure`

**Specific Changes**:
9. **Pro-rata remainder fairness (Lead)**: Apply the same remaining-amount / remaining-exposure pattern to all four allocation helpers. This is a structural refactor of the loop pattern, not a semantic change — total amounts conserved, only remainder distribution changes.

---

**File**: `src/equalscale/EqualScaleAlphaFacet.sol`

**Function**: `draw`

**Specific Changes**:
10. **Add `nonReentrant` (Finding 4)**: Make `EqualScaleAlphaFacet` inherit `ReentrancyGuardModifiers` and add `nonReentrant` to `draw`:
    ```diff
    - function draw(uint256 lineId, uint256 amount) external {
    + function draw(uint256 lineId, uint256 amount) external nonReentrant {
    ```

---

**Function**: `updateBorrowerProfile`

**Specific Changes**:
11. **Treasury wallet lock (Lead)**: Before allowing `treasuryWallet` change, scan borrower lines:
    ```
    if (profile.treasuryWallet != treasuryWallet) {
        uint256[] storage lineIds = store.borrowerLineIds[borrowerPositionKey];
        for (uint256 i = 0; i < lineIds.length; i++) {
            if (store.lines[lineIds[i]].status != LibEqualScaleAlphaStorage.CreditLineStatus.Closed) {
                revert TreasuryWalletLockedDuringLiveLines(borrowerPositionKey);
            }
        }
    }
    ```

---

**File**: `src/equalscale/EqualScaleAlphaViewFacet.sol`

**Specific Changes**:
12. **Filtered borrower line view (Lead)**: Add a new view function:
    ```
    function getActiveBorrowerLineIds(uint256 borrowerPositionId) external view returns (uint256[] memory) {
        bytes32 borrowerPositionKey = _positionNftContract().getPositionKey(borrowerPositionId);
        uint256[] storage allIds = LibEqualScaleAlphaStorage.s().borrowerLineIds[borrowerPositionKey];
        // Count live lines, then build filtered array
        // Exclude Closed status and canceled proposals (status check on each line)
    }
    ```

---

**New Error Declarations** (in `src/equalscale/IEqualScaleAlphaErrors.sol`):
- `TreasuryWalletLockedDuringLiveLines(bytes32 borrowerPositionKey)` — for treasury wallet lock
- `RefinancingNotAllowedWhileFrozen(uint256 lineId)` — for freeze bypass block (or reuse existing `InvalidProposalTerms`)

## Testing Strategy

### Validation Approach

The testing strategy follows the bug-condition methodology: first surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real deposits, real proposals, real commitments, real activation, real draws, real repayments, real delinquency, and real charge-off per workspace guidelines.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures.

**Test Cases**:
1. **Charge-off debt leak test**: Create line, draw, go delinquent, charge off, assert `userSameAssetDebt` is zeroed. On unfixed code this will FAIL because `reduceBorrowerDebt` is never called.
2. **Checkpoint multi-advance test**: Create line, draw, warp past due, make 3 minimum payments in one tx, assert `nextDueAt` advanced by only 1 period. On unfixed code this will FAIL because each payment advances the checkpoint.
3. **Checkpoint overshoot test**: Create line near term end, advance checkpoint, assert `nextDueAt <= termEndAt`. On unfixed code this will FAIL because no cap exists.
4. **Interest-loss discard test**: Create line, draw, accrue interest, charge off, assert lender commitments record interest loss. On unfixed code this will FAIL because interest is silently zeroed.
5. **Runoff cure below floor test**: Create line, activate, draw, enter refinancing, exit commitments to reduce below `minimumViableLine`, resolve to `Runoff`, repay to cure, assert line stays in `Runoff`. On unfixed code this will FAIL because `cureLineIfCovered` restarts without floor check.
6. **Native draw reentrancy test**: Create line with native settlement, deploy reentering treasury, draw, assert reentry blocked. On unfixed code this will FAIL because no `nonReentrant` guard exists.
7. **`missedPayments` overflow test**: Create line, cycle through 256 delinquency events, assert `missedPayments` does not wrap to 0. On unfixed code this will FAIL because `unchecked` wraps.
8. **Freeze bypass test**: Create line, freeze, warp past term, call `enterRefinancing`, assert revert. On unfixed code this will FAIL because `Frozen` is in the allowed set.
9. **Recovery stranding test**: Create line with 3 skewed lender commitments, charge off with partial recovery, assert all recovery is credited. On unfixed code this may FAIL if rounding strands value.
10. **Treasury wallet lock test**: Create line, activate, call `updateBorrowerProfile` with new treasury, assert revert. On unfixed code this will FAIL because no lifecycle guard exists.

### Fix Checking

**Goal**: Verify that for all inputs where each bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Finding 1
FOR ALL chargeOff WHERE outstandingPrincipal > 0 DO
  result := chargeOffLine_fixed(lineId)
  ASSERT settlementPool.userSameAssetDebt[borrowerKey] == 0
  ASSERT settlementPool.activeCreditPrincipalTotal reduced by writtenDown amount
END FOR

// Finding 5
FOR ALL repayLine WHERE repeatedPayments > 1 DO
  nextDueBefore := line.nextDueAt
  FOR EACH payment DO
    repayLine_fixed(lineId, amount)
  END FOR
  ASSERT line.nextDueAt <= nextDueBefore + paymentIntervalSecs
  ASSERT line.nextDueAt <= line.termEndAt
END FOR

// Finding 6
FOR ALL chargeOff WHERE accruedInterest > 0 DO
  result := chargeOffLine_fixed(lineId)
  ASSERT sum(commitment.interestLossAllocated) == accruedInterest
END FOR

// Finding 7
FOR ALL runoffCure WHERE currentCommittedAmount < minimumViableLine DO
  cureLineIfCovered_fixed(line, true)
  ASSERT line.status == Runoff
END FOR

// Finding 4
FOR ALL draw WHERE isNativeSettlement DO
  ASSERT nonReentrant guard active
END FOR

// missedPayments
FOR ALL markDelinquent WHERE missedPayments == 255 DO
  ASSERT REVERTS markDelinquent_fixed(lineId)
END FOR

// Freeze bypass
FOR ALL enterRefinancing WHERE status == Frozen DO
  ASSERT REVERTS enterRefinancing_fixed(lineId)
END FOR

// allocateRecovery
FOR ALL allocateRecovery WHERE skewedCommitments DO
  allocateRecovery_fixed(store, lineId, recoveryAmount)
  ASSERT sum(commitment.recoveryReceived) == min(recoveryAmount, totalExposed)
END FOR

// Treasury lock
FOR ALL updateBorrowerProfile WHERE treasuryChanged AND hasNonClosedLines DO
  ASSERT REVERTS updateBorrowerProfile_fixed(...)
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug conditions do NOT hold, the fixed functions produce the same result as the original functions.

**Test Cases**:
1. **Charge-off flow preservation**: Charge off a line with zero outstanding principal (already repaid), verify finalization unchanged
2. **Repayment preservation**: Single valid repayment, verify allocation waterfall, debt reduction, checkpoint advancement, cure logic unchanged
3. **Draw preservation**: ERC20 draw, verify capacity checks, principal updates, debt increases, exposure allocation, transfer unchanged
4. **Delinquency preservation**: Mark delinquent on eligible line, verify status transition, `delinquentSince`, `missedPayments` increment, event emission unchanged
5. **Refinancing preservation**: Enter refinancing on `Active` line past term, verify transition unchanged
6. **Activation/commitment preservation**: Full activation and commitment flow, verify unchanged
7. **Collateral recovery preservation**: Recovery moves backing without minting `totalDeposits`, verify unchanged
8. **View preservation**: `getBorrowerLineIds` returns full raw array, verify unchanged
9. **Profile preservation**: Update `bankrToken` and `metadataHash` while lines are active, verify unchanged

### Integration Tests

- Full charge-off lifecycle: propose → commit → activate → draw → delinquent → charge off → verify debt cleared, interest loss recorded, borrower can withdraw
- Repayment checkpoint lifecycle: propose → commit → activate → draw → warp past due → make repeated payments → verify single-period advancement and `termEndAt` cap
- Runoff cure lifecycle: propose → commit → activate → draw → refinance → exit commitments below floor → resolve to runoff → repay → verify stays in runoff
- Freeze integrity lifecycle: propose → commit → activate → freeze → warp past term → attempt refinancing (revert) → unfreeze → enter refinancing (success)
- Treasury lock lifecycle: propose → commit → activate → attempt treasury change (revert) → close line → treasury change (success)
- Recovery allocation lifecycle: propose → commit (3 skewed lenders) → activate → draw → charge off → verify full recovery credited
- Native draw reentrancy lifecycle: propose → commit → activate → draw with reentering treasury → verify blocked
