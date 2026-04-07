# Implementation Plan

- [ ] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — EqualScale Line Lifecycle Findings 1, 4, 5, 6, 7 and Agreed Leads
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/EqualScaleAlphaFacet.t.sol` for findings 1, 4, 5, 6, 7 and most leads; `test/EqualScaleAlphaViewFacet.t.sol` for borrower line view lead if separate view test file exists
  - Use real deposits, real proposals, real commitments, real activation, real draws, real repayments, real delinquency, real charge-off — no synthetic shortcuts
  - **Finding 1 — Charge-off debt leak**: Create line, commit, activate, draw, warp past delinquency + charge-off threshold, call `chargeOffLine`, assert `settlementPool.userSameAssetDebt[borrowerKey] == 0` and `activeCreditPrincipalTotal` reduced. On unfixed code this will FAIL because `reduceBorrowerDebt` is never called during charge-off.
  - **Finding 5 — Checkpoint multi-advance**: Create line, commit, activate, draw, warp past due + grace, make 2 minimum payments in sequence (same block), assert `nextDueAt` advanced by at most 1 period. On unfixed code this will FAIL because each payment triggers `advanceDueCheckpoint`.
  - **Finding 5b — Checkpoint overshoot**: Create line with short remaining term, commit, activate, draw, warp near `termEndAt`, make payment to trigger checkpoint, assert `nextDueAt <= termEndAt`. On unfixed code this will FAIL because no cap exists.
  - **Finding 6 — Interest-loss discard**: Create line, commit, activate, draw, warp to accrue interest, charge off, assert lender commitment records interest loss (not silently zeroed). On unfixed code this will FAIL because interest is discarded at finalization.
  - **Finding 7 — Runoff cure below floor**: Create line with `minimumViableLine`, commit, activate, draw, enter refinancing, exit commitments to reduce `currentCommittedAmount` below `minimumViableLine`, resolve to `Runoff`, repay enough to satisfy cure condition, assert line stays in `Runoff`. On unfixed code this will FAIL because `cureLineIfCovered` restarts without floor check.
  - **Finding 4 — Native draw reentrancy**: Create line with native settlement pool, deploy reentering treasury wallet contract, commit, activate, draw, assert reentry is blocked. On unfixed code this will FAIL because `draw` has no `nonReentrant` guard. Note: this test requires a narrow harness for the reentering treasury contract.
  - **Lead — `missedPayments` overflow**: Create line, cycle through delinquency events to reach `missedPayments == 255`, trigger one more `markDelinquent`, assert revert (checked overflow). On unfixed code this will FAIL because `unchecked` wraps to 0. Note: this test may use a synthetic shortcut to set `missedPayments` near 255 to avoid 256 real delinquency cycles.
  - **Lead — Freeze bypass**: Create line, commit, activate, admin freeze, warp past `termEndAt`, call `enterRefinancing`, assert revert. On unfixed code this will FAIL because `Frozen` is in the allowed status set.
  - **Lead — `allocateRecovery` stranding**: Create line with 3 lenders with skewed commitment amounts, commit, activate, draw, charge off with partial collateral recovery, assert `sum(commitment.recoveryReceived) == min(recoveryAmount, totalExposed)`. On unfixed code this may FAIL if rounding strands value in skewed sets.
  - **Lead — Treasury wallet lock**: Create line, commit, activate, call `updateBorrowerProfile` with a different `treasuryWallet`, assert revert. On unfixed code this will FAIL because no lifecycle guard exists.
  - **Lead — Pro-rata remainder fairness**: Create line with 3 lenders, make repayment, verify remainder dust is not always assigned to the last commitment. On unfixed code this will FAIL because the last commitment always gets the remainder.
  - Run tests on UNFIXED code: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 1.11, 1.12, 1.13, 1.14_

- [ ] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — EqualScale Line Lifecycle Unchanged Behavior
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/EqualScaleAlphaFacet.t.sol`
  - Use real deposits, real proposals, real commitments, real activation, real draws, real repayments, real delinquency, real charge-off — no synthetic shortcuts
  - **Charge-off flow preservation**: Charge off a line, verify interest accrual, collateral recovery, recovery allocation, principal write-down, status transition, and finalization work correctly
  - **Repayment preservation**: Make a valid single repayment, verify allocation waterfall (interest → principal), borrower debt reduction, position settlement, checkpoint advancement, cure logic, and event emission
  - **Draw preservation**: Draw from an active line with ERC20 settlement, verify capacity checks, principal updates, debt increases, exposure allocation, fund transfer, and events
  - **Delinquency preservation**: Mark delinquent on eligible line past grace, verify status transition, `delinquentSince`, `missedPayments` increment, and event
  - **Cure preservation**: Make payment on delinquent line satisfying minimum due, verify cure to `Active` or `Runoff` as appropriate
  - **Refinancing preservation**: Enter refinancing on `Active` line past term, verify transition to `Refinancing`
  - **Commitment roll/exit/resolve preservation**: Roll, exit, and resolve commitments during refinancing, verify correct behavior
  - **Activation/commitment preservation**: Full proposal → commit → activate flow, verify unchanged
  - **Close line preservation**: Repay fully, close line, verify finalization unchanged
  - **Collateral recovery preservation**: Verify recovery updates `trackedBalance` without minting `totalDeposits`
  - **View preservation**: `getBorrowerLineIds` returns full raw array including canceled proposals
  - **Profile preservation**: Update `bankrToken` and `metadataHash` while lines are active, verify allowed
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13, 3.14_

