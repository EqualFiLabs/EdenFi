# Implementation Plan

- [x] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — EqualX Findings 1-5 Accounting, ACI, Close, Share, and Cancel Bugs
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/EqualXSoloAmmFacet.t.sol` for findings 1-3, 5; `test/EqualXCommunityAmmFacet.t.sol` for finding 4
  - Use real deposits, real market creation, real swaps, real joins — no synthetic shortcuts
  - **Finding 1 — Solo swap trackedBalance**: Create Solo AMM market, execute a swap that routes non-zero protocol fees, assert `feePool.trackedBalance` increased by `toActive + toFeeIndex` after the swap. On unfixed code this will FAIL because `trackedBalance` is not incremented at swap time.
  - **Finding 2 — Solo swap ACI sync**: Create Solo AMM market, record both maker-side `encumberedCapital` and pool `activeCreditPrincipalTotal` before swap, execute a swap that moves reserves, assert the ACI change matches the encumbrance delta produced by the reserve update. On unfixed code this will FAIL because `_applyReserveDelta` mutates encumbrance without calling ACI.
  - **Finding 3 — Solo close skewed fees**: Create Solo AMM market, execute many one-sided swaps to skew reserves so cumulative protocol fees on one side exceed remaining reserve, finalize, assert `reserveForPrincipal == 0` (clamped). On unfixed code this will FAIL because conditional per-fee subtraction leaves protocol-fee amounts inside principal.
  - **Finding 4 — Community join after growth**: Create Community AMM market, execute swaps to grow reserves via retained fees, join with new maker, assert shares minted are proportional (`share == min(amountA * totalShares / reserveA, amountB * totalShares / reserveB)`). On unfixed code this will FAIL because `sqrt` formula grants excess shares.
  - **Finding 5 — Solo cancel after start**: Create Solo AMM market, warp to `startTime`, attempt cancel by owner, assert revert. On unfixed code this will FAIL because cancel succeeds after `startTime`.
  - Run tests on UNFIXED code: `forge test --match-path test/EqualXSoloAmmFacet.t.sol` and `forge test --match-path test/EqualXCommunityAmmFacet.t.sol`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Document counterexamples found to understand root cause
  - Observed counterexamples on unfixed code:
    - Finding 1: `trackedBalance` stayed `500e18` instead of increasing to `500.081e18` after a fee-routing Solo swap
    - Finding 2: pool A `activeCreditPrincipalTotal` delta stayed `0` while maker encumbrance delta was `+9.991e18`
    - Finding 3: after a skewed TokenOut Solo market close, maker pool-B principal settled to `467.688377630453860404e18` instead of the clamped `400e18`
    - Finding 4: Community post-growth join minted `43.566134717447065388e18` shares instead of proportional `43.483365438551482130e18`
    - Finding 5: Solo cancel at `startTime` did not revert
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7_

- [x] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — EqualX AMM Unchanged Behavior Across All Five Findings
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/EqualXSoloAmmFacet.t.sol` and `test/EqualXCommunityAmmFacet.t.sol`
  - Use real deposits, real market creation, real swaps, real joins, real leaves, real finalization — no synthetic shortcuts
  - **Solo AMM swap output preservation**: Execute Solo AMM swaps, verify swap output amounts, fee splits, maker fee accrual, and recipient payouts are correct and unchanged for any valid swap
  - **Solo AMM treasury fee preservation**: Verify treasury fee accrual does NOT touch `trackedBalance` (treasury portion only goes to market struct)
  - **Solo AMM live yield claim preservation**: Execute Solo AMM swap with non-zero routed protocol fees, claim yield while the market is still active, verify live claimability works and does not require finalization
  - **Solo AMM close zero-fee preservation**: Create and immediately finalize a Solo AMM market with no swaps (zero accrued fees), verify ACI settlement, backing unlock, encumbrance decrease, and principal reconciliation work identically
  - **Solo AMM finalize after endTime preservation**: Create Solo AMM market, warp past `endTime`, finalize, verify normal close behavior
  - **Solo AMM cancel before startTime preservation**: Create Solo AMM market, cancel before `startTime`, verify market closes successfully
  - **Solo AMM non-owner cancel preservation**: Attempt cancel from non-owner, verify revert with ownership error
  - **Community AMM swap preservation**: Execute Community AMM swap, verify fee routing and `trackedBalance` increments are correct
  - **Community AMM initial join preservation**: Join Community AMM market as first maker (`totalShares == 0`), verify `sqrt(amountA * amountB)` bootstrap formula is used
  - **Community AMM leave preservation**: Join then leave Community AMM market, verify shares burned, backing unlocked, fees settled, capital returned
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures that live in the same files:
    - `forge test --match-path test/EqualXSoloAmmFacet.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/EqualXCommunityAmmFacet.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Observed baseline on unfixed code:
    - Solo AMM preservation suite passed with `35/35` tests
    - Community AMM preservation suite passed with `12/12` tests
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11_


- [x] 3. Fix Finding 1 — Solo AMM live fee-backing accounting

  - [x] 3.1 Implement live `trackedBalance` increment in `swapEqualXSoloAmmExactIn`
    - In `src/equalx/EqualXSoloAmmFacet.sol`, function `swapEqualXSoloAmmExactIn`
    - After `LibFeeRouter.routeSamePool(...)` returns `(toTreasury, toActive, toFeeIndex)` and `_accrueProtocolFees` is called
    - Compute `backingIncrease = toActive + toFeeIndex`
    - If `backingIncrease > 0`, load fee pool via `LibPositionHelpers.pool(ctx.feePoolId)` and increment `feePool.trackedBalance += backingIncrease`
    - If fee pool underlying is native, increment `LibAppStorage.s().nativeTrackedTotal += backingIncrease`
    - Mirror the existing pattern in `swapEqualXCommunityAmmExactIn` (see Community AMM swap for reference)
    - _Bug_Condition: isBugCondition(finding=1) where isSoloAmmSwap AND protocolFeeRouted > 0 AND (toActive + toFeeIndex) > 0_
    - _Expected_Behavior: feePool.trackedBalance increases by toActive + toFeeIndex at swap time_
    - _Preservation: Treasury fee accrual unchanged; swap output, fee split, maker fee, payout unchanged_
    - _Requirements: 2.1, 3.1, 3.2_

  - [x] 3.2 Remove deferred `trackedBalance` top-up in `_closeMarket`
    - In `src/equalx/EqualXSoloAmmFacet.sol`, function `_closeMarket`
    - Remove the `protocolYieldA` and `protocolYieldB` blocks that increment `trackedBalance` at close time
    - These blocks compute `protocolYieldA = feeIndexFeeAAccrued + activeCreditFeeAAccrued` and increment `poolA.trackedBalance += protocolYieldA` (and similarly for B side)
    - This backing is now recognized live during swaps, so close must not re-credit it
    - _Bug_Condition: isBugCondition(finding=1) close-side — deferred top-up double-counts fees already recognized live_
    - _Expected_Behavior: _closeMarket does NOT increment trackedBalance for protocol fees_
    - _Preservation: Close with zero accrued fees still settles ACI, unlocks backing, reconciles principal identically_
    - _Requirements: 2.2, 3.3_

  - [x] 3.3 Verify bug condition exploration test for Finding 1 now passes
    - **Property 1: Expected Behavior** — Solo AMM Live Fee-Backing
    - **IMPORTANT**: Re-run the SAME Finding 1 test from task 1 — do NOT write a new test
    - The test from task 1 asserts `trackedBalance` increases by `toActive + toFeeIndex` at swap time
    - When this test passes, it confirms the expected behavior is satisfied
    - Run targeted regression: `forge test --match-path test/EqualXSoloAmmFacet.t.sol --match-test test_BugCondition_SoloSwap_TrackedBalanceShouldIncreaseLiveWithProtocolFees`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 1 bug is fixed)
    - Observed outcome after fix:
      - `test_BugCondition_SoloSwap_TrackedBalanceShouldIncreaseLiveWithProtocolFees` passed
    - _Requirements: 2.1, 2.2_

  - [x] 3.4 Verify preservation tests still pass after Finding 1 fix
    - **Property 2: Preservation** — Solo AMM Swap and Close Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualXSoloAmmFacet.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualXCommunityAmmFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Confirm swap output, fee splits, treasury accrual, close-with-zero-fees, finalize, cancel-before-start all still work
    - Observed outcome after fix:
      - Solo AMM preservation suite passed with `35/35` tests
      - Community AMM preservation suite passed with `12/12` tests
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

- [x] 4. Fix Finding 2 — Solo AMM live ACI synchronization

  - [x] 4.1 Implement ACI sync in `_applyReserveDelta`
    - In `src/equalx/EqualXSoloAmmFacet.sol`, function `_applyReserveDelta`
    - Load pool data: `Types.PoolData storage pool = LibPositionHelpers.pool(poolId)`
    - When `newReserve > previousReserve`: after `enc.encumberedCapital += delta`, call `LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, makerPositionKey, delta)`
    - When `newReserve < previousReserve`: after `enc.encumberedCapital -= delta`, call `LibActiveCreditIndex.applyEncumbranceDecrease(pool, poolId, makerPositionKey, delta)`
    - Note: `_applyReserveDelta` already receives `poolId` and `makerPositionKey` as parameters
    - Compatibility updates applied alongside the live sync:
      - `_closeMarket` now unwinds ACI using live `market.reserveA` / `market.reserveB`, so close zeroes the live swap-adjusted ACI state
      - executed rebalance now adjusts ACI from `previousReserve -> targetReserve` instead of `previousBaseline -> targetReserve`, preserving rebalance behavior after reserve drift
      - Solo swap continues routing protocol fees before reserve/ACI commit so previewed fee splits remain unchanged
    - _Bug_Condition: isBugCondition(finding=2) where isSoloAmmSwap AND reserveDelta != 0_
    - _Expected_Behavior: activeCreditPrincipalTotal stays synchronized with maker encumberedCapital changes caused by `_applyReserveDelta`_
    - _Preservation: Encumbrance bookkeeping unchanged; only adds ACI notification_
    - _Requirements: 2.3, 2.4_

  - [x] 4.2 Verify bug condition exploration test for Finding 2 now passes
    - **Property 1: Expected Behavior** — Solo AMM Live ACI Sync
    - **IMPORTANT**: Re-run the SAME Finding 2 test from task 1 — do NOT write a new test
    - The test from task 1 asserts `activeCreditPrincipalTotal` changes by the encumbrance delta after a swap
    - Run targeted regression: `forge test --match-path test/EqualXSoloAmmFacet.t.sol --match-test test_BugCondition_SoloSwap_AciShouldTrackEncumbranceDelta`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 2 bug is fixed)
    - Observed outcome after fix:
      - `test_BugCondition_SoloSwap_AciShouldTrackEncumbranceDelta` passed
    - _Requirements: 2.3, 2.4_

  - [x] 4.3 Verify preservation tests still pass after Finding 2 fix
    - **Property 2: Preservation** — Solo AMM Swap and Close Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualXSoloAmmFacet.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualXCommunityAmmFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed outcome after fix:
      - Solo AMM preservation suite passed with `35/35` tests
      - Community AMM preservation suite passed with `12/12` tests
    - _Requirements: 3.1, 3.3, 3.7_


- [x] 5. Fix Finding 3 — Solo AMM deterministic close-time fee subtraction

  - [x] 5.1 Implement clamped total-fee subtraction in `_closeMarket`
    - In `src/equalx/EqualXSoloAmmFacet.sol`, function `_closeMarket`
    - Replace the four conditional per-fee subtraction blocks with a single clamped subtraction per side
    - Compute `totalProtocolA = market.feeIndexFeeAAccrued + market.activeCreditFeeAAccrued`
    - Compute `reserveAForPrincipal = market.reserveA > totalProtocolA ? market.reserveA - totalProtocolA : 0`
    - Compute `totalProtocolB = market.feeIndexFeeBAccrued + market.activeCreditFeeBAccrued`
    - Compute `reserveBForPrincipal = market.reserveB > totalProtocolB ? market.reserveB - totalProtocolB : 0`
    - This prevents protocol-fee amounts from remaining inside maker principal when cumulative fees exceed remaining reserve
    - _Bug_Condition: isBugCondition(finding=3) where isSoloAmmClose AND totalProtocolFee > reserve on either side_
    - _Expected_Behavior: reserveForPrincipal = max(0, reserve - totalProtocol) per side_
    - _Preservation: Close with zero accrued fees still produces identical settlement_
    - _Requirements: 2.5, 3.3_

  - [x] 5.2 Verify bug condition exploration test for Finding 3 now passes
    - **Property 1: Expected Behavior** — Solo AMM Deterministic Close
    - **IMPORTANT**: Re-run the SAME Finding 3 test from task 1 — do NOT write a new test
    - The test from task 1 asserts `reserveForPrincipal == 0` when cumulative fees exceed reserve
    - Run targeted regression: `forge test --match-path test/EqualXSoloAmmFacet.t.sol --match-test test_BugCondition_SoloClose_ShouldClampPrincipalReserveWhenFeesExceedReserve`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 3 bug is fixed)
    - Observed outcome after fix:
      - `test_BugCondition_SoloClose_ShouldClampPrincipalReserveWhenFeesExceedReserve` passed
    - _Requirements: 2.5_

  - [x] 5.3 Verify preservation tests still pass after Finding 3 fix
    - **Property 2: Preservation** — Solo AMM Close Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/EqualXSoloAmmFacet.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/EqualXCommunityAmmFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed outcome after fix:
      - Solo AMM preservation suite passed with `35/35` tests
      - Community AMM preservation suite passed with `12/12` tests
    - _Requirements: 3.3, 3.4_

- [x] 6. Fix Finding 5 — Solo AMM cancel time guard

  - [x] 6.1 Implement time guard in `cancelEqualXSoloAmmMarket`
    - In `src/equalx/EqualXSoloAmmFacet.sol`, function `cancelEqualXSoloAmmMarket`
    - Add before the `_closeMarket` call: `if (block.timestamp >= market.startTime) { revert EqualXSoloAmm_MarketStarted(marketId); }`
    - This matches Community AMM cancellation semantics
    - Verify the `EqualXSoloAmm_MarketStarted` error is declared (add if missing)
    - _Bug_Condition: isBugCondition(finding=5) where isSoloAmmCancel AND blockTimestamp >= marketStartTime_
    - _Expected_Behavior: revert when block.timestamp >= market.startTime_
    - _Preservation: Cancel before startTime still allowed; non-owner cancel still reverts with ownership error_
    - _Requirements: 2.7, 3.5, 3.6_

  - [x] 6.2 Verify bug condition exploration test for Finding 5 now passes
    - **Property 1: Expected Behavior** — Solo AMM Cancel Time Guard
    - **IMPORTANT**: Re-run the SAME Finding 5 test from task 1 — do NOT write a new test
    - The test from task 1 asserts cancel reverts at or after `startTime`
    - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol --match-test test_BugCondition_SoloCancel_ShouldRevertAtOrAfterStartTime`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 5 bug is fixed)
    - Observed outcome after fix:
      - Finding 5 bug-condition regression passed with `1/1` tests
    - _Requirements: 2.7_

  - [x] 6.3 Verify preservation tests still pass after Finding 5 fix
    - **Property 2: Preservation** — Solo AMM Cancel Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed outcome after fix:
      - Solo AMM preservation suite passed with `35/35` tests
    - _Requirements: 3.5, 3.6_

