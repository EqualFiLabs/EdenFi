# Implementation Plan

- [x] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — ACI Bucket Asymmetry, Encumbrance Yield Loss, and Debt Tracker Desync
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/LibActiveCreditIndex.t.sol` for findings 1 and 2; `test/LibEqualLendDirectAccounting.t.sol` for finding 3
  - Use a minimal harness that exposes the library functions; use real deposits and real loan flows where practical
  - **Finding 1 — Bucket asymmetry**: Create an ACI state with `startTime` such that `offset >= BUCKET_COUNT`. Call `_scheduleState` to place principal in the last pending bucket. Record `activeCreditMaturedTotal` and `pendingBuckets[last]`. Call `_removeFromBase` for the same state and amount. Assert `pendingBuckets[last]` decreased by the amount and `activeCreditMaturedTotal` is unchanged. On unfixed code this will FAIL because `_removeFromBase` subtracts from `activeCreditMaturedTotal` instead of the pending bucket.
  - **Finding 1 — Phantom inflation after roll**: After the asymmetric schedule/remove, advance time to trigger `_rollMatured`. Assert `activeCreditMaturedTotal` does not contain phantom principal from the pending bucket that was already "removed" from matured total. On unfixed code this will FAIL because the pending bucket rolls into matured total while the removal was already taken from matured total.
  - **Finding 2 — Encumbrance increase yield loss**: Create an encumbrance state with known principal and `indexSnapshot`. Accrue ACI yield to advance `activeCreditIndex`. Call `applyEncumbranceIncrease` with a delta. Assert `userAccruedYield[user]` was credited with `principal * (currentIndex - oldSnapshot) / INDEX_SCALE`. On unfixed code this will FAIL because yield is permanently lost.
  - **Finding 2 — Encumbrance decrease yield loss**: Same setup as above but call `applyEncumbranceDecrease` (partial decrease, not zeroing). Assert `userAccruedYield[user]` was credited with the pending yield. On unfixed code this will FAIL.
  - **Finding 3 — Debt tracker over-subtraction**: Create two same-asset agreements on the same borrower/pool pair via real origination. Settle the first with `principalDelta` exceeding its individual `borrowedPrincipalByPool` tracker. Assert revert. On unfixed code this will FAIL because the clamp-to-zero silently absorbs the over-subtraction.
  - **Finding 3 — Debt tracker desync**: On unfixed code, after the silent over-subtraction, settle the second agreement. Assert all five trackers (`borrowedPrincipalByPool`, `sameAssetDebtByAsset`, `userSameAssetDebt`, per-positionId `sameAssetDebt`, `activeCreditPrincipalTotal`) are zero. On unfixed code this will FAIL because the trackers have diverged.
  - Run tests on UNFIXED code:
    - `forge test --match-path test/LibActiveCreditIndex.t.sol`
    - `forge test --match-path test/LibEqualLendDirectAccounting.t.sol`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Observed counterexamples on unfixed code:
    - `test_BugCondition_BucketOverflowRemoval_ShouldRemoveFromLastPendingBucket`: overflow principal stayed in the last pending bucket at `100 ether` instead of decrementing to `0`
    - `test_BugCondition_BucketOverflowRemoval_ShouldNotPhantomInflateAfterRoll`: rolling the untouched overflow bucket inflated `activeCreditMaturedTotal` to `100 ether` instead of leaving it at `0`
    - `test_BugCondition_EncumbranceIncrease_ShouldSettlePendingYieldBeforeSnapshotOverwrite`: `userAccruedYield[user]` stayed `0` instead of crediting the pending `10 ether`
    - `test_BugCondition_EncumbranceDecrease_ShouldSettlePendingYieldBeforeSnapshotOverwrite`: `userAccruedYield[user]` stayed `0` instead of crediting the pending `10 ether`
    - `test_BugCondition_DebtTrackerOverSubtraction_ShouldRevertWhenSettlementExceedsPositionDebt`: over-settling the first same-asset agreement by `20 ether` did not revert
    - `test_BugCondition_DebtTrackerDesync_ShouldLeaveTrackersZeroAfterRejectedOverSettlement`: the expected revert never happened, proving the silent clamp path is still reachable on unfixed code
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9_

- [x] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — ACI Bucket Mechanics, Encumbrance Lifecycle, and Debt Tracker Origination/Settlement
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/LibActiveCreditIndex.t.sol` and `test/LibEqualLendDirectAccounting.t.sol`
  - Use the same harnesses from task 1
  - **Normal bucket placement preservation**: Schedule and remove ACI states with `offset < BUCKET_COUNT`, verify identical bucket behavior before and after
  - **Mature state removal preservation**: Remove from base for mature states, verify `activeCreditMaturedTotal` decrements correctly
  - **Roll matured preservation**: Advance time and roll buckets, verify matured total accumulates correctly from pending buckets
  - **Encumbrance zero-amount preservation**: Call `applyEncumbranceIncrease` with `amount == 0`, verify early return with no state changes
  - **Encumbrance full-zero preservation**: Call `applyEncumbranceDecrease` that fully zeroes principal, verify `resetIfZeroWithGate` is called and state is cleared
  - **Encumbrance no-pending-yield preservation**: Call encumbrance change when `indexSnapshot == activeCreditIndex`, verify no yield settlement side effects
  - **Debt increase preservation**: Call `_increaseBorrowedPrincipal` and `_increaseSameAssetDebt` via origination, verify all five trackers increment correctly
  - **Debt in-bounds decrease preservation**: Call `_decreaseBorrowedPrincipal` and `_decreaseSameAssetDebt` via settlement with amounts within bounds, verify all five trackers decrement correctly
  - **Single-agreement settlement preservation**: Originate and settle a single same-asset loan, verify all trackers return to zero
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/LibActiveCreditIndex.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/LibEqualLendDirectAccounting.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Observed baseline on unfixed code:
    - `forge test --match-path test/LibActiveCreditIndex.t.sol --no-match-test BugCondition`
    - Result: `6/6` ACI preservation tests passed
    - `forge test --match-path test/LibEqualLendDirectAccounting.t.sol --no-match-test BugCondition`
    - Result: `7/7` direct-accounting preservation tests passed
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13_