- [ ] 3. Fix Finding 1 — Charge-off borrower debt cleanup

  - [ ] 3.1 Add `reduceBorrowerDebt` call in `chargeOffLine` before finalization
    - In `src/equalscale/LibEqualScaleAlphaLifecycle.sol`, function `chargeOffLine`
    - Before the `finalizeChargedOffLine` call, add:
      ```
      if (line.outstandingPrincipal != 0) {
          Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
          LibEqualScaleAlphaShared.settleSettlementPosition(line.settlementPoolId, line.borrowerPositionKey);
          LibEqualScaleAlphaShared.reduceBorrowerDebt(
              settlementPool, line.settlementPoolId, line.borrowerPositionKey, line.outstandingPrincipal
          );
      }
      ```
    - This reuses the existing `reduceBorrowerDebt` helper that already handles `userSameAssetDebt`, `userActiveCreditStateDebt`, and `activeCreditPrincipalTotal`
    - _Bug_Condition: isBugCondition(finding=1) where isChargeOff AND outstandingPrincipal > 0_
    - _Expected_Behavior: borrower debt state cleared before line principal is zeroed_
    - _Preservation: Charge-off flow otherwise unchanged_
    - _Requirements: 2.1, 2.2, 3.1_

  - [ ] 3.2 Verify bug condition exploration test for Finding 1 now passes
    - **Property 1: Expected Behavior** — Charge-Off Debt Cleanup
    - **IMPORTANT**: Re-run the SAME Finding 1 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*ChargeOffDebt`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 1 bug is fixed)
    - _Requirements: 2.1, 2.2_

  - [ ] 3.3 Verify preservation tests still pass after Finding 1 fix
    - **Property 2: Preservation** — Charge-Off and Repayment Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.2, 3.3_

- [ ] 4. Fix Finding 6 — Charge-off interest-loss recognition

  - [ ] 4.1 Add interest-loss allocation in `chargeOffLine`
    - In `src/equalscale/LibEqualScaleAlphaLifecycle.sol`, function `chargeOffLine`
    - After `accrueInterest(line)` and before recovery/write-down, snapshot `uint256 accruedInterestAtChargeOff = line.accruedInterest`
    - After write-down allocation, if `accruedInterestAtChargeOff > 0`, distribute interest loss across commitments pro-rata by current `principalExposed`
    - Do not use original committed amount; the loss basis for this remediation is current lender exposure at charge-off time
    - Add `uint256 interestLossAllocated` field to `LibEqualScaleAlphaStorage.Commitment` struct
    - Emit interest loss in the `CreditLineChargedOff` event or a new `CreditLineInterestLossRecorded` event
    - _Bug_Condition: isBugCondition(finding=6) where isChargeOff AND accruedInterest > 0_
    - _Expected_Behavior: accrued interest recorded as lender-side interest loss_
    - _Preservation: Zero-interest charge-offs preserve current principal-only behavior_
    - _Requirements: 2.5, 2.6_

  - [ ] 4.2 Verify bug condition exploration test for Finding 6 now passes
    - **Property 1: Expected Behavior** — Interest-Loss Recognition
    - **IMPORTANT**: Re-run the SAME Finding 6 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*InterestLoss`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 6 bug is fixed)
    - _Requirements: 2.5_

  - [ ] 4.3 Verify preservation tests still pass after Finding 6 fix
    - **Property 2: Preservation** — Charge-Off Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1_

