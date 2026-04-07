# EqualFi ACI / Encumbrance / Debt Tracker Consistency — Bugfix Design

## Overview

Three root-cause defects in the shared EqualFi accounting libraries require targeted fixes in `LibActiveCreditIndex.sol` and `LibEqualLendDirectAccounting.sol`. Finding 1: `_removeFromBase` and `_scheduleState` disagree on bucket placement when `offset >= BUCKET_COUNT`, causing permanent `activeCreditMaturedTotal` inflation and phantom ACI yield. Finding 2: `_increaseEncumbrance` and `_decreaseEncumbrance` overwrite `indexSnapshot` without settling pending yield, permanently destroying accrued ACI yield on every encumbrance change. Finding 3: `_decreaseBorrowedPrincipal` and `_decreaseSameAssetDebt` silently clamp five independent debt trackers to zero instead of reverting, causing permanent desynchronization.

The fix strategy preserves the current EqualFi ACI model: keep bucket placement symmetric between schedule and remove, settle pending yield before any snapshot overwrite, and revert on debt tracker over-subtraction to surface accounting drift immediately.

Canonical Track: Track B. ACI / Encumbrance / Debt Tracker Consistency
Phase: Phase 1. Shared Accounting Substrate

Source reports:
- `assets/findings/EdenFi-libraries-phase1-pashov-ai-audit-report-20260406-150000.md` (findings 3 [90], 4 [88])
- `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md` (finding 2 [93])
Remediation plan: `assets/remediation/EqualFi-unified-remediation-plan.md` (Track B)
Coding standards: `ETHSKILLS.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across three findings that trigger incorrect ACI bucket accounting, lost encumbrance yield, or permanent debt tracker desynchronization
- **Property (P)**: The desired correct behavior — symmetric bucket placement, settled yield before snapshot overwrite, and reverting debt trackers
- **Preservation**: Existing ACI maturity mechanics, encumbrance lifecycle, debt origination/settlement, and downstream product flows that must remain unchanged
- **`activeCreditMaturedTotal`**: Per-pool field tracking aggregate matured ACI principal eligible for yield distribution
- **`activeCreditPendingBuckets`**: Per-pool array of `BUCKET_COUNT` hourly buckets holding pending (not yet matured) ACI principal
- **`activeCreditPendingStartHour`**: Per-pool field tracking the start hour of the pending bucket window
- **`activeCreditPendingCursor`**: Per-pool field tracking the current write cursor into the pending bucket array
- **`activeCreditIndex`**: Per-pool global index tracking cumulative ACI yield per unit of matured principal
- **`indexSnapshot`**: Per-user per-pool field on `ActiveCreditState` tracking the last settled `activeCreditIndex` value
- **`activeCreditPrincipalTotal`**: Per-pool field tracking aggregate principal across all encumbrance and debt ACI states
- **`enc.encumberedCapital`**: Per-position per-pool field tracking capital committed to AMM reserves
- **`userSameAssetDebt`**: Per-user per-pool field tracking aggregate same-asset debt for a borrower
- **`sameAssetDebt`**: Per-positionId per-pool field tracking same-asset debt for a specific token position
- **`sameAssetDebtByAsset`**: Per-user per-asset field tracking same-asset debt by collateral asset
- **`borrowedPrincipalByPool`**: Per-user per-pool field tracking borrowed principal for a specific lender pool
- **`BUCKET_COUNT`**: Constant (168) — number of hourly pending buckets in the ACI ring buffer
- **`TIME_GATE`**: Constant (24 hours) — maturity threshold for ACI states
- **`INDEX_SCALE`**: Constant (1e18) — precision scale for ACI index arithmetic
- **`_scheduleState`**: Private function that places ACI principal into the correct pending bucket based on maturity offset
- **`_removeFromBase`**: Private function that removes ACI principal from the correct bucket or matured total
- **`_rollMatured`**: Private function that advances the bucket window and moves matured pending principal to `activeCreditMaturedTotal`

## Bug Details

### Bug Condition

The bugs manifest across three distinct conditions in the shared accounting libraries. Together they represent asymmetric ACI bucket accounting, lost encumbrance yield, and silent debt tracker desynchronization.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 1: _removeFromBase subtracts from activeCreditMaturedTotal
  //            when _scheduleState placed principal in a pending bucket (offset >= BUCKET_COUNT)
  IF input.finding == 1 THEN
    RETURN input.context.isRemoveFromBase
           AND input.context.maturityOffset >= BUCKET_COUNT

  // Finding 2: _increaseEncumbrance or _decreaseEncumbrance overwrites indexSnapshot
  //            without settling pending yield (currentIndex > oldSnapshot AND principal > 0)
  IF input.finding == 2 THEN
    RETURN input.context.isEncumbranceChange
           AND input.context.encPrincipal > 0
           AND input.context.currentActiveCreditIndex > input.context.encIndexSnapshot

  // Finding 3: _decreaseBorrowedPrincipal or _decreaseSameAssetDebt called with
  //            amount exceeding any tracked value
  IF input.finding == 3 THEN
    RETURN input.context.isDebtDecrease
           AND input.context.decreaseAmount > input.context.anyTrackerCurrentValue

  RETURN false
END FUNCTION
```

