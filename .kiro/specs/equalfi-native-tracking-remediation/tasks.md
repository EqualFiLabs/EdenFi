# Implementation Plan

- [x] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — Native Transfer Tracking Drift and assertMsgValue Zero Bypass
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/LibCurrency.t.sol`
  - Use a minimal test harness that exposes `LibCurrency` functions via a diamond or direct library wrapper
  - Use real ETH sends, real `msg.value` manipulation, real `nativeTrackedTotal` reads — no synthetic shortcuts
  - **Finding 1 — transfer tracking drift**: Deposit native ETH via `pull(address(0), from, 1 ether)` with `msg.value = 1 ether`, then call `transfer(address(0), recipient, 1 ether)`. Assert `nativeTrackedTotal` decreased by 1 ether. On unfixed code this will FAIL because `transfer` does not decrement `nativeTrackedTotal`.
  - **Finding 1 — transferWithMin tracking drift**: Deposit native ETH via `pull()`, then call `transferWithMin(address(0), recipient, 1 ether, 0.99 ether)`. Assert `nativeTrackedTotal` decreased by 1 ether. On unfixed code this will FAIL because `transferWithMin` does not decrement `nativeTrackedTotal`.
  - **Finding 1 — cumulative drift**: Execute 5 sequential native transfers of 1 ETH each after a 5 ETH deposit via `pull()`. Assert `nativeTrackedTotal` returns to 0 (or pre-deposit baseline). On unfixed code this will FAIL because `nativeTrackedTotal` stays inflated by 5 ETH.
  - **Finding 2 — assertMsgValue zero bypass**: Call `assertMsgValue(address(0), 1 ether)` with `msg.value = 0`. Assert it reverts with `UnexpectedMsgValue`. On unfixed code this will FAIL because the short-circuit AND allows `msg.value = 0` to pass.
  - **Finding 2 — orphaned ETH theft**: Seed contract with orphaned ETH (e.g., via `selfdestruct` or direct `call`), call deposit flow with `msg.value = 0`, assert `pull()` does NOT credit orphaned ETH to caller. On unfixed code this will FAIL because `assertMsgValue` passes and `pull()` claims `nativeAvailable()` as the deposit.
  - Run tests on UNFIXED code: `forge test --match-path test/LibCurrency.t.sol`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Observed counterexamples on unfixed code:
    - `test_BugCondition_Transfer_ShouldDecreaseNativeTrackedTotal`: `nativeTrackedTotal` stayed `1 ether` instead of decreasing to `0`
    - `test_BugCondition_TransferWithMin_ShouldDecreaseNativeTrackedTotal`: `nativeTrackedTotal` stayed `1 ether` instead of decreasing to `0`
    - `test_BugCondition_CumulativeTransfers_ShouldReturnNativeTrackedTotalToBaseline`: `nativeTrackedTotal` stayed `5 ether` instead of returning to `0`
    - `test_BugCondition_AssertMsgValue_ShouldRevertWhenNativeAmountHasZeroMsgValue`: call did not revert when `msg.value = 0` and `amount = 1 ether`
    - `test_BugCondition_AssertMsgValueZeroBypass_ShouldNotAllowClaimingOrphanedEth`: call did not revert and was able to proceed against orphaned native balance
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7_

- [x] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — LibCurrency Unchanged Behavior Across ERC-20, Native Receive, Validation, and Utility Paths
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/LibCurrency.t.sol`
  - Use the same test harness from task 1
  - Use real token deploys, real approvals, real ETH sends — no synthetic shortcuts
  - **ERC-20 transfer preservation**: Verify `transfer()` for ERC-20 tokens executes `safeTransfer` without touching `nativeTrackedTotal`
  - **ERC-20 transferWithMin preservation**: Verify `transferWithMin()` for ERC-20 tokens executes identically without touching `nativeTrackedTotal`
  - **ERC-20 pull preservation**: Verify `pull()` for ERC-20 tokens executes `safeTransferFrom` with balance-delta accounting without touching `nativeTrackedTotal`
  - **ERC-20 pullAtLeast preservation**: Verify `pullAtLeast()` for ERC-20 tokens executes identically without touching `nativeTrackedTotal`
  - **Native pull preservation**: Verify `pull(address(0), from, amount)` with `msg.value == amount` increments `nativeTrackedTotal` by `amount`
  - **Native pullAtLeast preservation**: Verify `pullAtLeast(address(0), from, min, max)` with `msg.value == max` increments `nativeTrackedTotal` by `max`
  - **assertMsgValue ERC-20 preservation**: Verify `assertMsgValue(erc20, amount)` with `msg.value = 0` passes, and with `msg.value > 0` reverts
  - **assertZeroMsgValue preservation**: Verify `assertZeroMsgValue()` with `msg.value > 0` reverts
  - **Zero-amount transfer preservation**: Verify `transfer(address(0), to, 0)` returns early without modifying `nativeTrackedTotal` or executing any ETH send
  - **Zero-amount pull preservation**: Verify `pull(address(0), from, 0)` returns 0 without modifying `nativeTrackedTotal`
  - **Utility function preservation**: Verify `balanceOfSelf(address(0))` returns `address(this).balance`, `nativeAvailable()` returns `balance - tracked` clamped to 0, `decimals(address(0))` returns 18
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/LibCurrency.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Observed baseline on unfixed code:
    - `forge test --match-path test/LibCurrency.t.sol --no-match-test BugCondition`
    - Result: `11/11` preservation tests passed
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.14, 3.15_


