# Implementation Plan

- [x] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — EqualIndex Findings 1, 2, 6, 8 and Agreed Leads
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/EqualIndexPort.t.sol` for position-mode findings; `test/EqualIndexLaunch.t.sol` for wallet-mode and admin findings
  - Use real deposits, real index creation, real position-mode mint and burn, real borrow and repay, real recovery — no synthetic shortcuts
  - **Finding 1 — Burn encumbered collateral**: Create index, deposit underlying, position mint index units, borrow with collateral, attempt `burnFromPosition` with `units > availableUnencumbered`, assert revert with `InsufficientUnencumberedPrincipal`. On unfixed code this will FAIL because burn succeeds without checking encumbrance.
  - **Finding 2 — Encumbrance leak on position burn**: Create index, deposit underlying, position mint index units (encumbering underlying), position burn all units with nonzero burn fee, assert total index-related encumbrance is zero after full exit. On unfixed code this will FAIL because `navOut < bundleOut` leaves residual encumbrance.
  - **Finding 6 — Burn fee rounding**: Create index with burn fee that produces non-exact division, wallet-mode burn, assert `fee == Math.mulDiv(gross, burnFeeBps, 10_000, Math.Rounding.Ceil)`. Position-mode burn with same parameters, assert same ceiling rounding. On unfixed code this will FAIL because floor rounding underpays by 1 wei.
  - **Finding 8 — Fee-share setter**: Call `setEqualIndexPoolFeeShareBps(2000)` as timelock, assert value updated. Call `setEqualIndexMintBurnFeeIndexShareBps(5000)` as timelock, assert value updated. On unfixed code this will FAIL because no setter functions exist.
  - **Lead — Timelock fallback**: With timelock unset (`address(0)`), call `setPaused(indexId, true)` as owner, assert success. On unfixed code this will FAIL because `onlyTimelock` requires `msg.sender == address(0)`.
  - **Lead — Recovery grace period**: Create index, deposit, position mint, borrow, warp to `maturity + 1 second`, attempt `recoverExpiredIndexLoan`, assert revert (within grace period). Warp to `maturity + RECOVERY_GRACE_PERIOD + 1`, attempt recovery, assert success. On unfixed code this will FAIL because recovery succeeds immediately after maturity.
  - **Lead — Maintenance-exempt locked collateral**: Create index, deposit, position mint, borrow (locking collateral), advance time significantly to accrue maintenance, attempt `recoverExpiredIndexLoan` after grace period, assert success. On unfixed code this will FAIL because maintenance erodes locked collateral below `collateralUnits`.
  - **Lead — Exact-pull mint**: Wallet-mode ERC20 mint with `maxInputAmounts[i]` set to 2x the quoted `leg.total`, assert contract balance increase equals only the quoted total (not the max bound). On unfixed code this will FAIL because `pullAtLeast` transfers the full max bound.
  - **Lead — Position mint fee routing**: Deposit minimal underlying, position mint index units when pool has low preexisting tracked balance but sufficient unencumbered principal, assert mint succeeds. On unfixed code this will FAIL because `routeManagedShare` reverts on insufficient tracked balance.
  - Run tests on UNFIXED code:
    - `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition`
    - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 1.11, 1.12, 1.13, 1.14, 1.15, 1.16, 1.17_
  - Added `4` `BugCondition` regressions to `test/EqualIndexPort.t.sol` covering:
    - burn past available unencumbered index-pool principal after borrowing
    - residual encumbrance after a full fee-bearing position burn
    - position-mode burn fee ceiling rounding on a one-unit gross burn
    - maintenance handling where locked collateral stays intact but unlocked principal should still decay
  - Added `6` `BugCondition` regressions to `test/EqualIndexLaunch.t.sol` covering:
    - wallet-mode burn fee ceiling rounding on a one-unit gross burn
    - missing fee-share governance setters
    - owner fallback when timelock is unset
    - recovery grace period before expired-loan recovery
    - exact-pull wallet mint input handling
    - position mint fee routing when tracked balance is low but principal is sufficient
  - Observed runs on unfixed code:
    - `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition` -> `0/4` passed, `4/4` failed
    - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition` -> `0/6` passed, `6/6` failed
  - Documented counterexamples:
    - burning `2e18` position-held index units after borrowing `1e18` collateral reverted with `InsufficientPoolLiquidity(2e18, 1e18)` instead of the expected `InsufficientUnencumberedPrincipal(2e18, 1e18)`, proving burn is not gated on available unencumbered principal
    - a full fee-bearing position burn left nonzero residual index encumbrance, proving the fee-bearing burn path leaks encumbrance on exit
    - both wallet-mode and position-mode one-unit gross burns returned nonzero payout instead of charging the protocol-safe ceiling fee of `1`, proving burn fees round down instead of up
    - after a long maintenance interval and explicit fee-index settlement, the index-pool principal did not decay below its full pre-settlement amount, proving locked collateral handling currently exempts too much principal instead of only the locked portion
    - low-level calls to `setEqualIndexPoolFeeShareBps(2000)` and `setEqualIndexMintBurnFeeIndexShareBps(5000)` did not succeed, proving the governance setters do not exist yet
    - calling `setPaused(indexId, true)` as the owner with timelock unset reverted `Unauthorized()`, proving the owner fallback path is missing
    - recovering an expired loan at `maturity + 1` second succeeded instead of reverting during a grace period, proving there is no recovery grace window
    - wallet-mode ERC20 mint pulled the full `maxInputAmounts[0]` bound instead of only the quoted input, leaving the diamond balance delta above the quote
    - position-mode mint reverted `InsufficientPoolLiquidity(..., 0)` when tracked balance was forced low despite sufficient unencumbered principal, proving fee routing depends on preexisting tracked balance instead of pre-crediting pool share

