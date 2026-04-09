# Implementation Plan

- [x] 1. Write bug condition exploration tests (BEFORE implementing fixes)
  - **Property 1: Bug Condition** — Options Lifecycle Findings 3-8 and Agreed Leads
  - **CRITICAL**: These tests MUST FAIL on unfixed code — failure confirms the bugs exist
  - **DO NOT attempt to fix the tests or the code when they fail**
  - **NOTE**: These tests encode the expected behavior — they will validate the fixes when they pass after implementation
  - **GOAL**: Surface counterexamples that demonstrate each bug exists on the current unfixed code
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/OptionsFacet.t.sol` for findings 3-8 and leads; `test/OptionTokenAdminFacet.t.sol` for setOptionToken lead
  - Use real deposits, real series creation, real exercises, real reclaims — no synthetic shortcuts
  - **Finding 3 — Tolerance overflow**: Call `setEuropeanTolerance` with a value exceeding 30 days, assert revert with `Options_ExcessiveTolerance`. On unfixed code this will FAIL because the setter accepts any `uint64`.
  - **Finding 4 — European reclaim overlap**: Create European series with nonzero tolerance, warp to `expiry + tolerance/2` (inside exercise window), attempt `reclaimOptions`, assert revert. On unfixed code this will FAIL because reclaim succeeds during the overlap window.
  - **Finding 5 — Strike rounding**: Create call series with parameters producing fractional strike (e.g., non-round strike price with decimal mismatch), exercise, assert strike payment uses ceiling rounding (`payment >= ceil(expected)`). On unfixed code this will FAIL because floor rounding underpays.
  - **Finding 6 — Reclaim collateral dust**: Create put series, exercise partially multiple times with parameters that produce rounding truncation, reclaim remainder, assert `series.collateralLocked == 0` and collateral unlocked equals the stored residual. On unfixed code this will FAIL because recomputed collateral differs from stored residual.
  - **Finding 7 — Decimals fallback**: Deploy a mock token that reverts on `decimals()`, attempt to create a series using it, assert revert with `LibCurrency_DecimalsQueryFailed`. On unfixed code this will FAIL because silent fallback to 18 allows creation.
  - **Finding 8 — Deposit cap blocks exercise**: Create call series, set maker's pool to capped with a deposit cap just above current principal, exercise options (which credits strike payment to maker), assert exercise succeeds despite cap. On unfixed code this will FAIL because `_increasePrincipal` reverts on cap check.
  - **Lead — setOptionToken orphans**: Create a series (so `activeSeriesCount > 0`), call `setOptionToken(newAddr)`, assert revert. On unfixed code this will FAIL because replacement succeeds unconditionally.
  - **Lead — Zero-strike creation**: Call `createOptionSeries` with parameters where normalized strike truncates to zero (e.g., very low WAD strike price, small contract size, large decimal mismatch for calls), assert revert. On unfixed code this will FAIL because creation succeeds with dead-on-arrival economics.
  - Run tests on UNFIXED code: `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition` and `forge test --match-path test/OptionTokenAdminFacet.t.sol --match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests FAIL (this is correct — it proves the bugs exist)
  - Document counterexamples found to understand root cause
  - Mark task complete when tests are written, run, and failures are documented
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 1.11, 1.12, 1.13, 1.14, 1.17, 1.18_
  - Added `7` real-flow `BugCondition` regressions to `test/OptionsFacet.t.sol` covering:
    - tolerance overflow
    - European reclaim overlap
    - call strike rounding
    - put reclaim collateral dust
    - decimals fallback on series creation
    - capped-pool exercise settlement
    - zero-strike call creation
  - Added `1` `BugCondition` regression to `test/OptionTokenAdminFacet.t.sol` covering option-token replacement while a live series still exists
  - Observed runs on unfixed code:
    - `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition` -> `0/7` passed, `7/7` failed
    - `forge test --match-path test/OptionTokenAdminFacet.t.sol --match-test BugCondition` -> `0/1` passed, `1/1` failed
  - Documented counterexamples:
    - `setEuropeanTolerance(30 days + 1)` succeeded instead of reverting, proving the tolerance setter accepts overflow-prone values
    - European reclaim during `expiry + tolerance / 2` succeeded instead of reverting, proving reclaim overlaps the live exercise window
    - exercising the fractional-strike call paid `1_000_000` strike units instead of the protocol-safe ceiling `1_000_001`
    - partial put exercises left a stored reclaim residual mismatch: reclaim unlocked less than the stored residual and the series ended with nonzero `collateralLocked`
    - creating a put series against a token whose `decimals()` reverts still succeeded, proving silent 18-decimal fallback in the execution path
    - exercising a call into a capped maker strike pool reverted with `InvalidParameterRange("depositCap")`, proving pool deposit caps block exercise settlement credits
    - creating a call series with a normalized zero strike succeeded instead of reverting, proving dead-on-arrival economics are admitted at creation time
    - `setOptionToken(newAddr)` succeeded while a live series still existed, proving canonical token replacement can orphan outstanding option balances

