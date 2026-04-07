# Implementation Plan

- [ ] 1. Write bug condition exploration tests (BEFORE implementing fixes)
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

- [ ] 2. Write preservation property tests (BEFORE implementing fixes)
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


- [ ] 3. Fix Finding 1 — Burn gated against active index-loan encumbrance

  - [ ] 3.1 Add encumbrance check in `burnFromPosition`
    - In `src/equalindex/EqualIndexPositionFacet.sol`, function `burnFromPosition`
    - After settling `positionIndexBalance` via `LibEqualIndexRewards.settleBeforeEligibleBalanceChange` and before proceeding with burn
    - Add: `uint256 available = LibPositionHelpers.availablePrincipal(indexPool, positionKey, indexPoolId);`
    - Add: `if (units > available) revert InsufficientUnencumberedPrincipal(units, available);`
    - Reuse the existing `InsufficientUnencumberedPrincipal` error for consistency with lending checks
    - _Bug_Condition: isBugCondition(finding=1) where isBurnFromPosition AND units > availableUnencumbered_
    - _Expected_Behavior: revert when units > availableUnencumbered; succeed when units <= availableUnencumbered_
    - _Preservation: Burns with no active loans unchanged; InsufficientIndexTokens check still applies first_
    - _Requirements: 2.1, 2.2_

  - [ ] 3.2 Verify bug condition exploration test for Finding 1 now passes
    - **Property 1: Expected Behavior** — Burn Encumbrance Gating
    - **IMPORTANT**: Re-run the SAME Finding 1 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*BurnEncumbered`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 1 bug is fixed)
    - _Requirements: 2.1_

  - [ ] 3.3 Verify preservation tests still pass after Finding 1 fix
    - **Property 2: Preservation** — Position Burn and Lending Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.3, 3.4, 3.8, 3.9_

- [ ] 4. Fix Finding 2 — Deterministic encumbrance release on position burn

  - [ ] 4.1 Unencumber `bundleOut` instead of `navOut` in `_applyPositionBurnLeg`
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

  - [ ] 4.2 Verify bug condition exploration test for Finding 2 now passes
    - **Property 1: Expected Behavior** — Encumbrance Leak Fixed
    - **IMPORTANT**: Re-run the SAME Finding 2 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*EncumbranceLeak`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 2 bug is fixed)
    - _Requirements: 2.3_

  - [ ] 4.3 Verify preservation tests still pass after Finding 2 fix
    - **Property 2: Preservation** — Position Burn Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.3, 3.4_

