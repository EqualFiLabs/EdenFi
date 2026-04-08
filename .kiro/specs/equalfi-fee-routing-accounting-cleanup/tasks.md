# Implementation Plan

- [x] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — Maintenance Chargeable-Principal Overcharge, Curve Hardcoded Split, Treasury Accounting Policy Ambiguity, and Reward Reserve Truncation
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/LibMaintenance.t.sol` for finding 1, `test/LibEqualXCurveEngine.t.sol` for finding 2, `test/LibFeeRouter.t.sol` for finding 3, `test/LibEdenRewardsEngine.t.sol` for finding 4
  - Use real deposits, real pool creation, real swaps, real reward programs — no synthetic shortcuts unless unreachable state requires it
  - **Finding 1 — Maintenance chargeable-principal overcharge**: Create a pool with deposits from two users. Index-encumber one user's capital via a real EqualIndex flow or equivalent index encumbrance path. Accrue maintenance. Settle both users. Assert maintenance is charged only on each user's chargeable principal (`principal - indexEncumbered`). On unfixed code this will FAIL because `_applyMaintenanceToIndex` divides by `totalDeposits` and `settle` applies the delta to full principal.
  - **Finding 2 — Curve hardcoded 70/30 fee split**: Configure a canonical EqualX maker-share source at 5000 (50/50 split) for the test harness. Create a curve market. Execute a curve swap with a known fee amount. Assert maker received 50% of the fee (not 70%). On unfixed code this will FAIL because `_applyQuoteSide` hardcodes `fee * 7000 / 10_000`.
  - **Finding 3 — Treasury accounting policy ambiguity**: Create a pool with an exotic token mock whose sender-side balance delta is observable. Route protocol fees through every treasury helper path. Assert all treasury-routing paths debit `trackedBalance` according to the same pool-side balance-delta rule. On unfixed code this will FAIL if helpers diverge or rely on inconsistent nominal/receive-side assumptions.
  - **Finding 4a — Reward reserve deducted beyond indexed liability**: Create an EDEN reward program with `outboundTransferBps = 500` (5% fee) and parameters that cause partial reward-index truncation. Fund the program. Accrue rewards. Assert `fundedReserve` decreased only by the gross backing associated with the net amount that actually entered `globalRewardIndex`, not by a larger tentative allocation. On unfixed code this will FAIL because `_previewAccrual` deducts reserve before resolving distribution rounding.
  - **Finding 4b — Reward truncation loss**: Create an EDEN reward program with very large `eligibleSupply` and small `rewardRatePerSecond`. Accrue rewards. Assert `fundedReserve` is unchanged when the index delta truncates to zero. On unfixed code this will FAIL because `fundedReserve` is deducted even when the index delta is zero.
  - Run tests on UNFIXED code:
    - `forge test --match-path test/LibMaintenance.t.sol`
    - `forge test --match-path test/LibEqualXCurveEngine.t.sol`
    - `forge test --match-path test/LibFeeRouter.t.sol`
    - `forge test --match-path test/LibEdenRewardsEngine.t.sol`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - Counterexamples observed on unfixed code:
    - maintenance settlement charged the index-encumbered user on full principal instead of only chargeable principal
    - curve execution still credited the maker with a hardcoded 70% fee share under a 50/50 expectation
    - treasury routing debited tracked balance by nominal transfer amount instead of observed sender-side balance delta for exotic tokens
    - EDEN reward accrual reduced `fundedReserve` even when only a truncated subset, or none, of the reward actually entered `globalRewardIndex`
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.7, 1.8, 1.9, 1.10, 1.11_

- [x] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — Maintenance, Curve, FeeRouter, and EDEN Reward Unchanged Behavior
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/LibMaintenance.t.sol`, `test/LibEqualXCurveEngine.t.sol`, `test/LibFeeRouter.t.sol`, `test/LibEdenRewardsEngine.t.sol`
  - Use real deposits, real pool creation, real swaps, real reward programs — no synthetic shortcuts unless unreachable state requires it
  - **Maintenance zero-encumbrance preservation**: Accrue maintenance on a pool with zero encumbered capital, verify index delta and `totalDeposits` reduction are identical to current behavior
  - **Maintenance pay preservation**: Verify `_pay` transfers to foundation receiver correctly
  - **Maintenance enforce preservation**: Verify `enforce` on uninitialized pool or zero-receiver returns early
  - **Fee index settle yield preservation**: Verify fee yield computation for non-encumbered users is unchanged
  - **Fee index settle zero-principal preservation**: Verify settle for zero-principal user snaps indexes without computing yield
  - **Curve execution mechanics preservation**: Execute a curve swap, verify price computation, volume tracking, commitment updates, and position settlement are unchanged
  - **Curve base-side preservation**: Verify `_applyBaseSide` decreases maker principal, decreases totalDeposits, and unlocks collateral identically
  - **Fee router split preservation**: Verify `previewSplit` and `routeSamePool` split ratios are unchanged
  - **Treasury non-FoT preservation**: Verify `_transferTreasury` for standard ERC-20 tokens decrements `trackedBalance` by full nominal amount
  - **EDEN reward settlement preservation**: Verify `settleProgramPosition` claimable computation is unchanged
  - **EDEN reward short-circuit preservation**: Verify `_previewAccrual` short-circuits for zero supply, zero reserve, closed, disabled, paused programs
  - **EDEN gross/net utility preservation**: Verify `grossUpNetAmount` and `netFromGross` produce identical results
  - **EDEN zero-outboundTransferBps preservation**: Verify `_previewAccrual` with zero `outboundTransferBps` behaves identically (gross == net)
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/LibMaintenance.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/LibEqualXCurveEngine.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/LibFeeRouter.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/LibEdenRewardsEngine.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - Baseline observed on unfixed code:
    - `test/LibMaintenance.t.sol --no-match-test BugCondition` passed `4/4`
    - `test/LibEqualXCurveEngine.t.sol --no-match-test BugCondition` passed `15/15`
    - `test/LibFeeRouter.t.sol --no-match-test BugCondition` passed `3/3`
    - `test/LibEdenRewardsEngine.t.sol --no-match-test BugCondition` passed `31/31`
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13, 3.14, 3.15_

