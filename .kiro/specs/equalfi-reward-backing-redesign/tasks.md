# Implementation Plan

- [ ] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — EDEN Partial Claim, FoT Overpayment, Cross-Program Coupling, ETH Lock, Target Growth, Past-Start Skip
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/EdenRewardsFacet.t.sol`
  - Use real reward-program creation, real ERC20 approvals, real funding, real EqualIndex position flows — no synthetic shortcuts
  - **Finding 6 — Partial claim restoration**: Create a reward program, fund it, accrue rewards for a position. Arrange state so `grossClaimAmount > availableGross` (e.g., transfer some reward tokens out of the diamond or use a second program to consume shared balance). Claim and assert the call reverts (fail-closed). On unfixed code this will FAIL because the claim partially succeeds and restores unbacked `accruedRewards`.
  - **FoT overpayment**: Create a reward program with `outboundTransferBps > 0` using a mock FoT token where actual transfer fee is lower than configured bps. Fund, accrue, claim. Assert the claim reverts because `netReceived != claimed`. On unfixed code this will FAIL because the claim succeeds with `netReceived > claimed` (overpayment).
  - **Cross-program balance theft**: Create two reward programs sharing the same reward token. Fund both equally. Accrue and settle positions for both. Drain Program A's backing via legitimate claims until its own backing is exhausted. Attempt another claim from Program A. Assert it reverts. On unfixed code this will FAIL because Program A can consume Program B's backing from the shared diamond balance.
  - **Finding 3 — ETH lock**: Call `fundRewardProgram{value: 1 ether}(programId, amount, maxAmount)`. Assert the call reverts. On unfixed code this will FAIL because the function accepts nonzero `msg.value`.
  - **Finding 4 — Target array growth**: Create 3 reward programs for the same target. Close 2 of them. Assert `targetProgramIds` length is 1 (only the live program). On unfixed code this will FAIL because closed programs remain in the array (length stays 3).
  - **Past-start skip**: Create a reward program with `startTime = block.timestamp - 1 days`. Assert `program.state.lastRewardUpdate == startTime`. On unfixed code this will FAIL because `lastRewardUpdate` is set to `block.timestamp`.
  - Run tests on UNFIXED code: `forge test --match-path test/EdenRewardsFacet.t.sol --match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10_

- [ ] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — EDEN Reward System Unchanged Behavior
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/EdenRewardsFacet.t.sol`
  - Use real reward-program creation, real ERC20 approvals, real funding, real EqualIndex position flows — no synthetic shortcuts
  - **Creation preservation**: Create a reward program with future `startTime`, verify `lastRewardUpdate == block.timestamp`, all config and state fields set correctly, `RewardProgramCreated` event emitted
  - **Funding preservation**: Fund a reward program with zero `msg.value`, verify `fundedReserve` incremented, `RewardProgramFunded` event emitted
  - **Accrual preservation**: Accrue a funded program, verify eligible supply computed, `globalRewardIndex` advanced, `fundedReserve` decremented, `RewardProgramAccrued` event emitted
  - **Settlement preservation**: Settle a position after accrual, verify `accruedRewards` accumulated from index delta, `RewardProgramPositionSettled` event emitted
  - **Successful claim preservation**: Claim with sufficient backing and no FoT, verify tokens transferred, `accruedRewards` zeroed, `RewardProgramClaimed` event emitted
  - **Lifecycle preservation**: Enable/disable/pause/resume/end a program, verify config mutations and events
  - **Close preservation**: Close a program with zero `fundedReserve` after `endTime`, verify `closed == true`
  - **View preservation**: Call `previewRewardProgramPosition` and `previewRewardProgramsForPosition`, verify computed values match expected
  - **Consumer hook preservation**: Trigger EqualIndex mint/burn, verify EDEN settlement and supply updates for live programs
  - Run preservation tests on UNFIXED code: `forge test --match-path test/EdenRewardsFacet.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10_