- [x] 3. Fix Finding 1 — Auto-decrement `nativeTrackedTotal` in `transfer` and `transferWithMin`

  - [x] 3.1 Add auto-decrement to `LibCurrency.transfer` for native ETH
    - In `src/libraries/LibCurrency.sol`, function `transfer`
    - In the `isNative(token)` branch, add `LibAppStorage.s().nativeTrackedTotal -= amount;` before the ETH send
    - The existing `amount == 0` early return already guards against decrementing zero
    - _Bug_Condition: isBugCondition(finding=1) where isTransfer AND isNative(token) AND amount > 0_
    - _Expected_Behavior: nativeTrackedTotal decreases by amount on every native transfer_
    - _Preservation: ERC-20 path unchanged; zero-amount early return unchanged_
    - _Requirements: 2.1, 3.1, 3.14_

  - [x] 3.2 Add auto-decrement to `LibCurrency.transferWithMin` for native ETH
    - In `src/libraries/LibCurrency.sol`, function `transferWithMin`
    - In the `isNative(token)` branch, add `LibAppStorage.s().nativeTrackedTotal -= amount;` before the ETH send
    - The existing `amount == 0` early return already guards against decrementing zero
    - _Bug_Condition: isBugCondition(finding=1) where isTransferWithMin AND isNative(token) AND amount > 0_
    - _Expected_Behavior: nativeTrackedTotal decreases by amount on every native transferWithMin_
    - _Preservation: ERC-20 path unchanged; minimum-received validation unchanged; zero-amount early return unchanged_
    - _Requirements: 2.2, 3.2, 3.14_

  - [x] 3.3 Verify bug condition exploration tests for Finding 1 now pass
    - **Property 1: Expected Behavior** — Native Transfer Tracking Symmetry
    - **IMPORTANT**: Re-run the SAME Finding 1 tests from task 1 — do NOT write new tests
    - The tests from task 1 assert `nativeTrackedTotal` decreases by `amount` after `transfer()` and `transferWithMin()`
    - When these tests pass, it confirms the expected behavior is satisfied
    - Run: `forge test --match-path test/LibCurrency.t.sol --match-test BugCondition.*Transfer`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 1 bug is fixed)
    - Observed result:
      - `forge test --match-path test/LibCurrency.t.sol --match-test 'BugCondition.*Transfer'`
      - Result: `3/3` Finding 1 bug-condition tests passed
    - _Requirements: 2.1, 2.2_

  - [x] 3.4 Verify preservation tests still pass after Finding 1 fix
    - **Property 2: Preservation** — LibCurrency ERC-20, Native Receive, Utility Paths
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibCurrency.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed result:
      - `forge test --match-path test/LibCurrency.t.sol --no-match-test BugCondition`
      - Result: `11/11` preservation tests passed
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.10, 3.11, 3.12, 3.14, 3.15_

