# Implementation Plan

- [ ] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — EqualLend Payment Lifecycle Findings 3, 5, 6, 8 and Agreed Leads
  - **CRITICAL**: These tests MUST FAIL on unfixed code, except for the Finding 3 positive-control test which intentionally PASSES to prove the dead guard is ignored
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/EqualLendDirectRollingPaymentFacet.t.sol` for findings 3, 5 and rolling leads; `test/EqualLendDirectFixedAgreementFacet.t.sol` for finding 8 and ratio-fill lead; `test/EqualLendDirectRollingLifecycleFacet.t.sol` for finding 6; `test/PoolAumFacet.t.sol` for setAumFee lead
  - Use real deposits, real offers, real agreement origination, real payments, real defaults — no synthetic shortcuts
  - **Finding 3 — Dead `minReceived`**: Create rolling agreement, accrue interest over multiple periods, call `makeRollingPayment` with `minReceived` set to a value below actual interest, assert payment succeeds (proving `minReceived` is ignored). On unfixed code this will PASS (confirming the parameter is dead — this is the one test that passes to prove the bug exists by showing the guard does nothing).
  - **Finding 5 — Arrears trap**: Create rolling agreement, warp past multiple due checkpoints, pay exactly the historical overdue arrears amount, assert `nextDue` advanced to next checkpoint. On unfixed code this will FAIL because `nextDue` stays stuck when `agreement.arrears > 0` due to folded current-period interest.
  - **Finding 6 — Inflated penalty**: Create rolling agreement, warp far past due to accumulate large interest, trigger `recoverRolling`, assert `penaltyPaid <= (min(collateralSeized, totalDebt) * penaltyBps) / BPS_DENOM`. On unfixed code this will FAIL because penalty is computed from unbounded `totalDebt`.
  - **Finding 8 — Fixed zero interest**: Create fixed offer with small principal (1e6), low APR (1 BPS), short duration (1 day), accept offer, assert `interestAmount >= 1`. On unfixed code this will FAIL because floor rounding truncates to zero.
  - **Lead — Collateral rounding**: Create lender-ratio offer with parameters producing fractional collateral, fill tranche, assert `collateralRequired >= ceil(principal * priceNum / priceDenom)`. On unfixed code this will FAIL because floor rounding under-collateralizes.
  - **Lead — Over-receive revert**: Create amortization-disabled rolling agreement, arrange for `pullAtLeast` to over-deliver, call `makeRollingPayment`, assert payment succeeds without revert. On unfixed code this will FAIL because surplus triggers amortization-disabled revert.
  - **Lead — Payment cap bypass**: Create rolling agreement, advance `paymentCount` to `maxPaymentCount` through real payments, call `makeRollingPayment` again, assert revert. On unfixed code this will FAIL because payment succeeds past the cap.
  - **Lead — `setAumFee` owner lockout**: Configure timelock, call `setAumFee` as owner, assert success. On unfixed code this will FAIL because `enforceTimelockOrOwnerIfUnset()` reverts for owner when timelock is set.
  - Run tests on UNFIXED code:
    - `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --match-test BugCondition`
    - `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol --match-test BugCondition`
    - `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol --match-test BugCondition`
    - `forge test --match-path test/PoolAumFacet.t.sol --match-test BugCondition`
  - **EXPECTED OUTCOME**: All bug-condition tests FAIL except the Finding 3 positive-control test, which intentionally PASSES on unfixed code to prove the dead guard does nothing
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 1.11, 1.12_

- [ ] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — EqualLend Payment Lifecycle Unchanged Behavior
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/EqualLendDirectRollingPaymentFacet.t.sol`, `test/EqualLendDirectFixedAgreementFacet.t.sol`, `test/EqualLendDirectRollingLifecycleFacet.t.sol`, `test/PoolAumFacet.t.sol`
  - Use real deposits, real offers, real agreement origination, real payments, real defaults — no synthetic shortcuts
  - **Rolling payment preservation**: Execute valid rolling payment with satisfied guards, verify allocation waterfall (arrears → current interest → principal → refund), position settlement, lender capital restoration, and event emission are correct and unchanged
  - **Rolling amortization preservation**: Execute rolling payment with principal amortization on amortization-enabled agreement, verify `outstandingPrincipal` reduction, principal settlement, and collateral release
  - **Rolling full repay preservation**: Execute valid `repayRollingInFull`, verify total-due computation, fund pull, lender capital restoration, principal settlement, agreement finalization, surplus refund
  - **Rolling early repay guard preservation**: Attempt `repayRollingInFull` with `allowEarlyRepay == false` and `paymentCount < maxPaymentCount`, verify revert
  - **Rolling recovery preservation**: Create genuinely overdue agreement past grace with uncured arrears, verify `recoverRolling` succeeds
  - **Rolling default no-penalty preservation**: Trigger default with `applyPenalty == false` path (exercise), verify penalty computation skipped entirely
  - **Rolling default split preservation**: Trigger default, verify lender/treasury/active-credit/fee-index split routing is correct
  - **Fixed origination preservation**: Originate fixed agreement with normal parameters, verify interest, platform fee, due timestamp
  - **Fixed zero-APR preservation**: Originate with `aprBps == 0`, verify zero interest
  - **Ratio fill preservation**: Execute lender-ratio fill with valid parameters, verify validation context, funding, collateral, solvency checks
  - **AUM fee timelock preservation**: Call `setAumFee` via timelock, verify success
  - **AUM fee bounds preservation**: Call `setAumFee` with out-of-bounds fee, verify revert
  - **Rolling offer acceptance preservation**: Accept rolling offer with valid parameters, verify agreement storage, collateral locking, principal funding
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/PoolAumFacet.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13, 3.14, 3.15_