- [ ] 5. Fix Finding 6 — Protocol-safe burn fee rounding

  - [ ] 5.1 Switch wallet-mode burn fee to `Math.Rounding.Ceil` in `_quoteBurnLeg`
    - In `src/equalindex/EqualIndexActionsFacetV3.sol`, function `_quoteBurnLeg`
    - Change: `leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);`
    - To: `leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000, Math.Rounding.Ceil);`
    - _Bug_Condition: isBugCondition(finding=6) where isWalletBurn AND feeHasRemainder_
    - _Expected_Behavior: burn fee rounds up on non-exact division_
    - _Preservation: Exact-division cases unchanged_
    - _Requirements: 2.5_

  - [ ] 5.2 Switch position-mode burn fee to `Math.Rounding.Ceil` in `_quotePositionBurnLeg`
    - In `src/equalindex/EqualIndexPositionFacet.sol`, function `_quotePositionBurnLeg`
    - Change: `leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);`
    - To: `leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000, Math.Rounding.Ceil);`
    - _Bug_Condition: isBugCondition(finding=6) where isPositionBurn AND feeHasRemainder_
    - _Expected_Behavior: position burn fee rounds up on non-exact division_
    - _Preservation: Exact-division cases unchanged; wallet and position modes consistent_
    - _Requirements: 2.6_

  - [ ] 5.3 Verify bug condition exploration test for Finding 6 now passes
    - **Property 1: Expected Behavior** — Burn Fee Ceiling Rounding
    - **IMPORTANT**: Re-run the SAME Finding 6 test from task 1 — do NOT write a new test
    - Run targeted regression:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition.*BurnFeeRounding`
      - `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*BurnFeeRounding`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 6 bug is fixed)
    - _Requirements: 2.5, 2.6_

  - [ ] 5.4 Verify preservation tests still pass after Finding 6 fix
    - **Property 2: Preservation** — Burn Fee Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Note: burn fee amounts may change by +1 wei for non-exact divisions — preservation tests should use exact-division parameters or account for ceiling rounding
    - _Requirements: 3.3, 3.7_


- [ ] 6. Fix Finding 8 — Governance setters for fee-share parameters

  - [ ] 6.1 Add `setEqualIndexPoolFeeShareBps` and `setEqualIndexMintBurnFeeIndexShareBps` to `EqualIndexAdminFacetV3`
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

  - [ ] 6.2 Verify bug condition exploration test for Finding 8 now passes
    - **Property 1: Expected Behavior** — Fee-Share Governance Setters
    - **IMPORTANT**: Re-run the SAME Finding 8 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition.*FeeShareSetter`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 8 bug is fixed)
    - _Requirements: 2.7, 2.8_

  - [ ] 6.3 Verify preservation tests still pass after Finding 8 fix
    - **Property 2: Preservation** — Admin and Fee Routing Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.11, 3.14, 3.15_

- [ ] 7. Fix Lead — Replace `onlyTimelock` with shared fallback pattern

  - [ ] 7.1 Replace `onlyTimelock` modifier with `LibAccess.enforceTimelockOrOwnerIfUnset()` in EqualIndex
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

  - [ ] 7.2 Verify bug condition exploration test for timelock fallback now passes
    - **Property 1: Expected Behavior** — Admin Timelock Fallback
    - **IMPORTANT**: Re-run the SAME timelock fallback test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition.*TimelockFallback`
    - **EXPECTED OUTCOME**: Test PASSES (confirms timelock fallback lead is fixed)
    - _Requirements: 2.11_

  - [ ] 7.3 Verify preservation tests still pass after timelock fallback fix
    - **Property 2: Preservation** — Admin Access Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.11, 3.12, 3.13_

- [ ] 8. Fix Lead — Recovery grace period

  - [ ] 8.1 Add `RECOVERY_GRACE_PERIOD` constant and update maturity check in `recoverExpiredIndexLoan`
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

  - [ ] 8.2 Verify bug condition exploration test for recovery grace period now passes
    - **Property 1: Expected Behavior** — Recovery Grace Period
    - **IMPORTANT**: Re-run the SAME grace period test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*RecoveryGrace`
    - **EXPECTED OUTCOME**: Test PASSES (confirms recovery grace period lead is fixed)
    - _Requirements: 2.13, 2.14_

  - [ ] 8.3 Verify preservation tests still pass after recovery grace period fix
    - **Property 2: Preservation** — Lending Lifecycle Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Note: preservation recovery test should use a timestamp well past maturity + grace to remain unchanged
    - _Requirements: 3.9, 3.10_