- [x] 2. Write preservation property tests (BEFORE implementing fixes)
  - **Property 2: Preservation** — Options Lifecycle Unchanged Behavior
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on UNFIXED code first, then write tests capturing that behavior
  - **REFER TO ETHSKILLS.md** before writing any Solidity
  - Test file: `test/OptionsFacet.t.sol` and `test/OptionTokenAdminFacet.t.sol`
  - Use real deposits, real series creation, real exercises, real reclaims — no synthetic shortcuts
  - **Series creation preservation**: Create call and put series with valid parameters, verify collateral locking, state writing, token minting, events are correct and unchanged
  - **Call exercise preservation**: Exercise call options within window, verify payment collection, principal credit, collateral transfer to recipient are correct
  - **Put exercise preservation**: Exercise put options within window, verify payment collection, principal credit, collateral transfer to recipient are correct
  - **American lifecycle preservation**: Exercise American option before expiry, reclaim after expiry, verify both work correctly
  - **European exercise preservation**: Exercise European option within tolerance window, verify exercise succeeds
  - **Fully-exercised reclaim preservation**: Exercise all options in a series, reclaim, verify no collateral unlock and series marked reclaimed
  - **Non-owner reclaim preservation**: Attempt reclaim from non-owner, verify revert with ownership error
  - **Burn reclaimed claims preservation**: Reclaim series, burn claims, verify token burn works
  - **Admin pause preservation**: Toggle pause, verify state change
  - **View function preservation**: Call `previewExercisePayment`, verify correct preview amount
  - Run preservation tests on UNFIXED code while excluding the intentional task-1 `BugCondition` failures:
    - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - `forge test --match-path test/OptionTokenAdminFacet.t.sol --no-match-test BugCondition`
  - **EXPECTED OUTCOME**: Tests PASS (this confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13, 3.14, 3.15_
  - Reused the existing live options suite in `test/OptionsFacet.t.sol` for the baseline behaviors already covered on unfixed code:
    - call and put series creation with real deposits and real collateral locking
    - call and put exercise flows with real payment collection and principal updates
    - American exercise / reclaim lifecycle
    - European exercise within the configured tolerance window
    - pause toggling and exercise-payment previews
    - burn reclaimed claims behavior
  - Added explicit preservation coverage for the remaining gaps:
    - `test_ReclaimFullyExercisedSeries_MarksSeriesReclaimedWithoutUnlockingExtraCollateral`
    - `test_RevertWhen_ReclaimCalledByNonOwner`
    - `test_SetOptionToken_UpdatesCanonicalTokenWhenNoLiveSeriesExist`
  - Observed runs on unfixed code:
    - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition` -> `27/27` passed
    - `forge test --match-path test/OptionTokenAdminFacet.t.sol --no-match-test BugCondition` -> `1/1` passed


- [x] 3. Fix Finding 3 — Bound `setEuropeanTolerance`

  - [x] 3.1 Add `MAX_EUROPEAN_TOLERANCE` constant and bound check in `setEuropeanTolerance`
    - In `src/options/OptionsFacet.sol`, add constant: `uint64 constant MAX_EUROPEAN_TOLERANCE = 30 days;`
    - In `setEuropeanTolerance`, add: `if (toleranceSeconds > MAX_EUROPEAN_TOLERANCE) revert Options_ExcessiveTolerance(toleranceSeconds);`
    - Declare `Options_ExcessiveTolerance(uint64 tolerance)` error
    - _Bug_Condition: isBugCondition(finding=3) where toleranceValue > MAX_EUROPEAN_TOLERANCE_
    - _Expected_Behavior: revert on excessive tolerance; valid values stored successfully_
    - _Preservation: European exercise-window validation unchanged for valid tolerance values_
    - _Requirements: 2.1, 2.2_

  - [x] 3.2 Verify bug condition exploration test for Finding 3 now passes
    - **Property 1: Expected Behavior** — European Tolerance Bounded
    - **IMPORTANT**: Re-run the SAME Finding 3 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition.*ToleranceOverflow`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 3 bug is fixed)
    - _Requirements: 2.1_

  - [x] 3.3 Verify preservation tests still pass after Finding 3 fix
    - **Property 2: Preservation** — Options Admin and Exercise Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
    - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/OptionTokenAdminFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.8, 3.12_
  - Implemented in `src/options/OptionsFacet.sol` by:
    - adding `MAX_EUROPEAN_TOLERANCE = 30 days`
    - declaring `Options_ExcessiveTolerance(uint64 tolerance)`
    - reverting in `setEuropeanTolerance` when the configured tolerance exceeds the bound
  - Updated the existing task-1 `ToleranceOverflow` regression to assert on the timelock `execute(...)` step, which is the real revert boundary for this governance-gated setter
  - Verification:
    - `forge test --match-path test/OptionsFacet.t.sol --match-test 'BugCondition.*ToleranceOverflow'` -> `1/1` passed
    - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition` -> `27/27` passed
    - `forge test --match-path test/OptionTokenAdminFacet.t.sol --no-match-test BugCondition` -> `1/1` passed

- [x] 4. Fix Finding 4 — Eliminate European reclaim/exercise window overlap

  - [x] 4.1 Add European reclaim timing guard in `reclaimOptions`
    - In `src/options/OptionsFacet.sol`, function `reclaimOptions`
    - After the existing `block.timestamp <= series.expiry` check, add:
      ```
      if (!series.isAmerican) {
          uint64 tolerance = LibOptionsStorage.s().europeanToleranceSeconds;
          if (block.timestamp <= uint256(series.expiry) + uint256(tolerance)) {
              revert Options_ExerciseWindowStillOpen(seriesId);
          }
      }
      ```
    - Declare `Options_ExerciseWindowStillOpen(uint256 seriesId)` error
    - Keep existing American reclaim check (`block.timestamp <= series.expiry`) unchanged
    - _Bug_Condition: isBugCondition(finding=4) where isEuropean AND blockTimestamp <= expiry + tolerance_
    - _Expected_Behavior: European reclaim reverts during exercise window; succeeds after window closes_
    - _Preservation: American reclaim behavior unchanged; European exercise within window unchanged_
    - _Requirements: 2.3, 2.4, 2.5_

  - [x] 4.2 Verify bug condition exploration test for Finding 4 now passes
    - **Property 1: Expected Behavior** — European Reclaim Timing
    - **IMPORTANT**: Re-run the SAME Finding 4 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition.*EuropeanReclaimOverlap`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 4 bug is fixed)
    - _Requirements: 2.3, 2.4_

  - [x] 4.3 Verify preservation tests still pass after Finding 4 fix
    - **Property 2: Preservation** — Options Reclaim and Exercise Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.6, 3.7, 3.8, 3.9_
  - Implemented in `src/options/OptionsFacet.sol` by:
    - declaring `Options_ExerciseWindowStillOpen(uint256 seriesId)`
    - adding a European-only reclaim guard that reverts until `expiry + europeanToleranceSeconds` has passed
    - preserving the existing American reclaim rule based only on `expiry`
  - Verification:
    - `forge test --match-path test/OptionsFacet.t.sol --match-test 'BugCondition.*EuropeanReclaimOverlap'` -> `1/1` passed
    - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition` -> `27/27` passed

- [x] 5. Fix Finding 5 and Finding 7 — Protocol-safe strike normalization with fail-closed decimals

  - [x] 5.1 Rewrite `_normalizeStrikeAmount` with single ceiling `mulDiv` and `decimalsOrRevert`
    - In `src/options/OptionsFacet.sol`, function `_normalizeStrikeAmount`
    - Replace the two-step floor division with the overflow-safe staged ceiling formulation:
      ```
      uint256 underlyingScale = 10 ** uint256(LibCurrency.decimalsOrRevert(underlying));
      uint256 strikeScale = 10 ** uint256(LibCurrency.decimalsOrRevert(strike));
      uint256 wadValue = Math.mulDiv(underlyingAmount, strikePrice, underlyingScale, Math.Rounding.Ceil);
      strikeAmount = Math.mulDiv(wadValue, strikeScale, 1e18, Math.Rounding.Ceil);
      ```
    - This addresses both Finding 5 (ceiling rounding, single-step) and Finding 7 (decimalsOrRevert)
    - _Bug_Condition: isBugCondition(finding=5) AND isBugCondition(finding=7)_
    - _Expected_Behavior: strike amounts round up (protocol-safe); tokens with unusable decimals revert cleanly_
    - _Preservation: Standard ERC20 and native assets continue to behave unchanged; exact-division cases produce same results_
    - _Requirements: 2.6, 2.10_

  - [x] 5.2 Rewrite `_previewStrikeAmount` in `OptionsViewFacet` to match execution path
    - In `src/options/OptionsViewFacet.sol`, function `_previewStrikeAmount`
    - Replace with the same overflow-safe staged ceiling and `decimalsOrRevert` logic:
      ```
      uint256 underlyingScale = 10 ** uint256(LibCurrency.decimalsOrRevert(underlying));
      uint256 strikeScale = 10 ** uint256(LibCurrency.decimalsOrRevert(strike));
      uint256 wadValue = Math.mulDiv(underlyingAmount, strikePrice, underlyingScale, Math.Rounding.Ceil);
      strikeAmount = Math.mulDiv(wadValue, strikeScale, 1e18, Math.Rounding.Ceil);
      ```
    - _Bug_Condition: isBugCondition(finding=5) AND isBugCondition(finding=7) in preview path_
    - _Expected_Behavior: preview amounts match execution amounts; fail-closed decimals in previews_
    - _Requirements: 2.7, 2.11_

  - [x] 5.3 Verify bug condition exploration tests for Findings 5 and 7 now pass
    - **Property 1: Expected Behavior** — Strike Rounding and Decimals Safety
    - **IMPORTANT**: Re-run the SAME Finding 5 and Finding 7 tests from task 1 — do NOT write new tests
    - Run targeted regression:
      - `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition.*StrikeRounding`
      - `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition.*DecimalsFallback`
    - **EXPECTED OUTCOME**: Tests PASS (confirms Findings 5 and 7 bugs are fixed)
    - _Requirements: 2.6, 2.10_

  - [x] 5.4 Verify preservation tests still pass after Findings 5 and 7 fix
    - **Property 2: Preservation** — Options Creation, Exercise, and View Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - Note: strike amounts may change by +1 wei for non-exact divisions — preservation tests should account for ceiling rounding
    - _Requirements: 3.1, 3.3, 3.4, 3.5, 3.14_
  - Implemented in:
    - `src/options/OptionsFacet.sol::_normalizeStrikeAmount`
    - `src/options/OptionsViewFacet.sol::_previewStrikeAmount`
  - Both paths now:
    - use `LibCurrency.decimalsOrRevert(...)` so broken `decimals()` implementations fail closed
    - compute the strike amount with staged ceiling `Math.mulDiv(..., Math.Rounding.Ceil)` so protocol payments round up safely
  - Verification:
    - `forge test --match-path test/OptionsFacet.t.sol --match-test 'BugCondition.*StrikeRounding'` -> `1/1` passed
    - `forge test --match-path test/OptionsFacet.t.sol --match-test 'BugCondition.*DecimalsFallback'` -> `1/1` passed
    - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition` -> `27/27` passed
  - Note: the existing preservation suite already remained green without further assertion updates, which confirms the live options baselines were not brittle around the +1 rounding change