- [ ] 3. Fix Finding 3 — Replace rolling `minReceived` with `maxInterestDue` guard

  - [ ] 3.1 Replace `minReceived` with `maxInterestDue` in `makeRollingPayment`
    - In `src/equallend/EqualLendDirectRollingPaymentFacet.sol`, function `makeRollingPayment`
    - Rename parameter `minReceived` → `maxInterestDue`
    - Remove the bare `minReceived;` statement
    - After computing the accrual snapshot, add: `uint256 totalInterest = snapshot.arrearsDue + snapshot.currentInterestDue; if (totalInterest > maxInterestDue) revert RollingError_InterestExceedsMax(totalInterest, maxInterestDue);`
    - Declare `RollingError_InterestExceedsMax(uint256 actual, uint256 max)` error in `src/libraries/Errors.sol`
    - _Bug_Condition: isBugCondition(finding=3) where isRollingPayment AND minReceived silently discarded_
    - _Expected_Behavior: revert when totalInterest > maxInterestDue_
    - _Preservation: Payment allocation, settlement, events unchanged when guard is satisfied_
    - _Requirements: 2.1, 2.3, 3.1_

  - [ ] 3.2 Replace `minReceived` with `maxInterestDue` in `repayRollingInFull`
    - In `src/equallend/EqualLendDirectRollingLifecycleFacet.sol`, function `repayRollingInFull`
    - Rename parameter `minReceived` → `maxInterestDue`
    - Remove the bare `minReceived;` statement
    - After computing `interestDue`, add: `if (interestDue > maxInterestDue) revert RollingError_InterestExceedsMax(interestDue, maxInterestDue);`
    - _Bug_Condition: isBugCondition(finding=3) where isRollingFullRepay AND minReceived silently discarded_
    - _Expected_Behavior: revert when interestDue > maxInterestDue_
    - _Preservation: Full repay flow unchanged when guard is satisfied_
    - _Requirements: 2.2, 2.3, 3.3_

  - [ ] 3.3 Verify bug condition exploration test for Finding 3 now passes
    - **Property 1: Expected Behavior** — Rolling Interest Guard
    - **IMPORTANT**: Re-run the SAME Finding 3 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --match-test BugCondition.*InterestGuard`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 3 bug is fixed)
    - _Requirements: 2.1, 2.2_

  - [ ] 3.4 Verify preservation tests still pass after Finding 3 fix
    - **Property 2: Preservation** — Rolling Payment and Full Repay Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [ ] 4. Fix Finding 5 — Separate overdue arrears cure from current-period accrual

  - [ ] 4.1 Update `applyPaymentState` to advance `nextDue` on historical arrears cure
    - In `src/libraries/LibEqualLendDirectRolling.sol`, function `applyPaymentState`
    - Change the `nextDue` advancement condition from `if (agreement.arrears == 0 && snapshot.dueCountDelta != 0)` to `if (remainingArrears == 0 && snapshot.dueCountDelta != 0)`
    - This advances `nextDue` when historical overdue arrears are fully paid, regardless of whether current-period interest remains unpaid
    - The unpaid current-period interest is still folded into `agreement.arrears` for tracking, but it no longer blocks checkpoint advancement
    - _Bug_Condition: isBugCondition(finding=5) where historicalArrearsPaid >= historicalArrearsDue AND currentInterestRemaining > 0_
    - _Expected_Behavior: nextDue advances to next checkpoint; borrower not immediately recoverable on stale checkpoint_
    - _Preservation: Genuinely delinquent positions (uncured historical arrears) still do not advance nextDue_
    - _Requirements: 2.4, 2.5, 2.6_

  - [ ] 4.2 Verify bug condition exploration test for Finding 5 now passes
    - **Property 1: Expected Behavior** — Rolling Arrears Cure Advances NextDue
    - **IMPORTANT**: Re-run the SAME Finding 5 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --match-test BugCondition.*ArrearsTrap`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 5 bug is fixed)
    - _Requirements: 2.4, 2.5_

  - [ ] 4.3 Verify preservation tests still pass after Finding 5 fix
    - **Property 2: Preservation** — Rolling Payment State Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.5_