- [ ] 5. Fix Finding 7 — Runoff cure `minimumViableLine` enforcement

  - [ ] 5.1 Add `minimumViableLine` check in `cureLineIfCovered`
    - In `src/equalscale/LibEqualScaleAlphaShared.sol`, function `cureLineIfCovered`
    - Add `&& line.currentCommittedAmount >= line.minimumViableLine` to the `Runoff` restart condition:
      ```diff
        if (
            line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff
                && line.outstandingPrincipal <= line.currentCommittedAmount
      +         && line.currentCommittedAmount >= line.minimumViableLine
        ) {
            restartLineTerm(line, line.currentCommittedAmount);
        }
      ```
    - _Bug_Condition: isBugCondition(finding=7) where isRunoffCure AND currentCommittedAmount < minimumViableLine_
    - _Expected_Behavior: line stays in Runoff when below economic floor_
    - _Preservation: Cure at or above minimumViableLine still restarts as intended_
    - _Requirements: 2.7, 2.8_

  - [ ] 5.2 Verify bug condition exploration test for Finding 7 now passes
    - **Property 1: Expected Behavior** — Runoff Cure Floor
    - **IMPORTANT**: Re-run the SAME Finding 7 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*RunoffCureFloor`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 7 bug is fixed)
    - _Requirements: 2.7_

  - [ ] 5.3 Verify preservation tests still pass after Finding 7 fix
    - **Property 2: Preservation** — Cure and Refinancing Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.8, 3.9_

- [ ] 6. Fix Finding 5 — Payment checkpoint advancement guardrails

  - [ ] 6.1 Cap `nextDueAt` at `termEndAt` in `advanceDueCheckpoint`
    - In `src/equalscale/LibEqualScaleAlphaShared.sol`, function `advanceDueCheckpoint`
    - Replace unconditional increment with capped version:
      ```
      uint40 newDueAt = line.nextDueAt + line.paymentIntervalSecs;
      if (newDueAt > line.termEndAt) newDueAt = line.termEndAt;
      line.nextDueAt = newDueAt;
      ```
    - _Bug_Condition: isBugCondition(finding=5b) where nextDueAt + paymentIntervalSecs > termEndAt_
    - _Expected_Behavior: nextDueAt capped at termEndAt_
    - _Requirements: 2.3_

  - [ ] 6.2 Limit checkpoint advancement to one period per due window
    - In `src/equalscale/LibEqualScaleAlphaLifecycle.sol`, function `repayLine`
    - Snapshot the due checkpoint before allocation and allow at most one `advanceDueCheckpoint` call per transaction / due window satisfaction event
    - The guard must live in `repayLine`, where the code can distinguish "currently due window satisfied" from "extra payment after advancement"
    - Do not rely solely on `block.timestamp < line.nextDueAt`, because a deeply overdue line can still remain behind wall-clock time after one advancement
    - The required invariant is: repeated same-block repayments cannot roll `nextDueAt` forward more than one period for the same satisfied due window
    - _Bug_Condition: isBugCondition(finding=5) where repeatedMinimumPayments > 1 in same block_
    - _Expected_Behavior: at most one period advancement per due window_
    - _Preservation: Normal single-payment checkpoint advancement unchanged_
    - _Requirements: 2.4, 3.3_

  - [ ] 6.3 Verify bug condition exploration tests for Finding 5 now pass
    - **Property 1: Expected Behavior** — Checkpoint Guardrails
    - **IMPORTANT**: Re-run the SAME Finding 5 tests from task 1 — do NOT write new tests
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*Checkpoint`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 5 bugs are fixed)
    - _Requirements: 2.3, 2.4_

  - [ ] 6.4 Verify preservation tests still pass after Finding 5 fix
    - **Property 2: Preservation** — Repayment and Checkpoint Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.3, 3.4_

