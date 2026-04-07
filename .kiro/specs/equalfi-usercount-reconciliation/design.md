# EqualFi userCount / Pool Membership Reconciliation — Bugfix Design

## Overview

Four root-cause defects in the shared EqualFi accounting libraries break `userCount` tracking and pool membership consistency. The fix strategy centralizes `userCount` management: enforce `maxUserCount` on every principal-from-zero credit path, decrement `userCount` on every principal-to-zero transition (including maintenance settlement), and keep the `joined` membership flag as a separate concern that does not bypass capacity limits. The fixes land in two shared files (`LibFeeIndex.sol`, `LibEqualLendDirectAccounting.sol`) plus two facet-local `_creditPrincipal` functions. `LibPoolMembership.sol` is reviewed for scope but does not require direct code changes in this track.

Canonical Track: Track B. ACI / Encumbrance / Debt Tracker Consistency (userCount/membership portion)
Phase: Phase 1. Shared Accounting Substrate

Source reports:
- `assets/findings/EdenFi-libraries-phase3-pashov-ai-audit-report-20260406-193000.md` (findings 6 [83], 7 [80])
- `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md` (lead: `departLenderCapital` asymmetric `userCount`)
- `assets/remediation/Options-findings-3-8-remediation-plan.md` (`userCount` inflation via maintenance/settle)
Remediation plan: `assets/remediation/EqualFi-unified-remediation-plan.md` (Track B)
Coding standards: `ETHSKILLS.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across four findings that trigger `userCount` inflation, `maxUserCount` bypass, or stale counts surviving principal-to-zero transitions
- **Property (P)**: The desired correct behavior — `maxUserCount` enforced on all credit paths, `userCount` decremented on all zero-principal transitions, and membership remaining explicitly separate from count
- **Preservation**: Existing voluntary deposit/withdraw `userCount` tracking, partial withdrawal behavior, membership lifecycle, EqualScale recovery, Options exercise for existing-principal positions, and fee index settlement for non-zero-principal positions
- **`userCount`**: Per-pool field in `Types.PoolData` tracking the number of positions with nonzero principal
- **`maxUserCount`**: Per-pool config field in `Types.PoolConfig` limiting the maximum number of positions with nonzero principal (0 = unlimited)
- **`joined`**: Per-position per-pool boolean in `LibPoolMembership.PoolMembershipStorage` tracking pool membership independently of principal
- **`userPrincipal`**: Per-position per-pool field in `Types.PoolData` tracking the position's deposited principal
- **`_creditPrincipal`**: Internal function in `EqualLendDirectLifecycleFacet` and `EqualLendDirectRollingLifecycleFacet` that credits principal to a position during default settlement
- **`restoreLenderCapital`**: Internal function in `LibEqualLendDirectAccounting` that restores lender principal after loan settlement
- **`departLenderCapital`**: Internal function in `LibEqualLendDirectAccounting` that removes lender principal for loan origination
- **`LibFeeIndex.settle`**: Shared settlement function that applies maintenance fees and can zero `userPrincipal`
- **`_ensurePoolMembership`**: Function in `LibPoolMembership` that sets `joined = true` without touching `userCount`
- **`_leavePool`**: Function in `LibPoolMembership` that deletes `joined` without touching `userCount`

## Bug Details

### Bug Condition

The bugs manifest across four distinct conditions. Together they represent `maxUserCount` bypass on credit paths, stale `userCount` after maintenance-driven zero-principal transitions, and membership/count decoupling.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 6: _creditPrincipal or restoreLenderCapital increments userCount
  //            when principalBefore == 0 without checking maxUserCount
  IF input.finding == 6 THEN
    RETURN input.context.isPrincipalCredit
           AND input.context.principalBefore == 0
           AND input.context.maxUserCount > 0
           AND input.context.currentUserCount >= input.context.maxUserCount

  // Finding 7: membership decoupling is only harmful when principal reaches zero
  //            and userCount is not decremented on that transition
  IF input.finding == 7 THEN
    RETURN input.context.principalBefore > 0
           AND input.context.principalAfter == 0
           AND input.context.userCountNotDecremented

  // Lead: departLenderCapital/restoreLenderCapital asymmetric conditions
  //       after maintenance zeroes principal
  IF input.finding == "lead" THEN
    RETURN input.context.isRestoreLenderCapital
           AND input.context.principalBefore == 0
           AND input.context.principalWasZeroedByMaintenance

  // Options: maintenance settlement zeroes principal without decrementing userCount
  IF input.finding == "maintenance" THEN
    RETURN input.context.isLibFeeIndexSettle
           AND input.context.principalBefore > 0
           AND input.context.principalAfterMaintenance == 0

  RETURN false
END FUNCTION
```