- [x] 4. Fix Finding 2 — Strict `msg.value` validation in `assertMsgValue`

  - [x] 4.1 Replace short-circuit AND with separate native/ERC-20 branches in `assertMsgValue`
    - In `src/libraries/LibCurrency.sol`, function `assertMsgValue`
    - Replace `if (msg.value != 0 && msg.value != amount)` with `if (msg.value != amount)`
    - This ensures `msg.value = 0` reverts when `amount > 0` for native paths
    - The ERC-20 branch (`if (msg.value != 0)`) remains unchanged
    - _Bug_Condition: isBugCondition(finding=2) where isAssertMsgValue AND isNative(token) AND msgValue == 0 AND amount > 0_
    - _Expected_Behavior: revert with UnexpectedMsgValue when msg.value != amount for native_
    - _Preservation: ERC-20 assertMsgValue unchanged; assertMsgValue(native, amount) with msg.value == amount still passes; assertMsgValue(native, 0) with msg.value == 0 still passes_
    - _Requirements: 2.4, 2.5, 3.7, 3.8_

  - [x] 4.2 Verify bug condition exploration tests for Finding 2 now pass
    - **Property 1: Expected Behavior** — Strict msg.value Validation
    - **IMPORTANT**: Re-run the SAME Finding 2 tests from task 1 — do NOT write new tests
    - The tests from task 1 assert `assertMsgValue(address(0), amount)` reverts when `msg.value = 0` and `amount > 0`
    - Run: `forge test --match-path test/LibCurrency.t.sol --match-test BugCondition.*MsgValue`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 2 bug is fixed)
    - Observed result:
      - `forge test --match-path test/LibCurrency.t.sol --match-test 'BugCondition.*MsgValue'`
      - Result: `2/2` Finding 2 bug-condition tests passed
    - _Requirements: 2.4, 2.5_

  - [x] 4.3 Verify preservation tests still pass after Finding 2 fix
    - **Property 2: Preservation** — LibCurrency Validation Paths
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibCurrency.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed result:
      - `forge test --match-path test/LibCurrency.t.sol --no-match-test BugCondition`
      - Result: `11/11` preservation tests passed
    - _Requirements: 3.7, 3.8, 3.9_