### Examples

- **Finding 1 — Bucket asymmetry**: State has `startTime` such that `maturityHour - startHour - 1 >= BUCKET_COUNT`. `_scheduleState` places 100e18 principal in `pendingBuckets[last]`. Later, `_removeFromBase` is called for the same state. Instead of removing from `pendingBuckets[last]`, it subtracts 100e18 from `activeCreditMaturedTotal`. When `_rollMatured` later processes `pendingBuckets[last]`, it adds 100e18 to `activeCreditMaturedTotal` again — net inflation of 100e18 phantom matured principal.

- **Finding 2 — Lost encumbrance yield**: Encumbrance state has `principal = 500e18`, `indexSnapshot = 1.0e18`. Pool `activeCreditIndex` has grown to `1.02e18`. Pending yield = `500e18 * 0.02e18 / 1e18 = 10e18`. A Solo AMM swap calls `_increaseEncumbrance` with `delta = 50e18`. The function overwrites `indexSnapshot = 1.02e18` without settling the 10e18 pending yield. That yield is permanently lost.

- **Finding 3 — Debt tracker desync**: Borrower has two agreements on the same pool. Agreement A: `borrowedPrincipal = 100e18`. Agreement B: `borrowedPrincipal = 100e18`. Pool-level `borrowedPrincipalByPool = 200e18`. Agreement A settles with `principalDelta = 120e18` (over-clears by 20e18). `borrowedPrincipalByPool` clamps to `max(0, 200 - 120) = 80e18`. Agreement B settles with `principalDelta = 100e18`. `borrowedPrincipalByPool` clamps to `max(0, 80 - 100) = 0`. But the true remaining should be `200 - 120 - 100 = -20e18` — the over-subtraction was silently absorbed, and `activeCreditPrincipalTotal` is now inflated by the phantom 20e18.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- `_scheduleState` placement for `offset < BUCKET_COUNT` must continue to use `(cursor + offset) % BUCKET_COUNT`
- `_rollMatured` must continue to advance buckets and move pending principal to `activeCreditMaturedTotal` correctly
- `_removeFromBase` for mature states (`_isMature` returns true) must continue to subtract from `activeCreditMaturedTotal`
- `accrueWithSource` must continue to distribute ACI yield using `activeCreditMaturedTotal` as the base
- `applyEncumbranceIncrease` with `amount == 0` must continue to return early
- `applyEncumbranceDecrease` that fully zeroes principal must continue to call `resetIfZeroWithGate`
- `applyWeightedIncreaseWithGate` must continue to apply weighted dilution and emit timing events
- `applyPrincipalDecrease` must continue to remove from base and decrease principal
- `_increaseBorrowedPrincipal` must continue to increment `borrowedPrincipalByPool`
- `_increaseSameAssetDebt` must continue to increment all five debt trackers correctly
- `_decreaseBorrowedPrincipal` with `amount <= current` must continue to decrement without reverting
- `_decreaseSameAssetDebt` with `principalComponent` within bounds must continue to decrement all trackers correctly
- `settlePrincipal` for single-agreement borrower/pool pairs must continue to settle correctly
- EqualX Solo AMM encumbrance changes must continue to update `activeCreditPrincipalTotal`
- EqualLend Direct loan origination and settlement must continue to track debt correctly
- EqualScale chargeOffLine must continue to reduce debt trackers correctly