- [x] 3. Fix Finding 1 — Maintenance charged only on chargeable principal

  - [x] 3.1 Fix `_applyMaintenanceToIndex` to divide by `chargeableTvl` instead of `totalDeposits`
    - In `src/libraries/LibMaintenance.sol`, function `_applyMaintenanceToIndex`
    - Change function signature to accept `chargeableTvl` as a parameter
    - Replace `oldTotal = p.totalDeposits + amount` with `chargeableTvl` as the divisor
    - Update remainder computation to use `chargeableTvl`
    - Update the call site in `_accrue` to pass the already-computed `chargeableTvl`
    - _Bug_Condition: isBugCondition(finding=1) where isMaintenanceAccrual AND indexEncumberedTotal > 0_
    - _Expected_Behavior: indexDelta = scaledAmount / chargeableTvl, not scaledAmount / totalDeposits_
    - _Preservation: Pools with zero encumbered capital produce identical behavior since chargeableTvl == totalDeposits_
    - _Requirements: 2.1, 2.3, 3.1, 3.3_

  - [x] 3.2 Fix `previewState` to use `chargeableTvl` as divisor
    - In `src/libraries/LibMaintenance.sol`, function `previewState`
    - Replace `oldTotal = totalDepositsAfterAccrual + amountAccrued` with `chargeableTvl` as the divisor
    - Ensure preview matches the fixed `_applyMaintenanceToIndex` behavior
    - _Requirements: 2.1_

  - [x] 3.3 Apply maintenance only to chargeable principal in `LibFeeIndex.settle`
    - In `src/libraries/LibFeeIndex.sol`, function `settle`
    - Import and use `LibEncumbrance.getIndexEncumbered(user, pid)` as the per-user exempt-capital source
    - Compute `chargeablePrincipal = principal > indexEncumbered ? principal - indexEncumbered : 0`
    - Apply `maintenanceDelta` only to `chargeablePrincipal`, not to full principal
    - Always snap the user's maintenance index to current to prevent accumulation
    - _Bug_Condition: isBugCondition(finding=1) where isSettle AND userIndexEncumbered > 0_
    - _Expected_Behavior: maintenance charges only the user's non-index-encumbered principal_
    - _Preservation: Fee yield computation unchanged; zero-principal settle unchanged_
    - _Requirements: 2.2, 3.4, 3.5_

  - [x] 3.4 Verify bug condition exploration test for Finding 1 now passes
    - **Property 1: Expected Behavior** — Maintenance Chargeable Principal
    - **IMPORTANT**: Re-run the SAME Finding 1 test from task 1 — do NOT write a new test
    - Run: `forge test --match-path test/LibMaintenance.t.sol --match-test BugCondition`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 1 bug is fixed)
    - _Requirements: 2.1, 2.2, 2.3_

  - [x] 3.5 Verify preservation tests still pass after Finding 1 fix
    - **Property 2: Preservation** — Maintenance and Fee Index Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/LibMaintenance.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/LibFeeIndex.t.sol --no-match-test BugCondition` (if separate test file exists)
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed results:
      - `forge test --match-path test/LibMaintenance.t.sol --match-test BugCondition` passed `1/1`
      - `forge test --match-path test/LibMaintenance.t.sol --no-match-test BugCondition` passed `4/4`
      - no separate `test/LibFeeIndex.t.sol` exists; fee-index preservation for this track lives in `test/LibMaintenance.t.sol`
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [x] 4. Fix Finding 2 — Curve engine canonical fee split

  - [x] 4.1 Replace hardcoded 70/30 split with `splitFeeWithRouter` in `_applyQuoteSide`
    - In `src/libraries/LibEqualXCurveEngine.sol`, function `_applyQuoteSide`
    - Replace `uint256 makerFee = (preview.feeAmount * 7000) / 10_000` with a call to `LibEqualXSwapMath.splitFeeWithRouter(preview.feeAmount, makerBps)`
    - Introduce or reuse one canonical EqualX maker-share source consumed by curve execution and the AMM preview/execution paths; do not leave curve with a curve-local inline constant
    - Pass only the returned `protocolFee` leg into `routeSamePool` so routing happens exactly once
    - Import `LibEqualXSwapMath` if not already imported
    - _Bug_Condition: isBugCondition(finding=2) where isCurveSwapExecution AND feeAmount > 0_
    - _Expected_Behavior: makerFee = feeAmount * makerBps / 10_000 using the canonical EqualX maker-share source_
    - _Preservation: Curve execution mechanics, volume tracking, commitment updates, position settlement unchanged_
    - _Requirements: 2.4, 2.5, 3.6, 3.7, 3.8_

  - [x] 4.2 Verify bug condition exploration test for Finding 2 now passes
    - **Property 1: Expected Behavior** — Curve Canonical Fee Split
    - **IMPORTANT**: Re-run the SAME Finding 2 test from task 1 — do NOT write a new test
    - Run: `forge test --match-path test/LibEqualXCurveEngine.t.sol --match-test BugCondition`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 2 bug is fixed)
    - _Requirements: 2.4, 2.5_

  - [x] 4.3 Verify preservation tests still pass after Finding 2 fix
    - **Property 2: Preservation** — Curve Execution Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibEqualXCurveEngine.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Observed results:
      - `forge test --match-path test/LibEqualXCurveEngine.t.sol --match-test BugCondition` passed `1/1`
      - `forge test --match-path test/LibEqualXCurveEngine.t.sol --no-match-test BugCondition` passed `15/15`
    - _Requirements: 3.6, 3.7, 3.8_

- [ ] 5. Fix Finding 3 — Treasury transfer accounting policy hardening

  - [ ] 5.1 Encode pool-side balance-delta accounting in `_transferTreasury`
    - In `src/libraries/LibFeeRouter.sol`, function `_transferTreasury`
    - Make the implementation rule explicit: debit `trackedBalance` by the amount that actually left the pool balance
    - If measurement is needed for exotic tokens, use sender-side balance delta (`balBefore - balAfter` on the pool), not treasury-side received amount
    - Preserve current behavior when sender-side delta equals nominal `amount`
    - _Bug_Condition: isBugCondition(finding=3) where isTreasuryTransfer AND isFoT(token)_
    - _Expected_Behavior: trackedBalance debited by actual pool outflow under one explicit invariant across treasury helpers_
    - _Preservation: Non-FoT token treasury transfers produce identical trackedBalance changes_
    - _Requirements: 2.6, 2.7, 3.9, 3.10_

  - [ ] 5.2 Apply the same pool-side accounting rule to `_routeSystemShareToTreasury`
    - In `src/libraries/LibFeeRouter.sol`, function `_routeSystemShareToTreasury`
    - This function has a duplicate treasury transfer path — apply the same explicit sender-side balance-delta rule
    - _Requirements: 2.6, 2.7_

  - [ ] 5.3 Verify bug condition exploration test for Finding 3 now passes
    - **Property 1: Expected Behavior** — Treasury Pool-Side Balance-Delta Accounting
    - **IMPORTANT**: Re-run the SAME Finding 3 test from task 1 — do NOT write a new test
    - Run: `forge test --match-path test/LibFeeRouter.t.sol --match-test BugCondition`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 3 bug is fixed)
    - _Requirements: 2.6, 2.7_

  - [ ] 5.4 Verify preservation tests still pass after Finding 3 fix
    - **Property 2: Preservation** — Fee Router Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibFeeRouter.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.9, 3.10_

- [ ] 6. Fix Finding 4 — EDEN reward indexed-liability reserve accounting and truncation

  - [ ] 6.1 Make `_previewAccrual` deduct reserve only for rewards actually indexed this round
    - In `src/libraries/LibEdenRewardsEngine.sol`, function `_previewAccrual`
    - Reorder the accrual flow so reward-index delta and remainder are resolved before `fundedReserve` is debited
    - Derive the exact net amount that actually entered `globalRewardIndex` in this step
    - Decrement `fundedReserve` by `grossUpNetAmount(indexedNet, outboundTransferBps)`, not by a larger tentative pre-round allocation
    - When no reward is indexed this round, do not debit `fundedReserve`
    - _Bug_Condition: isBugCondition(finding=4) where isRewardAccrual AND outboundTransferBps > 0_
    - _Expected_Behavior: fundedReserve decremented only by the gross backing for rewards that actually entered the index_
    - _Preservation: Programs with zero outboundTransferBps produce identical behavior_
    - _Requirements: 2.8, 2.10, 3.13, 3.14_

  - [ ] 6.2 Add `rewardIndexRemainder` field to `RewardProgramState`
    - In `src/libraries/LibEdenRewardsStorage.sol`, struct `RewardProgramState`
    - Add `uint256 rewardIndexRemainder` as the last field (append-only for storage compatibility)
    - This field carries forward undistributed scaled reward amounts when the index delta truncates to zero
    - _Requirements: 2.9_

  - [ ] 6.3 Implement remainder tracking in `_previewAccrual`
    - In `src/libraries/LibEdenRewardsEngine.sol`, function `_previewAccrual`
    - Replace the direct `globalRewardIndex += Math.mulDiv(...)` with remainder-aware logic:
      - Compute `scaledNetDividend = Math.mulDiv(allocatedNet, REWARD_INDEX_SCALE, 1) + state.rewardIndexRemainder`
      - Compute `delta = scaledNetDividend / state.eligibleSupply`
      - If `delta > 0`: increment `globalRewardIndex` by `delta`, store remainder `scaledNetDividend - (delta * eligibleSupply)`, and debit `fundedReserve` only for the gross backing associated with the net amount actually indexed
      - If `delta == 0`: carry forward `scaledNetDividend` as remainder and do NOT deduct from `fundedReserve`
    - This mirrors the `LibFeeIndex.feeIndexRemainder` pattern
    - _Bug_Condition: isBugCondition(finding=4b) where indexDelta truncates to 0_
    - _Expected_Behavior: remainder carried forward, no fundedReserve deduction when truncated_
    - _Preservation: Non-truncating accruals produce identical index growth_
    - _Requirements: 2.8, 2.9, 2.10, 3.11_

  - [ ] 6.4 Verify bug condition exploration tests for Finding 4 now pass
    - **Property 1: Expected Behavior** — EDEN Reward Indexed-Liability Reserve and Remainder Tracking
    - **IMPORTANT**: Re-run the SAME Finding 4 tests from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/LibEdenRewardsEngine.t.sol --match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Finding 4 bugs are fixed)
    - _Requirements: 2.8, 2.9, 2.10_

  - [ ] 6.5 Verify preservation tests still pass after Finding 4 fix
    - **Property 2: Preservation** — EDEN Reward Engine Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/LibEdenRewardsEngine.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.11, 3.12, 3.13, 3.14, 3.15_

- [ ] 7. Expand regression and integration tests

  - [ ] 7.1 Add maintenance mixed-encumbrance lifecycle integration test
    - Test file: `test/LibMaintenance.t.sol`
    - Create pool with two depositors. Index-encumber one user's capital via a real EqualIndex or equivalent index-encumbrance flow.
    - Accrue maintenance over multiple epochs. Settle both users.
    - Assert maintenance charges track each user's chargeable principal, not full principal.
    - Include a mixed case where one user is partially index-encumbered, not just fully exempt.
    - Assert `totalDeposits` decreased by the correct aggregate maintenance amount.
    - Run: `forge test --match-path test/LibMaintenance.t.sol`
    - _Requirements: 2.1, 2.2, 2.3_

  - [ ] 7.2 Add curve fee-split canonical-source change integration test
    - Test file: `test/LibEqualXCurveEngine.t.sol`
    - Create a curve market with the default canonical EqualX maker-share source. Execute a swap, record maker fee.
    - Change the canonical maker-share source to a different value. Execute another swap.
    - Assert the second swap uses the updated source for the maker/protocol split.
    - Assert both swaps route protocol fees correctly through `routeSamePool`.
    - Run: `forge test --match-path test/LibEqualXCurveEngine.t.sol`
    - _Requirements: 2.4, 2.5_

  - [ ] 7.3 Add treasury exotic-token accounting consistency integration test
    - Test file: `test/LibFeeRouter.t.sol`
    - Create a pool with an exotic token mock that makes sender-side balance delta observable.
    - Execute treasury transfers through each helper path.
    - Assert `trackedBalance` after all transfers matches the explicit pool-side accounting invariant.
    - Assert no helper path diverges from actual backing semantics.
    - Run: `forge test --match-path test/LibFeeRouter.t.sol`
    - _Requirements: 2.6, 2.7_

  - [ ] 7.4 Add EDEN reward multi-cycle FoT lifecycle integration test
    - Test file: `test/LibEdenRewardsEngine.t.sol`
    - Create an EDEN reward program with `outboundTransferBps > 0`.
    - Fund the program. Accrue rewards over 5+ cycles.
    - Settle positions and compute total claimable.
    - Assert `fundedReserve` is sufficient to cover all outstanding claims.
    - Assert cumulative `fundedReserve` deductions match cumulative gross claim liability created by indexed rewards.
    - Run: `forge test --match-path test/LibEdenRewardsEngine.t.sol`
    - _Requirements: 2.8, 2.10_

  - [ ] 7.5 Add EDEN reward truncation recovery integration test
    - Test file: `test/LibEdenRewardsEngine.t.sol`
    - Create an EDEN reward program with very large `eligibleSupply` and small `rewardRatePerSecond`.
    - Accrue rewards in small increments where each individual accrual truncates to zero index delta.
    - Assert `fundedReserve` is unchanged during truncated accruals.
    - Assert `rewardIndexRemainder` accumulates correctly.
    - Continue accruing until remainder is large enough to produce a non-zero delta.
    - Assert `globalRewardIndex` increases and remainder is consumed.
    - Run: `forge test --match-path test/LibEdenRewardsEngine.t.sol`
    - _Requirements: 2.9_

  - Verification runs:
    - `forge test --match-path test/LibMaintenance.t.sol`
    - `forge test --match-path test/LibEqualXCurveEngine.t.sol`
    - `forge test --match-path test/LibFeeRouter.t.sol`
    - `forge test --match-path test/LibEdenRewardsEngine.t.sol`

- [ ] 8. Checkpoint — Run all targeted test suites and ensure all tests pass
  - Run: `forge test --match-path test/LibMaintenance.t.sol`
  - Run: `forge test --match-path test/LibEqualXCurveEngine.t.sol`
  - Run: `forge test --match-path test/LibFeeRouter.t.sol`
  - Run: `forge test --match-path test/LibEdenRewardsEngine.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all four findings are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ask the user if questions arise