- [ ] 7. Fix Lead — Block `Frozen -> Refinancing` bypass

  - [ ] 7.1 Remove `Frozen` from `enterRefinancing` allowed statuses
    - In `src/equalscale/LibEqualScaleAlphaLifecycle.sol`, function `enterRefinancing`
    - Change the status check from:
      ```
      if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active
          && line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Frozen) {
      ```
    - To:
      ```
      if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active) {
      ```
    - _Bug_Condition: isBugCondition(finding=9) where isEnterRefinancing AND status == Frozen_
    - _Expected_Behavior: revert for Frozen lines_
    - _Preservation: Active lines past term still enter refinancing normally_
    - _Requirements: 2.11, 3.9_

  - [ ] 7.2 Verify bug condition exploration test for freeze bypass now passes
    - **Property 1: Expected Behavior** — Freeze Integrity
    - **IMPORTANT**: Re-run the SAME freeze bypass test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*FreezeBypass`
    - **EXPECTED OUTCOME**: Test PASSES (confirms freeze bypass bug is fixed)
    - _Requirements: 2.11_

  - [ ] 7.3 Verify preservation tests still pass after freeze bypass fix
    - **Property 2: Preservation** — Refinancing Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.9, 3.10_

- [ ] 8. Fix Lead — Harden `missedPayments` tracking

  - [ ] 8.1 Remove `unchecked` block from `markDelinquent`
    - In `src/equalscale/LibEqualScaleAlphaLifecycle.sol`, function `markDelinquent`
    - Replace:
      ```
      unchecked {
          ++line.missedPayments;
      }
      ```
    - With:
      ```
      ++line.missedPayments;
      ```
    - _Bug_Condition: isBugCondition(finding=8) where missedPayments == 255_
    - _Expected_Behavior: checked arithmetic reverts on overflow_
    - _Preservation: Normal delinquency increment unchanged_
    - _Requirements: 2.10, 3.7_

  - [ ] 8.2 Verify bug condition exploration test for `missedPayments` overflow now passes
    - **Property 1: Expected Behavior** — Checked Overflow
    - **IMPORTANT**: Re-run the SAME overflow test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*MissedPaymentsOverflow`
    - **EXPECTED OUTCOME**: Test PASSES (confirms overflow bug is fixed)
    - _Requirements: 2.10_

  - [ ] 8.3 Verify preservation tests still pass after `missedPayments` fix
    - **Property 2: Preservation** — Delinquency Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.7_

- [ ] 9. Fix Lead — `allocateRecovery` value-stranding fix

  - [ ] 9.1 Replace `allocateRecovery` with remaining-amount / remaining-exposure pattern
    - In `src/equalscale/LibEqualScaleAlphaShared.sol`, function `allocateRecovery`
    - Replace the current pattern (early shares against original `totalExposed`, last commitment gets remainder) with:
      ```
      uint256 remainingRecovery = recoveryAmount > totalExposed ? totalExposed : recoveryAmount;
      uint256 remainingExposed = totalExposed;
      for each active commitment:
          uint256 exposureBefore = commitment.principalExposed;
          uint256 recoveryShare;
          if (remainingExposed == exposureBefore) {
              recoveryShare = remainingRecovery;
          } else {
              recoveryShare = Math.mulDiv(remainingRecovery, exposureBefore, remainingExposed);
          }
          if (recoveryShare > exposureBefore) recoveryShare = exposureBefore;
          commitment.recoveryReceived += recoveryShare;
          commitment.principalExposed -= recoveryShare;
          remainingRecovery -= recoveryShare;
          remainingExposed -= exposureBefore;
      ```
    - This ensures each step computes against the unreconciled remainder, preventing value stranding
    - _Bug_Condition: isBugCondition(finding=10) where skewed commitments AND last cap reached_
    - _Expected_Behavior: all recoverable value fully credited, no stranded remainder_
    - _Preservation: Total recovery conserved, bounded by totalExposed_
    - _Requirements: 2.12, 2.13_

  - [ ] 9.2 Verify bug condition exploration test for recovery stranding now passes
    - **Property 1: Expected Behavior** — Recovery Fully Credited
    - **IMPORTANT**: Re-run the SAME recovery stranding test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*RecoveryStranding`
    - **EXPECTED OUTCOME**: Test PASSES (confirms recovery stranding bug is fixed)
    - _Requirements: 2.12_

  - [ ] 9.3 Verify preservation tests still pass after recovery fix
    - **Property 2: Preservation** — Charge-Off and Recovery Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.12_

- [ ] 10. Fix Lead — Treasury wallet lock during live lines

  - [ ] 10.1 Add lifecycle guard to `updateBorrowerProfile` for treasury wallet changes
    - In `src/equalscale/EqualScaleAlphaFacet.sol`, function `updateBorrowerProfile`
    - Before setting `profile.treasuryWallet`, check if the new value differs and if any borrower line is non-closed:
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
    - Declare `TreasuryWalletLockedDuringLiveLines(bytes32 borrowerPositionKey)` error in `IEqualScaleAlphaErrors.sol`
    - Allow `bankrToken` and `metadataHash` changes regardless of line status
    - _Bug_Condition: isBugCondition(finding=11) where treasuryChanged AND hasNonClosedLines_
    - _Expected_Behavior: revert when treasury wallet changes while lines are non-closed_
    - _Preservation: Other profile fields remain mutable; treasury changes allowed when all lines closed_
    - _Requirements: 2.16, 2.17, 3.13_

  - [ ] 10.2 Verify bug condition exploration test for treasury lock now passes
    - **Property 1: Expected Behavior** — Treasury Wallet Lock
    - **IMPORTANT**: Re-run the SAME treasury lock test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*TreasuryLock`
    - **EXPECTED OUTCOME**: Test PASSES (confirms treasury lock bug is fixed)
    - _Requirements: 2.16_

  - [ ] 10.3 Verify preservation tests still pass after treasury lock fix
    - **Property 2: Preservation** — Profile Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.13_

