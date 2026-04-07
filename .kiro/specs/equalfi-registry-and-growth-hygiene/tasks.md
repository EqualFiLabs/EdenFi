# Implementation Plan

- [ ] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — Registry and Growth Hygiene Findings 1-5
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/EdenRewardsStorage.t.sol` for finding 1; `test/OptionsFacet.t.sol` for finding 2; `test/EqualXStorage.t.sol` for findings 3-4; `test/EqualScaleAlphaFacet.t.sol` for finding 5
  - Use real program creation, real diamond init, real market creation, real commitments — no synthetic shortcuts
  - **Finding 1 — Program ID zero sentinel collision**: Create the first EDEN reward program via the storage harness, assert the returned program ID >= 1. On unfixed code this will FAIL because `allocateProgramId` returns 0.
  - **Finding 2 — European tolerance default**: Deploy a fresh diamond via `DiamondInit.init` (or read the storage after standard test setup), read `europeanToleranceSeconds`, assert it equals 300. On unfixed code this will FAIL because the field is uninitialized (0).
  - **Finding 3 — Discovery semantics guardrail**: Create and close a Solo AMM market via the storage harness, query `marketsByPosition` and `marketsByPair`, assert the historical pointer is still present while `activeMarketsByType` no longer contains the market. This test SHOULD PASS on unfixed code and documents the intended EqualFi discovery split; do not treat historical position/pair entries as bugs.
  - **Finding 4 — Discovery duplicate registration**: Call `registerMarket` twice for the same market via the storage harness, query the relevant array, assert the array length equals 1 (no duplicate). On unfixed code this will FAIL because there is no dedup guard.
  - **Finding 5 — Commitment ID append-only**: Create a credit line with a lender commitment, transition the commitment to Canceled status, query `lineCommitmentPositionIds`, assert the canceled lender position ID is NOT in the array. On unfixed code this will FAIL because the array is append-only.
  - Run tests on UNFIXED code:
    - `forge test --match-path test/EdenRewardsStorage.t.sol --match-test BugCondition`
    - `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition`
    - `forge test --match-path test/EqualXStorage.t.sol --match-test BugCondition`
    - `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition`
  - **EXPECTED OUTCOME**: The true bug-condition tests FAIL for findings 1, 2, 4, and 5, while the discovery-semantics guardrail for finding 3 PASSES and documents the intended EqualFi behavior
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8_

- [ ] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — Registry and Growth Hygiene Unchanged Behavior
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test files: `test/EdenRewardsStorage.t.sol`, `test/OptionsFacet.t.sol`, `test/EqualXStorage.t.sol`, `test/EqualScaleAlphaFacet.t.sol`
  - Use real program creation, real option series, real market creation, real commitments — no synthetic shortcuts
  - **EDEN program lifecycle preservation**: Create multiple reward programs, verify IDs are sequential, verify program config storage, target registration, and lifecycle operations work correctly
  - **Options tolerance override preservation**: Verify `setEuropeanTolerance` overrides the stored value, verify American option exercise is unaffected by tolerance, verify European option exercise window uses `[expiry - tolerance, expiry + tolerance]`
  - **Discovery registration preservation**: Create markets, verify all three arrays are populated correctly, verify position/pair queries retain historical pointers and active queries only return live markets
  - **Discovery active market preservation**: Create a market, verify it appears in all three discovery arrays while live, then closes out of the active set while remaining discoverable historically by position/pair
  - **Commitment tracking preservation**: Create a line with multiple lender commitments, verify all active commitments appear in `lineCommitmentPositionIds`, verify allocation helpers distribute correctly across active commitments
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/EdenRewardsStorage.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/EqualXStorage.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12_


- [ ] 3. Fix Finding 1 — `allocateProgramId` one-based ID allocation

  - [ ] 3.1 Implement increment-then-return in `allocateProgramId`
    - In `src/libraries/LibEdenRewardsStorage.sol`, function `allocateProgramId`
    - Change from `programId = store.nextProgramId; store.nextProgramId = programId + 1` to `store.nextProgramId++; programId = store.nextProgramId`
    - This ensures the first program ID is 1, not 0
    - Consistent with every other ID allocator in the codebase (e.g., `allocateMarketId`)
    - _Bug_Condition: isBugCondition(finding=1) where isCreateRewardProgram AND store.nextProgramId == 0_
    - _Expected_Behavior: returned programId >= 1; ID 0 never assigned_
    - _Preservation: Program lifecycle operations unchanged; IDs are sequential starting from 1_
    - _Requirements: 2.1, 2.2_

  - [ ] 3.2 Verify bug condition exploration test for Finding 1 now passes
    - **Property 1: Expected Behavior** — One-Based Program ID
    - **IMPORTANT**: Re-run the SAME Finding 1 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EdenRewardsStorage.t.sol --match-test BugCondition`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 1 bug is fixed)
    - _Requirements: 2.1, 2.2_

  - [ ] 3.3 Verify preservation tests still pass after Finding 1 fix
    - **Property 2: Preservation** — EDEN Program Lifecycle
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EdenRewardsStorage.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.2, 3.3_