**Scope:**
All inputs that do NOT match any of the three bug conditions should be completely unaffected. This includes:
- ACI states with `offset < BUCKET_COUNT` (normal bucket placement)
- Encumbrance changes where `indexSnapshot == activeCreditIndex` (no pending yield)
- Debt decreases where `amount <= current` for all trackers (no over-subtraction)
- All ACI accrual, settlement, and view functions
- All debt origination paths

## Hypothesized Root Cause

Based on the audit findings and code analysis:

1. **Finding 1 — Asymmetric overflow bucket handling**: `_scheduleState` handles `offset >= BUCKET_COUNT` by placing principal in the last pending bucket (`pendingBuckets[last]`). But `_removeFromBase` handles the same condition by subtracting from `activeCreditMaturedTotal`. The two functions were written with different assumptions about where overflow principal lives. The silent clamp-to-zero in `_removeFromBase` absorbs the resulting accounting error rather than surfacing it. The fix is to make `_removeFromBase` use the same last-bucket logic as `_scheduleState` when `offset >= BUCKET_COUNT`.

2. **Finding 2 — Missing yield settlement in encumbrance functions**: `_increaseEncumbrance` and `_decreaseEncumbrance` both overwrite `enc.indexSnapshot = p.activeCreditIndex` as the final step. This is correct for snapshotting the new baseline, but it skips the settlement step that `_settleState` performs: computing `principal * (currentIndex - oldSnapshot) / INDEX_SCALE` and crediting it to `userAccruedYield`. The encumbrance functions were likely written as pure bookkeeping without awareness of the yield settlement dependency. The fix is to call `_settleState` (or inline the equivalent settlement logic) before overwriting the snapshot.

3. **Finding 3 — Silent clamp-to-zero instead of revert**: `_decreaseBorrowedPrincipal` uses `amount >= current ? 0 : current - amount` and `_decreaseSameAssetDebt` uses the same pattern for four independent trackers. This was likely a defensive coding choice to avoid reverts on edge cases, but it masks real accounting drift. When multiple agreements share the same borrower/pool pair, the first settlement can over-clear a tracker, and subsequent settlements silently skip the decrement. The fix is to revert on over-subtraction so the accounting error is surfaced immediately.

## Correctness Properties

Property 1: Bug Condition — ACI Bucket Placement Symmetry

_For any_ call to `_removeFromBase` where the state's maturity offset satisfies `offset >= BUCKET_COUNT`, the fixed function SHALL remove principal from the same pending bucket (`pendingBuckets[last]`) that `_scheduleState` placed it in, not from `activeCreditMaturedTotal`. After a schedule-then-remove cycle for the same state, `activeCreditMaturedTotal` SHALL remain unchanged and the target pending bucket SHALL be decremented by the removed amount.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — Encumbrance Yield Settlement Before Snapshot Overwrite

_For any_ call to `_increaseEncumbrance` or `_decreaseEncumbrance` where the encumbrance state has `principal > 0` and `activeCreditIndex > indexSnapshot`, the fixed function SHALL first settle pending ACI yield (computing `principal * (currentIndex - oldSnapshot) / INDEX_SCALE` and crediting it to `userAccruedYield[user]`) before overwriting `indexSnapshot`. No pending yield SHALL be lost.

**Validates: Requirements 2.3, 2.4**

Property 3: Bug Condition — Debt Tracker Revert on Over-Subtraction

_For any_ call to `_decreaseBorrowedPrincipal` where `amount > current`, the fixed function SHALL revert. _For any_ call to `_decreaseSameAssetDebt` where `principalComponent` exceeds any of the four independent tracker values, the fixed function SHALL revert. No silent clamp-to-zero SHALL occur, whether the revert comes from explicit checks or Solidity checked arithmetic.

**Validates: Requirements 2.5, 2.6**

Property 4: Preservation — ACI Bucket Mechanics for Normal Offsets

_For any_ call to `_scheduleState` or `_removeFromBase` where `offset < BUCKET_COUNT`, the fixed code SHALL produce exactly the same bucket placement and removal behavior as the original code. `_rollMatured`, `accrueWithSource`, and all ACI settlement/view functions SHALL remain unchanged.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4**

Property 5: Preservation — Encumbrance Lifecycle