- [ ] 3. Fix Finding 3 — `fundRewardProgram` missing `assertZeroMsgValue`

  - [ ] 3.1 Add `LibCurrency.assertZeroMsgValue()` to `fundRewardProgram`
    - In `src/eden/EdenRewardsFacet.sol`, function `fundRewardProgram`
    - Add `LibCurrency.assertZeroMsgValue();` as the first line of the function body, before the `amount == 0` check
    - This matches every other state-mutating function in the facet
    - _Bug_Condition: isBugCondition(finding=3) where isFundRewardProgram AND msgValue > 0_
    - _Expected_Behavior: revert via assertZeroMsgValue when msg.value > 0_
    - _Preservation: ERC20 funding with zero msg.value unchanged_
    - _Requirements: 2.8, 3.3_

  - [ ] 3.2 Verify bug condition exploration test for Finding 3 now passes
    - **Property 1: Expected Behavior** — fundRewardProgram ETH Guard
    - **IMPORTANT**: Re-run the SAME Finding 3 test from task 1 — do NOT write a new test
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --match-test BugCondition_FundRewardProgram`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 3 bug is fixed)
    - _Requirements: 2.8_

  - [ ] 3.3 Verify preservation tests still pass after Finding 3 fix
    - **Property 2: Preservation** — Funding Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.3_

- [ ] 4. Fix Finding 6 and FoT overpayment — Fail-closed claims with exact delivery

  - [ ] 4.1 Add per-program backing fields to `RewardProgramState`
    - In `src/libraries/LibEdenRewardsStorage.sol`, struct `RewardProgramState`
    - Add `uint256 programBackingBalance` as the last field (after `rewardIndexRemainder` from Phase 1)
    - This field tracks actual token backing held in the diamond for this specific program
    - Storage layout must be append-only for compatibility with Phase 1 additions
    - This task assumes a clean-break rollout or new-program-only rollout; do not apply this spec to existing live programs without a separate migration/bootstrap plan
    - _Requirements: 2.5_

  - [ ] 4.2 Increment `programBackingBalance` on funding
    - In `src/eden/EdenRewardsFacet.sol`, function `fundRewardProgram`
    - After `funded = LibCurrency.pullAtLeast(...)`, add `program.state.programBackingBalance += funded`
    - This ensures per-program backing tracks actual tokens pulled for this program
    - _Requirements: 2.5, 3.3_

  - [ ] 4.3 Implement fail-closed claim with per-program backing check and exact FoT delivery
    - In `src/eden/EdenRewardsFacet.sol`, function `claimRewardProgram`
    - Replace `availableGross = LibCurrency.balanceOfSelf(rewardToken)` with `program.state.programBackingBalance`
    - Replace the partial-claim cap (`if grossClaimAmount > availableGross`) with a revert: `if (grossClaimAmount > program.state.programBackingBalance) revert InvalidParameterRange("insufficientProgramBacking")`
    - Decrement `program.state.programBackingBalance -= grossClaimAmount` before the transfer
    - Replace `if (netReceived < claimed)` restoration with `if (netReceived != claimed) revert InvalidParameterRange("claimDeliveryMismatch")`
    - Remove the partial-claim `accruedRewards` restoration path entirely
    - _Bug_Condition: isBugCondition(finding=6) where grossClaimAmount > programBackingBalance; isBugCondition(finding=7) where netReceived != claimed_
    - _Expected_Behavior: claims revert when backing insufficient or delivery inexact; successful claims fully honored with zero restored accruedRewards_
    - _Preservation: Claims with sufficient backing and correct FoT config produce identical transfer and events_
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 3.6_

  - [ ] 4.4 Verify bug condition exploration tests for Finding 6, FoT, and cross-program now pass
    - **Property 1: Expected Behavior** — Fail-Closed Claims, Exact FoT Delivery, Per-Program Isolation
    - **IMPORTANT**: Re-run the SAME tests from task 1 — do NOT write new tests
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --match-test "BugCondition_PartialClaim|BugCondition_FoTOverpayment|BugCondition_CrossProgram"`
    - **EXPECTED OUTCOME**: Tests PASS (confirms claim bugs are fixed)
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7_

  - [ ] 4.5 Verify preservation tests still pass after claim fixes
    - **Property 2: Preservation** — Claim, Funding, Accrual, Settlement Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.3, 3.4, 3.5, 3.6_

