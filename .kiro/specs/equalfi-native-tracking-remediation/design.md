# EqualFi Native Tracking Remediation — Bugfix Design

## Overview

Two root-cause defects in `LibCurrency.sol` break native ETH accounting symmetry across the entire EqualFi protocol substrate. Finding 1: `transfer()` and `transferWithMin()` send native ETH without decrementing `nativeTrackedTotal`, forcing every downstream caller to manually decrement — a fragile pattern used across 20+ call sites where any omission permanently inflates `nativeTrackedTotal`. Finding 2: `assertMsgValue()` short-circuit evaluates `msg.value != 0 && msg.value != amount`, allowing `msg.value = 0` to pass for any native amount, enabling theft of orphaned ETH via `pull()`.

The fix strategy is: (1) make `transfer` / `transferWithMin` auto-decrement `nativeTrackedTotal` for native ETH, restoring pull/transfer symmetry; (2) replace the short-circuit `assertMsgValue` with separate native/ERC-20 branches; (3) split downstream manual decrements into a confirmed prune set and a manual call-graph audit set so only true decrement-before-transfer sites are removed.

Canonical Track: Track A. Native Asset Tracking and Transfer Symmetry
Phase: Phase 1. Shared Accounting Substrate

Source report: `assets/findings/EdenFi-libraries-phase3-pashov-ai-audit-report-20260406-193000.md` (findings 1, 2)
Remediation plan: `assets/remediation/EqualFi-unified-remediation-plan.md` (Track A)
Coding standards: `ETHSKILLS.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions that trigger incorrect native ETH accounting — asymmetric tracking on transfer and permissive `msg.value` validation
- **Property (P)**: The desired correct behavior — symmetric `nativeTrackedTotal` maintenance and strict `msg.value` enforcement
- **Preservation**: Existing ERC-20 paths, native receive paths, utility functions, and downstream caller behavior that must remain unchanged after the fix
- **`nativeTrackedTotal`**: Global accounting field in `LibAppStorage` tracking total native ETH currently under pool management across all pools
- **`nativeAvailable()`**: Computed as `address(this).balance - nativeTrackedTotal`, representing untracked (orphaned) ETH available for protocol use
- **`transfer()`**: Function in `LibCurrency` that sends ETH or ERC-20 tokens to a recipient
- **`transferWithMin()`**: Function in `LibCurrency` that sends ETH or ERC-20 tokens with minimum-received validation
- **`pull()`**: Function in `LibCurrency` that receives ETH or ERC-20 tokens, auto-incrementing `nativeTrackedTotal` for native
- **`pullAtLeast()`**: Function in `LibCurrency` that receives ETH or ERC-20 tokens with minimum-received validation, auto-incrementing `nativeTrackedTotal` for native
- **`assertMsgValue()`**: Function in `LibCurrency` that validates `msg.value` matches expected amount for native or is zero for ERC-20
- **Double-decrement site**: A downstream call site that manually decrements `nativeTrackedTotal` before calling `transfer()` / `transferWithMin()` — these will underflow once the library auto-decrements
- **Pull-then-undo site**: A downstream call site that calls `pull()` / `pullAtLeast()` (auto-incrementing tracking) then immediately decrements `nativeTrackedTotal` because the pulled ETH is being routed elsewhere, not kept as tracked — these are NOT affected by the transfer fix

## Bug Details

### Bug Condition

The bugs manifest across two distinct conditions in `LibCurrency.sol`. Together they represent asymmetric native ETH accounting and permissive `msg.value` validation.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 1: transfer/transferWithMin send native ETH without decrementing nativeTrackedTotal
  IF input.finding == 1 THEN
    RETURN input.context.isTransferOrTransferWithMin
           AND LibCurrency.isNative(input.context.token)
           AND input.context.amount > 0

  // Finding 2: assertMsgValue allows msg.value = 0 for any native amount
  IF input.finding == 2 THEN
    RETURN input.context.isAssertMsgValue
           AND LibCurrency.isNative(input.context.token)
           AND input.context.amount > 0
           AND input.context.msgValue == 0

  RETURN false
END FUNCTION
```

### Examples