- [x] 7. Fix Finding 4 — Community AMM proportional share minting

  - [x] 7.1 Implement proportional share formula in `joinEqualXCommunityAmmMarket`
    - In `src/equalx/EqualXCommunityAmmFacet.sol`, function `joinEqualXCommunityAmmMarket`
    - Replace `uint256 share = Math.sqrt(Math.mulDiv(amountA, amountB, 1))` with conditional logic:
    - If `market.totalShares == 0`: keep `share = Math.sqrt(Math.mulDiv(amountA, amountB, 1))` (bootstrap)
    - If `market.totalShares > 0`: compute `shareA = Math.mulDiv(amountA, market.totalShares, market.reserveA)`, `shareB = Math.mulDiv(amountB, market.totalShares, market.reserveB)`, `share = shareA < shareB ? shareA : shareB`
    - Keep existing ratio validation as front-door input guard
    - _Bug_Condition: isBugCondition(finding=4) where isCommunityAmmJoin AND totalShares > 0_
    - _Expected_Behavior: share = min(amountA * totalShares / reserveA, amountB * totalShares / reserveB)_
    - _Preservation: Initial join (totalShares == 0) still uses sqrt bootstrap; join bookkeeping, backing, reserves, snapshots, events unchanged_
    - _Requirements: 2.6, 3.9, 3.10_

  - [x] 7.2 Verify bug condition exploration test for Finding 4 now passes
    - **Property 1: Expected Behavior** — Community AMM Proportional Shares
    - **IMPORTANT**: Re-run the SAME Finding 4 test from task 1 — do NOT write a new test
    - The test from task 1 asserts shares minted are proportional to current reserves, not `sqrt`-based
    - Run: `forge test --match-path test/EqualXCommunityAmmFacet.t.sol --match-test test_BugCondition_CommunityJoin_ShouldMintProportionalSharesAfterReserveGrowth`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 4 bug is fixed)
    - Observed outcome after fix:
      - Finding 4 bug-condition regression passed with `1/1` tests
    - _Requirements: 2.6_

  - [x] 7.3 Verify preservation tests still pass after Finding 4 fix
    - **Property 2: Preservation** — Community AMM Flow Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualXCommunityAmmFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed outcome after fix:
      - Community AMM preservation suite passed with `12/12` tests
    - _Requirements: 3.8, 3.9, 3.10, 3.11_