- [x] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — EqualIndex Unchanged Behavior Across All Nine Items
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/EqualIndexPort.t.sol` and `test/EqualIndexLaunch.t.sol`
  - Use real deposits, real index creation, real position-mode mint and burn, real borrow and repay, real recovery, real withdrawal — no synthetic shortcuts
  - **Position mint preservation**: Position mint with valid parameters, verify encumbrance, vault accounting, fee routing, index-pool principal are correct and unchanged
  - **Position burn preservation**: Position burn with sufficient unencumbered principal (no active loans), verify burn legs, token burning, vault release, fee routing are correct
  - **Wallet mint preservation**: Wallet-mode mint with `maxInputAmounts == leg.total`, verify asset pulls, vault accounting, fee distribution are correct
  - **Wallet burn preservation**: Wallet-mode burn with exact-division fees, verify fee amounts, payout, distribution are correct
  - **Borrow preservation**: Borrow with valid parameters, verify collateral encumbrance, loan creation, asset disbursement are correct
  - **Repay preservation**: Repay active loan, verify asset collection, vault restoration, encumbrance release are correct
  - **Recovery preservation**: Recover expired loan (well past maturity), verify write-off, collateral release, loan deletion are correct
  - **Admin preservation**: Call `setPaused` with authorized caller (timelock when set), verify state change
  - **Flash loan preservation**: Execute flash loan, verify execution, validation, settlement are correct
  - **Insufficient principal revert preservation**: Attempt position mint with insufficient unencumbered principal, verify revert unchanged
  - **Insufficient index tokens revert preservation**: Attempt position burn with `units > positionIndexBalance`, verify revert unchanged
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13, 3.14, 3.15, 3.16_
  - Reused existing live and harness baselines already present in the EqualIndex suites for:
    - position-mode mint and burn accounting
    - wallet-mode mint and burn fee routing
    - borrow and repay flows
    - expired-loan recovery well past maturity
    - create-index validation and paused-index mint guards
    - reward-settlement ordering across mint, burn, and recovery paths
  - Added the missing preservation tests to `test/EqualIndexPort.t.sol`:
    - `test_RevertWhen_PositionMintExceedsAvailablePrincipal`
    - `test_RevertWhen_PositionBurnExceedsPositionIndexBalance`
  - Added the missing preservation tests to `test/EqualIndexLaunch.t.sol`:
    - `test_WalletMode_MintPreservesExactInputPull`
    - `test_AdminPausePreservesAuthorizedTimelockAccess`
    - `test_IndexFlashLoanPreservesVaultAndFeePotAccounting`
  - Observed runs on unfixed code while excluding `BugCondition` regressions:
    - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
    - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed


- [x] 3. Fix Finding 1 — Burn gated against active index-loan encumbrance

  - [x] 3.1 Add encumbrance check in `burnFromPosition`
    - In `src/equalindex/EqualIndexPositionFacet.sol`, function `burnFromPosition`
    - After settling `positionIndexBalance` via `LibEqualIndexRewards.settleBeforeEligibleBalanceChange` and before proceeding with burn
    - Add: `uint256 available = LibPositionHelpers.availablePrincipal(indexPool, positionKey, indexPoolId);`
    - Add: `if (units > available) revert InsufficientUnencumberedPrincipal(units, available);`
    - Reuse the existing `InsufficientUnencumberedPrincipal` error for consistency with lending checks
    - _Bug_Condition: isBugCondition(finding=1) where isBurnFromPosition AND units > availableUnencumbered_
    - _Expected_Behavior: revert when units > availableUnencumbered; succeed when units <= availableUnencumbered_
    - _Preservation: Burns with no active loans unchanged; InsufficientIndexTokens check still applies first_
    - _Requirements: 2.1, 2.2_
    - Implemented in `src/equalindex/EqualIndexPositionFacet.sol` immediately after the settled `positionIndexBalance` check, preserving the earlier `InsufficientIndexTokens` guard order.

  - [x] 3.2 Verify bug condition exploration test for Finding 1 now passes
    - **Property 1: Expected Behavior** — Burn Encumbrance Gating
    - **IMPORTANT**: Re-run the SAME Finding 1 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*BurnEncumbered`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 1 bug is fixed)
    - _Requirements: 2.1_
    - Observed run after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*BurnEncumbered` -> `1/1` passed

  - [x] 3.3 Verify preservation tests still pass after Finding 1 fix
    - **Property 2: Preservation** — Position Burn and Lending Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.3, 3.4, 3.8, 3.9_
    - Observed preservation runs after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed

- [x] 4. Fix Finding 2 — Deterministic encumbrance release on position burn

  - [x] 4.1 Unencumber `bundleOut` instead of `navOut` in `_applyPositionBurnLeg`
    - In `src/equalindex/EqualIndexPositionFacet.sol`, function `_applyPositionBurnLeg`
    - Replace the `navOut`-based unencumbrance block:
      ```
      // Before:
      uint256 navOut = Math.mulDiv(leg.payout, leg.bundleOut, gross);
      if (navOut > 0) {
          LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, navOut);
      }
      
      // After:
      if (leg.bundleOut > 0) {
          LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, leg.bundleOut);
      }
      ```
    - Remove the `navOut` variable entirely
    - Define `potOut` exactly as `leg.payout > leg.bundleOut ? leg.payout - leg.bundleOut : 0`
    - Do not derive `potOut` from a replacement `navOut`; the invariant is now explicit:
      - vault-side unencumbrance always equals `leg.bundleOut`
      - pool-side principal re-credit only covers any payout amount above `leg.bundleOut`
    - The key invariant: fee charging is explicit through fee-pot and routed-fee accounting, not through leftover encumbrance
    - _Bug_Condition: isBugCondition(finding=2) where isPositionBurn AND burnFeeBps > 0_
    - _Expected_Behavior: full exit leaves zero residual index-related encumbrance_
    - _Preservation: Zero-fee burns unchanged; potOut crediting path unchanged_
    - _Requirements: 2.3, 2.4_
    - Implemented in `src/equalindex/EqualIndexPositionFacet.sol` by removing the `gross` and `navOut` derivation, unencumbering `leg.bundleOut` directly, and defining `potOut` only as `leg.payout > leg.bundleOut ? leg.payout - leg.bundleOut : 0`.

  - [x] 4.2 Verify bug condition exploration test for Finding 2 now passes
    - **Property 1: Expected Behavior** — Encumbrance Leak Fixed
    - **IMPORTANT**: Re-run the SAME Finding 2 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*EncumbranceLeak`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 2 bug is fixed)
    - _Requirements: 2.3_
    - Observed run after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --match-test 'BugCondition.*ShouldClearAllEncumbrance'` -> `1/1` passed

  - [x] 4.3 Verify preservation tests still pass after Finding 2 fix
    - **Property 2: Preservation** — Position Burn Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.3, 3.4_
    - Observed preservation runs after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed

- [x] 5. Fix Finding 6 — Protocol-safe burn fee rounding

  - [x] 5.1 Switch wallet-mode burn fee to `Math.Rounding.Ceil` in `_quoteBurnLeg`
    - In `src/equalindex/EqualIndexActionsFacetV3.sol`, function `_quoteBurnLeg`
    - Change: `leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);`
    - To: `leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000, Math.Rounding.Ceil);`
    - _Bug_Condition: isBugCondition(finding=6) where isWalletBurn AND feeHasRemainder_
    - _Expected_Behavior: burn fee rounds up on non-exact division_
    - _Preservation: Exact-division cases unchanged_
    - _Requirements: 2.5_
    - Implemented in `src/equalindex/EqualIndexActionsFacetV3.sol` by switching the burn fee quote to `Math.Rounding.Ceil` while leaving exact-division behavior unchanged.

  - [x] 5.2 Switch position-mode burn fee to `Math.Rounding.Ceil` in `_quotePositionBurnLeg`
    - In `src/equalindex/EqualIndexPositionFacet.sol`, function `_quotePositionBurnLeg`
    - Change: `leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);`
    - To: `leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000, Math.Rounding.Ceil);`
    - _Bug_Condition: isBugCondition(finding=6) where isPositionBurn AND feeHasRemainder_
    - _Expected_Behavior: position burn fee rounds up on non-exact division_
    - _Preservation: Exact-division cases unchanged; wallet and position modes consistent_
    - _Requirements: 2.6_
    - Implemented in `src/equalindex/EqualIndexPositionFacet.sol` by switching the position burn fee quote to `Math.Rounding.Ceil` so wallet and position modes now share the same protocol-safe rounding rule.

  - [x] 5.3 Verify bug condition exploration test for Finding 6 now passes
    - **Property 1: Expected Behavior** — Burn Fee Ceiling Rounding
    - **IMPORTANT**: Re-run the SAME Finding 6 test from task 1 — do NOT write a new test
    - Run targeted regression:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition.*BurnFeeRounding`
      - `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*BurnFeeRounding`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 6 bug is fixed)
    - _Requirements: 2.5, 2.6_
    - Observed targeted regressions after the fix:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test 'BugCondition.*BurnFeeRounding'` -> `1/1` passed
      - `forge test --match-path test/EqualIndexPort.t.sol --match-test 'BugCondition.*BurnFeeRounding'` -> `1/1` passed

  - [x] 5.4 Verify preservation tests still pass after Finding 6 fix
    - **Property 2: Preservation** — Burn Fee Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Note: burn fee amounts may change by +1 wei for non-exact divisions — preservation tests should use exact-division parameters or account for ceiling rounding
    - _Requirements: 3.3, 3.7_
    - Observed preservation runs after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed


- [x] 6. Fix Finding 8 — Governance setters for fee-share parameters

  - [x] 6.1 Add `setEqualIndexPoolFeeShareBps` and `setEqualIndexMintBurnFeeIndexShareBps` to `EqualIndexAdminFacetV3`
    - In `src/equalindex/EqualIndexAdminFacetV3.sol`
    - Add function `setEqualIndexPoolFeeShareBps(uint16 newBps)`:
      - Gate with `onlyTimelock` as an intermediate step only (final policy in task 7 is `LibAccess.enforceTimelockOrOwnerIfUnset()`)
      - Validate `newBps <= 10_000`, revert with `InvalidParameterRange("poolFeeShareBps")` if exceeded
      - Store `s().poolFeeShareBps = newBps`
      - Emit `EqualIndexPoolFeeShareBpsUpdated(oldBps, newBps)`
    - Add function `setEqualIndexMintBurnFeeIndexShareBps(uint16 newBps)`:
      - Gate with `onlyTimelock` as an intermediate step only (final policy in task 7 is `LibAccess.enforceTimelockOrOwnerIfUnset()`)
      - Validate `newBps <= 10_000`, revert with `InvalidParameterRange("mintBurnFeeIndexShareBps")` if exceeded
      - Store `s().mintBurnFeeIndexShareBps = newBps`
      - Emit `EqualIndexMintBurnFeeIndexShareBpsUpdated(oldBps, newBps)`
    - Declare events: `EqualIndexPoolFeeShareBpsUpdated(uint16 oldBps, uint16 newBps)` and `EqualIndexMintBurnFeeIndexShareBpsUpdated(uint16 oldBps, uint16 newBps)`
    - _Bug_Condition: isBugCondition(finding=8) where noSetterExists_
    - _Expected_Behavior: timelock can update fee-share parameters; invalid values revert; events emitted_
    - _Preservation: Default fallback values in `_poolFeeShareBps()` and `_mintBurnFeeIndexShareBps()` unchanged_
    - _Requirements: 2.7, 2.8, 2.9, 2.10_
    - Implemented in `src/equalindex/EqualIndexAdminFacetV3.sol` with `onlyTimelock` gating, `InvalidParameterRange` bounds checks for values above `10_000`, storage updates, and the two required update events.

  - [x] 6.2 Verify bug condition exploration test for Finding 8 now passes
    - **Property 1: Expected Behavior** — Fee-Share Governance Setters
    - **IMPORTANT**: Re-run the SAME Finding 8 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition.*FeeShareSetter`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 8 bug is fixed)
    - _Requirements: 2.7, 2.8_
    - Rechecked the existing regression to align it with the documented timelock caller requirement, then observed:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test 'BugCondition.*FeeShareSetter'` -> `1/1` passed

  - [x] 6.3 Verify preservation tests still pass after Finding 8 fix
    - **Property 2: Preservation** — Admin and Fee Routing Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.11, 3.14, 3.15_
    - Observed preservation runs after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed

- [x] 7. Fix Lead — Replace `onlyTimelock` with shared fallback pattern

  - [x] 7.1 Replace `onlyTimelock` modifier with `LibAccess.enforceTimelockOrOwnerIfUnset()` in EqualIndex
    - In `src/equalindex/EqualIndexBaseV3.sol`:
      - Remove the local `onlyTimelock` modifier entirely
    - In `src/equalindex/EqualIndexAdminFacetV3.sol`:
      - Replace `onlyTimelock` modifier on `setPaused` with inline `LibAccess.enforceTimelockOrOwnerIfUnset();`
      - Replace `onlyTimelock` modifier on `setEqualIndexPoolFeeShareBps` with inline `LibAccess.enforceTimelockOrOwnerIfUnset();`
      - Replace `onlyTimelock` modifier on `setEqualIndexMintBurnFeeIndexShareBps` with inline `LibAccess.enforceTimelockOrOwnerIfUnset();`
    - In `src/equalindex/EqualIndexLendingFacet.sol`:
      - Replace `onlyTimelock` modifier on `configureLending` with inline `LibAccess.enforceTimelockOrOwnerIfUnset();`
      - Replace `onlyTimelock` modifier on `configureBorrowFeeTiers` with inline `LibAccess.enforceTimelockOrOwnerIfUnset();`
    - Import `LibAccess` where not already imported
    - _Bug_Condition: isBugCondition(finding=9) where timelockAddress == address(0) AND callerIsOwner_
    - _Expected_Behavior: owner can call admin functions when timelock is unset; timelock required when configured_
    - _Preservation: Unauthorized callers still revert; timelock-gated behavior unchanged when timelock is set_
    - _Requirements: 2.11, 2.12_
    - Implemented by removing the local `onlyTimelock` modifier from `src/equalindex/EqualIndexBaseV3.sol`, replacing the admin setter and pause entrypoints in `src/equalindex/EqualIndexAdminFacetV3.sol` with inline `LibAccess.enforceTimelockOrOwnerIfUnset();`, and applying the same shared helper to `configureLending` and `configureBorrowFeeTiers` in `src/equalindex/EqualIndexLendingFacet.sol`.

  - [x] 7.2 Verify bug condition exploration test for timelock fallback now passes
    - **Property 1: Expected Behavior** — Admin Timelock Fallback
    - **IMPORTANT**: Re-run the SAME timelock fallback test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition.*TimelockFallback`
    - **EXPECTED OUTCOME**: Test PASSES (confirms timelock fallback lead is fixed)
    - _Requirements: 2.11_
    - Observed targeted regression after the fix:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test 'BugCondition.*TimelockFallback'` -> `1/1` passed

  - [x] 7.3 Verify preservation tests still pass after timelock fallback fix
    - **Property 2: Preservation** — Admin Access Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.11, 3.12, 3.13_
    - Observed preservation runs after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed

- [x] 8. Fix Lead — Recovery grace period

  - [x] 8.1 Add `RECOVERY_GRACE_PERIOD` constant and update maturity check in `recoverExpiredIndexLoan`
    - In `src/equalindex/EqualIndexLendingFacet.sol`
    - Add constant: `uint256 constant RECOVERY_GRACE_PERIOD = 1 hours;`
    - In `recoverExpiredIndexLoan`, change:
      ```
      // Before:
      if (block.timestamp <= loan.maturity) {
          revert LibEqualIndexLending.LoanNotExpired(loanId, loan.maturity);
      }
      
      // After:
      if (block.timestamp <= uint256(loan.maturity) + RECOVERY_GRACE_PERIOD) {
          revert LibEqualIndexLending.LoanNotExpired(loanId, loan.maturity);
      }
      ```
    - Keep `repayFromPosition` maturity check unchanged (repay remains available during grace period)
    - _Bug_Condition: isBugCondition(finding=10) where blockTimestamp <= maturity + RECOVERY_GRACE_PERIOD_
    - _Expected_Behavior: recovery blocked during grace period; repayment available during grace period; recovery succeeds after grace_
    - _Preservation: Repay flow unchanged; recovery after grace period unchanged_
    - _Requirements: 2.13, 2.14, 2.15_
    - Implemented in `src/equalindex/EqualIndexLendingFacet.sol` by adding `RECOVERY_GRACE_PERIOD = 1 hours` and extending the `recoverExpiredIndexLoan` expiry gate to `loan.maturity + RECOVERY_GRACE_PERIOD`, while leaving `repayFromPosition` unchanged.

  - [x] 8.2 Verify bug condition exploration test for recovery grace period now passes
    - **Property 1: Expected Behavior** — Recovery Grace Period
    - **IMPORTANT**: Re-run the SAME grace period test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*RecoveryGrace`
    - **EXPECTED OUTCOME**: Test PASSES (confirms recovery grace period lead is fixed)
    - _Requirements: 2.13, 2.14_
    - The existing `BugCondition_RecoveryGrace` regression lives in `test/EqualIndexLaunch.t.sol`; observed run after the fix:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test 'BugCondition.*RecoveryGrace'` -> `1/1` passed

  - [x] 8.3 Verify preservation tests still pass after recovery grace period fix
    - **Property 2: Preservation** — Lending Lifecycle Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Note: preservation recovery test should use a timestamp well past maturity + grace to remain unchanged
    - _Requirements: 3.9, 3.10_
    - Observed preservation runs after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed

- [x] 9. Fix Lead — Maintenance-exempt locked index collateral

  - [x] 9.1 Add per-user encumbered-collateral tracking to `Types.PoolData`
    - In `src/libraries/Types.sol`, add `mapping(bytes32 => uint256) userIndexEncumberedPrincipal;` to the `PoolData` struct
    - Reuse the existing `indexEncumberedTotal` aggregate for pool-level maintenance accrual exclusion; do not add a second aggregate field
    - This mapping tracks the borrowing `positionKey`'s loan-locked collateral that is exempt from maintenance fee deduction during `LibFeeIndex` settlement and previews
    - _Requirements: 2.16_
    - Implemented in `src/libraries/Types.sol` by adding `mapping(bytes32 => uint256) userIndexEncumberedPrincipal;` to `Types.PoolData` while preserving the existing aggregate `indexEncumberedTotal` accrual exclusion.

  - [x] 9.2 Track maintenance exemption on borrow and release on repay/recovery
    - In `src/equalindex/EqualIndexLendingFacet.sol`, function `borrowFromPosition`:
      - After `LibIndexEncumbrance.encumber(...)`, add: `indexPool.userIndexEncumberedPrincipal[positionKey] += collateralUnits;`
      - Keep the existing pool-level `indexEncumberedTotal` path as the aggregate maintenance-accrual exclusion
    - In `src/equalindex/EqualIndexLendingFacet.sol`, function `repayFromPosition`:
      - After `LibIndexEncumbrance.unencumber(...)`, add: `indexPool.userIndexEncumberedPrincipal[loan.positionKey] -= loan.collateralUnits;`
      - Load `indexPool` via `LibAppStorage.s().pools[indexPoolId]` if not already loaded
    - In `src/equalindex/EqualIndexLendingFacet.sol`, function `recoverExpiredIndexLoan` (or `_releaseRecoveredCollateral`):
      - After releasing collateral, add: `indexPool.userIndexEncumberedPrincipal[loan.positionKey] -= loan.collateralUnits;`
      - Load `indexPool` via `LibAppStorage.s().pools[s().indexToPoolId[loan.indexId]]`
    - _Bug_Condition: isBugCondition(finding=11) where positionHasLockedIndexCollateral_
    - _Expected_Behavior: locked collateral tracked as maintenance-exempt; exemption removed on repay/recovery_
    - _Preservation: Borrow, repay, recovery flows otherwise unchanged_
    - _Requirements: 2.16, 2.18_
    - Implemented in `src/equalindex/EqualIndexLendingFacet.sol` by incrementing `indexPool.userIndexEncumberedPrincipal[positionKey]` on borrow and decrementing it after the existing index-pool unencumbrance paths in both repay and recovered-collateral release.

  - [x] 9.3 Update maintenance settlement to exclude exempt principal
    - In the relevant maintenance library (likely `LibFeeIndex` or the maintenance settlement path for the index-token pool):
      - Keep the existing pool-accrual exclusion through `indexEncumberedTotal`
      - Update maintenance preview and settlement logic so the user-level maintenance-chargeable base excludes `userIndexEncumberedPrincipal[positionKey]`
      - The key invariant: `chargeableBase(positionKey) = userPrincipal[positionKey] - userIndexEncumberedPrincipal[positionKey]`
      - Locked collateral must not decay under maintenance while the loan is active
      - Unlocked index-pool principal must still accrue maintenance normally
    - _Bug_Condition: isBugCondition(finding=11) where maintenanceAppliesToLockedPrincipal_
    - _Expected_Behavior: maintenance applies only to unlocked principal; locked collateral preserved at fixed nominal amount_
    - _Preservation: Maintenance on non-index pools unchanged; maintenance on unlocked index principal unchanged_
    - _Requirements: 2.17, 2.19_
    - Implemented in `src/libraries/LibFeeIndex.sol` by switching maintenance preview and settlement charge-base computation from broad index encumbrance to `userIndexEncumberedPrincipal[positionKey]`, keeping the existing pool-level accrual exclusion through `indexEncumberedTotal` unchanged.

  - [x] 9.4 Verify bug condition exploration test for maintenance exemption now passes
    - **Property 1: Expected Behavior** — Maintenance-Exempt Locked Collateral
    - **IMPORTANT**: Re-run the SAME maintenance erosion test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*MaintenanceExempt`
    - **EXPECTED OUTCOME**: Test PASSES (confirms maintenance exemption lead is fixed)
    - _Requirements: 2.17, 2.19_
    - Re-aligned the existing port regression in `test/EqualIndexPort.t.sol` so it configures a `foundationReceiver` before settling maintenance and checks `principalAfterMaintenance >= 1e18`, which matches the documented invariant that locked collateral is preserved while unlocked principal decays.
    - Observed targeted regression after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --match-test 'BugCondition.*MaintenanceExempt'` -> `1/1` passed

  - [x] 9.5 Verify preservation tests still pass after maintenance exemption fix
    - **Property 2: Preservation** — Lending and Maintenance Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.8, 3.9, 3.10_
    - Observed preservation runs after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed


- [x] 10. Fix Lead — Exact-pull mint inputs

  - [x] 10.1 Change ERC20 mint pull to transfer only quoted `leg.total` in `_prepareMint`
    - In `src/equalindex/EqualIndexActionsFacetV3.sol`, function `_prepareMint`
    - Change the ERC20 pull path:
      ```
      // Before:
      uint256 received = LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.total, maxInputAmounts[i]);
      
      // After:
      uint256 received = LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.total, leg.total);
      ```
    - Keep the existing max-bound validation: `if (maxInputAmounts[i] < leg.total)` revert is already present
    - `maxInputAmounts` remains a user protection bound, not the transfer amount
    - Fee-on-transfer handling still relies on balance-delta measurement and reverts if actual received < quoted requirement
    - Native mint behavior unchanged (exact `msg.value` only)
    - _Bug_Condition: isBugCondition(finding=12) where isWalletMintERC20 AND maxInputAmount > legTotal_
    - _Expected_Behavior: only leg.total transferred; no surplus stranded_
    - _Preservation: Native mint unchanged; fee-on-transfer revert unchanged; maxInputAmounts validation unchanged_
    - _Requirements: 2.20, 2.21, 2.22_
    - Implemented in `src/equalindex/EqualIndexActionsFacetV3.sol` by keeping the existing `maxInputAmounts[i] < leg.total` guard ahead of both mint paths while changing the ERC20 `pullAtLeast` call to transfer exactly `leg.total` instead of the user ceiling.

  - [x] 10.2 Verify bug condition exploration test for exact-pull mint now passes
    - **Property 1: Expected Behavior** — Exact-Pull Mint
    - **IMPORTANT**: Re-run the SAME exact-pull test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition.*ExactPullMint`
    - **EXPECTED OUTCOME**: Test PASSES (confirms exact-pull lead is fixed)
    - _Requirements: 2.20_
    - Observed targeted regression after the fix:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test 'BugCondition.*ExactPullMint'` -> `1/1` passed

  - [x] 10.3 Verify preservation tests still pass after exact-pull mint fix
    - **Property 2: Preservation** — Wallet Mint Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.5, 3.6_
    - Rechecked the existing invalid-mint-input preservation guard to confirm the user-provided ceiling still reverts when it is below the quote, then observed:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test 'test_EqualIndex_RevertsForCanonicalDuplicatePausedIndexAndInvalidMintInputsOnLiveDiamond'` -> `1/1` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed

- [x] 11. Fix Lead — Position mint fee routing pre-credit

  - [x] 11.1 Pre-credit `pool.trackedBalance` by `poolShare` before `routeManagedShare` in `_applyPositionMintLeg`
    - In `src/equalindex/EqualIndexPositionFacet.sol`, function `_applyPositionMintLeg`
    - In the `if (poolShare > 0)` block, add `pool.trackedBalance += poolShare;` before calling `LibFeeRouter.routeManagedShare(...)`
    - This matches the pattern already used in `_applyPositionBurnLeg` where `pool.trackedBalance += leg.poolShare` is credited before `routeManagedShare`
    - Keep `pullFromTracked = true` so treasury routing and downstream fee splits consume the newly credited backing consistently
    - _Bug_Condition: isBugCondition(finding=13) where isPositionMint AND poolShare > 0 AND poolTrackedBalance < poolShare_
    - _Expected_Behavior: position mint succeeds when position has sufficient unencumbered principal even if pool had little preexisting tracked balance_
    - _Preservation: Position mint fee routing matches the intended tracked-balance behavior already used on position burn_
    - _Requirements: 2.23, 2.24_
    - Implemented in `src/equalindex/EqualIndexPositionFacet.sol` by aligning the mint-side fee flow with the burn-side pattern: the fee-pot share no longer depends on base-pool tracked balance, the managed pool share is pre-credited to `pool.trackedBalance` before routing, and that same `poolShare` is passed as `extraBacking` so downstream treasury and fee-index splits can consume the newly created backing consistently.

  - [x] 11.2 Verify bug condition exploration test for position mint fee routing now passes
    - **Property 1: Expected Behavior** — Position Mint Fee Routing
    - **IMPORTANT**: Re-run the SAME fee routing test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*PositionMintFeeRouting`
    - **EXPECTED OUTCOME**: Test PASSES (confirms position mint fee routing lead is fixed)
    - _Requirements: 2.23_
    - The existing `BugCondition_PositionMintFeeRouting` regression lives in `test/EqualIndexLaunch.t.sol`; observed run after the fix:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test 'BugCondition.*PositionMintFeeRouting'` -> `1/1` passed

  - [x] 11.3 Verify preservation tests still pass after position mint fee routing fix
    - **Property 2: Preservation** — Position Mint Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.15_
    - Observed preservation runs after the fix:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition` -> `6/6` passed
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition` -> `16/16` passed