- **Finding 1 — transfer**: Pool calls `LibCurrency.transfer(address(0), recipient, 1 ether)`. Expected: `nativeTrackedTotal` decreases by 1 ether. Actual: `nativeTrackedTotal` unchanged; 1 ether of tracking permanently orphaned.
- **Finding 1 — transferWithMin**: Pool calls `LibCurrency.transferWithMin(address(0), recipient, 1 ether, 0.99 ether)`. Expected: `nativeTrackedTotal` decreases by 1 ether. Actual: `nativeTrackedTotal` unchanged.
- **Finding 1 — cumulative drift**: After 10 native transfers of 1 ETH each without manual decrements, `nativeTrackedTotal` is inflated by 10 ETH. `nativeAvailable()` returns 0 even though 10 ETH of untracked balance exists. All native pool operations that depend on untracked balance are bricked.
- **Finding 2 — zero msg.value bypass**: `assertMsgValue(address(0), 5 ether)` called with `msg.value = 0`. Expected: revert with `UnexpectedMsgValue`. Actual: passes silently because `msg.value != 0` evaluates to `false`, short-circuiting the AND.
- **Finding 2 — orphaned ETH theft**: Contract holds 10 ETH balance, 8 ETH tracked. Attacker calls deposit with `msg.value = 0`. `assertMsgValue` passes. `pull()` claims `nativeAvailable() = 2 ETH` as attacker's deposit for free.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- ERC-20 `transfer()` and `transferWithMin()` must continue to execute `safeTransfer` without touching `nativeTrackedTotal`
- ERC-20 `pull()` and `pullAtLeast()` must continue to execute `safeTransferFrom` with balance-delta accounting without touching `nativeTrackedTotal`
- Native `pull()` with `msg.value > 0` and `msg.value == amount` must continue to increment `nativeTrackedTotal` by `amount`
- Native `pullAtLeast()` with `msg.value == maxAmount` must continue to increment `nativeTrackedTotal` by `maxAmount`
- `assertMsgValue()` for ERC-20 with `msg.value = 0` must continue to pass
- `assertMsgValue()` for ERC-20 with `msg.value > 0` must continue to revert
- `assertZeroMsgValue()` with `msg.value > 0` must continue to revert
- `balanceOfSelf()` for native must continue to return `address(this).balance`
- `nativeAvailable()` must continue to return `address(this).balance - nativeTrackedTotal` (clamped to 0)
- `decimals()` and `decimalsOrRevert()` must continue to return 18 for native
- `transfer()` with `amount = 0` for native must continue to return early without side effects
- `pull()` with `amount = 0` for native must continue to return 0 without side effects

**Scope:**
All inputs that do NOT involve native ETH transfers or native `assertMsgValue` validation should be completely unaffected by this fix. This includes:
- All ERC-20 token operations
- Native receive paths (`pull`, `pullAtLeast`)
- Utility functions (`balanceOfSelf`, `nativeAvailable`, `decimals`)
- `assertZeroMsgValue()`

## Hypothesized Root Cause

Based on the audit findings and code analysis:

1. **Finding 1 — Asymmetric design in `transfer` / `transferWithMin`**: The `pull()` and `pullAtLeast()` functions were designed to auto-increment `nativeTrackedTotal` on receive, but the corresponding `transfer()` and `transferWithMin()` functions were not designed to auto-decrement on send. This created an asymmetric caller-responsibility pattern where every downstream caller must remember to manually decrement before calling transfer. The pattern is used across 20+ call sites in EqualLend, EqualIndex, EqualScale, EqualX, Options, LibFeeRouter, LibMaintenance, and LibEqualLendDirectAccounting. Any single omission permanently inflates `nativeTrackedTotal`.

2. **Finding 2 — Short-circuit AND in `assertMsgValue`**: The native branch checks `msg.value != 0 && msg.value != amount`. When `msg.value = 0`, the left operand evaluates to `false`, short-circuiting the entire expression to `false`, so the revert is never reached. The intent was to reject any `msg.value` that doesn't match `amount`, but the implementation accidentally allows `msg.value = 0` for any `amount`. The ERC-20 branch (`msg.value != 0`) is correct. The fix is to use separate branches: for native, check `msg.value != amount`; for ERC-20, check `msg.value != 0`.

