# Implementation Plan

- [x] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — `userCount` Inflation, `maxUserCount` Bypass, and Maintenance-Driven Stale Count
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/LibUserCountReconciliation.t.sol`
  - Use the existing `EqualLendDirectAccountingHarness` or extend it; use real deposits and real settlement flows where practical
  - **Finding 6 — `restoreLenderCapital` maxUserCount bypass**: Set up a pool with `maxUserCount = 2` and 2 users with nonzero principal. Call `departLenderCapital` to fully remove one user (`userCount` → 1). Then call `restoreLenderCapital` for a THIRD position with `principalBefore == 0` while `userCount` is at capacity (restore the departed user first to fill back to 2, then try a third). Assert revert with `MaxUserCountExceeded`. On unfixed code this will FAIL because `restoreLenderCapital` does not check `maxUserCount`.
  - **Finding 6 — `_creditPrincipal` maxUserCount bypass (Direct)**: Set up a pool at `maxUserCount` capacity. Trigger a default settlement path that calls `_creditPrincipal` for a position with `principalBefore == 0` in the Direct lifecycle facet. Assert revert with `MaxUserCountExceeded`. On unfixed code this will FAIL because `_creditPrincipal` does not check `maxUserCount`.
  - **Finding 6 — `_creditPrincipal` maxUserCount bypass (Rolling)**: Same as above but through the rolling lifecycle settlement path. Assert revert with `MaxUserCountExceeded`. On unfixed code this will FAIL.
  - **Maintenance — `LibFeeIndex.settle` zeroes principal without userCount decrement**: Set up a pool with one user who has principal. Configure maintenance rate high enough that `LibFeeIndex.settle` will zero the principal. Call `settle`. Assert `pool.userCount` decremented by 1. On unfixed code this will FAIL because `settle` does not touch `userCount`.
  - **Maintenance — double-count after maintenance-then-credit**: After maintenance zeroes principal (from previous test), call `restoreLenderCapital` for the same position. Assert `pool.userCount` equals the original count (not inflated). On unfixed code this will FAIL because maintenance didn't decrement, so restore double-increments.
  - Run tests on UNFIXED code: `forge test --match-path test/LibUserCountReconciliation.t.sol`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - Observed results:
    - `forge test --match-path test/LibUserCountReconciliation.t.sol` failed `5/5` as expected on unfixed code
    - `restoreLenderCapital` restored a third zero-principal position into a pool already back at `userCount = 2 / maxUserCount = 2` instead of reverting
    - Direct recovery re-credited a zero-principal lender position into a capped same-asset pool at capacity instead of reverting
    - Rolling recovery re-credited a zero-principal lender position into a capped same-asset pool at capacity instead of reverting
    - `LibFeeIndex.settle` zeroed principal while leaving `pool.userCount == 1`
    - maintenance-then-restore inflated `pool.userCount` from `1` to `2` for the same position
  - _Requirements: 1.1, 1.2, 1.3, 1.7, 1.8_

- [x] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — `userCount` Tracking for Normal Deposit/Withdraw, Partial Operations, and Non-Zeroing Settlement
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/LibUserCountReconciliation.t.sol`
  - Use the same harness from task 1
  - **Voluntary deposit userCount preservation**: Deposit into a pool for the first time via real deposit flow, verify `userCount` increments by 1 and `maxUserCount` is enforced
  - **Voluntary full withdrawal preservation**: Withdraw all principal, verify `userCount` decrements by exactly 1
  - **Partial withdrawal preservation**: Withdraw partial principal (principal remains nonzero), verify `userCount` unchanged
  - **restoreLenderCapital nonzero-principal preservation**: Call `restoreLenderCapital` for a position that already has nonzero principal, verify `userCount` unchanged
  - **departLenderCapital partial preservation**: Call `departLenderCapital` for a partial departure (principal remains nonzero), verify `userCount` unchanged
  - **departLenderCapital full then restoreLenderCapital preservation**: Full departure then restore, verify symmetric `userCount` tracking (decrement then increment, net zero)
  - **LibFeeIndex.settle non-zeroing preservation**: Call `settle` where maintenance reduces but does not zero principal, verify `userCount` unchanged
  - **LibFeeIndex.settle zero-principal preservation**: Call `settle` for a user with zero principal, verify `userCount` unchanged and no maintenance applied
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - Observed results:
    - `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition` passed `8/8`
    - live deposit/withdraw preservation covered first-user increment, cap enforcement, full-withdraw decrement, and partial-withdraw stability
    - harness preservation covered partial depart, full depart/restore symmetry, nonzero-principal restore stability, non-zeroing maintenance settle stability, and zero-principal settle snapshot behavior
  - _Requirements: 3.1, 3.2, 3.3, 3.7, 3.8, 3.9, 3.12, 3.13_