- [x] 6. Fix Finding 6 — Reclaim uses stored residual collateral

  - [x] 6.1 Replace collateral recomputation with stored `series.collateralLocked` in `reclaimOptions`
    - In `src/options/OptionsFacet.sol`, function `reclaimOptions`
    - Replace the block that recomputes collateral from `remainingSize`:
      ```
      // Before (recomputes):
      // uint256 underlyingAmount = remainingSize * series.contractSize;
      // collateralUnlocked = series.isCall ? underlyingAmount : _normalizeStrikeAmount(...);
      
      // After (uses stored residual):
      collateralUnlocked = series.collateralLocked;
      ```
    - After unlocking, zero the stored field: `series.collateralLocked = 0;`
    - Keep the collateral pool ID resolution unchanged
    - _Bug_Condition: isBugCondition(finding=6) where remainingSize > 0 AND recomputed != stored_
    - _Expected_Behavior: reclaim unlocks exactly the stored residual; no encumbrance dust_
    - _Preservation: Fully-exercised reclaim (remainingSize == 0, collateralLocked == 0) unchanged_
    - _Requirements: 2.8, 2.9_

  - [x] 6.2 Verify bug condition exploration test for Finding 6 now passes
    - **Property 1: Expected Behavior** — Reclaim Stored Collateral
    - **IMPORTANT**: Re-run the SAME Finding 6 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/OptionsFacet.t.sol --match-test BugCondition.*ReclaimCollateralDust`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 6 bug is fixed)
    - _Requirements: 2.8_

  - [x] 6.3 Verify preservation tests still pass after Finding 6 fix
    - **Property 2: Preservation** — Options Reclaim Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.9, 3.10_

- [x] 7. Fix Finding 8 — Bypass deposit cap for exercise settlement

  - [x] 7.1 Add `isExerciseSettlement` bypass to `_increasePrincipal`
    - In `src/options/OptionsFacet.sol`, function `_increasePrincipal`
    - Add `bool isExerciseSettlement` parameter
    - When `isExerciseSettlement == true`, skip `depositCap` and `maxUserCount` checks
    - Keep `userCount` increment for new users even during exercise (count must stay accurate)
    - Update call sites in `_exerciseCall` and `_exercisePut` to pass `true`
    - _Bug_Condition: isBugCondition(finding=8) where makerPool at cap AND isExercise_
    - _Expected_Behavior: exercise succeeds despite pool cap; ordinary deposits still capped_
    - _Preservation: Non-exercise principal increases (if any exist in Options) still enforce caps_
    - _Requirements: 2.12, 2.13_

  - [x] 7.2 Verify bug condition exploration test for Finding 8 now passes
    - **Property 1: Expected Behavior** — Exercise Through Capped Pool
    - **IMPORTANT**: Re-run the SAME Finding 8 test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/OptionsFacet.t.sol --match-test test_BugCondition_ExerciseOptions_ShouldBypassDepositCapDuringExerciseSettlement`
    - **EXPECTED OUTCOME**: Test PASSES (confirms Finding 8 bug is fixed)
    - _Requirements: 2.12_

  - [x] 7.3 Verify preservation tests still pass after Finding 8 fix
    - **Property 2: Preservation** — Options Exercise Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.3, 3.4, 3.5_

