# Options Lifecycle and Pricing Remediation — Bugfix Design

## Overview

Ten remediation items in the EqualFi Options contracts require targeted fixes across European tolerance bounding, European reclaim timing, strike normalization rounding, reclaim collateral accounting, decimals safety, exercise settlement bypass, option-token governance, userCount reconciliation, creation-time parameterization guards, and WAD convention documentation. The fix strategy preserves the existing Options lifecycle model while correcting timing overlaps, rounding biases, accounting mismatches, silent fallbacks, and governance footguns.

Canonical Track: Track F. Options Lifecycle and Exerciseability
Phase: Phase 2. Product Lifecycle Fixes

Source report: `assets/findings/EdenFi-options-pashov-ai-audit-report-20260405-033500.md`
Remediation plan: `assets/remediation/Options-findings-3-8-remediation-plan.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across ten items that trigger overflow-prone tolerance, reclaim/exercise overlap, rounding bias, collateral dust, silent mispricing, blocked exercise, orphaned series, inflated userCount, dead-on-arrival series, or mis-scaled strike prices
- **Property (P)**: The desired correct behavior for each item
- **Preservation**: Existing series creation, exercise flow, American lifecycle, European exercise window, reclaim for fully-exercised series, burn reclaimed claims, admin functions, and view functions that must remain unchanged
- **`europeanToleranceSeconds`**: Protocol-wide tolerance window for European option exercise, stored in `LibOptionsStorage.OptionsStorage`
- **`MAX_EUROPEAN_TOLERANCE`**: New constant bounding tolerance at 30 days (2,592,000 seconds)
- **`_normalizeStrikeAmount`**: Internal function converting underlying amounts to strike-denominated amounts using two sequential `Math.mulDiv` calls with floor rounding
- **`_previewStrikeAmount`**: View function in `OptionsViewFacet` mirroring `_normalizeStrikeAmount` for previews
- **`collateralLocked`**: Per-series field tracking the residual locked collateral after partial exercises
- **`LibCurrency.decimals`**: Silent-fallback decimals lookup that returns 18 on revert
- **`LibCurrency.decimalsOrRevert`**: Fail-closed decimals lookup that reverts on query failure
- **`_increasePrincipal`**: Internal function crediting principal to a pool position, currently enforcing `depositCap` and `maxUserCount`
- **`activeSeriesCount`**: New storage field tracking the number of live (non-terminal) option series
- **WAD**: 1e18 scale convention used for `strikePrice` throughout the Options system

## Bug Details

### Bug Condition

The bugs manifest across ten distinct conditions in the Options contracts. Together they represent unbounded configuration, timing overlap, rounding bias, accounting mismatch, silent fallback, blocked settlement, governance footgun, count inflation, parameterization failure, and undocumented convention.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 3: setEuropeanTolerance accepts any uint64
  IF input.finding == 3 THEN
    RETURN input.context.isSetEuropeanTolerance
           AND input.context.toleranceValue > MAX_EUROPEAN_TOLERANCE

  // Finding 4: European reclaim during exercise window
  IF input.finding == 4 THEN
    RETURN input.context.isReclaimOptions
           AND NOT input.context.series.isAmerican
           AND input.context.blockTimestamp > input.context.series.expiry
           AND input.context.blockTimestamp <= input.context.series.expiry + tolerance

  // Finding 5: Strike normalization uses floor rounding
  IF input.finding == 5 THEN
    RETURN (input.context.isExercise OR input.context.isCreateSeries OR input.context.isReclaim)
           AND input.context.strikeNormalizationUsesFloor

  // Finding 6: Reclaim recomputes collateral instead of using stored residual
  IF input.finding == 6 THEN
    RETURN input.context.isReclaimOptions
           AND input.context.series.remainingSize > 0
           AND input.context.recomputedCollateral != input.context.series.collateralLocked

  // Finding 7: Options math uses silent-fallback decimals
  IF input.finding == 7 THEN
    RETURN (input.context.isExercise OR input.context.isCreateSeries OR input.context.isReclaim)
           AND input.context.tokenDecimalsQueryReverts

  // Finding 8: Exercise blocked by deposit cap
  IF input.finding == 8 THEN
    RETURN input.context.isExercise
           AND (input.context.makerPoolAtDepositCap OR input.context.makerPoolAtMaxUserCount)

  // Lead: setOptionToken while live series exist
  IF input.finding == 9 THEN
    RETURN input.context.isSetOptionToken
           AND input.context.activeSeriesCount > 0

  // Lead: userCount inflation via maintenance
  IF input.finding == 10 THEN
    RETURN input.context.isMaintenanceSettle
           AND input.context.principalZeroedByMaintenance
           AND input.context.userCountNotDecremented

  // Lead: Normalized strike truncates to zero at creation
  IF input.finding == 11 THEN
    RETURN input.context.isCreateSeries
           AND input.context.normalizedStrikeAmount == 0

  // Lead: strikePrice not WAD-scaled
  IF input.finding == 12 THEN
    RETURN input.context.isCreateSeries
           AND input.context.strikePriceNotWadScaled

  RETURN false
END FUNCTION
```