## Correctness Properties

Property 1: Bug Condition — Native Transfer Tracking Symmetry

_For any_ call to `LibCurrency.transfer()` or `LibCurrency.transferWithMin()` where the token is native ETH (`address(0)`) and `amount > 0`, the fixed function SHALL decrement `nativeTrackedTotal` by `amount` before executing the ETH send, maintaining the invariant that `nativeTrackedTotal` reflects only ETH currently tracked by pools.

**Validates: Requirements 2.1, 2.2, 2.3**

Property 2: Bug Condition — Strict msg.value Validation for Native Paths

_For any_ call to `assertMsgValue(address(0), amount)` where `msg.value != amount` (including `msg.value = 0` when `amount > 0`), the fixed function SHALL revert with `UnexpectedMsgValue`, preventing zero-value calls from passing validation for non-zero native amounts.

**Validates: Requirements 2.4, 2.5**

Property 3: Preservation — ERC-20 Path Isolation

_For any_ call to `transfer()`, `transferWithMin()`, `pull()`, `pullAtLeast()`, or `assertMsgValue()` where the token is an ERC-20 (non-native), the fixed code SHALL produce exactly the same behavior as the original code, preserving all ERC-20 token operations without touching `nativeTrackedTotal`.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.7, 3.8**

Property 4: Preservation — Native Receive Path Isolation

_For any_ call to `pull()` or `pullAtLeast()` for native ETH, the fixed code SHALL produce exactly the same behavior as the original code, preserving the auto-increment of `nativeTrackedTotal` on receive.

**Validates: Requirements 3.5, 3.6**

Property 5: Preservation — Utility Function Isolation

_For any_ call to `balanceOfSelf()`, `nativeAvailable()`, `decimals()`, `decimalsOrRevert()`, or `assertZeroMsgValue()`, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.9, 3.10, 3.11, 3.12**

Property 6: Bug Condition — No Double-Decrement After Downstream Pruning

_For any_ downstream call site that previously manually decremented `nativeTrackedTotal` before calling `transfer()` or `transferWithMin()` for native ETH, the pruned code SHALL NOT decrement `nativeTrackedTotal` manually, relying solely on the library's internal auto-decrement to prevent underflow.

**Validates: Requirements 2.3, 3.13**

Property 7: Preservation — Zero-Amount Edge Cases

_For any_ call to `transfer()` with `amount = 0` for native ETH, the fixed code SHALL return early without modifying `nativeTrackedTotal` or executing any ETH send. For `pull()` with `amount = 0`, the fixed code SHALL return 0 without modifying `nativeTrackedTotal`.

**Validates: Requirements 3.14, 3.15**


## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

**File**: `src/libraries/LibCurrency.sol`

**Function**: `transfer`

**Specific Changes**:
1. **Auto-decrement `nativeTrackedTotal` on native send (Finding 1)**: Add `LibAppStorage.s().nativeTrackedTotal -= amount;` in the native branch before the ETH send. The zero-amount early return already guards against decrementing zero.

```diff
  function transfer(address token, address to, uint256 amount) internal {
      if (amount == 0) {
          return;
      }
      if (isNative(token)) {
+         LibAppStorage.s().nativeTrackedTotal -= amount;
          (bool success,) = to.call{value: amount}("");
          if (!success) {
              revert NativeTransferFailed(to, amount);
          }
          return;
      }
      IERC20(token).safeTransfer(to, amount);
  }
```

**Function**: `transferWithMin`

**Specific Changes**:
2. **Auto-decrement `nativeTrackedTotal` on native send (Finding 1)**: Add `LibAppStorage.s().nativeTrackedTotal -= amount;` in the native branch before the ETH send. The zero-amount early return already guards against decrementing zero.