- [ ] 9. Fix Lead — Maintenance-exempt locked index collateral

  - [ ] 9.1 Add per-user encumbered-collateral tracking to `Types.PoolData`
    - In `src/libraries/Types.sol`, add `mapping(bytes32 => uint256) userIndexEncumberedPrincipal;` to the `PoolData` struct
    - Reuse the existing `indexEncumberedTotal` aggregate for pool-level maintenance accrual exclusion; do not add a second aggregate field
    - This mapping tracks the borrowing `positionKey`'s loan-locked collateral that is exempt from maintenance fee deduction during `LibFeeIndex` settlement and previews
    - _Requirements: 2.16_

  - [ ] 9.2 Track maintenance exemption on borrow and release on repay/recovery
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

  - [ ] 9.3 Update maintenance settlement to exclude exempt principal
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

  - [ ] 9.4 Verify bug condition exploration test for maintenance exemption now passes
    - **Property 1: Expected Behavior** — Maintenance-Exempt Locked Collateral
    - **IMPORTANT**: Re-run the SAME maintenance erosion test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*MaintenanceExempt`
    - **EXPECTED OUTCOME**: Test PASSES (confirms maintenance exemption lead is fixed)
    - _Requirements: 2.17, 2.19_

  - [ ] 9.5 Verify preservation tests still pass after maintenance exemption fix
    - **Property 2: Preservation** — Lending and Maintenance Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.8, 3.9, 3.10_


- [ ] 10. Fix Lead — Exact-pull mint inputs

  - [ ] 10.1 Change ERC20 mint pull to transfer only quoted `leg.total` in `_prepareMint`
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

  - [ ] 10.2 Verify bug condition exploration test for exact-pull mint now passes
    - **Property 1: Expected Behavior** — Exact-Pull Mint
    - **IMPORTANT**: Re-run the SAME exact-pull test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexLaunch.t.sol --match-test BugCondition.*ExactPullMint`
    - **EXPECTED OUTCOME**: Test PASSES (confirms exact-pull lead is fixed)
    - _Requirements: 2.20_

  - [ ] 10.3 Verify preservation tests still pass after exact-pull mint fix
    - **Property 2: Preservation** — Wallet Mint Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexLaunch.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.5, 3.6_