- [x] 8. Fix Lead — Block `setOptionToken` while live series exist

  - [x] 8.1 Add `activeSeriesCount` to `LibOptionsStorage` and guard `_setOptionToken`
    - In `src/libraries/LibOptionsStorage.sol`, add `uint256 activeSeriesCount;` to `OptionsStorage` struct
    - In `src/options/OptionsFacet.sol`, function `createOptionSeries`: after writing series, increment `store.activeSeriesCount`
    - In `src/options/OptionsFacet.sol`, function `reclaimOptions`: after marking `series.reclaimed = true`, decrement `store.activeSeriesCount`
    - In `src/options/OptionTokenAdminFacet.sol`, function `_setOptionToken`: before replacing token, check `if (LibOptionsStorage.s().activeSeriesCount > 0) revert OptionTokenAdmin_ActiveSeriesExist(LibOptionsStorage.s().activeSeriesCount);`
    - Declare `OptionTokenAdmin_ActiveSeriesExist(uint256 count)` error
    - _Bug_Condition: isBugCondition(finding=9) where activeSeriesCount > 0 AND isSetOptionToken_
    - _Expected_Behavior: setOptionToken reverts while live series exist; succeeds when quiescent_
    - _Preservation: deployOptionToken and setOptionToken with no live series unchanged_
    - _Requirements: 2.14, 2.15_

  - [x] 8.2 Verify bug condition exploration test for setOptionToken now passes
    - **Property 1: Expected Behavior** — Option Token Replacement Safety
    - **IMPORTANT**: Re-run the SAME setOptionToken test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/OptionTokenAdminFacet.t.sol --match-test test_BugCondition_SetOptionTokenOrphans_ShouldRejectReplacementWhileSeriesLive`
    - **EXPECTED OUTCOME**: Test PASSES (confirms setOptionToken lead is fixed)
    - _Requirements: 2.14_

  - [x] 8.3 Verify preservation tests still pass after setOptionToken fix
    - **Property 2: Preservation** — Admin Function Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/OptionTokenAdminFacet.t.sol --no-match-test BugCondition`
      - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.12, 3.13_