### Examples

- **Finding 3**: Admin calls `setEuropeanTolerance(type(uint64).max)`. Later, `_validateExerciseWindow` computes `series.expiry + tolerance` which overflows, reverting all European exercises globally. Expected: revert at setter with `ExcessiveTolerance`.
- **Finding 4**: European series with `expiry = T`, `tolerance = 1 hour`. At `T + 30 min`, both exercise and reclaim are valid. Maker front-runs holder's exercise with `reclaimOptions`, setting `remainingSize = 0`. Holder's exercise reverts. Expected: reclaim reverts until `T + 1 hour`.
- **Finding 5**: WBTC(8)/USDC(6) call, `strikePrice = 50000.5e18`, `contractSize = 1e8`. Two-step floor: `mulDiv(mulDiv(1e8, 50000.5e18, 1e8), 1e6, 1e18) = mulDiv(50000.5e18, 1e6, 1e18) = 50000500000` (floor). Single-step ceil: `mulDiv(1e8 * 50000.5e18, 1e6, 1e8 * 1e18, Ceil) = 50000500001`. Exerciser underpays by 1 micro-USDC per contract.
- **Finding 6**: 10-unit put option, each exercise truncates ~0.3 micro-USDC collateral decrement. After 10 exercises, `series.collateralLocked = 3 micro-USDC` residual. Reclaim recomputes from `remainingSize = 0`, unlocks 0. 3 micro-USDC permanently stuck.
- **Finding 7**: Token reverts on `decimals()`. `LibCurrency.decimals` returns 18. Actual decimals = 6. Collateral calculation off by 10^12.
- **Finding 8**: Maker's pool has `depositCap = 1000e18`, current principal = 999e18. Exercise tries to credit 100e18. `_increasePrincipal` reverts on cap check. Options permanently unexercisable.
- **Lead (setOptionToken)**: Admin calls `setOptionToken(newAddr)` while series 42 has 100 tokens on old contract. Exercise calls `_optionToken()` → new contract → `balanceOf(holder, 42) = 0` → revert.
- **Lead (zero strike)**: `strikePrice = 1` (1 wei in WAD), `contractSize = 1`, underlying 18 decimals, strike 6 decimals. `mulDiv(1, 1, 1e18) = 0`. Series created with zero strike obligation.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Series creation with valid parameters must continue to validate inputs, settle positions, compute and lock collateral, write series state, mint ERC-1155 tokens, and emit events correctly
- Call and put exercise flows must continue to collect payment, credit maker principal, unlock and transfer collateral correctly
- American option exercise before expiry and reclaim after expiry must remain unchanged
- European option exercise within the tolerance-bounded window must remain unchanged
- Reclaim for fully-exercised series (`remainingSize == 0`) must continue to mark as reclaimed without unlocking collateral
- Burn reclaimed claims must continue to work for reclaimed series
- `setOptionsPaused`, `deployOptionToken`, and view functions must remain unchanged
- Non-owner reclaim must continue to revert with ownership error