- [ ] 11. Fix Lead — Position mint fee routing pre-credit

  - [ ] 11.1 Pre-credit `pool.trackedBalance` by `poolShare` before `routeManagedShare` in `_applyPositionMintLeg`
    - In `src/equalindex/EqualIndexPositionFacet.sol`, function `_applyPositionMintLeg`
    - In the `if (poolShare > 0)` block, add `pool.trackedBalance += poolShare;` before calling `LibFeeRouter.routeManagedShare(...)`
    - This matches the pattern already used in `_applyPositionBurnLeg` where `pool.trackedBalance += leg.poolShare` is credited before `routeManagedShare`
    - Keep `pullFromTracked = true` so treasury routing and downstream fee splits consume the newly credited backing consistently
    - _Bug_Condition: isBugCondition(finding=13) where isPositionMint AND poolShare > 0 AND poolTrackedBalance < poolShare_
    - _Expected_Behavior: position mint succeeds when position has sufficient unencumbered principal even if pool had little preexisting tracked balance_
    - _Preservation: Position mint fee routing matches the intended tracked-balance behavior already used on position burn_
    - _Requirements: 2.23, 2.24_

  - [ ] 11.2 Verify bug condition exploration test for position mint fee routing now passes
    - **Property 1: Expected Behavior** — Position Mint Fee Routing
    - **IMPORTANT**: Re-run the SAME fee routing test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualIndexPort.t.sol --match-test BugCondition.*PositionMintFeeRouting`
    - **EXPECTED OUTCOME**: Test PASSES (confirms position mint fee routing lead is fixed)
    - _Requirements: 2.23_

  - [ ] 11.3 Verify preservation tests still pass after position mint fee routing fix
    - **Property 2: Preservation** — Position Mint Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualIndexPort.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.15_

- [ ] 12. Refresh and expand EqualIndex regression tests

  - [ ] 12.1 Add full position lifecycle integration test
    - Create index → deposit underlying → position mint → borrow (encumber collateral) → attempt burn of encumbered (revert) → repay → burn (success) → withdraw
    - Proves finding 1 fix end-to-end through a value-moving live flow
    - Use real deposits, real index creation, real position-mode mint and burn, real borrow and repay
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.1, 2.2, 3.8, 3.9_

  - [ ] 12.2 Add encumbrance integrity integration test
    - Create index → deposit → position mint (encumber underlying) → full position burn with nonzero fees → verify zero residual encumbrance → verify pool membership clearable
    - Repeated mint/burn cycles: position mint → burn → mint → burn with nonzero fees → verify no accumulated stranded encumbrance
    - Proves finding 2 fix end-to-end
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.3, 2.4_

  - [ ] 12.3 Add burn rounding consistency integration test
    - Wallet-mode burn and position-mode burn with same index and parameters producing non-exact fee division
    - Verify both use ceiling rounding and fee routing matches the intended fee-pot and pool-share split
    - Proves finding 6 fix consistency across modes
    - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
    - _Requirements: 2.5, 2.6_

  - [ ] 12.4 Add fee-share governance integration test
    - Set `poolFeeShareBps` to new value → wallet-mode mint → wallet-mode burn → verify updated parameters reflected in fee routing
    - Set `mintBurnFeeIndexShareBps` to new value → position-mode mint → position-mode burn → verify updated parameters reflected in fee routing
    - Verify invalid values (> 10_000) revert
    - Verify non-timelock callers revert
    - Proves finding 8 fix end-to-end
    - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
    - _Requirements: 2.7, 2.8, 2.9, 2.10_

  - [ ] 12.5 Add admin access integration test
    - With timelock unset: owner calls `setPaused`, `configureLending`, `configureBorrowFeeTiers`, fee-share setters — all succeed
    - With timelock set: owner alone cannot call — revert; timelock can call — succeed
    - Unauthorized callers cannot call in either mode
    - Proves timelock fallback lead end-to-end
    - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
    - _Requirements: 2.11, 2.12_

  - [ ] 12.6 Add recovery grace period integration test
    - Create index → deposit → position mint → borrow → warp to maturity → attempt recovery (revert, within grace) → repay during grace (success)
    - Create index → deposit → position mint → borrow → warp past maturity + grace → recovery (success)
    - Proves recovery grace period lead end-to-end
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.13, 2.14, 2.15_

  - [ ] 12.7 Add maintenance exemption integration test
    - Create index → deposit → position mint → borrow (lock collateral) → advance time for significant maintenance accrual → verify locked collateral unchanged → verify unlocked principal reduced by maintenance → recovery succeeds after grace period
    - Proves maintenance exemption lead end-to-end
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.16, 2.17, 2.18, 2.19_

  - [ ] 12.8 Add exact-pull mint integration test
    - Wallet-mode ERC20 mint with `maxInputAmounts[i] = 2 * leg.total` → verify only `leg.total` transferred → verify no surplus stranded in contract → verify vault balances correct
    - Wallet-mode ERC20 mint with `maxInputAmounts[i] == leg.total` → verify identical behavior to before
    - Proves exact-pull mint lead end-to-end
    - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
    - _Requirements: 2.20, 2.21_

  - [ ] 12.9 Add position mint fee routing integration test
    - Deposit minimal underlying → position mint when pool has low preexisting tracked balance → verify mint succeeds → verify tracked balance and downstream fee allocations remain conserved
    - Proves position mint fee routing lead end-to-end
    - Run: `forge test --match-path test/EqualIndexPort.t.sol`
    - _Requirements: 2.23, 2.24_

  - Verification runs:
    - `forge test --match-path test/EqualIndexPort.t.sol`
    - `forge test --match-path test/EqualIndexLaunch.t.sol`
    - `forge test --match-path test/EqualIndexLendingFacet.t.sol`
    - `forge test --match-path test/EqualIndexFuzz.t.sol`

- [ ] 13. Checkpoint — Run targeted EqualIndex test suites and ensure all tests pass
  - Run: `forge test --match-path test/EqualIndexPort.t.sol`
  - Run: `forge test --match-path test/EqualIndexLaunch.t.sol`
  - Run: `forge test --match-path test/EqualIndexLendingFacet.t.sol`
  - Run: `forge test --match-path test/EqualIndexFuzz.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all nine bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ask the user if questions arise