- [ ] 5. Fix Finding 6 — Rebase rolling default penalty onto realized recovery value

  - [ ] 5.1 Compute penalty from `min(collateralSeized, totalDebt)` in `_settleRollingDefaultPath`
    - In `src/equallend/EqualLendDirectRollingLifecycleFacet.sol`, function `_settleRollingDefaultPath`
    - Replace `settlement.penaltyPaid = (totalDebt * store.rollingConfig.defaultPenaltyBps) / LibEqualLendDirectStorage.BPS_DENOMINATOR;`
    - With:
      ```
      uint256 penaltyBase = settlement.collateralSeized < totalDebt ? settlement.collateralSeized : totalDebt;
      settlement.penaltyPaid = (penaltyBase * store.rollingConfig.defaultPenaltyBps) / LibEqualLendDirectStorage.BPS_DENOMINATOR;
      ```
    - Keep the existing `if (settlement.penaltyPaid > settlement.collateralSeized)` clamp
    - _Bug_Condition: isBugCondition(finding=6) where totalDebt > collateralSeized AND applyPenalty_
    - _Expected_Behavior: penaltyPaid based on min(collateralSeized, totalDebt), not unbounded totalDebt_
    - _Preservation: Default split routing, lender credit, terminal state finalization unchanged_
    - _Requirements: 2.7, 2.8, 3.7_

  - [ ] 5.2 Verify bug condition exploration test for Finding 6 now passes
    - **Property 1: Expected Behavior** — Default Penalty on Realized Value
    - **IMPORTANT**: Re-run the SAME Finding 6 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol --match-test BugCondition.*PenaltyBase`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 6 bug is fixed)
    - _Requirements: 2.7_

  - [ ] 5.3 Verify preservation tests still pass after Finding 6 fix
    - **Property 2: Preservation** — Rolling Default Settlement Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.5, 3.6, 3.7_

- [ ] 6. Fix Finding 8 — Round fixed interest up with `Math.Rounding.Ceil`

  - [ ] 6.1 Use ceiling rounding in `_quoteFixedFees`
    - In `src/equallend/EqualLendDirectFixedAgreementFacet.sol`, function `_quoteFixedFees`
    - Replace `quote.interestAmount = Math.mulDiv(principal, uint256(aprBps) * effectiveDuration, YEAR * BPS_DENOMINATOR);`
    - With `quote.interestAmount = Math.mulDiv(principal, uint256(aprBps) * effectiveDuration, YEAR * BPS_DENOMINATOR, Math.Rounding.Ceil);`
    - This ensures nonzero principal, APR, and effective duration always produce at least 1 wei of interest
    - _Bug_Condition: isBugCondition(finding=8) where principal > 0 AND aprBps > 0 AND effectiveDuration > 0 AND floor rounds to 0_
    - _Expected_Behavior: interestAmount >= 1 for any nonzero inputs_
    - _Preservation: Normal (non-truncating) fixed fee quotes produce identical or +1 wei results_
    - _Requirements: 2.9, 2.10, 3.8, 3.9_

  - [ ] 6.2 Verify bug condition exploration test for Finding 8 now passes
    - **Property 1: Expected Behavior** — Fixed Interest Ceiling Rounding
    - **IMPORTANT**: Re-run the SAME Finding 8 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol --match-test BugCondition.*FixedInterestZero`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 8 bug is fixed)
    - _Requirements: 2.9_

  - [ ] 6.3 Verify preservation tests still pass after Finding 8 fix
    - **Property 2: Preservation** — Fixed Origination Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.8, 3.9_