_For any_ encumbrance change where `indexSnapshot == activeCreditIndex` (no pending yield to settle), or where `amount == 0`, or where the decrease fully zeroes principal, the fixed code SHALL produce exactly the same behavior as the original code. `applyWeightedIncreaseWithGate`, `applyPrincipalDecrease`, and `resetIfZeroWithGate` SHALL remain unchanged.

**Validates: Requirements 3.5, 3.6, 3.7, 3.8**

Property 6: Preservation — Debt Tracker Origination and In-Bounds Settlement

_For any_ call to `_increaseBorrowedPrincipal`, `_increaseSameAssetDebt`, or `_decreaseBorrowedPrincipal` / `_decreaseSameAssetDebt` where the decrease amount is within bounds of all trackers, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.9, 3.10, 3.11, 3.12, 3.13**

Property 7: Preservation — Downstream Product Flows

_For any_ downstream product flow (EqualX encumbrance changes, EqualLend debt origination/settlement, EqualScale debt cleanup) that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.14, 3.15, 3.16**

## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

**File**: `src/libraries/LibActiveCreditIndex.sol`

**Function**: `_removeFromBase`

**Specific Changes**:
1. **Symmetric overflow bucket removal (Finding 1)**: When `offset >= BUCKET_COUNT`, remove from the same last pending bucket that `_scheduleState` uses instead of from `activeCreditMaturedTotal`.

```diff
  function _removeFromBase(Types.PoolData storage p, Types.ActiveCreditState storage state, uint256 amount) private {
      if (amount == 0) return;
      _rollMatured(p);
      if (_isMature(state)) {
-         if (p.activeCreditMaturedTotal >= amount) {
-             p.activeCreditMaturedTotal -= amount;
-         } else {
-             p.activeCreditMaturedTotal = 0;
-         }
+         p.activeCreditMaturedTotal -= amount;
          return;
      }
      uint64 maturityHour = _maturityHour(state.startTime);
      uint64 startHour = p.activeCreditPendingStartHour - 1;
      if (maturityHour <= startHour) {
-         if (p.activeCreditMaturedTotal >= amount) {
-             p.activeCreditMaturedTotal -= amount;
-         } else {
-             p.activeCreditMaturedTotal = 0;
-         }
+         p.activeCreditMaturedTotal -= amount;
          return;
      }
      uint64 offset = maturityHour - startHour - 1;
      if (offset >= BUCKET_COUNT) {
-         if (p.activeCreditMaturedTotal >= amount) {
-             p.activeCreditMaturedTotal -= amount;
-         } else {
-             p.activeCreditMaturedTotal = 0;
-         }
+         uint8 last = uint8((p.activeCreditPendingCursor + (BUCKET_COUNT - 1)) % BUCKET_COUNT);
+         p.activeCreditPendingBuckets[last] -= amount;
          return;
      }
      uint8 index = uint8((p.activeCreditPendingCursor + uint8(offset)) % BUCKET_COUNT);
      uint256 bucket = p.activeCreditPendingBuckets[index];
-     if (bucket >= amount) {
-         p.activeCreditPendingBuckets[index] = bucket - amount;
-         return;
-     }
-     p.activeCreditPendingBuckets[index] = 0;
-     uint256 remainder = amount - bucket;
-     if (p.activeCreditMaturedTotal >= remainder) {
-         p.activeCreditMaturedTotal -= remainder;
-     } else {
-         p.activeCreditMaturedTotal = 0;
-     }
+     p.activeCreditPendingBuckets[index] = bucket - amount;
  }
```

Note: Removing the silent clamp-to-zero throughout `_removeFromBase` means any accounting drift will revert immediately via Solidity's built-in underflow check (0.8.x checked arithmetic). This is the desired behavior per requirement 2.2.

**Function**: `_increaseEncumbrance`

**Specific Changes**:
2. **Settle pending yield before snapshot overwrite (Finding 2)**: Call `_settleState` before overwriting `indexSnapshot`.

```diff
  function _increaseEncumbrance(
      Types.PoolData storage p,
      uint256 pid,
      bytes32 user,
      uint256 amount
  ) private {
      if (amount == 0) return;
+     Types.ActiveCreditState storage enc = p.userActiveCreditStateEncumbrance[user];
+     _settleState(p, enc, pid, user);
      p.activeCreditPrincipalTotal += amount;
-     Types.ActiveCreditState storage enc = p.userActiveCreditStateEncumbrance[user];
      applyWeightedIncreaseWithGate(p, enc, amount, pid, user, false);
      enc.indexSnapshot = p.activeCreditIndex;
  }
```