```diff
  function transferWithMin(
      address token,
      address to,
      uint256 amount,
      uint256 minReceived
  ) internal returns (uint256 received) {
      if (amount == 0) {
          return 0;
      }
      if (isNative(token)) {
+         LibAppStorage.s().nativeTrackedTotal -= amount;
          uint256 balanceBefore = to.balance;
          (bool success,) = to.call{value: amount}("");
          if (!success) {
              revert NativeTransferFailed(to, amount);
          }
          received = to.balance - balanceBefore;
      } else {
```

**Function**: `assertMsgValue`

**Specific Changes**:
3. **Separate native/ERC-20 branches (Finding 2)**: Replace the short-circuit AND with explicit branch logic. For native: revert if `msg.value != amount`. For ERC-20: revert if `msg.value != 0`.

```diff
  function assertMsgValue(address token, uint256 amount) internal view {
      if (isNative(token)) {
-         if (msg.value != 0 && msg.value != amount) {
+         if (msg.value != amount) {
              revert UnexpectedMsgValue(msg.value);
          }
          return;
      }
      if (msg.value != 0) {
          revert UnexpectedMsgValue(msg.value);
      }
  }
```

### Downstream Caller Audit — Confirmed Prune Set vs Manual Audit Set

Once `transfer()` and `transferWithMin()` auto-decrement `nativeTrackedTotal`, all downstream sites that manually decrement before calling these functions will cause double-decrement underflow. These sites must be audited and pruned.

**Category A: Confirmed decrement-before-transfer sites (MUST prune — will double-decrement)**

These sites manually decrement `nativeTrackedTotal` and then call `LibCurrency.transfer()` or `transferWithMin()`. After the library fix, the manual decrement must be removed.

| # | File | Line(s) | Pattern | Action |
|---|------|---------|---------|--------|
| A1 | `src/equalindex/EqualIndexActionsFacetV3.sol` | ~274-277 | `nativeTrackedTotal -= leg.payout` → `transfer(leg.asset, to, leg.payout)` | Remove manual decrement |
| A2 | `src/equalindex/EqualIndexActionsFacetV3.sol` | ~394-396 | `nativeTrackedTotal -= toTreasury` → `transfer(pool.underlying, treasury, toTreasury)` | Remove manual decrement |
| A3 | `src/equalindex/EqualIndexLendingFacet.sol` | ~462-465 | `nativeTrackedTotal -= principal` → `transfer(asset, msg.sender, principal)` | Remove manual decrement |
| A4 | `src/equalx/EqualXCommunityAmmFacet.sol` | ~536-538 | `nativeTrackedTotal -= outputToRecipient` → after `transferWithMin(...)` | Remove manual decrement |
| A5 | `src/equalx/EqualXSoloAmmFacet.sol` | ~889-891 | `nativeTrackedTotal -= amountOut` → after `transferWithMin(...)` | Remove manual decrement |
| A6 | `src/options/OptionsFacet.sol` | ~311-314 | `nativeTrackedTotal -= excess` → `transfer(asset, payer, excess)` | Remove manual decrement |
| A8 | `src/libraries/LibMaintenance.sol` | ~232-235 | `nativeTrackedTotal -= paid` → `transferWithMin(p.underlying, receiver, paid, paid)` | Remove manual decrement |
| A9 | `src/libraries/LibEqualXCurveEngine.sol` | ~273-276 | `nativeTrackedTotal -= excess` → `transfer(preview.quoteToken, msg.sender, excess)` | Remove manual decrement |
| A10 | `src/libraries/LibEqualXCurveEngine.sol` | ~278-281 | `nativeTrackedTotal -= preview.amountOut` → `transferWithMin(preview.baseToken, ...)` | Remove manual decrement |
| A12 | `src/libraries/LibFeeRouter.sol` | ~203-206 | `nativeTrackedTotal -= amount` → `transfer(pool.underlying, treasury, amount)` | Remove manual decrement |
| A13 | `src/libraries/LibFeeRouter.sol` | ~225-227 | `nativeTrackedTotal -= amount` (duplicate `_transferTreasury`) → `transfer(...)` | Remove manual decrement |
| A16 | `src/equallend/EqualLendDirectRollingLifecycleFacet.sol` | ~383-386 | `nativeTrackedTotal -= amount` → `transfer(collateralPool.underlying, treasury, amount)` | Remove manual decrement |
| A18 | `src/equallend/SelfSecuredCreditFacet.sol` | ~259-262 | `nativeTrackedTotal -= surplus` → `transfer(pool.underlying, msg.sender, surplus)` | Remove manual decrement |