- [x] 5. Prune downstream confirmed Category A double-decrement sites

  - [x] 5.1 Prune A1 — `EqualIndexActionsFacetV3.sol` ~L274-277 (leg payout)
    - In `src/equalindex/EqualIndexActionsFacetV3.sol`
    - Remove `nativeTrackedTotal -= leg.payout` before `transfer(leg.asset, to, leg.payout)`
    - The library `transfer()` now auto-decrements for native ETH
    - _Requirements: 2.3, 3.13_

  - [x] 5.2 Prune A2 — `EqualIndexActionsFacetV3.sol` ~L394-396 (treasury fee)
    - In `src/equalindex/EqualIndexActionsFacetV3.sol`
    - Remove `nativeTrackedTotal -= toTreasury` before `transfer(pool.underlying, treasury, toTreasury)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.3 Prune A3 — `EqualIndexLendingFacet.sol` ~L462-465 (loan repayment)
    - In `src/equalindex/EqualIndexLendingFacet.sol`
    - Remove `nativeTrackedTotal -= principal` before `transfer(asset, msg.sender, principal)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.4 Prune A4 — `EqualXCommunityAmmFacet.sol` ~L536-538 (swap output)
    - In `src/equalx/EqualXCommunityAmmFacet.sol`
    - Remove `nativeTrackedTotal -= outputToRecipient` after `transferWithMin(...)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.5 Prune A5 — `EqualXSoloAmmFacet.sol` ~L889-891 (swap output)
    - In `src/equalx/EqualXSoloAmmFacet.sol`
    - Remove `nativeTrackedTotal -= amountOut` after `transferWithMin(...)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.6 Prune A6 — `OptionsFacet.sol` ~L311-314 (excess refund)
    - In `src/options/OptionsFacet.sol`
    - Remove `nativeTrackedTotal -= excess` before `transfer(asset, payer, excess)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.7 Prune A8 — `LibMaintenance.sol` ~L232-235 (maintenance fee)
    - In `src/libraries/LibMaintenance.sol`
    - Remove `nativeTrackedTotal -= paid` before `transferWithMin(p.underlying, receiver, paid, paid)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.8 Prune A9 — `LibEqualXCurveEngine.sol` ~L273-276 (quote excess)
    - In `src/libraries/LibEqualXCurveEngine.sol`
    - Remove `nativeTrackedTotal -= excess` before `transfer(preview.quoteToken, msg.sender, excess)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.9 Prune A10 — `LibEqualXCurveEngine.sol` ~L278-281 (base output)
    - In `src/libraries/LibEqualXCurveEngine.sol`
    - Remove `nativeTrackedTotal -= preview.amountOut` before `transferWithMin(preview.baseToken, ...)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.10 Prune A12 — `LibFeeRouter.sol` ~L203-206 (treasury transfer)
    - In `src/libraries/LibFeeRouter.sol`
    - Remove `nativeTrackedTotal -= amount` before `transfer(pool.underlying, treasury, amount)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.11 Prune A13 — `LibFeeRouter.sol` ~L225-227 (duplicate treasury transfer)
    - In `src/libraries/LibFeeRouter.sol`
    - Remove `nativeTrackedTotal -= amount` before `transfer(...)` in duplicate `_transferTreasury` path
    - _Requirements: 2.3, 3.13_

  - [x] 5.12 Prune A16 — `EqualLendDirectRollingLifecycleFacet.sol` ~L383-386 (treasury fee)
    - In `src/equallend/EqualLendDirectRollingLifecycleFacet.sol`
    - Remove `nativeTrackedTotal -= amount` before `transfer(collateralPool.underlying, treasury, amount)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.13 Prune A18 — `SelfSecuredCreditFacet.sol` ~L259-262 (SSC surplus)
    - In `src/equallend/SelfSecuredCreditFacet.sol`
    - Remove `nativeTrackedTotal -= surplus` before `transfer(pool.underlying, msg.sender, surplus)`
    - _Requirements: 2.3, 3.13_

  - [x] 5.14 Verify compilation after all confirmed Category A pruning
    - Run: `forge test --match-path test/LibCurrency.t.sol` (quick compile check)
    - Ensure no compilation errors from removed lines
    - Observed result:
      - `forge test --match-path test/LibCurrency.t.sol`
      - Result: compile successful and `16/16` `LibCurrency` tests passed
    - _Requirements: 2.3, 3.13_


- [x] 6. Resolve manual call-graph audit sites before pruning

  - [x] 6.1 Audit R1 — `OptionsFacet.sol` helper decrement
    - Confirm whether `nativeTrackedTotal -= amount` in the helper is always paired with a downstream native `transfer()`
    - If yes, promote to confirmed prune and remove it in this spec
    - If no, document the pattern and leave it intact
    - Observed result:
      - `_decreasePrincipalAndTransfer(...)` was always paired with downstream native `transferWithMin(...)`
      - Promoted and pruned in this spec
    - _Requirements: 2.3, 3.13_

  - [x] 6.2 Audit R2 — `LibEqualLendDirectAccounting.sol` helper decrement
    - Confirm whether the decrement is a true decrement-before-transfer site or a helper-layer accounting adjustment
    - Promote or retain based on the actual caller graph
    - Observed result:
      - `departLenderCapital(...)` is helper-layer accounting used during direct-loan origination, not an immediate outbound native send
      - Retained unchanged; not promoted into the prune set
    - _Requirements: 2.3, 3.13_

  - [x] 6.3 Audit R3-R4 — `PositionManagementFacet.sol` claim and withdraw paths
    - Confirm whether both decrements are immediately consumed by `transfer()` paths
    - Promote only the true decrement-before-transfer sites
    - Observed result:
      - `claimPositionYield(...)` and `_withdrawFromPosition(...)` both decremented immediately before downstream native `transferWithMin(...)`
      - Promoted and pruned in this spec
    - _Requirements: 2.3, 3.13_

  - [x] 6.4 Audit R5 — `SelfSecuredCreditFacet.sol` SSC draw path
    - Confirm whether the decrement is paired with outbound native settlement or represents internal pool accounting
    - Promote or retain based on the actual flow
    - Observed result:
      - `drawSelfSecuredCredit(...)` decremented immediately before downstream native `transferWithMin(...)`
      - Promoted and pruned in this spec
    - _Requirements: 2.3, 3.13_

  - [x] 6.5 Audit R6 — `EqualScaleAlphaFacet.sol` settlement path
    - Confirm whether the decrement is followed by outbound native `transfer()` in the same logical flow
    - Promote or retain based on the actual flow
    - Observed result:
      - `draw(...)` decremented immediately before downstream native `transfer(...)`
      - Promoted and pruned in this spec
    - _Requirements: 2.3, 3.13_

  - [x] 6.6 Verify compilation after any promoted audit-site pruning
    - Run: `forge test --match-path test/LibCurrency.t.sol`
    - Ensure promoted audit-site edits compile and do not underflow at runtime
    - Observed result:
      - `forge test --match-path test/LibCurrency.t.sol`
      - Result: compile successful and `20/20` `LibCurrency` tests passed
    - _Requirements: 2.3, 3.13_