- [x] 9. Fix Lead — Creation-time zero-strike guard

  - [x] 9.1 Add zero-strike check in `createOptionSeries` for call options
    - In `src/options/OptionsFacet.sol`, function `createOptionSeries`
    - After computing `collateralLocked`, for call options add:
      ```
      if (params.isCall) {
          uint256 exerciseStrike = _normalizeStrikeAmount(
              params.contractSize, params.strikePrice, underlyingAsset, strikeAsset
          );
          if (exerciseStrike == 0) revert Options_InvalidAmount(exerciseStrike);
      }
      ```
    - For puts, the existing `collateralLocked == 0` check already catches zero-strike since put collateral IS the normalized strike amount
    - _Bug_Condition: isBugCondition(finding=11) where normalizedStrike == 0 for calls_
    - _Expected_Behavior: creation reverts when exercise-time strike would be zero_
    - _Preservation: Valid nonzero-amount configurations still create successfully_
    - _Requirements: 2.18_

  - [x] 9.2 Verify bug condition exploration test for zero-strike now passes
    - **Property 1: Expected Behavior** — Zero-Strike Creation Guard
    - **IMPORTANT**: Re-run the SAME zero-strike test from task 1 — do NOT write a new test
    - Run targeted regression: `forge test --match-path test/OptionsFacet.t.sol --match-test test_BugCondition_CreateOptionSeries_ShouldRejectZeroStrikeCallSeries`
    - **EXPECTED OUTCOME**: Test PASSES (confirms zero-strike lead is fixed)
    - _Requirements: 2.18_

  - [x] 9.3 Verify preservation tests still pass after zero-strike fix
    - **Property 2: Preservation** — Series Creation Preservation
    - **IMPORTANT**: Re-run the SAME preservation tests from task 2 — do NOT write new tests
    - Run:
      - `forge test --match-path test/OptionsFacet.t.sol --no-match-test BugCondition`
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions)
    - _Requirements: 3.1, 3.2_