- [ ] 4. Fix Finding 2 — `europeanToleranceSeconds` safe default initialization

  - [ ] 4.1 Add tolerance initialization to `DiamondInit.init`
    - In `src/core/DiamondInit.sol`, function `init`
    - Add import: `import {LibOptionsStorage} from "../libraries/LibOptionsStorage.sol";`
    - Add after existing initialization: `LibOptionsStorage.s().europeanToleranceSeconds = 300;`
    - 300 seconds (5 minutes) matches the audit report recommendation
    - Governance can still override via `setEuropeanTolerance`
    - _Bug_Condition: isBugCondition(finding=2) where isDiamondInit AND europeanToleranceSeconds == 0_
    - _Expected_Behavior: europeanToleranceSeconds == 300 after DiamondInit.init_
    - _Preservation: setEuropeanTolerance override unchanged; American options unaffected; exercise window validation unchanged_
    - _Requirements: 2.3_

  - [ ] 4.2 Verify bug condition exploration test for Finding 2 now passes
    - **Property 1: Expected Behavior** — Safe Default Tolerance
    - **IMPORTANT**: Re-run the SAME Finding 2 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 2 bug is fixed)
    - _Requirements: 2.3_

  - [ ] 4.3 Verify preservation tests still pass after Finding 2 fix
    - **Property 2: Preservation** — Options Exercise Lifecycle
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.4, 3.5, 3.6_

- [ ] 5. Fix Findings 3-4 — Discovery registry semantics preservation and deduplication

  - [ ] 5.1 Add deduplication guard to `registerMarket`
    - In `src/libraries/LibEqualXDiscoveryStorage.sol`, function `registerMarket`
    - Add a private `_containsMarket` helper that checks if a `MarketPointer` with the given `marketType` and `marketId` already exists in an array
    - Before each `.push(pointer)` call, check `_containsMarket` and skip if already present
    - This prevents duplicate entries in `marketsByPosition`, `marketsByPair`, and `activeMarketsByType`
    - _Bug_Condition: isBugCondition(finding=4) where isRegisterMarket AND marketAlreadyRegistered_
    - _Expected_Behavior: no duplicate MarketPointer entries in any discovery array_
    - _Preservation: First-time registration unchanged; all three arrays still populated_
    - _Requirements: 2.5_

  - [ ] 5.2 Preserve historical discovery arrays and document the invariant in tests
    - Do NOT add close-time removal for `marketsByPosition` or `marketsByPair`
    - Add or update tests in `test/EqualXStorage.t.sol` so they explicitly assert:
      - `activeMarketsByType` drops closed markets
      - `marketsByPosition` and `marketsByPair` retain historical pointers
    - _Bug_Condition: isBugCondition(finding=3) where a remediation change would collapse historical and live discovery semantics_
    - _Expected_Behavior: historical queries remain historical; active queries remain live-only_
    - _Requirements: 2.4, 2.6_

  - [ ] 5.3 Verify bug condition exploration test for Finding 4 now passes
    - **Property 1: Expected Behavior** — Deduplication With Historical Discovery Preserved
    - **IMPORTANT**: Re-run the SAME Finding 4 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualXStorage.t.sol --match-test BugCondition.*Duplicate`
    - **EXPECTED OUTCOME**: Test PASSES (confirms discovery duplicate registration is fixed)
    - _Requirements: 2.5_

  - [ ] 5.4 Verify preservation tests still pass after Findings 3-4 fix
    - **Property 2: Preservation** — Discovery Registry
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualXStorage.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.7, 3.8, 3.9_

- [ ] 6. Fix Finding 5 — `lineCommitmentPositionIds` bounded tracking

  - [ ] 6.1 Add `removeCommitmentPositionId` to `LibEqualScaleAlphaStorage`
    - In `src/libraries/LibEqualScaleAlphaStorage.sol`
    - Add a new function `removeCommitmentPositionId(EqualScaleAlphaStorage storage store, uint256 lineId, uint256 lenderPositionId)` using swap-and-pop on `store.lineCommitmentPositionIds[lineId]`
    - Linear scan to find the position ID, swap with last element, pop
    - Also clear `store.lineHasCommitmentPosition[lineId][lenderPositionId] = false` so the mapping reflects active membership and allows re-commitment
    - _Bug_Condition: isBugCondition(finding=5) where isCommitmentTerminalTransition AND positionIdStillInArray_
    - _Expected_Behavior: lender position ID removed from lineCommitmentPositionIds on terminal transition_
    - _Requirements: 2.7, 2.8_

  - [ ] 6.2 Call `removeCommitmentPositionId` on commitment terminal transitions
    - In `src/equalscale/EqualScaleAlphaFacet.sol` and/or `src/equalscale/LibEqualScaleAlphaShared.sol`
    - When a commitment status is set to `Canceled`: call `removeCommitmentPositionId`
    - When a commitment status is set to `Exited`: call `removeCommitmentPositionId`
    - When a commitment status is set to `WrittenDown`: call `removeCommitmentPositionId`
    - When `closeAllCommitments` sets status to `Closed`: call `removeCommitmentPositionId` for each commitment being closed
    - Note: `closeAllCommitments` iterates the array — it should iterate in reverse or collect IDs first to avoid index shifting during swap-and-pop
    - _Requirements: 2.7_

  - [ ] 6.3 Verify bug condition exploration test for Finding 5 now passes
    - **Property 1: Expected Behavior** — Bounded Commitment Tracking
    - **IMPORTANT**: Re-run the SAME Finding 5 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --match-test BugCondition`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 5 bug is fixed)
    - _Requirements: 2.7, 2.8_

  - [ ] 6.4 Verify preservation tests still pass after Finding 5 fix
    - **Property 2: Preservation** — EqualScale Commitment Lifecycle
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.10, 3.11, 3.12_