**Scope:**
All inputs that do NOT match any of the ten bug conditions should be completely unaffected by these fixes.

## Hypothesized Root Cause

1. **Finding 3 — Unbounded tolerance**: `setEuropeanTolerance` accepts any `uint64` with no upper-bound validation. The function was likely intended to be admin-only with implicit trust, but the arithmetic consequences of extreme values were not considered.

2. **Finding 4 — Overlapping windows**: `reclaimOptions` checks `block.timestamp > series.expiry` for all option types. For European options with nonzero tolerance, the exercise window extends to `expiry + tolerance`, but reclaim does not account for this extension. The reclaim guard was written before the tolerance feature was added.

3. **Finding 5 — Double floor truncation**: `_normalizeStrikeAmount` performs two sequential `Math.mulDiv` calls, each defaulting to floor rounding. The intermediate result loses precision, and the final result compounds the loss. The function was written for simplicity without considering the rounding-direction implications for protocol economics.

4. **Finding 6 — Recomputed vs stored collateral**: `reclaimOptions` recomputes collateral from `remainingSize * contractSize` through `_normalizeStrikeAmount` instead of using the stored `series.collateralLocked`. After partial exercises that each truncate the collateral decrement, the stored residual diverges from what a fresh recomputation would produce.

5. **Finding 7 — Silent decimals fallback**: `_normalizeStrikeAmount` and `_previewStrikeAmount` call `LibCurrency.decimals()` which silently returns 18 on revert. The contract already has `decimalsOrRevert()` but the Options code was written before the fail-closed variant was available or was not updated to use it.

6. **Finding 8 — Exercise as deposit**: `_increasePrincipal` treats all principal credits uniformly, enforcing `depositCap` and `maxUserCount`. Exercise settlement is economically an obligation fulfillment, not a voluntary deposit, but the code does not distinguish between the two.

7. **Lead (setOptionToken)**: `_setOptionToken` unconditionally replaces the stored address. There is no check for live series that depend on the current token contract. The function was written for initial setup, not for runtime replacement.

8. **Lead (userCount)**: `LibFeeIndex.settle` can reduce `userPrincipal` to zero through maintenance fees without decrementing `userCount`. This is a shared substrate issue — the core fix lands in `equalfi-usercount-reconciliation`. This spec adds Options-specific regression tests.

9. **Lead (zero strike)**: `createOptionSeries` validates `strikePrice != 0` and `collateralLocked != 0` but does not check the normalized strike amount for the exercise path. For puts, `collateralLocked` is the normalized strike amount (which is checked), but for calls, `collateralLocked` is the underlying notional, and the strike amount used at exercise time can independently truncate to zero.

10. **Lead (WAD convention)**: `strikePrice` is implicitly WAD-scaled throughout the codebase but this is not documented in NatSpec or enforced at the interface level.

## Correctness Properties

Property 1: Bug Condition — European tolerance bounded (Finding 3)

_For any_ call to `setEuropeanTolerance` with a value exceeding `MAX_EUROPEAN_TOLERANCE` (30 days), the fixed function SHALL revert. Values within the bound SHALL be stored successfully.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — European reclaim waits for exercise window (Finding 4)

_For any_ European option series where `block.timestamp <= expiry + tolerance`, the fixed `reclaimOptions` SHALL revert. Reclaim SHALL succeed only after the full tolerance-adjusted window has closed. American reclaim behavior SHALL remain unchanged.

**Validates: Requirements 2.3, 2.4, 2.5**

Property 3: Bug Condition — Protocol-safe strike normalization (Finding 5)

_For any_ strike normalization computation, the fixed `_normalizeStrikeAmount` SHALL use a single `Math.mulDiv` with `Math.Rounding.Ceil`, eliminating double truncation and rounding in the protocol-safe direction. Preview paths SHALL use the same logic.