- [x] 3. Fix Finding 1 — ACI Bucket Asymmetry in `_removeFromBase`

  - [x] 3.1 Make `_removeFromBase` use the same last-bucket logic as `_scheduleState` when `offset >= BUCKET_COUNT`
    - In `src/libraries/LibActiveCreditIndex.sol`, function `_removeFromBase`
    - When `offset >= BUCKET_COUNT`, compute `uint8 last = uint8((p.activeCreditPendingCursor + (BUCKET_COUNT - 1)) % BUCKET_COUNT)` and subtract from `p.activeCreditPendingBuckets[last]` instead of from `p.activeCreditMaturedTotal`
    - This mirrors the existing logic in `_scheduleState` for the same condition
    - _Bug_Condition: isBugCondition(finding=1) where isRemoveFromBase AND maturityOffset >= BUCKET_COUNT_
    - _Expected_Behavior: principal removed from the same pending bucket that _scheduleState placed it in_
    - _Preservation: Mature state removal and normal-offset removal unchanged_
    - _Requirements: 2.1_

  - [x] 3.2 Remove silent clamp-to-zero throughout `_removeFromBase`
    - In `src/libraries/LibActiveCreditIndex.sol`, function `_removeFromBase`
    - Replace all `if (x >= amount) { x -= amount; } else { x = 0; }` patterns with direct `x -= amount`
    - Solidity 0.8.x checked arithmetic will revert on underflow, surfacing accounting drift immediately
    - Also remove the remainder-to-matured fallback in the normal-offset branch (the bucket should contain the full amount)
    - _Bug_Condition: isBugCondition(finding=1) — silent clamp masks drift_
    - _Expected_Behavior: revert on any over-subtraction from buckets or matured total_
    - _Preservation: In-bounds subtractions produce identical results_
    - _Requirements: 2.2_

  - [x] 3.3 Verify bug condition exploration tests for Finding 1 now pass
    - **Property 1: Expected Behavior** — Symmetric Bucket Placement
    - **IMPORTANT**: Re-run the SAME Finding 1 tests from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/LibActiveCreditIndex.t.sol --match-test BugCondition.*Bucket`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 1 bug is fixed)
    - Observed result:
      - `forge test --match-path test/LibActiveCreditIndex.t.sol --match-test 'BugCondition.*Bucket'`
      - Result: `2/2` Finding 1 bug-condition tests passed
    - _Requirements: 2.1, 2.2_

  - [x] 3.4 Verify preservation tests still pass after Finding 1 fix
    - **Property 2: Preservation** — ACI Bucket Mechanics
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibActiveCreditIndex.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed result:
      - `forge test --match-path test/LibActiveCreditIndex.t.sol --no-match-test BugCondition`
      - Result: `6/6` ACI preservation tests passed
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [x] 4. Fix Finding 2 — ACI Encumbrance Yield Settlement Before Snapshot Overwrite

  - [x] 4.1 Add `_settleState` call in `_increaseEncumbrance` before snapshot overwrite
    - In `src/libraries/LibActiveCreditIndex.sol`, function `_increaseEncumbrance`
    - Load `enc` storage pointer before the `activeCreditPrincipalTotal` increment
    - Call `_settleState(p, enc, pid, user)` before `applyWeightedIncreaseWithGate`
    - `_settleState` handles `principal == 0` and `!_isMature` cases safely by just updating `indexSnapshot`
    - _Bug_Condition: isBugCondition(finding=2) where isEncumbranceIncrease AND principal > 0 AND currentIndex > snapshot_
    - _Expected_Behavior: pending yield credited to userAccruedYield before snapshot overwrite_
    - _Preservation: Zero-amount early return unchanged; weighted dilution and timing events unchanged_
    - _Requirements: 2.3_

  - [x] 4.2 Add `_settleState` call in `_decreaseEncumbrance` before snapshot overwrite
    - In `src/libraries/LibActiveCreditIndex.sol`, function `_decreaseEncumbrance`
    - Call `_settleState(p, enc, pid, user)` after loading `enc` but before `principalBefore` read and principal decrease
    - _Bug_Condition: isBugCondition(finding=2) where isEncumbranceDecrease AND principal > 0 AND currentIndex > snapshot_
    - _Expected_Behavior: pending yield credited to userAccruedYield before snapshot overwrite_
    - _Preservation: Full-zero resetIfZeroWithGate unchanged; principal decrease mechanics unchanged_
    - _Requirements: 2.4_

  - [x] 4.3 Verify bug condition exploration tests for Finding 2 now pass
    - **Property 1: Expected Behavior** — Encumbrance Yield Settlement
    - **IMPORTANT**: Re-run the SAME Finding 2 tests from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/LibActiveCreditIndex.t.sol --match-test BugCondition.*Encumbrance`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 2 bug is fixed)
    - Observed result:
      - `forge test --match-path test/LibActiveCreditIndex.t.sol --match-test 'BugCondition.*Encumbrance'`
      - Result: `2/2` Finding 2 bug-condition tests passed
    - _Requirements: 2.3, 2.4_

  - [x] 4.4 Verify preservation tests still pass after Finding 2 fix
    - **Property 2: Preservation** — Encumbrance Lifecycle
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibActiveCreditIndex.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed result:
      - `forge test --match-path test/LibActiveCreditIndex.t.sol --no-match-test BugCondition`
      - Result: `6/6` ACI preservation tests passed
    - _Requirements: 3.5, 3.6, 3.7, 3.8_