- [x] 10. Fix Lead — WAD strike-price convention documentation

  - [x] 10.1 Add NatSpec documentation for WAD-scaled `strikePrice`
    - In `src/libraries/LibOptionsStorage.sol`, add NatSpec to `CreateOptionSeriesParams.strikePrice`:
      `/// @param strikePrice WAD-scaled (1e18) strike price. E.g., 50000e18 for $50,000.`
    - In `src/options/OptionsFacet.sol`, add NatSpec to `createOptionSeries`:
      `/// @notice strikePrice must be WAD-scaled (1e18). See CreateOptionSeriesParams.`
    - _Expected_Behavior: WAD convention is explicit in NatSpec_
    - _Requirements: 2.19_

  - [x] 10.2 Add WAD-scale convention test
    - In `test/OptionsFacet.t.sol`, add a test that creates a series with a known WAD-scaled strike price and verifies the exercise payment matches the expected WAD-based calculation
    - Run: `forge test --match-path test/OptionsFacet.t.sol --match-test test_WadStrikePriceConvention`
    - **EXPECTED OUTCOME**: Test PASSES
    - _Requirements: 2.19_


- [x] 11. Write userCount reconciliation regression tests (Options-specific)
  - **NOTE**: The core `userCount` fix lands in the shared `equalfi-usercount-reconciliation` spec. This task adds Options-specific regression tests to verify the fix works in the Options exercise/maintenance context.
  - **DEPENDENCY**: Requires `equalfi-usercount-reconciliation` spec to be implemented first
  - Test file: `test/OptionsFacet.t.sol`
  - **Long-idle joined-pool accounting test**: Create series, deposit into maker's joined strike pool, warp through a long idle period, create another series, verify the maker's joined-pool principal and `userCount` remain coherent in the Options path
  - **Exercise after long idle test**: After the long idle period, exercise options (which credits principal back), verify `userCount` remains accurate and does not double-count the maker
  - **maxUserCount not blocked test**: After maintenance churn, verify new pool entrants are not blocked by inflated `userCount`
  - Run: `forge test --match-path test/OptionsFacet.t.sol --match-test test_UserCount`
  - **EXPECTED OUTCOME**: Tests PASS (confirms shared fix works in Options context)
  - _Requirements: 2.16, 2.17_
  - Added `3` Options-specific regressions to `test/OptionsFacet.t.sol`:
    - `test_UserCount_LongIdleSeriesCreationPreservesMakerPoolCount`
    - `test_UserCount_ExerciseAfterLongIdleKeepsSingleMakerCount`
    - `test_UserCount_MaintenanceChurnDoesNotBlockNewEntrant`
  - Note: the live Options flow settles the maker's joined-pool state through Options entrypoints but does not expose the shared harness-only `settleFeeIndex(...)` hook used by `equalfi-usercount-reconciliation`, so the Options-specific coverage validates the reachable long-idle/exercise accounting invariants plus the max-user churn regression.
  - Verification:
    - `forge test --match-path test/OptionsFacet.t.sol --match-test test_UserCount` -> `3/3` passed