**Validates: Requirements 2.6, 2.7**

Property 4: Bug Condition — Reclaim uses stored residual collateral (Finding 6)

_For any_ reclaim where `remainingSize > 0`, the fixed `reclaimOptions` SHALL unlock exactly `series.collateralLocked` instead of recomputing from `remainingSize`, leaving no encumbrance dust.

**Validates: Requirements 2.8, 2.9**

Property 5: Bug Condition — Fail-closed decimals in Options math (Finding 7)

_For any_ Options execution or preview path that queries token decimals, the fixed code SHALL use `LibCurrency.decimalsOrRevert`, reverting cleanly for tokens with unusable metadata.

**Validates: Requirements 2.10, 2.11**

Property 6: Bug Condition — Exercise bypasses deposit cap (Finding 8)

_For any_ option exercise where the maker's pool is at or near deposit cap or max user count, the fixed `_increasePrincipal` (or a dedicated exercise-settlement path) SHALL bypass those checks, allowing exercise to complete. Ordinary deposits SHALL continue to be capped.

**Validates: Requirements 2.12, 2.13**

Property 7: Bug Condition — Option-token replacement blocked while live series exist (Lead)

_For any_ call to `setOptionToken` while `activeSeriesCount > 0`, the fixed function SHALL revert. Token replacement SHALL succeed only when the system is quiescent.

**Validates: Requirements 2.14, 2.15**

Property 8: Bug Condition — userCount reconciliation regression (Lead)

_For any_ maintenance settlement that zeros a user's principal, the shared fix SHALL decrement `userCount`. Subsequent exercise-driven principal credit SHALL not double-count. This spec adds Options-specific regression tests; the core fix is in `equalfi-usercount-reconciliation`.

**Validates: Requirements 2.16, 2.17**

Property 9: Bug Condition — Creation-time zero-strike guard (Lead)

_For any_ `createOptionSeries` where the normalized strike amount for the configured parameters would be zero, the fixed function SHALL revert at creation time.

**Validates: Requirements 2.18**

Property 10: Bug Condition — WAD strike-price convention (Lead)

_For any_ series creation, NatSpec and test coverage SHALL explicitly document and reinforce the WAD-scaled `strikePrice` convention.

**Validates: Requirements 2.19**

Property 11: Preservation — Series creation and exercise

_For any_ series creation or exercise that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code, preserving input validation, collateral locking, payment collection, principal credit, collateral transfer, and event emission.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**

Property 12: Preservation — American and European lifecycle

_For any_ American exercise/reclaim or European exercise within the tolerance window that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.6, 3.7, 3.8**

Property 13: Preservation — Reclaim, burn, admin, and view functions

_For any_ reclaim of fully-exercised series, burn of reclaimed claims, admin pause/deploy, or view queries that do NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.9, 3.10, 3.11, 3.12, 3.13, 3.14, 3.15**


## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

---

**File**: `src/options/OptionsFacet.sol`

**Function**: `setEuropeanTolerance`

**Specific Changes**:
1. **Bound tolerance (Finding 3)**: Add a constant `uint64 constant MAX_EUROPEAN_TOLERANCE = 30 days;`. In `setEuropeanTolerance`, add: `if (toleranceSeconds > MAX_EUROPEAN_TOLERANCE) revert Options_ExcessiveTolerance(toleranceSeconds);`. Declare the error.

**Function**: `reclaimOptions`

**Specific Changes**:
2. **European reclaim timing (Finding 4)**: After the existing `block.timestamp <= series.expiry` check, add a European-specific guard:
   ```
   if (!series.isAmerican) {
       uint64 tolerance = LibOptionsStorage.s().europeanToleranceSeconds;
       if (block.timestamp <= uint256(series.expiry) + uint256(tolerance)) {
           revert Options_ExerciseWindowStillOpen(seriesId);
       }
   }
   ```
   Declare the error. Keep the existing American reclaim check unchanged.