**Function**: `_decreaseEncumbrance`

**Specific Changes**:
3. **Settle pending yield before snapshot overwrite (Finding 2)**: Call `_settleState` before the principal decrease and snapshot overwrite.

```diff
  function _decreaseEncumbrance(
      Types.PoolData storage p,
      uint256 pid,
      bytes32 user,
      uint256 amount
  ) private {
      if (amount == 0) return;
      Types.ActiveCreditState storage enc = p.userActiveCreditStateEncumbrance[user];
+     _settleState(p, enc, pid, user);
      uint256 principalBefore = enc.principal;
      uint256 decrease = principalBefore >= amount ? amount : principalBefore;
      if (p.activeCreditPrincipalTotal >= decrease) {
          p.activeCreditPrincipalTotal -= decrease;
      } else {
          p.activeCreditPrincipalTotal = 0;
      }
      applyPrincipalDecrease(p, enc, decrease);
      if (principalBefore <= amount || enc.principal == 0) {
          resetIfZeroWithGate(enc, pid, user, false);
      } else {
          enc.indexSnapshot = p.activeCreditIndex;
      }
  }
```

Note: `_settleState` already handles the case where `principal == 0` or `!_isMature(state)` by just updating `indexSnapshot` without computing yield. So calling it unconditionally before the encumbrance change is safe and handles all edge cases.

---

**File**: `src/libraries/LibEqualLendDirectAccounting.sol`

**Function**: `_decreaseBorrowedPrincipal`

**Specific Changes**:
4. **Revert on over-subtraction (Finding 3)**: Replace silent clamp-to-zero with a revert.

```diff
  function _decreaseBorrowedPrincipal(
      LibEqualLendDirectStorage.DirectStorage storage store,
      bytes32 borrowerPositionKey,
      uint256 lenderPoolId,
      uint256 amount
  ) private {
      uint256 current = store.borrowedPrincipalByPool[borrowerPositionKey][lenderPoolId];
-     store.borrowedPrincipalByPool[borrowerPositionKey][lenderPoolId] = amount >= current ? 0 : current - amount;
+     store.borrowedPrincipalByPool[borrowerPositionKey][lenderPoolId] = current - amount;
  }
```

Note: Solidity 0.8.x checked arithmetic will revert on underflow when `amount > current`. This surfaces the accounting drift immediately rather than masking it.

**Function**: `_decreaseSameAssetDebt`

**Specific Changes**:
5. **Revert on over-subtraction for all four independent trackers (Finding 3)**: Replace silent clamp-to-zero with direct subtraction (reverts on underflow).

```diff
  function _decreaseSameAssetDebt(
      LibEqualLendDirectStorage.DirectStorage storage store,
      bytes32 borrowerPositionKey,
      uint256 borrowerPositionId,
      uint256 collateralPoolId,
      address collateralAsset,
      uint256 principalComponent
  ) private {
-     uint256 storedDebt = store.sameAssetDebtByAsset[borrowerPositionKey][collateralAsset];
-     store.sameAssetDebtByAsset[borrowerPositionKey][collateralAsset] =
-         principalComponent >= storedDebt ? 0 : storedDebt - principalComponent;
+     store.sameAssetDebtByAsset[borrowerPositionKey][collateralAsset] -= principalComponent;

      Types.PoolData storage collateralPool = LibAppStorage.s().pools[collateralPoolId];

-     uint256 sameAssetDebt = collateralPool.userSameAssetDebt[borrowerPositionKey];
-     collateralPool.userSameAssetDebt[borrowerPositionKey] =
-         principalComponent >= sameAssetDebt ? 0 : sameAssetDebt - principalComponent;
+     collateralPool.userSameAssetDebt[borrowerPositionKey] -= principalComponent;

-     uint256 tokenDebt = collateralPool.sameAssetDebt[borrowerPositionId];
-     collateralPool.sameAssetDebt[borrowerPositionId] =
-         principalComponent >= tokenDebt ? 0 : tokenDebt - principalComponent;
+     collateralPool.sameAssetDebt[borrowerPositionId] -= principalComponent;

      Types.ActiveCreditState storage debtState = collateralPool.userActiveCreditStateDebt[borrowerPositionKey];
      uint256 debtPrincipalBefore = debtState.principal;
-     uint256 debtDecrease = debtPrincipalBefore > principalComponent ? principalComponent : debtPrincipalBefore;
+     uint256 debtDecrease = principalComponent;
      LibActiveCreditIndex.applyPrincipalDecrease(collateralPool, debtState, debtDecrease);

      if (debtPrincipalBefore <= principalComponent || debtState.principal == 0) {
          LibActiveCreditIndex.resetIfZeroWithGate(debtState, collateralPoolId, borrowerPositionKey, true);
      } else {
          debtState.indexSnapshot = collateralPool.activeCreditIndex;
      }

-     if (collateralPool.activeCreditPrincipalTotal >= debtDecrease) {
-         collateralPool.activeCreditPrincipalTotal -= debtDecrease;
-     } else {
-         collateralPool.activeCreditPrincipalTotal = 0;
-     }
+     collateralPool.activeCreditPrincipalTotal -= debtDecrease;
  }
```