- [ ] 7. Refresh and expand regression tests

  - [ ] 7.1 Add EDEN reward program lifecycle integration test
    - Create multiple reward programs, verify IDs are 1, 2, 3 (not 0, 1, 2)
    - Fund a program, accrue rewards, claim rewards — verify full lifecycle works with one-based IDs
    - Verify `targetProgramIds` returns correct program IDs for the target
    - Run: `forge test --match-path test/EdenRewardsStorage.t.sol`
    - _Requirements: 2.1, 2.2, 3.1, 3.2, 3.3_

  - [ ] 7.2 Add European tolerance initialization integration test
    - Deploy diamond, verify `europeanToleranceSeconds == 300`
    - Create a European option series, exercise within the 300-second window, verify success
    - Call `setEuropeanTolerance(600)`, verify override, exercise within the 600-second window
    - Verify American option exercise is unaffected by tolerance value
    - Run: `forge test --match-path test/OptionsFacet.t.sol`
    - _Requirements: 2.3, 3.4, 3.5, 3.6_

  - [ ] 7.3 Add discovery registry complete lifecycle integration test
    - Create a Solo AMM market, verify it appears in all three discovery arrays
    - Finalize the market, verify it is removed from `activeMarketsByType` but remains visible in historical position/pair discovery
    - Create a second market for the same position/pair, verify no duplicate active registration and both historical pointers remain queryable
    - Attempt duplicate registration, verify no duplicates in any array
    - Run: `forge test --match-path test/EqualXStorage.t.sol`
    - _Requirements: 2.4, 2.5, 2.6, 3.7, 3.8, 3.9_

  - [ ] 7.4 Add EqualScale commitment pruning lifecycle integration test
    - Create a credit line with two lender commitments
    - Cancel one commitment, verify it is removed from `lineCommitmentPositionIds`
    - Verify the remaining active commitment is still in the array
    - Run allocation (repayment) on the line, verify only the active commitment receives allocation
    - Close the line, verify all commitments are removed from the array and can be recommitted later if desired
    - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
    - _Requirements: 2.7, 2.8, 3.10, 3.11, 3.12_

  - Verification runs:
    - `forge test --match-path test/EdenRewardsStorage.t.sol`
    - `forge test --match-path test/OptionsFacet.t.sol`
    - `forge test --match-path test/EqualXStorage.t.sol`
    - `forge test --match-path test/EqualScaleAlphaFacet.t.sol`

- [ ] 8. Checkpoint — Run all targeted test suites and ensure all tests pass
  - Run: `forge test --match-path test/EdenRewardsStorage.t.sol`
  - Run: `forge test --match-path test/OptionsFacet.t.sol`
  - Run: `forge test --match-path test/EqualXStorage.t.sol`
  - Run: `forge test --match-path test/EqualScaleAlphaFacet.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all five bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ask the user if questions arise