3. **Reclaim stored collateral (Finding 6)**: Replace the collateral recomputation block with direct use of stored residual:
   ```
   // Replace:
   // uint256 underlyingAmount = remainingSize * series.contractSize;
   // collateralUnlocked = series.isCall ? underlyingAmount : _normalizeStrikeAmount(...);
   // With:
   collateralUnlocked = series.collateralLocked;
   ```
   Remove the `if (collateralUnlocked == 0)` check since `collateralLocked` is the authoritative residual. Zero the stored field after unlock: `series.collateralLocked = 0;`

4. **Decrement activeSeriesCount on reclaim**: After marking `series.reclaimed = true`, decrement `store.activeSeriesCount`.

**Function**: `_normalizeStrikeAmount`

**Specific Changes**:
5. **Protocol-safe rounding (Finding 5)**: Replace the current floor-rounding logic with an overflow-safe staged ceiling formulation:
   ```
   function _normalizeStrikeAmount(uint256 underlyingAmount, uint256 strikePrice, address underlying, address strike)
       internal view returns (uint256 strikeAmount)
   {
       uint256 underlyingScale = 10 ** uint256(LibCurrency.decimalsOrRevert(underlying));
       uint256 strikeScale = 10 ** uint256(LibCurrency.decimalsOrRevert(strike));
       uint256 wadValue = Math.mulDiv(underlyingAmount, strikePrice, underlyingScale, Math.Rounding.Ceil);
       strikeAmount = Math.mulDiv(wadValue, strikeScale, 1e18, Math.Rounding.Ceil);
   }
   ```
   This preserves the intended protocol-safe rounding direction while avoiding a raw `underlyingAmount * strikePrice` intermediate multiplication. It also addresses Finding 7 (`decimalsOrRevert`) in the same function.

**Function**: `createOptionSeries`

**Specific Changes**:
6. **Creation-time zero-strike guard (Lead)**: After computing `collateralLocked`, add a check for call options where the strike amount at exercise could be zero:
   ```
   if (params.isCall) {
       uint256 exerciseStrike = _normalizeStrikeAmount(
           params.contractSize, params.strikePrice, underlyingAsset, strikeAsset
       );
       if (exerciseStrike == 0) revert Options_InvalidAmount(exerciseStrike);
   }
   ```
   For puts, the existing `collateralLocked == 0` check already catches this since put collateral IS the normalized strike amount.

7. **Increment activeSeriesCount**: After writing the series, increment `store.activeSeriesCount`.

8. **WAD convention NatSpec (Lead)**: Add NatSpec to `CreateOptionSeriesParams.strikePrice`: `/// @param strikePrice WAD-scaled (1e18) strike price. E.g., 50000e18 for $50,000.`

**Function**: `_increasePrincipal`

**Specific Changes**:
9. **Exercise settlement bypass (Finding 8)**: Add a `bool isExerciseSettlement` parameter. When `true`, skip `depositCap` and `maxUserCount` checks:
   ```
   function _increasePrincipal(
       Types.PoolData storage pool, uint256 poolId, bytes32 positionKey, uint256 amount, bool isExerciseSettlement
   ) internal {
       uint256 currentPrincipal = pool.userPrincipal[positionKey];
       if (currentPrincipal == 0) {
           if (!isExerciseSettlement) {
               uint256 maxUsers = pool.poolConfig.maxUserCount;
               if (maxUsers != 0 && pool.userCount >= maxUsers) {
                   revert InvalidParameterRange("maxUserCount");
               }
           }
           pool.userCount += 1;
       }

       uint256 newPrincipal = currentPrincipal + amount;
       if (!isExerciseSettlement && pool.poolConfig.isCapped && pool.poolConfig.depositCap != 0 && newPrincipal > pool.poolConfig.depositCap) {
           revert InvalidParameterRange("depositCap");
       }

       pool.userPrincipal[positionKey] = newPrincipal;
       pool.totalDeposits += amount;
       pool.userFeeIndex[positionKey] = pool.feeIndex;
       pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
       LibActiveCreditIndex.settle(poolId, positionKey);
   }
   ```
   Update call sites in `_exerciseCall` and `_exercisePut` to pass `true`. If `_increasePrincipal` is used elsewhere in the Options facet (it is not), those call sites pass `false`.