- [x] 7. Write fix verification tests — downstream double-decrement and integration

  - [x] 7.1 Add native transfer tracking invariant test
    - Test file: `test/LibCurrency.t.sol`
    - Execute N pulls and M transfers for native ETH with varying amounts
    - Assert `nativeTrackedTotal == sum(pulls) - sum(transfers)` after all operations
    - Verify `nativeAvailable()` returns correct value throughout
    - Run: `forge test --match-path test/LibCurrency.t.sol`
    - Observed result:
      - Covered by `test_NativeTransferTrackingInvariant_MatchesPullsMinusTransfers`
    - _Requirements: 2.1, 2.2, 3.11_

  - [x] 7.2 Add assertMsgValue exhaustive validation test
    - Test file: `test/LibCurrency.t.sol`
    - Test `assertMsgValue(address(0), amount)` with `msg.value == amount` — passes
    - Test `assertMsgValue(address(0), amount)` with `msg.value != amount` (including 0) — reverts
    - Test `assertMsgValue(address(0), 0)` with `msg.value == 0` — passes (legitimate zero-amount)
    - Test `assertMsgValue(erc20, amount)` with `msg.value == 0` — passes
    - Test `assertMsgValue(erc20, amount)` with `msg.value > 0` — reverts
    - Run: `forge test --match-path test/LibCurrency.t.sol`
    - Observed result:
      - Covered by `test_AssertMsgValue_ExhaustiveValidation`
    - _Requirements: 2.4, 2.5, 3.7, 3.8_

  - [x] 7.3 Add full native lifecycle integration test
    - Test file: `test/LibCurrency.t.sol`
    - Deposit via `pull()` → verify tracking increment → withdraw via `transfer()` → verify tracking decrement → verify `nativeTrackedTotal` returns to original value
    - Multi-pool variant: deposit into pool A and pool B → transfer from pool A → transfer from pool B → verify aggregate `nativeTrackedTotal` is correct
    - Run: `forge test --match-path test/LibCurrency.t.sol`
    - Observed result:
      - Covered by `test_NativeLifecycleIntegration_SingleAndMultiPoolTracking`
    - _Requirements: 2.1, 2.2, 3.5, 3.11_

  - [x] 7.4 Add orphaned ETH protection integration test
    - Test file: `test/LibCurrency.t.sol`
    - Seed contract with orphaned ETH (via selfdestruct or direct call)
    - Attempt deposit with `msg.value = 0` for native path
    - Verify revert from `assertMsgValue` — attacker cannot claim orphaned ETH
    - Run: `forge test --match-path test/LibCurrency.t.sol`
    - Observed result:
      - Covered by `test_OrphanedEthProtectionIntegration_RevertsBeforePull`
    - _Requirements: 2.4, 2.6_

  - [x] 7.5 Add downstream double-decrement smoke tests
    - Test file: `test/NativeTrackingDownstream.t.sol`
    - Use real deposits, real pool operations, real transfers per workspace guidelines
    - Include only sites promoted into the confirmed prune set after task 6 audit
    - For retained audit sites, add documentation or a narrow smoke test proving why they were not pruned
    - Implemented promoted-site coverage:
      - `test_PositionClaimYield_NativeTrackedTotalDecrementsExactlyOnce`
      - `test_PositionWithdraw_NativeTrackedTotalDecrementsExactlyOnce`
      - `test_OptionsExcessRefund_NativeTrackedTotalDecrementsExactlyOnce`
      - `test_SelfSecuredCreditDraw_NativeTrackedTotalDecrementsExactlyOnce`
      - `test_EqualScaleDraw_NativeTrackedTotalDecrementsExactlyOnce`
    - Retained-site documentation:
      - `LibEqualLendDirectAccounting.departLenderCapital(...)` remains unchanged because it is helper-layer accounting, not an immediate outbound native transfer site
    - Each test verifies `nativeTrackedTotal` before and after the operation, asserting exactly one decrement of the expected amount
    - Run: `forge test --match-path test/NativeTrackingDownstream.t.sol`
    - Observed result:
      - `forge test --match-path test/NativeTrackingDownstream.t.sol`
      - Result: `5/5` downstream smoke tests passed
    - _Requirements: 2.3, 3.13_