- [ ] 5. Fix Finding 4 — Unbounded target program array cleanup

  - [ ] 5.1 Add `removeProgramFromTarget` to `LibEdenRewardsStorage`
    - In `src/libraries/LibEdenRewardsStorage.sol`
    - Add a new function `removeProgramFromTarget(RewardsStorage storage store, uint256 programId, RewardTarget memory target)` that uses swap-and-pop to remove the program from `targetProgramIds`
    - Iterate the array, find the matching `programId`, swap with the last element, pop
    - If the program is not found, no-op (defensive)
    - _Requirements: 2.9_

  - [ ] 5.2 Call `removeProgramFromTarget` in `closeRewardProgram`
    - In `src/eden/EdenRewardsFacet.sol`, function `closeRewardProgram`
    - Require `program.state.programBackingBalance == 0` in addition to the existing zero-`fundedReserve` close precondition
    - After setting `program.config.closed = true`, call `LibEdenRewardsStorage.removeProgramFromTarget(store, programId, program.config.target)`
    - _Bug_Condition: isBugCondition(finding=4) where isCloseRewardProgram_
    - _Expected_Behavior: closed program removed from targetProgramIds, array shrinks by 1_
    - _Preservation: Close still marks program closed, now requiring zero reserve, zero backing, and past endTime_
    - _Requirements: 2.9, 2.10, 2.11, 3.8_

  - [ ] 5.3 Add closed-program skip in consumer loops (defense-in-depth)
    - In `src/libraries/LibEdenRewardsConsumer.sol`, functions `_settleTargetPositionPrograms` and `afterTargetBalanceChange`
    - Add `if (store.programs[programId].config.closed) continue;` inside each iteration loop
    - This is a secondary guard in case any historical entries remain after the swap-and-pop removal
    - _Requirements: 2.10, 3.10_

  - [ ] 5.4 Verify bug condition exploration test for Finding 4 now passes
    - **Property 1: Expected Behavior** — Target Array Cleanup
    - **IMPORTANT**: Re-run the SAME Finding 4 test from task 1 — do NOT write a new test
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --match-test BugCondition_TargetArray`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 4 bug is fixed)
    - _Requirements: 2.9, 2.10_

  - [ ] 5.5 Verify preservation tests still pass after Finding 4 fix
    - **Property 2: Preservation** — Consumer Hook and Close Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.8, 3.10_

- [ ] 6. Fix past-start program semantics — Retroactive accrual support

  - [ ] 6.1 Initialize `lastRewardUpdate` to `startTime` when `startTime < block.timestamp`
    - In `src/eden/EdenRewardsFacet.sol`, function `createRewardProgram`
    - Replace `store.programs[programId].state.lastRewardUpdate = block.timestamp` with:
      `store.programs[programId].state.lastRewardUpdate = startTime < block.timestamp ? startTime : block.timestamp`
    - This enables retroactive reward accrual from the configured `startTime` when it is in the past
    - Programs with future `startTime` continue to use `block.timestamp` (the accrual engine already uses `max(lastRewardUpdate, startTime)` as the effective start)
    - _Bug_Condition: isBugCondition(finding=9) where startTime < block.timestamp_
    - _Expected_Behavior: lastRewardUpdate == startTime for past-start programs_
    - _Preservation: Future-start programs unchanged_
    - _Requirements: 2.12, 2.13, 3.1_

  - [ ] 6.2 Verify bug condition exploration test for past-start now passes
    - **Property 1: Expected Behavior** — Retroactive Start
    - **IMPORTANT**: Re-run the SAME past-start test from task 1 — do NOT write a new test
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --match-test BugCondition_PastStart`
    - **EXPECTED OUTCOME**: Test PASSES (confirms past-start bug is fixed)
    - _Requirements: 2.12_

  - [ ] 6.3 Verify preservation tests still pass after past-start fix
    - **Property 2: Preservation** — Creation Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1_