**Category A-Review: Manual call-graph audit sites (MUST confirm before pruning)**

These sites currently look adjacent to outbound native settlement, but the decrement and transfer are not co-located strongly enough in the spec to make blind edits safe. Each site must be reviewed in code first, then either promoted into the confirmed prune set or explicitly retained as a different accounting pattern.

| # | File | Line(s) | Pattern | Action |
|---|------|---------|---------|--------|
| R1 | `src/options/OptionsFacet.sol` | ~362-364 | helper-level decrement | Audit caller graph before pruning |
| R2 | `src/libraries/LibEqualLendDirectAccounting.sol` | ~118-120 | helper-level decrement, transfer may occur elsewhere | Audit caller graph before pruning |
| R3 | `src/equallend/PositionManagementFacet.sol` | ~139-141 | claim path decrement, transfer may be deferred | Audit caller graph before pruning |
| R4 | `src/equallend/PositionManagementFacet.sol` | ~272-274 | withdraw path decrement, transfer may be deferred | Audit caller graph before pruning |
| R5 | `src/equallend/SelfSecuredCreditFacet.sol` | ~122-124 | SSC draw decrement, transfer may be deferred | Audit caller graph before pruning |
| R6 | `src/equalscale/EqualScaleAlphaFacet.sol` | ~324-326 | settlement decrement in helper path | Audit caller graph before pruning |

**Category B: Pull-then-undo-tracking sites (NOT affected by transfer fix — different pattern)**

These sites call `pull()` / `pullAtLeast()` (which auto-increments `nativeTrackedTotal`) and then immediately decrement `nativeTrackedTotal` because the pulled ETH is being routed to lender pools or other accounting, not kept as tracked. These are NOT double-decrement candidates because they don't precede a `transfer()` call — they undo the pull's auto-increment.

| # | File | Line(s) | Pattern | Action |
|---|------|---------|---------|--------|
| B1 | `src/equallend/EqualLendDirectRollingPaymentFacet.sol` | ~91-93 | `pullAtLeast(...)` → `nativeTrackedTotal -= allocation.received` | No change needed — pull-undo pattern |
| B2 | `src/equallend/EqualLendDirectRollingLifecycleFacet.sol` | ~148-151 | `pullAtLeast(...)` → `nativeTrackedTotal -= received` | No change needed — pull-undo pattern |
| B3 | `src/equallend/EqualLendDirectLifecycleFacet.sol` | ~66-68 | `pullAtLeast(...)` → `nativeTrackedTotal -= received` | No change needed — pull-undo pattern |

**Category C: TrackedBalance-only accounting sites (NOT affected — no transfer call)**

These sites decrement `nativeTrackedTotal` as part of `pool.trackedBalance` accounting (e.g., pool-to-pool transfers, internal rebalancing) without calling `LibCurrency.transfer()`. They are not affected by the library fix.

| # | File | Line(s) | Pattern | Action |
|---|------|---------|---------|--------|
| C1 | `src/equalx/EqualXCommunityAmmFacet.sol` | ~799-802 | `trackedBalance -= deltaDecrease; nativeTrackedTotal -= deltaDecrease` | Audit: confirm no transfer follows |
| C2 | `src/equalx/EqualXSoloAmmFacet.sol` | ~841-844 | `trackedBalance -= deltaDecrease; nativeTrackedTotal -= deltaDecrease` | Audit: confirm no transfer follows |

### Dependencies

- This is a Phase 1 shared substrate fix. All downstream product specs (EqualLend, EqualIndex, EqualScale, EqualX, Options, EDEN) depend on this fix landing first.
- The downstream caller pruning for confirmed decrement-before-transfer sites (Category A) is part of this spec.
- The manual call-graph audit sites (Category A-Review) must be resolved inside this spec before any edits are made.
- Category B (pull-then-undo) sites should be reviewed during product-specific lifecycle specs (Track D, E, F, G) but are not changed here.
- Category C sites should be verified during this spec's integration testing but are not changed here.

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real deposits, real transfers, and real pool operations per workspace guidelines (`ETHSKILLS.md`, `AGENTS.md`).

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes. Confirm or refute the root cause analysis. If we refute, we will need to re-hypothesize.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures and understand the root cause.