Note: All five trackers now use Solidity 0.8.x checked arithmetic. Any over-subtraction will revert immediately, surfacing the accounting drift rather than masking it. The `debtDecrease` variable no longer clamps to `debtPrincipalBefore` — it uses the full `principalComponent` so the ACI state decrease matches the other tracker decreases.

### Dependencies

- This is a Phase 1 shared substrate fix. Downstream product specs (Track D, E, F, G) depend on these fixes landing first.
- Track A (Native Asset Tracking) should land first or concurrently — it does not conflict with these changes.
- The EqualX finding 2 fix (Solo AMM swap missing ACI update on encumbrance changes) depends on the encumbrance yield settlement fix (Finding 2 here) being in place so that the newly added `applyEncumbranceIncrease` / `applyEncumbranceDecrease` calls in `_applyReserveDelta` correctly settle yield.
- The EqualScale finding 1 fix (chargeOffLine never clears borrower debt state) depends on the debt tracker revert fix (Finding 3 here) being in place so that `reduceBorrowerDebt` surfaces any over-subtraction rather than silently absorbing it.

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. Tests for findings 1 and 2 use a minimal ACI harness that exposes `LibActiveCreditIndex` functions. Tests for finding 3 use a minimal Direct Accounting harness or real EqualLend lifecycle flows. All tests follow workspace guidelines (`ETHSKILLS.md`, `AGENTS.md`).

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes. Confirm or refute the root cause analysis.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures and understand the root cause.

**Test Cases**:
1. **Bucket Asymmetry Test**: Create an ACI state with `offset >= BUCKET_COUNT`. Call `_scheduleState` to place principal in the last pending bucket. Call `_removeFromBase` for the same state. Assert that the pending bucket was decremented (not `activeCreditMaturedTotal`). On unfixed code this will FAIL because `_removeFromBase` subtracts from `activeCreditMaturedTotal`.
2. **Bucket Inflation After Roll Test**: After the asymmetric schedule/remove from test 1, call `_rollMatured` to advance buckets. Assert `activeCreditMaturedTotal` does not contain phantom principal. On unfixed code this will FAIL because the pending bucket principal rolls into matured total while the removal was already taken from matured total.
3. **Encumbrance Yield Settlement Test**: Create an encumbrance state with known principal and `indexSnapshot`. Accrue ACI yield to advance `activeCreditIndex`. Call `_increaseEncumbrance` with a delta. Assert `userAccruedYield` was credited with the pending yield before the snapshot overwrite. On unfixed code this will FAIL because yield is lost.
4. **Encumbrance Decrease Yield Settlement Test**: Same setup as test 3 but call `_decreaseEncumbrance` (partial decrease, not zeroing). Assert `userAccruedYield` was credited. On unfixed code this will FAIL.
5. **Debt Tracker Over-Subtraction Test**: Create two same-asset agreements on the same borrower/pool pair. Settle the first with `principalDelta` exceeding its individual tracker. Assert revert. On unfixed code this will FAIL because the clamp-to-zero silently absorbs the over-subtraction.
6. **Debt Tracker Desync Test**: After the silent over-subtraction from test 5 (on unfixed code), settle the second agreement. Assert that all five trackers are zero. On unfixed code this will FAIL because the trackers have diverged.