- [x] 8. Verify Category B and Category C sites are unaffected

  - [x] 8.1 Verify Category B pull-then-undo sites are unchanged
    - Confirm B1 (`EqualLendDirectRollingPaymentFacet.sol` ~L91-93), B2 (`EqualLendDirectRollingLifecycleFacet.sol` ~L148-151), B3 (`EqualLendDirectLifecycleFacet.sol` ~L66-68) are NOT modified
    - These sites call `pull()` / `pullAtLeast()` then decrement `nativeTrackedTotal` — they undo the pull's auto-increment, not a transfer
    - Verify these flows still work correctly via existing test suites or a targeted smoke test
    - Observed result:
      - `git diff -- src/equallend/EqualLendDirectRollingPaymentFacet.sol src/equallend/EqualLendDirectRollingLifecycleFacet.sol src/equallend/EqualLendDirectLifecycleFacet.sol` showed no modifications to the Category B sites
      - B1/B2/B3 remain pull-then-undo accounting sites; they were not pruned in this remediation
      - `forge test --match-path test/EqualLendDirectRollingPaymentFacet.t.sol` -> `8/8` passed, including `test_repayRollingInFull_clearsRollingAgreementAndUnlocksCollateral`
      - `forge test --match-path test/EqualLendDirectLifecycleFacet.t.sol` -> `5/5` passed, including native repay lifecycle coverage
      - `forge test --match-path test/EqualLendDirectRollingLifecycleFacet.t.sol` reported `No tests found in project!`; rolling-payment coverage was used as the live verification anchor for the repay-in-full path
    - _Requirements: 3.5, 3.6_

  - [x] 8.2 Verify Category C trackedBalance-only sites are unchanged
    - Confirm C1 (`EqualXCommunityAmmFacet.sol` ~L799-802) and C2 (`EqualXSoloAmmFacet.sol` ~L841-844) are NOT modified
    - These sites decrement `nativeTrackedTotal` as part of `pool.trackedBalance` accounting without calling `transfer()`
    - Verify no `transfer()` call follows these decrements
    - Observed result:
      - `git diff -- src/equalx/EqualXCommunityAmmFacet.sol src/equalx/EqualXSoloAmmFacet.sol` showed no Category C changes in this remediation step
      - Code inspection confirmed the C1/C2 decrements remain trackedBalance-only accounting adjustments
      - No downstream `LibCurrency.transfer(...)` or `LibCurrency.transferWithMin(...)` call follows either Category C decrement block
    - _Requirements: 3.13_

- [x] 9. Checkpoint — Run full test suite and ensure all tests pass
  - Run: `forge test --match-path test/LibCurrency.t.sol`
  - Run: `forge test --match-path test/NativeTrackingDownstream.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming both findings are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all fix verification and downstream integration tests PASS (confirming end-to-end correctness)
  - Ensure Category B and C sites are verified unaffected
  - Observed result:
    - `forge test --match-path test/LibCurrency.t.sol` -> `20/20` passed
    - `forge test --match-path test/NativeTrackingDownstream.t.sol` -> `5/5` passed
    - Finding 1 and Finding 2 bug-condition tests now pass inside the full `LibCurrency` suite
    - Preservation, fix verification, and downstream integration coverage all passed in the checkpoint runs
    - Category B pull-then-undo and Category C trackedBalance-only sites were verified unaffected
  - Ask the user if questions arise