### Examples

- **Finding 6**: Pool has `maxUserCount = 10`, `userCount = 10`. Default settlement calls `_creditPrincipal` for a lender whose `principalBefore == 0`. Expected: revert with `MaxUserCountExceeded(10)`. Actual: `userCount` becomes 11, exceeding the cap.

- **Finding 7**: Position A has nonzero principal and `joined = true`. Maintenance zeroes principal, but `userCount` is not decremented. Later `_leavePool` clears membership. The bug is not the decoupling itself; the bug is that the zero-principal transition left `userCount` stale.

- **Lead**: Lender has `principal = 100e18` in pool. `departLenderCapital(100e18)` → `principal = 0`, `userCount -= 1`. Maintenance settlement runs, but principal is already 0 so no effect. `restoreLenderCapital(50e18)` → `principalBefore == 0`, `userCount += 1`. This is correct. But: Lender has `principal = 100e18`. Maintenance zeroes it to 0 (no `userCount` decrement). `restoreLenderCapital(50e18)` → `principalBefore == 0`, `userCount += 1`. Now `userCount` is inflated by 1 because maintenance didn't decrement.

- **Options maintenance**: User has `principal = 100e18`, `userCount = 5`. `LibFeeIndex.settle` applies maintenance fee of 100e18, zeroing principal. `userCount` stays 5. Later, Options `_increasePrincipal` credits 50e18 to the same position. `principalBefore == 0` → `userCount` becomes 6. The user was counted twice.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Voluntary deposit via `PositionManagementFacet` must continue to increment `userCount` and enforce `maxUserCount` as today
- Voluntary full withdrawal must continue to decrement `userCount` exactly once
- Partial withdrawal must continue to leave `userCount` unchanged
- `_ensurePoolMembership` for an already-member position must continue to return `true` without state changes
- `_leavePool` must continue to delete the `joined` flag when obligations are cleared
- `canClearMembership` must continue to check principal, debt, loans, and encumbrance
- `departLenderCapital` for partial departure (principal remains nonzero) must continue to leave `userCount` unchanged
- `restoreLenderCapital` for a position with existing nonzero principal must continue to leave `userCount` unchanged
- `settlePrincipal` crediting a lender who already has nonzero principal must continue to leave `userCount` unchanged
- Options `_increasePrincipal` for a position with existing nonzero principal must continue to leave `userCount` unchanged
- `recoverBorrowerCollateral` reducing principal to zero must continue to decrement `userCount` exactly once
- `LibFeeIndex.settle` where maintenance does NOT zero principal must continue to leave `userCount` unchanged
- `LibFeeIndex.settle` where principal is already zero must continue to skip maintenance and leave `userCount` unchanged

**Scope:**
All inputs that do NOT match any of the four bug conditions should be completely unaffected. This includes:
- All principal credit paths where `principalBefore > 0` (no `userCount` change)
- All principal debit paths where principal remains nonzero (no `userCount` change)
- All membership operations for already-joined positions
- All fee index settlements where maintenance does not zero principal

## Hypothesized Root Cause

1. **Finding 6 — Missing `maxUserCount` check in credit paths**: `_creditPrincipal` in both lifecycle facets and `restoreLenderCapital` in `LibEqualLendDirectAccounting` were written as pure accounting functions without awareness of the pool capacity constraint. The `maxUserCount` check was only added to the voluntary deposit path (`PositionManagementFacet._enforceDepositCap` and the inline check in `_deposit`). Default settlement and capital restoration were treated as obligation fulfillment rather than capacity-consuming operations, but they still increment `userCount` and should respect the cap.

2. **Finding 7 — Membership/count decoupling exposes stale counts**: `LibPoolMembership` was designed as a separate concern from principal accounting. The `joined` flag tracks "is this position associated with this pool" while `userCount` tracks "how many positions have nonzero principal." That decoupling is intentional. The actual defect is that principal-to-zero transitions can leave `userCount` stale, and the decoupled membership lifecycle makes the stale count visible later.

3. **Lead — Asymmetric depart/restore conditions**: `departLenderCapital` decrements `userCount` only on full departure (`principalBefore == amount`), which is correct. `restoreLenderCapital` increments on `principalBefore == 0`, which is also correct in isolation. The asymmetry becomes a bug only when an intermediate path (maintenance settlement) zeroes principal without decrementing `userCount`, causing the restore to double-count.