- [x] 3. Fix Maintenance-Driven `userCount` Decrement in `LibFeeIndex.settle`

  - [x] 3.1 Add `userCount` decrement when maintenance zeroes `userPrincipal`
    - In `src/libraries/LibFeeIndex.sol`, function `settle`
    - Inside the `if (maintenanceFee >= principal)` block, after `p.userPrincipal[user] = 0`, add:
      ```
      if (p.userCount > 0) {
          p.userCount -= 1;
      }
      ```
    - The `p.userCount > 0` guard prevents underflow in edge cases
    - This ensures `userCount` accurately reflects positions with nonzero principal after maintenance settlement
    - _Bug_Condition: isBugCondition(finding="maintenance") where isLibFeeIndexSettle AND principalBefore > 0 AND maintenanceFee >= principal_
    - _Expected_Behavior: pool.userCount decremented by 1 when maintenance zeroes principal_
    - _Preservation: Non-zeroing maintenance settlements leave userCount unchanged; zero-principal users skip maintenance entirely_
    - _Requirements: 2.7, 3.12, 3.13_

  - [x] 3.2 Verify bug condition exploration test for maintenance userCount now passes
    - **Property 1: Expected Behavior** — Maintenance-Driven `userCount` Decrement
    - **IMPORTANT**: Re-run the SAME maintenance tests from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol --match-test BugCondition.*Maintenance`
    - **EXPECTED OUTCOME**: Tests PASS (confirms maintenance userCount bug is fixed)
    - Observed results:
      - `forge test --match-path test/LibUserCountReconciliation.t.sol --match-test 'BugCondition.*Maintenance'` passed `2/2`
    - _Requirements: 2.7, 2.8_

  - [x] 3.3 Verify preservation tests still pass after maintenance fix
    - **Property 2: Preservation** — Fee Index Settlement Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed results:
      - `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition` passed `8/8`
    - _Requirements: 3.12, 3.13_

- [x] 4. Fix `maxUserCount` Enforcement in `restoreLenderCapital`

  - [x] 4.1 Add `maxUserCount` check in `restoreLenderCapital` when `principalBefore == 0`
    - In `src/libraries/LibEqualLendDirectAccounting.sol`, function `restoreLenderCapital`
    - Inside the `if (principalBefore == 0)` block, before `lenderPool.userCount += 1`, add:
      ```
      uint256 maxUsers = lenderPool.poolConfig.maxUserCount;
      if (maxUsers > 0 && lenderPool.userCount >= maxUsers) {
          revert MaxUserCountExceeded(maxUsers);
      }
      ```
    - Import `MaxUserCountExceeded` from `Errors.sol` if not already imported
    - This mirrors the existing pattern in `PositionManagementFacet._deposit` and `OptionsFacet._increasePrincipal`
    - _Bug_Condition: isBugCondition(finding=6) where isRestoreLenderCapital AND principalBefore == 0 AND userCount >= maxUserCount_
    - _Expected_Behavior: revert with MaxUserCountExceeded when pool is at capacity_
    - _Preservation: Restore to nonzero-principal positions unchanged; restore below capacity unchanged_
    - _Requirements: 2.3, 3.8_

  - [x] 4.2 Verify bug condition exploration test for restoreLenderCapital maxUserCount now passes
    - **Property 1: Expected Behavior** — `restoreLenderCapital` `maxUserCount` Enforcement
    - **IMPORTANT**: Re-run the SAME Finding 6 restoreLenderCapital test from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol --match-test BugCondition.*RestoreLenderCapital`
    - **EXPECTED OUTCOME**: Tests PASS (confirms restoreLenderCapital maxUserCount bug is fixed)
    - Observed results:
      - `forge test --match-path test/LibUserCountReconciliation.t.sol --match-test 'BugCondition.*RestoreLenderCapital'` passed `1/1`
    - _Requirements: 2.3_

  - [x] 4.3 Verify preservation tests still pass after restoreLenderCapital fix
    - **Property 2: Preservation** — Depart/Restore Lifecycle Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed results:
      - `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition` passed `8/8`
    - _Requirements: 3.7, 3.8, 3.9_