**Test Cases**:
1. **Transfer Tracking Drift Test**: Call `transfer(address(0), recipient, 1 ether)` after depositing via `pull()`. Check that `nativeTrackedTotal` did NOT decrease (will demonstrate finding 1 on unfixed code).
2. **TransferWithMin Tracking Drift Test**: Call `transferWithMin(address(0), recipient, 1 ether, 0.99 ether)` after depositing via `pull()`. Check that `nativeTrackedTotal` did NOT decrease (will demonstrate finding 1 on unfixed code).
3. **Cumulative Drift Test**: Execute 5 sequential native transfers without manual decrements. Check that `nativeTrackedTotal` is inflated by the sum of all transfers and `nativeAvailable()` returns 0 (will demonstrate finding 1 cumulative impact).
4. **assertMsgValue Zero Bypass Test**: Call `assertMsgValue(address(0), 1 ether)` with `msg.value = 0`. Check that it does NOT revert (will demonstrate finding 2 on unfixed code).
5. **Orphaned ETH Theft Test**: Seed contract with orphaned ETH, call deposit with `msg.value = 0`, check that `pull()` credits orphaned ETH to attacker (will demonstrate finding 2 exploit path).

**Expected Counterexamples**:
- Finding 1: `nativeTrackedTotal` unchanged after `transfer()` / `transferWithMin()` for native ETH
- Finding 2: `assertMsgValue(address(0), amount)` passes with `msg.value = 0` when `amount > 0`
- Finding 2: Attacker credited with orphaned ETH balance for free

### Fix Checking

**Goal**: Verify that for all inputs where each bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Finding 1 — transfer
FOR ALL transfer WHERE isNative(token) AND amount > 0 DO
  trackedBefore := nativeTrackedTotal
  transfer_fixed(token, to, amount)
  ASSERT nativeTrackedTotal == trackedBefore - amount
END FOR

// Finding 1 — transferWithMin
FOR ALL transferWithMin WHERE isNative(token) AND amount > 0 DO
  trackedBefore := nativeTrackedTotal
  transferWithMin_fixed(token, to, amount, minReceived)
  ASSERT nativeTrackedTotal == trackedBefore - amount
END FOR

// Finding 2 — assertMsgValue
FOR ALL assertMsgValue WHERE isNative(token) AND msgValue != amount DO
  ASSERT REVERTS assertMsgValue_fixed(token, amount)
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug conditions do NOT hold, the fixed functions produce the same result as the original functions.

**Pseudocode:**
```
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT originalFunction(input) == fixedFunction(input)
END FOR
```

**Testing Approach**: Property-based testing is recommended for preservation checking because:
- It generates many test cases automatically across the input domain
- It catches edge cases that manual unit tests might miss
- It provides strong guarantees that behavior is unchanged for all non-buggy inputs

**Test Plan**: Observe behavior on UNFIXED code first for ERC-20 operations, native receive operations, and utility functions, then write property-based tests capturing that behavior.

**Test Cases**:
1. **ERC-20 Transfer Preservation**: Verify `transfer()` for ERC-20 tokens executes `safeTransfer` identically before and after fix, with no `nativeTrackedTotal` side effects
2. **ERC-20 TransferWithMin Preservation**: Verify `transferWithMin()` for ERC-20 tokens executes identically
3. **ERC-20 Pull Preservation**: Verify `pull()` for ERC-20 tokens executes `safeTransferFrom` with balance-delta accounting identically
4. **ERC-20 PullAtLeast Preservation**: Verify `pullAtLeast()` for ERC-20 tokens executes identically
5. **Native Pull Preservation**: Verify `pull()` for native ETH with `msg.value > 0` increments `nativeTrackedTotal` identically
6. **Native PullAtLeast Preservation**: Verify `pullAtLeast()` for native ETH increments `nativeTrackedTotal` identically
7. **assertMsgValue ERC-20 Preservation**: Verify `assertMsgValue()` for ERC-20 with `msg.value = 0` passes and with `msg.value > 0` reverts, identically
8. **Zero-Amount Transfer Preservation**: Verify `transfer(address(0), to, 0)` returns early without modifying `nativeTrackedTotal`
9. **Zero-Amount Pull Preservation**: Verify `pull(address(0), from, 0)` returns 0 without modifying `nativeTrackedTotal`