- [x] 5. Fix Finding 3 — Debt Tracker Revert on Over-Subtraction

  - [x] 5.1 Replace silent clamp-to-zero in `_decreaseBorrowedPrincipal` with direct subtraction
    - In `src/libraries/LibEqualLendDirectAccounting.sol`, function `_decreaseBorrowedPrincipal`
    - Replace `amount >= current ? 0 : current - amount` with `current - amount`
    - Solidity 0.8.x checked arithmetic will revert on underflow when `amount > current`
    - _Bug_Condition: isBugCondition(finding=3) where isDebtDecrease AND amount > borrowedPrincipalByPool_
    - _Expected_Behavior: revert on over-subtraction_
    - _Preservation: In-bounds decreases produce identical results_
    - _Requirements: 2.5_

  - [x] 5.2 Replace silent clamp-to-zero in `_decreaseSameAssetDebt` with direct subtraction for all four trackers
    - In `src/libraries/LibEqualLendDirectAccounting.sol`, function `_decreaseSameAssetDebt`
    - Replace `principalComponent >= storedDebt ? 0 : storedDebt - principalComponent` with `storedDebt -= principalComponent` for `sameAssetDebtByAsset`
    - Replace `principalComponent >= sameAssetDebt ? 0 : sameAssetDebt - principalComponent` with direct subtraction for `userSameAssetDebt`
    - Replace `principalComponent >= tokenDebt ? 0 : tokenDebt - principalComponent` with direct subtraction for per-positionId `sameAssetDebt`
    - Replace `debtPrincipalBefore > principalComponent ? principalComponent : debtPrincipalBefore` with `principalComponent` for `debtDecrease`
    - Replace `activeCreditPrincipalTotal >= debtDecrease ? ... : 0` with direct subtraction for `activeCreditPrincipalTotal`
    - _Bug_Condition: isBugCondition(finding=3) where isDebtDecrease AND principalComponent > anyTrackerValue_
    - _Expected_Behavior: revert on over-subtraction for any of the five trackers_
    - _Preservation: In-bounds decreases produce identical results across all five trackers_
    - _Requirements: 2.6_

  - [x] 5.3 Verify bug condition exploration tests for Finding 3 now pass
    - **Property 1: Expected Behavior** — Debt Tracker Revert
    - **IMPORTANT**: Re-run the SAME Finding 3 tests from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/LibEqualLendDirectAccounting.t.sol --match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 3 bug is fixed)
    - Observed result:
      - `forge test --match-path test/LibEqualLendDirectAccounting.t.sol --match-test BugCondition`
      - Result: `2/2` Finding 3 bug-condition tests passed
    - _Requirements: 2.5, 2.6_

  - [x] 5.4 Verify preservation tests still pass after Finding 3 fix
    - **Property 2: Preservation** — Debt Tracker Origination and Settlement
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibEqualLendDirectAccounting.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed result:
      - `forge test --match-path test/LibEqualLendDirectAccounting.t.sol --no-match-test BugCondition`
      - Result: `7/7` direct-accounting preservation tests passed
    - _Requirements: 3.9, 3.10, 3.11, 3.12, 3.13_