**Expected Counterexamples**:
- Finding 1: `activeCreditMaturedTotal` inflated by phantom principal after schedule/remove/roll cycle
- Finding 2: `userAccruedYield` unchanged after encumbrance change despite pending yield
- Finding 3: `borrowedPrincipalByPool` or `sameAssetDebt` trackers diverge after multi-agreement settlement

### Fix Checking

**Pseudocode:**
```
// Finding 1
FOR ALL removeFromBase WHERE offset >= BUCKET_COUNT DO
  maturedBefore := activeCreditMaturedTotal
  bucketBefore := pendingBuckets[last]
  _removeFromBase_fixed(state, amount)
  ASSERT activeCreditMaturedTotal == maturedBefore
  ASSERT pendingBuckets[last] == bucketBefore - amount
END FOR

// Finding 2
FOR ALL encumbranceChange WHERE principal > 0 AND currentIndex > snapshot DO
  expectedYield := principal * (currentIndex - snapshot) / INDEX_SCALE
  yieldBefore := userAccruedYield[user]
  encumbranceChange_fixed(...)
  ASSERT userAccruedYield[user] >= yieldBefore + expectedYield
END FOR

// Finding 3
FOR ALL debtDecrease WHERE amount > anyTrackerValue DO
  ASSERT REVERTS _decreaseBorrowedPrincipal_fixed(amount)
  ASSERT REVERTS _decreaseSameAssetDebt_fixed(amount)
END FOR
```

### Preservation Checking

**Pseudocode:**
```
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT originalFunction(input) == fixedFunction(input)
END FOR
```

**Test Cases**:
1. **Normal Bucket Placement Preservation**: Schedule and remove ACI states with `offset < BUCKET_COUNT`, verify identical bucket behavior
2. **Mature State Removal Preservation**: Remove from base for mature states, verify `activeCreditMaturedTotal` decrements correctly
3. **Roll Matured Preservation**: Advance time and roll buckets, verify matured total accumulates correctly
4. **Encumbrance Zero-Amount Preservation**: Call `applyEncumbranceIncrease` with `amount == 0`, verify early return
5. **Encumbrance Full-Zero Preservation**: Call `applyEncumbranceDecrease` that fully zeroes principal, verify `resetIfZeroWithGate` called
6. **Encumbrance No-Pending-Yield Preservation**: Call encumbrance change when `indexSnapshot == activeCreditIndex`, verify no yield settlement side effects
7. **Debt Increase Preservation**: Call `_increaseBorrowedPrincipal` and `_increaseSameAssetDebt`, verify all trackers increment correctly
8. **Debt In-Bounds Decrease Preservation**: Call `_decreaseBorrowedPrincipal` and `_decreaseSameAssetDebt` with amounts within bounds, verify all trackers decrement correctly
9. **Single-Agreement Settlement Preservation**: Originate and settle a single same-asset loan, verify all trackers return to zero

### Unit Tests

- `_removeFromBase` with `offset >= BUCKET_COUNT`: verify pending bucket decremented, not `activeCreditMaturedTotal`
- `_removeFromBase` with `offset < BUCKET_COUNT`: verify correct bucket decremented
- `_removeFromBase` for mature state: verify `activeCreditMaturedTotal` decremented
- `_removeFromBase` underflow: verify revert (no silent clamp)
- `_increaseEncumbrance` with pending yield: verify `userAccruedYield` credited before snapshot overwrite
- `_decreaseEncumbrance` with pending yield (partial): verify `userAccruedYield` credited
- `_decreaseEncumbrance` to zero: verify `resetIfZeroWithGate` called, yield settled
- `_decreaseBorrowedPrincipal` over-subtraction: verify revert
- `_decreaseSameAssetDebt` over-subtraction on each tracker: verify revert

### Integration Tests

- Full ACI lifecycle: schedule → accrue → settle → remove → verify matured total and yield are correct
- Multi-encumbrance lifecycle: increase → accrue → increase again → accrue → decrease → verify cumulative yield is correct and no yield is lost
- Multi-agreement debt lifecycle: originate two same-asset loans → settle first → settle second → verify all five trackers are zero
- EqualX Solo AMM with ACI: create market → swap (triggers encumbrance change) → verify yield is settled before snapshot overwrite → finalize → verify clean ACI state
- EqualLend Direct with same-asset: originate → partial settle → full settle → verify all debt trackers are zero