### Downstream Double-Decrement Verification

**Goal**: Verify that after pruning Category A sites, no double-decrement occurs and `nativeTrackedTotal` remains correct through full lifecycle flows.

**Test Cases**:
1. **EqualIndex Action Payout**: Execute a full index action lifecycle with native ETH payout, verify `nativeTrackedTotal` decrements exactly once (via library)
2. **EqualIndex Treasury Fee**: Execute treasury fee routing for native pool, verify no double-decrement
3. **EqualIndex Loan Repayment**: Execute native loan repayment, verify tracking stays consistent
4. **EqualX Community Swap Output**: Execute community AMM swap with native output, verify single decrement
5. **EqualX Solo Swap Output**: Execute solo AMM swap with native output, verify single decrement
6. **Options Excess Refund**: Execute options payment with native excess, verify single decrement on refund
7. **LibMaintenance Fee**: Execute maintenance fee collection for native pool, verify single decrement
8. **LibFeeRouter Treasury**: Execute fee router treasury transfer for native pool, verify single decrement
9. **EqualLend Yield Claim**: Execute yield claim from native pool, verify single decrement
10. **EqualLend Withdraw**: Execute principal withdrawal from native pool, verify single decrement
11. **EqualScale Settlement**: Execute settlement transfer for native pool, verify single decrement
12. **SelfSecuredCredit Draw/Surplus**: Execute SSC draw and surplus return for native pool, verify single decrement
13. **LibEqualXCurveEngine Fill**: Execute curve fill with native base/quote, verify single decrement

### Unit Tests

- `transfer()` native: verify `nativeTrackedTotal` decrements by `amount`
- `transfer()` native with `amount = 0`: verify no decrement, no ETH send
- `transferWithMin()` native: verify `nativeTrackedTotal` decrements by `amount`
- `transferWithMin()` native with `amount = 0`: verify no decrement
- `assertMsgValue(address(0), amount)` with `msg.value = amount`: verify passes
- `assertMsgValue(address(0), amount)` with `msg.value = 0` and `amount > 0`: verify reverts
- `assertMsgValue(address(0), 0)` with `msg.value = 0`: verify passes (legitimate zero-amount call)
- `assertMsgValue(erc20, 0)` with `msg.value = 0`: verify passes (ERC-20 path unchanged)
- `assertMsgValue(erc20, amount)` with `msg.value > 0`: verify reverts (ERC-20 path unchanged)

### Property-Based Tests

- Generate random native transfer amounts and verify `nativeTrackedTotal` invariant: after N pulls and M transfers, `nativeTrackedTotal == sum(pulls) - sum(transfers)`
- Generate random `msg.value` and `amount` pairs for `assertMsgValue(address(0), amount)` and verify: passes iff `msg.value == amount`
- Generate random ERC-20 transfer sequences and verify `nativeTrackedTotal` is never modified
- Generate random mixed native/ERC-20 operation sequences and verify `nativeTrackedTotal` tracks only native operations

### Integration Tests

- Full native pool lifecycle: deposit via `pull()` → verify tracking increment → withdraw via `transfer()` → verify tracking decrement → verify `nativeTrackedTotal` returns to original value
- Multi-pool native lifecycle: deposit into pool A and pool B → transfer from pool A → transfer from pool B → verify aggregate `nativeTrackedTotal` is correct
- Orphaned ETH protection: seed contract with orphaned ETH → attempt deposit with `msg.value = 0` → verify revert from `assertMsgValue`
- Downstream pruning smoke test: execute one representative flow from each Category A caller after pruning → verify no underflow and correct final `nativeTrackedTotal`