- [ ] 7. Fix Lead — Round lender-ratio collateral up

  - [ ] 7.1 Use ceiling rounding in `_validateLenderRatioFill`
    - In `src/equallend/EqualLendDirectFixedAgreementFacet.sol`, function `_validateLenderRatioFill`
    - Replace `collateralRequired = Math.mulDiv(principalAmount, offer.priceNumerator, offer.priceDenominator);`
    - With `collateralRequired = Math.mulDiv(principalAmount, offer.priceNumerator, offer.priceDenominator, Math.Rounding.Ceil);`
    - _Bug_Condition: isBugCondition(finding=9) where floor rounding under-collateralizes_
    - _Expected_Behavior: collateralRequired rounds up in protocol-safe direction_
    - _Preservation: Ratio-fill validation, solvency checks, zero-collateral revert unchanged_
    - _Requirements: 2.11, 3.10, 3.11_

  - [ ] 7.2 Verify bug condition exploration test for collateral rounding now passes
    - **Property 1: Expected Behavior** — Collateral Ceiling Rounding
    - **IMPORTANT**: Re-run the SAME collateral rounding test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol --match-test BugCondition.*CollateralRounding`
    - **EXPECTED OUTCOME**: Test PASSES (confirms collateral rounding bug is fixed)
    - _Requirements: 2.11_

  - [ ] 7.3 Verify preservation tests still pass after collateral rounding fix
    - **Property 2: Preservation** — Ratio Fill Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.10, 3.11_

- [ ] 8. Fix Lead — Normalize rolling over-receive handling

  - [ ] 8.1 Cap allocatable amount in `_collectPayment` for amortization-disabled paths
    - In `src/equallend/EqualLendDirectRollingPaymentFacet.sol`, function `_collectPayment`
    - After `pullAtLeast` returns `allocation.received`, add normalization:
      ```
      uint256 allocatable = allocation.received;
      if (!agreement.allowAmortization && allocatable > amount) {
          allocatable = amount;
      }
      ```
    - Use `allocatable` instead of `allocation.received` for the waterfall allocation (arrears → current interest → principal)
    - Set `allocation.refund` to include `allocation.received - allocatable` surplus at the end
    - Remove the pre-pull amortization guard (`if (!agreement.allowAmortization && amount > interestDue)`) since the post-allocation logic with capped `allocatable` handles it correctly
    - Keep the post-allocation amortization check for genuine principal reduction attempts
    - _Bug_Condition: isBugCondition(finding=10) where !allowAmortization AND received > amount_
    - _Expected_Behavior: payment succeeds, surplus refunded, no spurious amortization revert_
    - _Preservation: Genuine principal reduction on amortization-disabled agreements still reverts_
    - _Requirements: 2.12, 2.13_

  - [ ] 8.2 Verify bug condition exploration test for over-receive now passes
    - **Property 1: Expected Behavior** — Over-Receive Normalization
    - **IMPORTANT**: Re-run the SAME over-receive test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --match-test BugCondition.*OverReceive`
    - **EXPECTED OUTCOME**: Test PASSES (confirms over-receive bug is fixed)
    - _Requirements: 2.12_

  - [ ] 8.3 Verify preservation tests still pass after over-receive fix
    - **Property 2: Preservation** — Rolling Payment Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.2_