- [ ] 7. Fix manager rotation — Add `setRewardProgramManager`

  - [ ] 7.1 Add `RewardProgramManagerUpdated` event and `setRewardProgramManager` function
    - In `src/eden/EdenRewardsFacet.sol`
    - Add event: `event RewardProgramManagerUpdated(uint256 indexed programId, address indexed oldManager, address indexed newManager)`
    - Add function:
      ```
      function setRewardProgramManager(uint256 programId, address newManager) external nonReentrant {
          LibCurrency.assertZeroMsgValue();
          if (newManager == address(0)) revert InvalidParameterRange("manager");
          LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
          _enforceManagerOrGovernance(program.config.manager);
          if (program.config.closed) revert InvalidParameterRange("programClosed");
          address oldManager = program.config.manager;
          program.config.manager = newManager;
          emit RewardProgramManagerUpdated(programId, oldManager, newManager);
      }
      ```
    - _Bug_Condition: isBugCondition(finding=10) where manager rotation needed_
    - _Expected_Behavior: manager rotated by current manager or governance; unauthorized callers rejected_
    - _Preservation: Existing lifecycle functions continue to use _enforceManagerOrGovernance identically_
    - _Requirements: 2.14, 2.15, 3.7_

  - [ ] 7.2 Write manager rotation unit tests
    - Test file: `test/EdenRewardsFacet.t.sol`
    - Test current manager can rotate to new manager
    - Test governance can rotate the manager
    - Test unauthorized caller reverts with `Unauthorized()`
    - Test `address(0)` newManager reverts
    - Test rotation on closed program reverts
    - Test rotated manager controls subsequent lifecycle operations
    - Test old manager is rejected after rotation
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --match-test ManagerRotation`
    - **EXPECTED OUTCOME**: Tests PASS
    - _Requirements: 2.14, 2.15_

  - [ ] 7.3 Verify preservation tests still pass after manager rotation addition
    - **Property 2: Preservation** — Lifecycle Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.7_

- [ ] 8. Expand regression and integration tests

  - [ ] 8.1 Add full EDEN lifecycle integration test with backing isolation
    - Test file: `test/EdenRewardsFacet.t.sol`
    - Create → fund → accrue → settle → claim → end → close
    - Verify `programBackingBalance` tracks correctly through the full lifecycle
    - Verify `fundedReserve` and `programBackingBalance` are both zero after all claims and close
    - Verify `targetProgramIds` is empty after close
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol`
    - _Requirements: 2.1, 2.2, 2.5, 2.9_

  - [ ] 8.2 Add two-program same-token isolation integration test
    - Test file: `test/EdenRewardsFacet.t.sol`
    - Create two programs with the same reward token
    - Fund both, accrue both, settle positions for both
    - Claim from each program, verify each claim bounded by its own `programBackingBalance`
    - Verify one program's claims cannot affect the other's backing
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol`
    - _Requirements: 2.5, 2.6, 2.7_

  - [ ] 8.3 Add past-start retroactive accrual integration test
    - Test file: `test/EdenRewardsFacet.t.sol`
    - Create a program with `startTime = block.timestamp - 1 days`
    - Fund the program
    - Accrue and verify rewards accrued from `startTime` (1 day of retroactive rewards)
    - Settle and claim, verify correct amount
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol`
    - _Requirements: 2.12_

  - [ ] 8.4 Add target cleanup lifecycle integration test
    - Test file: `test/EdenRewardsFacet.t.sol`
    - Create 3 programs for the same target
    - Close 2 of them only after ending and draining both reserve and backing
    - Trigger EqualIndex mint/burn, verify consumer hooks only iterate the 1 live program
    - Verify programs cannot be closed while `programBackingBalance > 0`
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol`
    - _Requirements: 2.9, 2.10, 2.11_

  - [ ] 8.5 Add manager rotation lifecycle integration test
    - Test file: `test/EdenRewardsFacet.t.sol`
    - Create a program → rotate manager → verify new manager can pause/resume/end
    - Verify old manager is rejected for lifecycle operations
    - Verify governance can still override
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol`
    - _Requirements: 2.14, 2.15_

  - [ ] 8.6 Add FoT exact-delivery claim integration test
    - Test file: `test/EdenRewardsFacet.t.sol`
    - Create a program with `outboundTransferBps` matching a mock FoT token's actual fee
    - Fund, accrue, settle, claim — verify exact delivery succeeds
    - Change mock FoT fee to differ from configured bps — verify claim reverts
    - Run: `forge test --match-path test/EdenRewardsFacet.t.sol`
    - _Requirements: 2.3, 2.4_

  - Verification runs:
    - `forge test --match-path test/EdenRewardsFacet.t.sol`

- [ ] 9. Checkpoint — Run targeted EDEN test suite and ensure all tests pass
  - Run: `forge test --match-path test/EdenRewardsFacet.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ensure manager rotation tests PASS
  - Ask the user if questions arise