- [x] 12. Refresh and expand Options regression tests

  - [x] 12.1 Add full call lifecycle integration test
    - Create call series → exercise partial → exercise remaining → reclaim
    - Verify zero residual collateral, correct payment amounts, correct principal credits
    - Proves findings 5, 6, 8 fixes end-to-end through a value-moving live flow
    - Run: `forge test --match-path test/OptionsFacet.t.sol`
    - _Requirements: 2.6, 2.8, 2.12_

  - [x] 12.2 Add full put lifecycle integration test
    - Create put series → exercise partial → reclaim remainder
    - Verify stored collateral unlocked exactly on reclaim, no dust
    - Proves findings 5, 6 fixes for put-side collateral
    - Run: `forge test --match-path test/OptionsFacet.t.sol`
    - _Requirements: 2.6, 2.8_

  - [x] 12.3 Add European lifecycle integration test
    - Create European series with tolerance → warp to exercise window → exercise → warp to overlap window → attempt reclaim (revert) → warp past window → reclaim (success)
    - Proves findings 3, 4 fixes end-to-end
    - Run: `forge test --match-path test/OptionsFacet.t.sol`
    - _Requirements: 2.1, 2.3, 2.4_

  - [x] 12.4 Add tolerance bounding integration test
    - Set valid tolerance (1 hour) → verify stored → set excessive tolerance (31 days) → verify revert → verify valid tolerance still active
    - Run: `forge test --match-path test/OptionsFacet.t.sol`
    - _Requirements: 2.1, 2.2_

  - [x] 12.5 Add exercise through capped pool integration test
    - Create call series → cap maker's strike pool with low deposit cap → exercise options → verify exercise succeeds → attempt ordinary deposit → verify deposit reverts on cap
    - Proves finding 8 fix: exercise bypasses cap, ordinary deposits still capped
    - Run: `forge test --match-path test/OptionsFacet.t.sol`
    - _Requirements: 2.12, 2.13_

  - [x] 12.6 Add option-token replacement safety integration test
    - Create series → attempt `setOptionToken(newAddr)` (revert) → reclaim all series → `setOptionToken(newAddr)` (success)
    - Proves setOptionToken lead fix end-to-end
    - Run: `forge test --match-path test/OptionTokenAdminFacet.t.sol`
    - _Requirements: 2.14, 2.15_

  - [x] 12.7 Add zero-strike rejection integration test
    - Attempt creation with zero-strike parameters (revert) → create with valid parameters (success) → exercise → reclaim
    - Proves zero-strike lead fix does not interfere with valid series
    - Run: `forge test --match-path test/OptionsFacet.t.sol`
    - _Requirements: 2.18_

  - Verification runs:
    - `forge test --match-path test/OptionsFacet.t.sol`
    - `forge test --match-path test/OptionTokenAdminFacet.t.sol`
  - Added integration coverage:
    - `test_Integration_CallLifecycle_PartialThenTerminalExerciseThenReclaim`
    - `test_Integration_PutLifecycle_PartialExerciseThenResidualReclaim`
    - `test_Integration_EuropeanLifecycle_ExerciseWindowAndReclaimBoundary`
    - `test_Integration_ToleranceBounding_PreservesValidTolerance`
    - `test_Integration_ExerciseThroughCappedPool_PreservesDepositCap`
    - `test_Integration_SetOptionToken_RevertsWhileLiveAndSucceedsAfterReclaim`
    - `test_Integration_ZeroStrikeRejection_DoesNotBlockValidLifecycle`

- [x] 13. Checkpoint — Run targeted Options test suites and ensure all tests pass
  - Run: `forge test --match-path test/OptionsFacet.t.sol`
  - Run: `forge test --match-path test/OptionTokenAdminFacet.t.sol`
  - Ensure all bug condition exploration tests now PASS (confirming all bugs are fixed)
  - Ensure all preservation tests still PASS (confirming no regressions)
  - Ensure all integration regression tests PASS (confirming end-to-end correctness)
  - Ask the user if questions arise
  - Verification:
    - `forge test --match-path test/OptionsFacet.t.sol` -> `44/44` passed
    - `forge test --match-path test/OptionTokenAdminFacet.t.sol` -> `3/3` passed