- [ ] 9. Fix Lead — Enforce rolling `maxPaymentCount` as hard cap

  - [ ] 9.1 Add payment cap check in `makeRollingPayment`
    - In `src/equallend/EqualLendDirectRollingPaymentFacet.sol`, function `makeRollingPayment`
    - After `_settleAgreementPositions`, before accrual computation, add:
      ```
      if (agreement.paymentCount >= agreement.maxPaymentCount) {
          revert RollingError_PaymentCapReached();
      }
      ```
    - Declare `RollingError_PaymentCapReached()` error in `src/libraries/Errors.sol`
    - Keep `repayRollingInFull` behavior unchanged — terminal repayment remains possible
    - _Bug_Condition: isBugCondition(finding=11) where paymentCount >= maxPaymentCount_
    - _Expected_Behavior: makeRollingPayment reverts at payment cap_
    - _Preservation: repayRollingInFull still follows intended closeout policy_
    - _Requirements: 2.14, 2.15_

  - [ ] 9.2 Verify bug condition exploration test for payment cap now passes
    - **Property 1: Expected Behavior** — Payment Cap Enforcement
    - **IMPORTANT**: Re-run the SAME payment cap test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --match-test BugCondition.*PaymentCap`
    - **EXPECTED OUTCOME**: Test PASSES (confirms payment cap bug is fixed)
    - _Requirements: 2.14_

  - [ ] 9.3 Verify preservation tests still pass after payment cap fix
    - **Property 2: Preservation** — Rolling Payment and Full Repay Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.3, 3.4_

- [ ] 10. Fix Lead — Normalize `setAumFee` access control

  - [ ] 10.1 Change `setAumFee` to use `enforceOwnerOrTimelock()`
    - In `src/equallend/PoolManagementFacet.sol`, function `setAumFee`
    - Replace `LibAccess.enforceTimelockOrOwnerIfUnset();` with `LibAccess.enforceOwnerOrTimelock();`
    - Keep existing bounds checks and event behavior unchanged
    - _Bug_Condition: isBugCondition(finding=12) where callerIsOwner AND timelockConfigured_
    - _Expected_Behavior: owner can call setAumFee after timelock is configured_
    - _Preservation: Timelock retains same authority; non-owner non-timelock callers still revert; bounds checks unchanged_
    - _Requirements: 2.16, 2.17, 3.12, 3.13_

  - [ ] 10.2 Verify bug condition exploration test for `setAumFee` now passes
    - **Property 1: Expected Behavior** — `setAumFee` Owner Access
    - **IMPORTANT**: Re-run the SAME `setAumFee` test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/PoolAumFacet.t.sol --match-test BugCondition.*AumFeeOwner`
    - **EXPECTED OUTCOME**: Test PASSES (confirms `setAumFee` access control bug is fixed)
    - _Requirements: 2.16_

  - [ ] 10.3 Update existing `setAumFee` tests to reflect new access control
    - In `test/PoolAumFacet.t.sol`, update `test_SetAumFee_IsTimelockOnlyAndEmitsEvent` to verify owner can also call after timelock is configured
    - Verify timelock still works
    - Verify non-owner non-timelock still reverts
    - Run: `forge test --match-path test/PoolAumFacet.t.sol`
    - **EXPECTED OUTCOME**: All tests PASS
    - _Requirements: 2.16, 2.17, 3.12, 3.13_

- [ ] 11. Refresh and expand EqualLend regression tests

  - [ ] 11.1 Add rolling full lifecycle integration test
    - Originate rolling agreement → make payments with `maxInterestDue` guard → repay in full
    - Proves Finding 3 fix end-to-end through a value-moving live flow
    - Use real deposits, real offers, real origination, real payments, real full repay
    - Run: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol`
    - _Requirements: 2.1, 2.2, 2.3_

  - [ ] 11.2 Add rolling catch-up lifecycle integration test
    - Originate → miss multiple payments → pay historical arrears → verify not immediately recoverable → make current payment → verify clean state
    - Proves Finding 5 fix end-to-end with real overdue-state transitions
    - Run: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol`
    - _Requirements: 2.4, 2.5, 2.6_

  - [ ] 11.3 Add rolling default penalty integration test
    - Originate → warp far past due → trigger `recoverRolling` → verify penalty based on realized recovery value
    - Verify lender recovery does not degrade solely because `totalDebt` increased
    - Run: `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol`
    - _Requirements: 2.7, 2.8_

  - [ ] 11.4 Add fixed small-loan integration test
    - Originate fixed agreement with small principal, low APR, short duration → verify nonzero interest charged
    - Verify fixed and rolling fee behavior are directionally aligned on rounding
    - Run: `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol`
    - _Requirements: 2.9, 2.10_

  - [ ] 11.5 Add lender-ratio fill collateral rounding integration test
    - Create lender-ratio offer → fill tranche → verify collateral rounded up
    - Verify no valid fill can under-collateralize solely because of floor rounding
    - Run: `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol`
    - _Requirements: 2.11_

  - [ ] 11.6 Add rolling payment cap lifecycle integration test
    - Originate → make `maxPaymentCount` payments → verify next `makeRollingPayment` reverts → verify `repayRollingInFull` still succeeds
    - Run: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol`
    - _Requirements: 2.14, 2.15_

  - [ ] 11.7 Add AUM fee admin lifecycle integration test
    - Configure timelock → owner sets fee → verify success → timelock sets fee → verify success → non-owner non-timelock → verify revert
    - Run: `forge test --match-path test/PoolAumFacet.t.sol`
    - _Requirements: 2.16, 2.17_

  - Verification runs:
    - `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol`
    - `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol`
    - `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol`
    - `forge test --match-path test/PoolAumFacet.t.sol`

- [ ] 12. Checkpoint — Run targeted EqualLend test suites and ensure all tests pass
  - Run: `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol`
  - Run: `forge test --match-path test/EqualLendDirectFixedAgreementFacet.t.sol`
  - Run: `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol`
  - Run: `forge test --match-path test/PoolAumFacet.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all eight bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ask the user if questions arise