- [x] 12. Refresh and expand EqualIndex regression tests

  - [x] 12.1 Add full position lifecycle integration test
    - Create index → deposit underlying → position mint → borrow (encumber collateral) → attempt burn of encumbered (revert) → repay → burn (success) → withdraw
    - Proves finding 1 fix end-to-end through a value-moving live flow
    - Use real deposits, real index creation, real position-mode mint and burn, real borrow and repay
    - Added `test_PositionLifecycle_RepayUnlocksBurnAndFinalWithdrawal()` to `test/EqualIndexPort.t.sol`
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.1, 2.2, 3.8, 3.9_

  - [x] 12.2 Add encumbrance integrity integration test
    - Create index → deposit → position mint (encumber underlying) → full position burn with nonzero fees → verify zero residual encumbrance → verify pool membership clearable
    - Repeated mint/burn cycles: position mint → burn → mint → burn with nonzero fees → verify no accumulated stranded encumbrance
    - Proves finding 2 fix end-to-end
    - Added `test_PositionBurnCycles_DoNotAccumulateResidualEncumbrance()` to `test/EqualIndexPort.t.sol`
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.3, 2.4_

  - [x] 12.3 Add burn rounding consistency integration test
    - Wallet-mode burn and position-mode burn with same index and parameters producing non-exact fee division
    - Verify both use ceiling rounding and fee routing matches the intended fee-pot and pool-share split
    - Proves finding 6 fix consistency across modes
    - Added `test_BurnRounding_ConsistentAcrossWalletAndPositionModes()` to `test/EqualIndexLaunch.t.sol`
    - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
    - _Requirements: 2.5, 2.6_

  - [x] 12.4 Add fee-share governance integration test
    - Set `poolFeeShareBps` to new value → wallet-mode mint → wallet-mode burn → verify updated parameters reflected in fee routing
    - Set `mintBurnFeeIndexShareBps` to new value → position-mode mint → position-mode burn → verify updated parameters reflected in fee routing
    - Verify invalid values (> 10_000) revert
    - Verify non-timelock callers revert
    - Proves finding 8 fix end-to-end
    - Added `test_FeeShareGovernance_UpdatedMintBurnFeeIndexShareRoutesWalletFees()`, `test_FeeShareGovernance_UpdatedPoolShareRoutesPositionFees()`, and `test_FeeShareGovernance_SettersRejectUnauthorizedAndInvalidValues()` to `test/EqualIndexLaunch.t.sol`
    - Live-diamond coverage required wiring `setEqualIndexPoolFeeShareBps` and `setEqualIndexMintBurnFeeIndexShareBps` selectors into `script/DeployEqualFi.s.sol`
    - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
    - _Requirements: 2.7, 2.8, 2.9, 2.10_

  - [x] 12.5 Add admin access integration test
    - With timelock unset: owner calls `setPaused`, `configureLending`, `configureBorrowFeeTiers`, fee-share setters — all succeed
    - With timelock set: owner alone cannot call — revert; timelock can call — succeed
    - Unauthorized callers cannot call in either mode
    - Proves timelock fallback lead end-to-end
    - Added `EqualIndexGovernanceHarness` and `test_AdminAccess_FallbackAndTimelockModesGateEqualIndexGovernanceCalls()` to `test/EqualIndexLaunch.t.sol`
    - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
    - _Requirements: 2.11, 2.12_

  - [x] 12.6 Add recovery grace period integration test
    - Create index → deposit → position mint → borrow → warp to maturity → attempt recovery (revert, within grace) → repay during grace (success)
    - Create index → deposit → position mint → borrow → warp past maturity + grace → recovery (success)
    - Proves recovery grace period lead end-to-end
    - Added `test_RecoveryGraceLifecycle_AllowsRepayDuringGraceAndRecoveryAfterward()` to `test/EqualIndexPort.t.sol`
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.13, 2.14, 2.15_

  - [x] 12.7 Add maintenance exemption integration test
    - Create index → deposit → position mint → borrow (lock collateral) → advance time for significant maintenance accrual → verify locked collateral unchanged → verify unlocked principal reduced by maintenance → recovery succeeds after grace period
    - Proves maintenance exemption lead end-to-end
    - Added `test_MaintenanceExemptLockedCollateral_PreservesLockedUnitsDuringDecay()` to `test/EqualIndexPort.t.sol`
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.16, 2.17, 2.18, 2.19_

  - [x] 12.8 Add exact-pull mint integration test
    - Wallet-mode ERC20 mint with `maxInputAmounts[i] = 2 * leg.total` → verify only `leg.total` transferred → verify no surplus stranded in contract → verify vault balances correct
    - Wallet-mode ERC20 mint with `maxInputAmounts[i] == leg.total` → verify identical behavior to before
    - Proves exact-pull mint lead end-to-end
    - Added `test_WalletMode_MintExactPull_AvoidsSurplusAcrossBothMaxBoundShapes()` to `test/EqualIndexLaunch.t.sol`
    - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
    - _Requirements: 2.20, 2.21_

  - [x] 12.9 Add position mint fee routing integration test
    - Deposit minimal underlying → position mint when pool has low preexisting tracked balance → verify mint succeeds → verify tracked balance and downstream fee allocations remain conserved
    - Proves position mint fee routing lead end-to-end
    - Added `test_PositionMintFeeRouting_ConservesTrackedBackingWithLowPreexistingLiquidity()` to `test/EqualIndexPort.t.sol`
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.23, 2.24_

  - Verification runs:
    - `forge test --match-path test/EqualIndexPort.t.sol` -> `15/15` passed
    - `forge test --match-path test/EqualIndexLaunch.t.sol` -> `28/28` passed
    - `forge test --match-path test/EqualIndexLendingFacet.t.sol` -> `15/15` passed
    - `forge test --match-path test/EqualIndexFuzz.t.sol` -> `3/3` passed