4. **Options maintenance — Missing `userCount` decrement in `LibFeeIndex.settle`**: The maintenance fee application in `settle` can reduce `userPrincipal` to zero, but the function was written as a pure fee/yield accounting function without awareness of the `userCount` lifecycle. The zero-principal transition is a side effect of maintenance, not an explicit user action, so the `userCount` decrement was never added.

## Correctness Properties

Property 1: Bug Condition — `maxUserCount` Enforcement on All Credit Paths

_For any_ call to `_creditPrincipal` (in either lifecycle facet) or `restoreLenderCapital` where `principalBefore == 0` and `pool.poolConfig.maxUserCount > 0` and `pool.userCount >= pool.poolConfig.maxUserCount`, the fixed function SHALL revert with `MaxUserCountExceeded`. The pool SHALL NOT exceed its configured user cap through any principal credit path.

**Validates: Requirements 2.1, 2.2, 2.3**

Property 2: Bug Condition — Maintenance-Driven `userCount` Decrement

_For any_ call to `LibFeeIndex.settle` where maintenance fees reduce `userPrincipal` from a nonzero value to zero, the fixed function SHALL decrement `pool.userCount` by 1. After the decrement, `userCount` SHALL accurately reflect the number of positions with nonzero principal.

**Validates: Requirements 2.7, 2.8**

Property 3: Bug Condition — No Double-Count After Maintenance Zeroing

_For any_ sequence where (1) `LibFeeIndex.settle` zeroes a position's principal and decrements `userCount`, then (2) a subsequent credit path (`restoreLenderCapital`, `_creditPrincipal`, or `_increasePrincipal`) credits principal to the same position, the `userCount` SHALL be incremented exactly once by the credit path (because the maintenance path already decremented). The net effect is `userCount` unchanged from before the maintenance-then-credit sequence.

**Validates: Requirements 2.6, 2.8**

Property 4: Preservation — Voluntary Deposit/Withdraw `userCount`

_For any_ voluntary deposit where `principalBefore == 0`, the fixed code SHALL produce exactly the same `userCount` increment and `maxUserCount` enforcement as the original code. _For any_ voluntary full withdrawal, the fixed code SHALL produce exactly the same `userCount` decrement. _For any_ partial withdrawal, `userCount` SHALL remain unchanged.

**Validates: Requirements 3.1, 3.2, 3.3**

Property 5: Preservation — Existing Credit Paths for Nonzero-Principal Positions

_For any_ call to `restoreLenderCapital`, `_creditPrincipal`, or `_increasePrincipal` where `principalBefore > 0`, the fixed code SHALL produce exactly the same behavior as the original code — no `userCount` change, no `maxUserCount` check.

**Validates: Requirements 3.8, 3.9, 3.10**

Property 6: Preservation — Fee Index Settlement for Non-Zero-Principal Results

_For any_ call to `LibFeeIndex.settle` where maintenance fees do NOT reduce principal to zero, or where principal is already zero before settlement, the fixed code SHALL produce exactly the same behavior as the original code — no `userCount` change.

**Validates: Requirements 3.12, 3.13**


## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

**File**: `src/libraries/LibFeeIndex.sol`

**Function**: `settle`

**Specific Changes**:
1. **Decrement `userCount` when maintenance zeroes principal (Finding: maintenance)**: After the maintenance fee block that sets `p.userPrincipal[user] = 0`, add a `userCount` decrement:

```diff
  if (maintenanceFee > 0) {
      if (maintenanceFee >= principal) {
          principal = 0;
          p.userPrincipal[user] = 0;
+         if (p.userCount > 0) {
+             p.userCount -= 1;
+         }
      } else {
          principal -= maintenanceFee;
          p.userPrincipal[user] = principal;
      }
  }
```

Note: The `p.userCount > 0` guard prevents underflow in edge cases where `userCount` is already zero (e.g., pool initialization). This is a defensive check — in normal operation, `userCount` should always be >= 1 when a user has nonzero principal.

---

**File**: `src/libraries/LibEqualLendDirectAccounting.sol`

**Function**: `restoreLenderCapital`

**Specific Changes**:
2. **Enforce `maxUserCount` when restoring capital to a zero-principal position (Finding 6)**: Add a `maxUserCount` check before incrementing `userCount`:

```diff
  function restoreLenderCapital(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) internal {
      if (amount == 0) return;

      Types.PoolData storage lenderPool = LibAppStorage.s().pools[lenderPoolId];
      uint256 principalBefore = lenderPool.userPrincipal[lenderPositionKey];
      lenderPool.userPrincipal[lenderPositionKey] = principalBefore + amount;
      lenderPool.totalDeposits += amount;
      lenderPool.trackedBalance += amount;

      if (principalBefore == 0) {
+         uint256 maxUsers = lenderPool.poolConfig.maxUserCount;
+         if (maxUsers > 0 && lenderPool.userCount >= maxUsers) {
+             revert MaxUserCountExceeded(maxUsers);
+         }
          lenderPool.userCount += 1;
      }

      if (LibCurrency.isNative(lenderPool.underlying)) {
          LibAppStorage.s().nativeTrackedTotal += amount;
      }
  }
```