---

**File**: `src/options/OptionsViewFacet.sol`

**Function**: `_previewStrikeAmount`

**Specific Changes**:
10. **Consistent preview rounding (Finding 5, 7)**: Replace the current preview logic with the same overflow-safe staged ceiling formulation used in `_normalizeStrikeAmount`:
    ```
    function _previewStrikeAmount(uint256 underlyingAmount, uint256 strikePrice, address underlying, address strike)
        internal view returns (uint256 strikeAmount)
    {
        uint256 underlyingScale = 10 ** uint256(LibCurrency.decimalsOrRevert(underlying));
        uint256 strikeScale = 10 ** uint256(LibCurrency.decimalsOrRevert(strike));
        uint256 wadValue = Math.mulDiv(underlyingAmount, strikePrice, underlyingScale, Math.Rounding.Ceil);
        strikeAmount = Math.mulDiv(wadValue, strikeScale, 1e18, Math.Rounding.Ceil);
    }
    ```

---

**File**: `src/options/OptionTokenAdminFacet.sol`

**Function**: `_setOptionToken`

**Specific Changes**:
11. **Block replacement while live series exist (Lead)**: Before replacing the token address, check:
    ```
    LibOptionsStorage.OptionsStorage storage store = LibOptionsStorage.s();
    if (store.activeSeriesCount > 0) {
        revert OptionTokenAdmin_ActiveSeriesExist(store.activeSeriesCount);
    }
    ```
    Declare the error.

---

**File**: `src/libraries/LibOptionsStorage.sol`

**Specific Changes**:
12. **Add `activeSeriesCount` field**: Add `uint256 activeSeriesCount;` to the `OptionsStorage` struct. This tracks live (non-terminal) series for the `setOptionToken` guard.

---

**New Error Declarations** (in `src/options/OptionsFacet.sol` or `src/libraries/Errors.sol`):
- `Options_ExcessiveTolerance(uint64 tolerance)` — for the tolerance bound
- `Options_ExerciseWindowStillOpen(uint256 seriesId)` — for European reclaim during exercise window
- `OptionTokenAdmin_ActiveSeriesExist(uint256 count)` — for token replacement while live series exist

## Testing Strategy

### Validation Approach

The testing strategy follows the bug-condition methodology: first surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real deposits, real series creation, real exercises, real reclaims per workspace guidelines.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures.

**Test Cases**:
1. **Tolerance overflow test**: Call `setEuropeanTolerance(type(uint64).max)` and assert revert at setter time. On unfixed code this will FAIL because the setter accepts the oversized tolerance.
2. **European reclaim overlap test**: Create European series with tolerance, warp to `expiry + tolerance/2`, attempt reclaim, assert revert. On unfixed code this will FAIL because reclaim succeeds during the overlap window.
3. **Strike rounding test**: Create call series with parameters producing fractional strike, exercise, assert strike payment uses ceiling rounding. On unfixed code this will FAIL because floor rounding underpays.
4. **Reclaim collateral dust test**: Create put series, exercise partially multiple times, reclaim remainder, assert `series.collateralLocked == 0` and no encumbrance dust. On unfixed code this will FAIL because recomputed collateral differs from stored residual.
5. **Decimals fallback test**: This requires a mock token that reverts on `decimals()`. Create series with such a token, assert creation reverts cleanly. On unfixed code this will FAIL because silent fallback to 18 allows creation with wrong math.
6. **Deposit cap blocks exercise test**: Create series, set maker's pool to capped with low cap, exercise, assert success. On unfixed code this will FAIL because `_increasePrincipal` reverts on cap.
7. **setOptionToken orphans test**: Create series, call `setOptionToken(newAddr)`, assert revert. On unfixed code this will FAIL because replacement succeeds unconditionally.
8. **Zero-strike creation test**: Create series with parameters that produce zero normalized strike, assert creation reverts. On unfixed code this will FAIL because creation succeeds with dead-on-arrival economics.