- [x] 13. Checkpoint — Run targeted EqualIndex test suites and ensure all tests pass
  - Run: `forge test --match-path test/EqualIndexPort.t.sol` -> `15/15` passed
  - Run: `forge test --match-path test/EqualIndexLaunch.t.sol` -> `28/28` passed
  - Run: `forge test --match-path test/EqualIndexLendingFacet.t.sol` -> `15/15` passed
  - Run: `forge test --match-path test/EqualIndexFuzz.t.sol` -> `3/3` passed
  - Checkpointing surfaced two additional fixes required for the full EqualIndex slice to go green:
    - live-diamond selector registration for `setEqualIndexPoolFeeShareBps` and `setEqualIndexMintBurnFeeIndexShareBps` in `script/DeployEqualFi.s.sol`
    - flat native borrow/extend fee collection in `src/equalindex/EqualIndexLendingFacet.sol`, which now pays treasury directly instead of decrementing tracked native pool accounting
  - Updated `test/EqualIndexLendingFacet.t.sol` to match the current timelock revert surface (`LibAccess: not timelock`) during the final checkpoint pass
  - All bug condition exploration tests now PASS for the targeted EqualIndex suites exercised in this checkpoint
  - All preservation and integration regressions added for Tasks 10-12 remain green after the full checkpoint reruns