Note: This mirrors the existing pattern in `PositionManagementFacet._deposit` and `OptionsFacet._increasePrincipal`. EqualFi chooses enforcement in this shared substrate: default settlement and capital restoration do NOT receive an implicit `maxUserCount` carveout. If a product later wants a carveout for obligation settlement, that must be introduced explicitly in a downstream product spec rather than silently bypassing the shared invariant.

---

**File**: `src/equallend/EqualLendDirectLifecycleFacet.sol`

**Function**: `_creditPrincipal`

**Specific Changes**:
3. **Enforce `maxUserCount` in Direct lifecycle `_creditPrincipal` (Finding 6)**:

```diff
  function _creditPrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 amount) internal {
      uint256 principalBefore = pool.userPrincipal[positionKey];
      pool.userPrincipal[positionKey] = principalBefore + amount;
      pool.totalDeposits += amount;
      if (principalBefore == 0) {
+         uint256 maxUsers = pool.poolConfig.maxUserCount;
+         if (maxUsers > 0 && pool.userCount >= maxUsers) {
+             revert MaxUserCountExceeded(maxUsers);
+         }
          pool.userCount += 1;
      }
  }
```

---

**File**: `src/equallend/EqualLendDirectRollingLifecycleFacet.sol`

**Function**: `_creditPrincipal`

**Specific Changes**:
4. **Enforce `maxUserCount` in Rolling lifecycle `_creditPrincipal` (Finding 6)**:

```diff
  function _creditPrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 amount) internal {
      uint256 principalBefore = pool.userPrincipal[positionKey];
      pool.userPrincipal[positionKey] = principalBefore + amount;
      pool.totalDeposits += amount;
      if (principalBefore == 0) {
+         uint256 maxUsers = pool.poolConfig.maxUserCount;
+         if (maxUsers > 0 && pool.userCount >= maxUsers) {
+             revert MaxUserCountExceeded(maxUsers);
+         }
          pool.userCount += 1;
      }
  }
```

---

**File**: `src/libraries/LibPoolMembership.sol`

**Specific Changes**:
5. **Finding 7 — No code change required for membership/count decoupling**: The `joined` flag and `userCount` serve different purposes by design. The `joined` flag tracks pool association (for whitelist enforcement, obligation tracking). `userCount` tracks positions with nonzero principal (for capacity limiting). The real fix is ensuring `userCount` is correctly maintained on all principal transitions (findings 6 and maintenance), not coupling membership to count. The membership library remains unchanged.

The decoupling is acceptable because:
- `_ensurePoolMembership` is called before deposit/credit paths that will increment `userCount` if `principalBefore == 0`
- `_leavePool` is called after all obligations are cleared, which means principal is already zero and `userCount` was already decremented
- Ghost members (joined but no principal) are harmless — they don't consume capacity
- The `maxUserCount` cap is enforced on principal credit, not on membership

### Dependencies

- This is a Phase 1 shared substrate fix. Downstream product specs depend on these fixes landing first.
- Track A (Native Asset Tracking) should land first or concurrently — it does not conflict with these changes.
- `equalfi-aci-encumbrance-consistency` should land first or concurrently — it fixes the debt tracker revert-on-overflow behavior that interacts with the same `LibEqualLendDirectAccounting` functions.
- The Options finding 8 fix (deposit cap blocks option exercise) depends on correct `userCount` behavior from this spec. The Options spec may need a controlled bypass for exercise settlement, but that is a downstream product decision.

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. Tests use a minimal harness for `LibFeeIndex` and `LibEqualLendDirectAccounting` functions, plus real lifecycle flows where practical. All tests follow workspace guidelines (`ETHSKILLS.md`, `AGENTS.md`).

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes. Confirm or refute the root cause analysis.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures and understand the root cause.