- [x] 5. Fix `maxUserCount` Enforcement in `_creditPrincipal` (Direct Lifecycle)

  - [x] 5.1 Add `maxUserCount` check in Direct lifecycle `_creditPrincipal` when `principalBefore == 0`
    - In `src/equallend/EqualLendDirectLifecycleFacet.sol`, function `_creditPrincipal`
    - Inside the `if (principalBefore == 0)` block, before `pool.userCount += 1`, add:
      ```
      uint256 maxUsers = pool.poolConfig.maxUserCount;
      if (maxUsers > 0 && pool.userCount >= maxUsers) {
          revert MaxUserCountExceeded(maxUsers);
      }
      ```
    - Import `MaxUserCountExceeded` from `Errors.sol` if not already imported
    - _Bug_Condition: isBugCondition(finding=6) where isCreditPrincipalDirect AND principalBefore == 0 AND userCount >= maxUserCount_
    - _Expected_Behavior: revert with MaxUserCountExceeded when pool is at capacity_
    - _Preservation: Credit to nonzero-principal positions unchanged; credit below capacity unchanged_
    - _Requirements: 2.1_

  - [x] 5.2 Verify bug condition exploration test for Direct _creditPrincipal maxUserCount now passes
    - **Property 1: Expected Behavior** — Direct `_creditPrincipal` `maxUserCount` Enforcement
    - **IMPORTANT**: Re-run the SAME Finding 6 Direct _creditPrincipal test from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol --match-test BugCondition.*CreditPrincipalDirect`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Direct _creditPrincipal maxUserCount bug is fixed)
    - Observed results:
      - `forge test --match-path test/LibUserCountReconciliation.t.sol --match-test 'BugCondition.*CreditPrincipalDirect'` passed `1/1`
    - _Requirements: 2.1_

  - [x] 5.3 Verify preservation tests still pass after Direct _creditPrincipal fix
    - **Property 2: Preservation**
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed results:
      - `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition` passed `8/8`
    - _Requirements: 3.9_

- [x] 6. Fix `maxUserCount` Enforcement in `_creditPrincipal` (Rolling Lifecycle)

  - [x] 6.1 Add `maxUserCount` check in Rolling lifecycle `_creditPrincipal` when `principalBefore == 0`
    - In `src/equallend/EqualLendDirectRollingLifecycleFacet.sol`, function `_creditPrincipal`
    - Inside the `if (principalBefore == 0)` block, before `pool.userCount += 1`, add:
      ```
      uint256 maxUsers = pool.poolConfig.maxUserCount;
      if (maxUsers > 0 && pool.userCount >= maxUsers) {
          revert MaxUserCountExceeded(maxUsers);
      }
      ```
    - Import `MaxUserCountExceeded` from `Errors.sol` if not already imported
    - _Bug_Condition: isBugCondition(finding=6) where isCreditPrincipalRolling AND principalBefore == 0 AND userCount >= maxUserCount_
    - _Expected_Behavior: revert with MaxUserCountExceeded when pool is at capacity_
    - _Preservation: Credit to nonzero-principal positions unchanged; credit below capacity unchanged_
    - _Requirements: 2.2_

  - [x] 6.2 Verify bug condition exploration test for Rolling _creditPrincipal maxUserCount now passes
    - **Property 1: Expected Behavior** — Rolling `_creditPrincipal` `maxUserCount` Enforcement
    - **IMPORTANT**: Re-run the SAME Finding 6 Rolling _creditPrincipal test from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol --match-test BugCondition.*CreditPrincipalRolling`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Rolling _creditPrincipal maxUserCount bug is fixed)
    - Observed results:
      - `forge test --match-path test/LibUserCountReconciliation.t.sol --match-test 'BugCondition.*CreditPrincipalRolling'` passed `1/1`
    - _Requirements: 2.2_

  - [x] 6.3 Verify preservation tests still pass after Rolling _creditPrincipal fix
    - **Property 2: Preservation**
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed results:
      - `forge test --match-path test/LibUserCountReconciliation.t.sol --no-match-test BugCondition` passed `8/8`
    - _Requirements: 3.9_