- [x] 8. Refresh and expand AMM regression tests

  - [x] 8.1 Add Solo AMM full lifecycle integration test
    - Create → swap (verify live `trackedBalance` and ACI accounting) → claim yield while market is active → finalize → claim any remaining yield
    - Proves findings 1 and 2 fixes end-to-end through a value-moving live flow
    - Use real deposits, real market creation, real swaps, real finalization, real yield claims
    - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol`
    - Implemented in `test_Integration_SoloLifecycle_SwapClaimLiveFinalizeAndClaimRemainingYield()`
    - _Requirements: 2.1, 2.2, 2.3, 2.4_

  - [x] 8.2 Add Solo AMM skewed-reserve lifecycle integration test
    - Create → many one-sided swaps to deplete one reserve → finalize
    - Verify clamped fee subtraction with real reserve depletion
    - Verify maker principal after close excludes all protocol-fee amounts
    - Verify `trackedBalance` is not inflated at close
    - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol`
    - Implemented in `test_Integration_SoloSkewedReserveLifecycle_ClampsCloseAndPreservesTrackedBalance()`
    - _Requirements: 2.5_

  - [x] 8.3 Add Solo AMM multi-directional swap ACI consistency test
    - Create → swap A→B → swap B→A → swap A→B → finalize
    - Verify `activeCreditPrincipalTotal` stays consistent through direction changes
    - Verify encumbrance and ACI reduce cleanly to zero at finalization
    - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol`
    - Implemented in `test_Integration_SoloMultiDirectionalSwaps_KeepAciConsistentThroughFinalize()`
    - _Requirements: 2.3, 2.4_

  - [x] 8.4 Add Solo AMM rebalance-bearing lifecycle integration test
    - Create → swap to move reserves → schedule rebalance → execute rebalance after timelock → finalize
    - Verify live `trackedBalance` and ACI accounting remain correct across the rebalance path
    - Verify close-time reconciliation still excludes protocol fees from maker principal after rebalance
    - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol`
    - Implemented in `test_Integration_SoloLifecycle_WithRebalance_PreservesLiveAccountingAndCloseReconciliation()`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5_

  - [x] 8.5 Add Community AMM post-growth join integration test
    - Create → swap to grow reserves via retained fees → join with new maker → leave
    - Verify new joiner receives only proportional ownership
    - Verify existing makers are not diluted by post-fee reserve growth
    - Run: `forge test --match-path test/EqualXCommunityAmmFacet.t.sol`
    - Implemented in `test_Integration_CommunityPostGrowthJoinAndLeave_PreservesProportionalOwnership()`
    - _Requirements: 2.6_

  - [x] 8.6 Add Solo AMM cancel lifecycle integration test
    - Create → warp past `startTime` → attempt cancel (expect revert) → create new market → cancel before `startTime` (expect success)
    - Verify unauthorized callers still cannot cancel
    - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol`
    - Implemented in `test_Integration_SoloCancelLifecycle_RejectsStartedMarketsAndAllowsPreStartCancel()`
    - _Requirements: 2.7, 3.5, 3.6_

  - Verification runs:
    - `forge test --match-path test/EqualXSoloAmmFacet.t.sol`
    - `forge test --match-path test/EqualXCommunityAmmFacet.t.sol`
  - Observed outcome after expansion:
    - Solo AMM suite passed with `44/44` tests
    - Community AMM suite passed with `14/14` tests

- [ ] 9. Checkpoint — Run targeted AMM test suites and ensure all tests pass
  - Run: `forge test --match-path test/EqualXSoloAmmFacet.t.sol`
  - Run: `forge test --match-path test/EqualXCommunityAmmFacet.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all five bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ask the user if questions arise