**Test Cases**:
1. **`restoreLenderCapital` maxUserCount bypass**: Set up a pool with `maxUserCount = 2` and 2 existing users. Call `departLenderCapital` to fully remove one user (userCount → 1). Call `restoreLenderCapital` for a NEW position with `principalBefore == 0`. Assert revert with `MaxUserCountExceeded`. On unfixed code this will FAIL because `restoreLenderCapital` does not check `maxUserCount`.
2. **`_creditPrincipal` maxUserCount bypass (Direct)**: Set up a pool at `maxUserCount` capacity. Trigger a default settlement that calls `_creditPrincipal` for a position with `principalBefore == 0`. Assert revert. On unfixed code this will FAIL.
3. **`_creditPrincipal` maxUserCount bypass (Rolling)**: Same as above but through the rolling lifecycle settlement path. Assert revert. On unfixed code this will FAIL.
4. **Maintenance zeroes principal without userCount decrement**: Set up a pool with a user who has principal. Accrue enough maintenance fees to zero the principal via `LibFeeIndex.settle`. Assert `userCount` decremented. On unfixed code this will FAIL because `settle` does not touch `userCount`.
5. **Maintenance-then-credit double-count**: After maintenance zeroes principal (test 4), call `restoreLenderCapital` for the same position. Assert `userCount` is back to the original value (not inflated). On unfixed code this will FAIL because maintenance didn't decrement, so restore double-increments.

**Expected Counterexamples**:
- Finding 6: `userCount` exceeds `maxUserCount` after `restoreLenderCapital` or `_creditPrincipal`
- Maintenance: `userCount` unchanged after `LibFeeIndex.settle` zeroes principal
- Double-count: `userCount` inflated by 1 after maintenance-then-credit sequence

### Fix Checking

**Pseudocode:**
```
// Finding 6
FOR ALL creditPath WHERE principalBefore == 0 AND maxUserCount > 0 AND userCount >= maxUserCount DO
  ASSERT REVERTS creditPath_fixed(...)
END FOR

// Maintenance
FOR ALL settle WHERE principalBefore > 0 AND maintenanceFee >= principalBefore DO
  userCountBefore := pool.userCount
  settle_fixed(pid, user)
  ASSERT pool.userCount == userCountBefore - 1
END FOR

// Double-count prevention
FOR ALL (settle, credit) WHERE settle zeroes principal AND credit restores principal DO
  userCountBefore := pool.userCount
  settle_fixed(pid, user)
  credit_fixed(positionKey, poolId, amount)
  ASSERT pool.userCount == userCountBefore
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
1. **Voluntary deposit userCount preservation**: Deposit into a pool for the first time, verify `userCount` increments and `maxUserCount` is enforced identically
2. **Voluntary full withdrawal preservation**: Withdraw all principal, verify `userCount` decrements exactly once
3. **Partial withdrawal preservation**: Withdraw partial principal, verify `userCount` unchanged
4. **restoreLenderCapital nonzero-principal preservation**: Restore capital to a position with existing principal, verify `userCount` unchanged
5. **departLenderCapital partial preservation**: Depart partial capital, verify `userCount` unchanged
6. **settlePrincipal existing-principal preservation**: Settle principal to a lender with existing principal, verify `userCount` unchanged
7. **LibFeeIndex.settle non-zeroing preservation**: Settle with maintenance that reduces but does not zero principal, verify `userCount` unchanged
8. **LibFeeIndex.settle zero-principal preservation**: Settle for a user with zero principal, verify `userCount` unchanged
9. **EqualScale recoverBorrowerCollateral preservation**: Recover collateral that zeroes borrower principal, verify `userCount` decrements exactly once

### Unit Tests

- `restoreLenderCapital` with `principalBefore == 0` and pool at `maxUserCount`: verify revert
- `restoreLenderCapital` with `principalBefore == 0` and pool below `maxUserCount`: verify `userCount` increments
- `restoreLenderCapital` with `principalBefore > 0`: verify `userCount` unchanged
- `_creditPrincipal` (Direct) with `principalBefore == 0` and pool at `maxUserCount`: verify revert
- `_creditPrincipal` (Rolling) with `principalBefore == 0` and pool at `maxUserCount`: verify revert
- `LibFeeIndex.settle` maintenance zeroes principal: verify `userCount` decrements
- `LibFeeIndex.settle` maintenance reduces but doesn't zero: verify `userCount` unchanged
- `LibFeeIndex.settle` maintenance zeroes then credit restores: verify `userCount` net unchanged
- `departLenderCapital` full departure then `restoreLenderCapital`: verify symmetric `userCount` tracking

### Integration Tests

- Full maintenance-then-credit lifecycle: deposit → accrue maintenance → settle (zeroes principal, decrements `userCount`) → restore capital (increments `userCount`) → verify `userCount` is correct
- Default settlement at capacity: set pool to `maxUserCount` → trigger default settlement for a new position → verify revert
- Multi-user pool lifecycle: multiple users deposit → one user's principal zeroed by maintenance → new user attempts deposit → verify `maxUserCount` correctly reflects available capacity