- [x] 7. Refresh and expand userCount regression tests

  - [x] 7.1 Add maintenance-then-credit lifecycle integration test
    - Test file: `test/LibUserCountReconciliation.t.sol`
    - Deposit → accrue maintenance fees → settle (zeroes principal, decrements `userCount`) → restore capital (increments `userCount`) → verify `userCount` equals original count
    - Use real deposits, real maintenance accrual, real settlement, real capital restoration
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol`
    - _Requirements: 2.7, 2.8_

  - [x] 7.2 Add multi-user pool capacity lifecycle integration test
    - Test file: `test/LibUserCountReconciliation.t.sol`
    - Set pool `maxUserCount = 3` → deposit 3 users → maintenance zeroes one user's principal → verify `userCount = 2` → new user deposits → verify `userCount = 3` and succeeds → fourth user attempts deposit → verify revert
    - Use real deposits, real maintenance, real settlement
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol`
    - _Requirements: 2.1, 2.3, 2.7, 3.1_

  - [x] 7.3 Add default settlement at capacity integration test
    - Test file: `test/LibUserCountReconciliation.t.sol`
    - Set pool at `maxUserCount` capacity → trigger default settlement that would credit a new position → verify revert with `MaxUserCountExceeded`
    - Use real loan origination and settlement flows where practical
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol`
    - _Requirements: 2.1, 2.2, 2.3_

  - [x] 7.4 Add symmetric depart/restore userCount tracking integration test
    - Test file: `test/LibUserCountReconciliation.t.sol`
    - Deposit → full departure → verify `userCount` decremented → restore → verify `userCount` incremented → verify net `userCount` unchanged
    - Include a variant where maintenance zeroes principal between depart and restore
    - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol`
    - _Requirements: 2.6, 3.7, 3.8_

  - Observed results:
    - `test_Integration_MaintenanceThenRestore_KeepsUserCountSymmetric` proves real deposit, time-based maintenance accrual, maintenance settlement, and capital restoration keep `userCount` symmetric
    - `test_Integration_MultiUserCapacity_MaintenanceOpensSingleSlot` proves maintenance-driven zeroing frees exactly one slot in a capped pool and that the next depositor succeeds while the following depositor still reverts
    - `test_Integration_DefaultSettlementAtCapacity_DirectRecoveryStillReverts` and `test_Integration_DefaultSettlementAtCapacity_RollingRecoveryStillReverts` prove both real default recovery paths respect `maxUserCount`
    - `test_Integration_DepartRestoreAndMaintenanceZeroing_RemainSymmetric` proves both full depart/restore and maintenance-zero/restore round trips keep `userCount` symmetric

- [x] 8. Checkpoint — Run targeted test suite and ensure all tests pass
  - Run: `forge test --match-path test/LibUserCountReconciliation.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all userCount bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ask the user if questions arise
  - Observed results:
    - `forge test --match-path test/LibUserCountReconciliation.t.sol` passed `18/18`
    - all bug condition exploration tests passed
    - all preservation tests passed
    - all integration regression tests passed