- [x] 6. Refresh and expand regression tests

  - [x] 6.1 Add ACI full lifecycle integration test
    - Test file: `test/LibActiveCreditIndex.t.sol`
    - Schedule state → accrue yield via `accrueWithSource` → settle → remove from base → verify `activeCreditMaturedTotal` and `userAccruedYield` are correct
    - Include both normal-offset and overflow-offset states in the same test
    - Run: `forge test --match-path test/LibActiveCreditIndex.t.sol`
    - Observed result:
      - Added `test_Integration_AciLifecycle_SettlesYieldAndRemovesNormalAndOverflowBase`
    - _Requirements: 2.1, 2.2_

  - [x] 6.2 Add multi-encumbrance yield accumulation integration test
    - Test file: `test/LibActiveCreditIndex.t.sol`
    - Increase encumbrance → accrue yield → increase encumbrance again → accrue yield → decrease encumbrance → verify cumulative yield is correct and no yield is lost at any step
    - Use real pool state with real ACI accrual
    - Run: `forge test --match-path test/LibActiveCreditIndex.t.sol`
    - Observed result:
      - Added `test_Integration_MultiEncumbranceYieldAccumulation_PreservesAllPendingYield`
    - _Requirements: 2.3, 2.4_

  - [x] 6.3 Add multi-agreement debt lifecycle integration test
    - Test file: `test/LibEqualLendDirectAccounting.t.sol`
    - Originate two same-asset loans on the same borrower/pool pair → settle first → settle second → verify all five trackers are zero
    - Use real origination and settlement flows
    - Run: `forge test --match-path test/LibEqualLendDirectAccounting.t.sol`
    - Observed result:
      - Added `test_Integration_MultiAgreementDebtLifecycle_SettlesBothAgreementsAndClearsTrackers`
    - _Requirements: 2.5, 2.6, 3.13_

  - [x] 6.4 Add downstream EqualX encumbrance-with-yield integration test
    - Primary downstream owner: `test/EqualXSoloAmmFacet.t.sol` under `.kiro/specs/equalx-findings-1-5-remediation`
    - Create Solo AMM market → swap (triggers encumbrance change) → verify yield is settled before snapshot overwrite → finalize → verify clean ACI state
    - Reuse the existing EqualX downstream lifecycle suite if it already covers this flow; do not duplicate equivalent ownership in `test/LibActiveCreditIndex.t.sol`
    - Add a narrow library-side smoke test only if a substrate-only edge remains unreachable from the real EqualX flow
    - This proves the EqualX finding 2 downstream fix works correctly with the substrate yield settlement fix
    - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol`
    - Observed result:
      - Reused existing downstream owner test `test_Integration_SoloLifecycle_SwapClaimLiveFinalizeAndClaimRemainingYield`
      - `forge test --match-path test/EqualXSoloAmmFacet.t.sol` -> `44/44` passed
    - _Requirements: 2.3, 2.4, 3.14_

  - [x] 6.5 Add downstream EqualLend same-asset debt integration test
    - Test file: `test/LibEqualLendDirectAccounting.t.sol`
    - Originate same-asset loan → partial settle → full settle → verify all debt trackers are zero
    - This proves the EqualLend debt-service tracker integrity downstream fix works correctly with the substrate revert fix
    - Run: `forge test --match-path test/LibEqualLendDirectAccounting.t.sol`
    - Observed result:
      - Added `test_Integration_SameAssetLoan_PartialThenFullSettle_ClearsAllDebtTrackers`
    - _Requirements: 2.5, 2.6, 3.15_

- [x] 7. Checkpoint — Run targeted test suites and ensure all tests pass
  - Run: `forge test --match-path test/LibActiveCreditIndex.t.sol`
  - Run: `forge test --match-path test/LibEqualLendDirectAccounting.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all three bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Verify downstream EqualX and EqualLend integration tests pass
  - Observed result:
    - `forge test --match-path test/LibActiveCreditIndex.t.sol` -> `12/12` passed
    - `forge test --match-path test/LibEqualLendDirectAccounting.t.sol` -> `11/11` passed
    - `forge test --match-path test/EqualXSoloAmmFacet.t.sol` -> `44/44` passed
    - All bug-condition, preservation, and integration regression tests passed across the ACI and direct-accounting suites
    - Downstream EqualX lifecycle coverage passed using the existing owner suite, and downstream EqualLend same-asset settlement coverage passed in the refreshed direct-accounting suite
  - Ask the user if questions arise