### Fix Checking

**Goal**: Verify that for all inputs where each bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Finding 3
FOR ALL setTolerance WHERE tolerance > MAX_EUROPEAN_TOLERANCE DO
  ASSERT REVERTS setEuropeanTolerance_fixed(tolerance)
END FOR

// Finding 4
FOR ALL europeanReclaim WHERE blockTimestamp <= expiry + tolerance DO
  ASSERT REVERTS reclaimOptions_fixed(seriesId)
END FOR

// Finding 5
FOR ALL exercise WHERE strikeNormalization produces fractional result DO
  result := _normalizeStrikeAmount_fixed(params)
  ASSERT result >= ceil(underlyingAmount * strikePrice * strikeScale / (underlyingScale * WAD))
END FOR

// Finding 6
FOR ALL reclaim WHERE remainingSize > 0 DO
  result := reclaimOptions_fixed(seriesId)
  ASSERT collateralUnlocked == series.collateralLocked (stored value)
  ASSERT series.collateralLocked == 0 after reclaim
END FOR

// Finding 7
FOR ALL optionsMath WHERE token.decimals() reverts DO
  ASSERT REVERTS _normalizeStrikeAmount_fixed(params)
END FOR

// Finding 8
FOR ALL exercise WHERE makerPool.isCapped AND newPrincipal > depositCap DO
  result := exerciseOptions_fixed(params)
  ASSERT no revert (exercise succeeds despite cap)
END FOR

// Lead: setOptionToken
FOR ALL setOptionToken WHERE activeSeriesCount > 0 DO
  ASSERT REVERTS setOptionToken_fixed(newAddr)
END FOR

// Lead: zero strike
FOR ALL createSeries WHERE normalizedStrike == 0 DO
  ASSERT REVERTS createOptionSeries_fixed(params)
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug conditions do NOT hold, the fixed functions produce the same result as the original functions.

**Test Cases**:
1. **Series creation preservation**: Create call and put series with valid parameters, verify collateral locking, state writing, token minting, events unchanged
2. **Call exercise preservation**: Exercise call options within window, verify payment collection, principal credit, collateral transfer unchanged
3. **Put exercise preservation**: Exercise put options within window, verify payment collection, principal credit, collateral transfer unchanged
4. **American lifecycle preservation**: Exercise American option before expiry, reclaim after expiry, verify both work unchanged
5. **European exercise preservation**: Exercise European option within tolerance window, verify exercise works unchanged
6. **Fully-exercised reclaim preservation**: Exercise all options in a series, reclaim, verify no collateral unlock and series marked reclaimed
7. **Burn reclaimed claims preservation**: Reclaim series, burn claims, verify token burn works unchanged
8. **Admin function preservation**: Toggle pause, deploy token (when no live series), verify unchanged
9. **View function preservation**: Call `previewExercisePayment`, `getOptionSeries`, productive-collateral views, verify correct results

### Integration Tests

- Full call lifecycle: create → exercise partial → exercise remaining → reclaim (verify zero residual)
- Full put lifecycle: create → exercise partial → reclaim remainder (verify stored collateral unlocked exactly)
- European lifecycle: create → warp to exercise window → exercise → warp past window → reclaim
- European reclaim timing: create → warp to overlap window → attempt reclaim (revert) → warp past window → reclaim (success)
- Tolerance bounding: set valid tolerance → set excessive tolerance (revert) → verify valid tolerance still active
- Exercise through capped pool: create series → cap maker's pool → exercise (success) → verify ordinary deposit still capped
- Option-token replacement safety: create series → attempt replacement (revert) → reclaim all series → replacement (success)
- Zero-strike rejection: attempt creation with zero-strike parameters (revert) → create with valid parameters (success)