- [ ] 11. Fix Finding 4 — Native-asset draw reentrancy hardening

  - [ ] 11.1 Add `nonReentrant` to `draw`
    - In `src/equalscale/EqualScaleAlphaFacet.sol`
    - Make `EqualScaleAlphaFacet` inherit `ReentrancyGuardModifiers` (from the diamond's shared reentrancy guard)
    - Add `nonReentrant` modifier to `draw`:
      ```diff
      - function draw(uint256 lineId, uint256 amount) external {
      + function draw(uint256 lineId, uint256 amount) external nonReentrant {
      ```
    - Review whether `repayLine` and other lifecycle entrypoints should also be guarded for consistency
    - _Bug_Condition: isBugCondition(finding=4) where isDraw AND isNativeSettlement_
    - _Expected_Behavior: nonReentrant blocks reentry through treasury callback_
    - _Preservation: ERC20 draws and normal native draws unchanged_
    - _Requirements: 2.9, 3.5, 3.6_

  - [ ] 11.2 Verify bug condition exploration test for reentrancy now passes
    - **Property 1: Expected Behavior** — Reentrancy Guard
    - **IMPORTANT**: Re-run the SAME reentrancy test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*DrawReentrancy`
    - **EXPECTED OUTCOME**: Test PASSES (confirms reentrancy bug is fixed)
    - _Requirements: 2.9_

  - [ ] 11.3 Verify preservation tests still pass after reentrancy fix
    - **Property 2: Preservation** — Draw Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.5, 3.6_

- [ ] 12. Fix Lead — Pro-rata remainder fairness

  - [ ] 12.1 Apply remaining-amount / remaining-exposure pattern to all allocation helpers
    - In `src/equalscale/LibEqualScaleAlphaShared.sol`, functions `allocateRepayment`, `allocateWriteDown`, and `allocateDrawExposure`
    - Replace the current pattern (early shares against original total, last commitment gets remainder) with the same remaining-amount / remaining-exposure pattern used in the fixed `allocateRecovery`
    - Each step computes its share against the unreconciled remainder and remaining exposure, so dust distributes more fairly
    - Keep total amounts conserved — this is a structural refactor of the loop pattern, not a semantic change
    - _Bug_Condition: isBugCondition(finding=12) where remainderDust > 0_
    - _Expected_Behavior: remainder dust not always assigned to last commitment_
    - _Preservation: Total allocated amounts conserved_
    - _Requirements: 2.18_

  - [ ] 12.2 Verify bug condition exploration test for remainder fairness now passes
    - **Property 1: Expected Behavior** — Fair Remainder Distribution
    - **IMPORTANT**: Re-run the SAME remainder fairness test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition.*RemainderFairness`
    - **EXPECTED OUTCOME**: Test PASSES (confirms remainder fairness bug is fixed)
    - _Requirements: 2.18_

  - [ ] 12.3 Verify preservation tests still pass after remainder fairness fix
    - **Property 2: Preservation** — Allocation Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.3_

- [ ] 13. Fix Lead — Filtered borrower line view

  - [ ] 13.1 Add `getActiveBorrowerLineIds` view function
    - In `src/equalscale/EqualScaleAlphaViewFacet.sol`
    - Add a new view function that returns only non-closed, non-canceled-proposal line IDs:
      ```
      function getActiveBorrowerLineIds(uint256 borrowerPositionId) external view returns (uint256[] memory) {
          bytes32 borrowerPositionKey = _positionNftContract().getPositionKey(borrowerPositionId);
          uint256[] storage allIds = LibEqualScaleAlphaStorage.s().borrowerLineIds[borrowerPositionKey];
          uint256 len = allIds.length;
          // First pass: count live lines
          uint256 liveCount;
          for (uint256 i = 0; i < len; i++) {
              LibEqualScaleAlphaStorage.CreditLineStatus status = LibEqualScaleAlphaStorage.s().lines[allIds[i]].status;
              if (status != LibEqualScaleAlphaStorage.CreditLineStatus.Closed) {
                  liveCount++;
              }
          }
          // Second pass: build filtered array
          uint256[] memory result = new uint256[](liveCount);
          uint256 idx;
          for (uint256 i = 0; i < len; i++) {
              LibEqualScaleAlphaStorage.CreditLineStatus status = LibEqualScaleAlphaStorage.s().lines[allIds[i]].status;
              if (status != LibEqualScaleAlphaStorage.CreditLineStatus.Closed) {
                  result[idx++] = allIds[i];
              }
          }
          return result;
      }
      ```
    - Keep existing `getBorrowerLineIds` unchanged for full auditability
    - _Bug_Condition: isBugCondition(finding=borrowerView) where raw view includes stale entries_
    - _Expected_Behavior: filtered view excludes closed/canceled proposals_
    - _Preservation: raw historical view unchanged_
    - _Requirements: 2.14, 2.15, 3.14_

  - [ ] 13.2 Add test for filtered borrower line view
    - Create line proposals, cancel some, close some, verify `getActiveBorrowerLineIds` returns only live lines
    - Verify `getBorrowerLineIds` still returns the full raw array
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test FilteredBorrowerView`
    - _Requirements: 2.14, 2.15, 3.14_

- [ ] 14. Refresh and expand EqualScale regression tests

  - [ ] 14.1 Add full charge-off lifecycle integration test
    - Propose → commit → activate → draw → warp past delinquency + charge-off threshold → charge off
    - Verify borrower debt state fully cleared, interest loss recorded, borrower can withdraw or clean up membership
    - Proves findings 1 and 6 fixes end-to-end through a value-moving live flow
    - Use real deposits, real proposals, real commitments, real activation, real draws, real delinquency, real charge-off
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - _Requirements: 2.1, 2.2, 2.5, 2.6_

  - [ ] 14.2 Add repayment checkpoint lifecycle integration test
    - Propose → commit → activate → draw → warp past due → make repeated payments → verify single-period advancement and `termEndAt` cap
    - Proves finding 5 fix end-to-end with real payment flows
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - _Requirements: 2.3, 2.4_

  - [ ] 14.3 Add runoff cure lifecycle integration test
    - Propose → commit → activate → draw → enter refinancing → exit commitments below `minimumViableLine` → resolve to runoff → repay → verify stays in runoff
    - Also test cure at or above `minimumViableLine` succeeds
    - Proves finding 7 fix end-to-end
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - _Requirements: 2.7, 2.8_

  - [ ] 14.4 Add freeze integrity lifecycle integration test
    - Propose → commit → activate → admin freeze → warp past term → attempt `enterRefinancing` (revert) → admin unfreeze → `enterRefinancing` (success)
    - Proves freeze bypass fix end-to-end
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - _Requirements: 2.11, 3.9_

  - [ ] 14.5 Add treasury wallet lock lifecycle integration test
    - Propose → commit → activate → attempt treasury change (revert) → repay fully → close line → treasury change (success)
    - Proves treasury lock fix end-to-end
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - _Requirements: 2.16, 2.17_

  - [ ] 14.6 Add recovery allocation lifecycle integration test
    - Propose → commit (3 skewed lenders) → activate → draw → charge off with partial collateral recovery
    - Verify all recovery is fully credited across commitments with no stranded remainder
    - Proves `allocateRecovery` fix end-to-end
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - _Requirements: 2.12, 2.13_

  - [ ] 14.7 Add native draw reentrancy lifecycle integration test
    - Propose → commit → activate → draw with reentering treasury harness → verify blocked
    - Also verify normal native draw succeeds
    - Proves finding 4 fix end-to-end
    - Note: requires narrow reentering treasury harness contract
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - _Requirements: 2.9_

  - Verification runs:
    - `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - `forge test --match-path test/EqualScaleAlpha.t.sol`
    - `forge test --match-path test/EqualScaleAlphaLaunch.t.sol`

- [ ] 15. Checkpoint — Run targeted EqualScale test suites and ensure all tests pass
  - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
  - Run: `forge test --match-path test/EqualScaleAlpha.t.sol`
  - Run: `forge test --match-path test/EqualScaleAlphaLaunch.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all eleven bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ask the user if questions arise
