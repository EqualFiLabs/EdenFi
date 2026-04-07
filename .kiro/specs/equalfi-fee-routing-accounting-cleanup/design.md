# EqualFi Fee Routing & Accounting Cleanup — Bugfix Design

## Overview

Four audit findings across the EqualFi shared library layer require targeted fixes to maintenance fee distribution, curve fee-split consistency, treasury transfer accounting hardening, and EDEN reward reserve integrity. The fix strategy preserves the current EqualFi substrate model: keep maintenance fee computation on `chargeableTvl` but apply the maintenance index only to chargeable principal; make curve fee splits use the same canonical EqualX maker-share source as the AMM paths; define treasury accounting in terms of pool-side balance delta; and make EDEN reserve deductions follow the gross claim liability actually created by indexed rewards while adding truncation remainder tracking.

Canonical Track: Track C. Fee Routing, Backing Isolation, and Exotic Token Policy
Phase: Phase 1. Shared Accounting Substrate

Source reports:
- `assets/findings/EdenFi-libraries-phase1-pashov-ai-audit-report-20260406-150000.md` (findings 1, 2, 7)
- `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md` (finding 4)

Remediation plan: `assets/remediation/EqualFi-unified-remediation-plan.md` (Track C)
Coding standards: `ETHSKILLS.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across four findings that trigger incorrect maintenance distribution, hardcoded fee splits, FoT accounting drift, and reward reserve drain
- **Property (P)**: The desired correct behavior — fair maintenance charging on chargeable principal, canonical curve splits, treasury accounting anchored to pool-side outflow, and EDEN reserve deductions aligned with indexed gross claim liability
- **Preservation**: Existing maintenance accrual computation, fee index yield settlement, curve execution mechanics, fee router split ratios, and EDEN reward settlement that must remain unchanged
- **`chargeableTvl`**: `totalDeposits - indexEncumberedTotal` — the portion of pool TVL subject to maintenance fees
- **`indexEncumberedTotal`**: Per-pool aggregate of encumbered capital tracked for maintenance exemption
- **`maintenanceIndex`**: Per-pool cumulative index tracking maintenance fee deductions applied to user principals via `LibFeeIndex.settle`
- **`makerBps`**: The canonical EqualX maker-share basis points source consumed by swap and curve fee-splitting paths
- **`trackedBalance`**: Per-pool accounting field backing claimable yield and pool-isolated liquidity checks
- **`fundedReserve`**: Per-EDEN-program reserve tracking gross tokens available to back indexed reward claims
- **`globalRewardIndex`**: Per-EDEN-program cumulative index tracking net reward distribution per unit of eligible supply
- **`REWARD_INDEX_SCALE`**: 1e27 — scaling factor for EDEN reward index precision
- **`netFromGross`**: Function converting gross amount to net after configured outbound transfer fee deduction
- **`grossUpNetAmount`**: Function converting net amount to gross for actual token transfer

## Bug Details

### Bug Condition

The bugs manifest across four distinct conditions in the EqualFi shared library layer. Together they represent incorrect fee distribution, a curve-local fee-split bypass of canonical EqualX policy, treasury accounting ambiguity, and reward reserve drain.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 1: Maintenance index delta divided by totalDeposits instead of chargeableTvl
  IF input.finding == 1 THEN
    RETURN input.context.isMaintenanceAccrual
           AND input.context.indexEncumberedTotal > 0
           AND input.context.chargeableTvl < input.context.totalDeposits

  // Finding 2: Curve engine hardcodes 70/30 fee split
  IF input.finding == 2 THEN
    RETURN input.context.isCurveSwapExecution
           AND input.context.feeAmount > 0

  // Finding 3: Treasury transfer uses nominal amount for trackedBalance with FoT token
  IF input.finding == 3 THEN
    RETURN input.context.isTreasuryTransfer
           AND input.context.isFeeOnTransferToken
           AND input.context.amount > 0

  // Finding 4: Reward accrual deducts gross from fundedReserve but credits net to index
  IF input.finding == 4 THEN
    RETURN input.context.isRewardAccrual
           AND input.context.outboundTransferBps > 0
           AND input.context.allocatedGross > 0

  // Finding 4b: Reward index truncation with no remainder tracking
  IF input.finding == 4 THEN
    RETURN input.context.isRewardAccrual
           AND input.context.allocatedNet > 0
           AND Math.mulDiv(input.context.allocatedNet, REWARD_INDEX_SCALE, input.context.eligibleSupply) == 0

  RETURN false
END FUNCTION
```

### Examples

- **Finding 1**: Pool has `totalDeposits = 1000e18`, `indexEncumberedTotal = 500e18`, `chargeableTvl = 500e18`. Maintenance fee = 10e18 (on 500e18 chargeable). Index delta = `10e18 * 1e18 / 1000e18 = 0.01e18`. User A has `principal = 500e18` and `indexEncumbered = 500e18`; user B has `principal = 500e18` and `indexEncumbered = 0`. Unfixed settle charges both users on full principal, so A pays 5e18 despite being fully index-encumbered and B pays only 5e18 despite holding all chargeable capital. Expected: index delta = `10e18 * 1e18 / 500e18 = 0.02e18`, then settle applies that delta only to each user's chargeable principal, so A pays 0 and B pays the full 10e18.

- **Finding 2**: EqualX adopts a canonical `makerBps = 5000` source for maker/protocol split. AMM swap with 100 USDC fee → `makerFee = 50, protocolFee = 50`. Curve swap with 100 USDC fee → `makerFee = 70, protocolFee = 30` (curve-local hardcoded constant). Expected: curve swap should also produce `makerFee = 50, protocolFee = 50` using the same canonical source as the AMM path.

- **Finding 3**: Pool has `trackedBalance = 1000e18`. Treasury transfer helper is reused for an exotic token with nonstandard sender-side accounting. If one path decrements by nominal `amount` while another future path reasons about what the treasury received, treasury routing becomes inconsistent. Expected: every treasury helper uses the same invariant, namely "debit by the amount that actually left the pool balance."

- **Finding 4 — reserve deducted before index liability is known**: Program with `outboundTransferBps = 500` (5% fee) and very large `eligibleSupply`. Accrual computes `allocatedGross` / `allocatedNet`, then deducts gross reserve before confirming how much net reward can actually be represented in `globalRewardIndex`. If the resulting index delta truncates or partially truncates, reserve is consumed for reward value that never becomes claimable. Expected: reserve is debited only for the gross backing associated with the net amount that actually entered the index, and the undistributed scaled net amount is carried forward as remainder.

- **Finding 4 — truncation**: Program with `eligibleSupply = 1e30`, `allocatedNet = 1e18`. Index delta = `1e18 * 1e27 / 1e30 = 0` (truncated). `fundedReserve` still decreased by `allocatedGross`. Zero claimable produced. Reserve value permanently destroyed.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- `LibMaintenance._accrue` fee computation on `chargeableTvl` must continue to use `(chargeableTvl * rateBps * epochs) / (365 * 10_000)` and reduce `totalDeposits` by `amountAccrued`
- `LibMaintenance._pay` must continue to transfer from `trackedBalance` to the foundation receiver
- `LibMaintenance.enforce` on pools with zero encumbered capital must produce identical behavior (since `chargeableTvl == totalDeposits`)
- `LibFeeIndex.settle` fee yield computation must continue to use `feeBase * (globalIndex - prevIndex) / INDEX_SCALE`
- `LibFeeIndex.settle` for zero-principal users must continue to snap indexes without computing yield
- `LibEqualXCurveEngine.executeCurveSwap` price computation, volume tracking, commitment updates, and position settlement must remain unchanged
- `LibEqualXCurveEngine._applyQuoteSide` must continue to route protocol fees via `LibFeeRouter.routeSamePool` and update `trackedBalance`, `userPrincipal`, `totalDeposits`, and indexes
- `LibEqualXCurveEngine._applyBaseSide` must continue to decrease maker principal, decrease totalDeposits, and unlock collateral
- `LibFeeRouter.routeSamePool` must continue to use `previewSplit` for split ratios
- `LibFeeRouter._transferTreasury` for non-FoT tokens must continue to decrement `trackedBalance` by the full nominal amount
- `LibEdenRewardsEngine.accrueProgram` must continue to compute eligible supply and store updated state
- `LibEdenRewardsEngine.settleProgramPosition` must continue to compute claimable rewards from index delta
- `LibEdenRewardsEngine._previewAccrual` must continue to short-circuit for zero supply, zero reserve, closed, disabled, or paused programs
- `LibEdenRewardsEngine.grossUpNetAmount` and `netFromGross` must remain unchanged

**Scope:**
All inputs that do NOT match any of the four bug conditions should be completely unaffected by these fixes. This includes:
- Maintenance accrual on pools with zero encumbered capital
- AMM swap fee splits (already use `splitFeeWithRouter`)
- Treasury transfers for non-FoT tokens
- EDEN reward accrual with zero `outboundTransferBps`
- All access-control checks and parameter validation

## Hypothesized Root Cause

Based on the audit findings and code analysis:

1. **Finding 1 — Wrong divisor and wrong per-user maintenance base**: The function computes `oldTotal = p.totalDeposits + amount` (the pre-deduction totalDeposits) and divides the scaled fee by `oldTotal`. But the fee was computed on `chargeableTvl` (which excludes index-encumbered capital). Dividing by the larger `oldTotal` dilutes the per-unit delta, spreading it across all depositors. The fix is to pass `chargeableTvl` into `_applyMaintenanceToIndex` and use it as the divisor. Then `LibFeeIndex.settle` should apply maintenance only to each user's chargeable principal, computed from principal minus `LibEncumbrance.getIndexEncumbered(positionKey, pid)`.

2. **Finding 2 — Curve-local fee-share constant**: The curve engine was written with `(preview.feeAmount * 7000) / 10_000` as a literal constant instead of consuming the same canonical EqualX maker-share source used by the AMM fee-split path. The fix is to centralize the maker-share source and have curve execution call `LibEqualXSwapMath.splitFeeWithRouter(fee, makerBps)` with that shared value, then pass only the returned `protocolFee` leg into `routeSamePool`.

3. **Finding 3 — Treasury accounting policy is implicit instead of explicit**: The current helper debits `trackedBalance` by nominal `amount` and comments that this is intended to tolerate fee-on-transfer tokens. That is acceptable only if every treasury helper is explicitly defined in terms of pool-side balance delta. The fix is to encode that invariant directly in the implementation guidance and mirror it across all treasury-routing paths so future variants cannot mix "what left the pool" with "what treasury received."

4. **Finding 4 — Reserve deduction happens before distribution rounding is resolved**: The function computes `allocatedGross` and `allocatedNet`, then deducts reserve before knowing how much net reward can actually be represented in `globalRewardIndex`. When index math truncates, reserve is consumed for undistributed reward value. The fix is to make `_previewAccrual` remainder-aware first, determine the exact net amount actually indexed this round, deduct only the gross backing for that indexed amount, and carry forward the undistributed scaled net amount like `LibFeeIndex.feeIndexRemainder`.

## Correctness Properties

Property 1: Bug Condition — Maintenance index delta uses chargeableTvl as divisor

_For any_ maintenance accrual where `indexEncumberedTotal > 0` (i.e., `chargeableTvl < totalDeposits`), the fixed `_applyMaintenanceToIndex` SHALL compute the index delta as `scaledAmount / chargeableTvl` instead of `scaledAmount / totalDeposits`, ensuring the per-unit maintenance fee is correctly sized for non-encumbered depositors only.

**Validates: Requirements 2.1, 2.3**

Property 2: Bug Condition — Maintenance applies only to chargeable principal in settle

_For any_ call to `LibFeeIndex.settle`, the fixed `settle` SHALL apply the maintenance index only to the user's chargeable principal (`principal - indexEncumbered`, floored at zero), ensuring partially or fully index-encumbered users are not charged on exempt capital.

**Validates: Requirements 2.2**

Property 3: Bug Condition — Curve fee split uses canonical EqualX maker-share source

_For any_ curve swap execution where `feeAmount > 0`, the fixed `_applyQuoteSide` SHALL compute the maker/protocol fee split using `LibEqualXSwapMath.splitFeeWithRouter(fee, makerBps)` with the same canonical maker-share source used by the AMM paths, instead of the curve-local `7000` constant.

**Validates: Requirements 2.4, 2.5**

Property 4: Bug Condition — Treasury transfer uses balance-delta for FoT tokens

_For any_ treasury transfer where the token is a fee-on-transfer token, the fixed `_transferTreasury` SHALL decrement `trackedBalance` by the actual amount that left the pool (measured via balance delta) rather than the nominal amount, preventing progressive accounting drift.

**Validates: Requirements 2.6, 2.7**

Property 5: Bug Condition — Reward accrual deducts reserve only for indexed claim liability

_For any_ reward accrual where `outboundTransferBps > 0`, the fixed `_previewAccrual` SHALL deduct reserve only for the gross backing associated with the net reward amount that actually entered `globalRewardIndex` during that accrual step.

**Validates: Requirements 2.8, 2.10**

Property 6: Bug Condition — Reward index truncation carries forward remainder

_For any_ reward accrual where the index delta truncates to zero, the fixed `_previewAccrual` SHALL carry forward the undistributed scaled amount as a per-program remainder, preventing permanent reserve value destruction from truncation.

**Validates: Requirements 2.9**

Property 7: Preservation — Maintenance accrual computation unchanged

_For any_ maintenance accrual on a pool with zero encumbered capital (`chargeableTvl == totalDeposits`), the fixed code SHALL produce exactly the same behavior as the original code, preserving fee computation, `totalDeposits` reduction, and index delta.

**Validates: Requirements 3.1, 3.2, 3.3**

Property 8: Preservation — Fee index settle yield unchanged

_For any_ call to `LibFeeIndex.settle` that computes fee yield (not maintenance), the fixed code SHALL produce exactly the same yield computation, preserving `feeBase * (globalIndex - prevIndex) / INDEX_SCALE` and `userAccruedYield` / `userClaimableFeeYield` accumulation.

**Validates: Requirements 3.4, 3.5**

Property 9: Preservation — Curve execution mechanics unchanged

_For any_ curve swap execution, the fixed code SHALL preserve price computation, volume tracking, commitment updates, position settlement, base-side processing, and `trackedBalance` / `userPrincipal` / `totalDeposits` updates — only the maker/protocol fee split ratio changes.

**Validates: Requirements 3.6, 3.7, 3.8**

Property 10: Preservation — Fee router split ratios unchanged

_For any_ call to `LibFeeRouter.routeSamePool` or `previewSplit`, the fixed code SHALL produce exactly the same treasury/activeCredit/feeIndex split ratios.

**Validates: Requirements 3.9, 3.10**

Property 11: Preservation — EDEN reward settlement and utility functions unchanged

_For any_ call to `settleProgramPosition`, `accrueProgram` (for zero-supply/zero-reserve/closed/disabled/paused programs), `grossUpNetAmount`, or `netFromGross`, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.11, 3.12, 3.13, 3.14, 3.15**

## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

---

**File**: `src/libraries/LibMaintenance.sol`

**Function**: `_applyMaintenanceToIndex`

**Specific Changes**:
1. **Pass `chargeableTvl` as parameter and use it as divisor (Finding 1)**: Change the function signature to accept `chargeableTvl` and use it instead of `oldTotal` for the index delta computation.

```diff
- function _applyMaintenanceToIndex(LibAppStorage.AppStorage storage, Types.PoolData storage p, uint256 amount)
-     private
- {
+ function _applyMaintenanceToIndex(LibAppStorage.AppStorage storage, Types.PoolData storage p, uint256 amount, uint256 chargeableTvl)
+     private
+ {
      if (amount == 0) return;
-     uint256 oldTotal = p.totalDeposits + amount;
-     if (oldTotal == 0) return;
+     if (chargeableTvl == 0) return;
      uint256 scaledAmount = (amount * 1e18) / 1;
      uint256 dividend = scaledAmount + p.maintenanceIndexRemainder;
-     uint256 delta = dividend / oldTotal;
+     uint256 delta = dividend / chargeableTvl;
      if (delta == 0) {
          p.maintenanceIndexRemainder = dividend;
          return;
      }
-     p.maintenanceIndexRemainder = dividend - (delta * oldTotal);
+     p.maintenanceIndexRemainder = dividend - (delta * chargeableTvl);
      p.maintenanceIndex += delta;
  }
```

**Function**: `_accrue`

**Specific Changes**:
2. **Pass `chargeableTvl` to `_applyMaintenanceToIndex`**: Update the call site to pass the already-computed `chargeableTvl`.

```diff
- _applyMaintenanceToIndex(store, p, amountAccrued);
+ _applyMaintenanceToIndex(store, p, amountAccrued, chargeableTvl);
```

**Function**: `previewState`

**Specific Changes**:
3. **Use `chargeableTvl` as divisor in preview**: Update the preview computation to match the fixed `_applyMaintenanceToIndex`.

```diff
- uint256 oldTotal = totalDepositsAfterAccrual + amountAccrued;
- if (oldTotal == 0) {
+ if (chargeableTvl == 0) {
      return (totalDepositsAfterAccrual, maintenanceIndexAfterAccrual);
  }
  uint256 scaledAmount = (amountAccrued * 1e18) / 1;
  uint256 dividend = scaledAmount + p.maintenanceIndexRemainder;
- uint256 delta = dividend / oldTotal;
+ uint256 delta = dividend / chargeableTvl;
```

---

**File**: `src/libraries/LibFeeIndex.sol`

**Function**: `settle`

**Specific Changes**:
4. **Apply maintenance only to chargeable principal (Finding 1)**: Read the user's index encumbrance via `LibEncumbrance.getIndexEncumbered(positionKey, pid)`, derive `chargeablePrincipal = principal > indexEncumbered ? principal - indexEncumbered : 0`, and compute the maintenance deduction only on that chargeable principal.

```diff
  uint256 globalMaintenanceIndex = p.maintenanceIndex;
  uint256 prevMaintenanceIndex = p.userMaintenanceIndex[user];
  if (globalMaintenanceIndex > prevMaintenanceIndex) {
+     uint256 indexEncumbered = LibEncumbrance.getIndexEncumbered(user, pid);
+     uint256 chargeablePrincipal = principal > indexEncumbered ? principal - indexEncumbered : 0;
+     uint256 maintenanceDelta = globalMaintenanceIndex - prevMaintenanceIndex;
+     uint256 maintenanceFee = Math.mulDiv(chargeablePrincipal, maintenanceDelta, INDEX_SCALE);
+     if (maintenanceFee > 0) {
+         if (maintenanceFee >= principal) {
+             principal = 0;
+             p.userPrincipal[user] = 0;
+         } else {
+             principal -= maintenanceFee;
+             p.userPrincipal[user] = principal;
+         }
+     }
      p.userMaintenanceIndex[user] = globalMaintenanceIndex;
  }
```

Note: The key point is not a blanket "encumbered or not" boolean. The maintenance deduction must scale with the user's chargeable principal, so partial index encumbrance is handled correctly.

---

**File**: `src/libraries/LibEqualXCurveEngine.sol`

**Function**: `_applyQuoteSide`

**Specific Changes**:
5. **Replace hardcoded 70/30 split with configurable `splitFeeWithRouter` (Finding 2)**:

```diff
- uint256 makerFee = (preview.feeAmount * 7000) / 10_000;
- uint256 protocolFee = preview.feeAmount - makerFee;
+ LibEqualXSwapMath.FeeSplit memory feeSplit = LibEqualXSwapMath.splitFeeWithRouter(
+     preview.feeAmount, makerBps
+ );
+ uint256 makerFee = feeSplit.makerFee;
+ uint256 protocolFee = feeSplit.protocolFee;
```

Note: `makerBps` must be resolved from the curve's pool configuration. The implementation task should determine the correct source — likely from `LibAppStorage` or the pool's fee configuration, matching how AMM swaps resolve `makerBps`.

Additionally, since `splitFeeWithRouter` also computes the treasury/ACI/feeIndex sub-split via `LibFeeRouter.previewSplit`, the subsequent `routeSamePool` call may need adjustment to avoid double-splitting the protocol fee. The implementation should verify whether `routeSamePool` re-splits or accepts pre-split amounts.

---

**File**: `src/libraries/LibFeeRouter.sol`

**Function**: `_transferTreasury`

**Specific Changes**:
6. **Use balance-delta accounting for FoT tokens (Finding 3)**:

```diff
  function _transferTreasury(Types.PoolData storage pool, uint256 amount, bool pullFromTracked) private {
      address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
      if (treasury == address(0) || amount == 0) return;
-     uint256 contractBal = LibCurrency.balanceOfSelf(pool.underlying);
-     if (contractBal < amount) {
-         revert InsufficientPrincipal(amount, contractBal);
-     }
+     uint256 balBefore = LibCurrency.balanceOfSelf(pool.underlying);
+     if (balBefore < amount) {
+         revert InsufficientPrincipal(amount, balBefore);
+     }
+     LibCurrency.transfer(pool.underlying, treasury, amount);
+     uint256 balAfter = LibCurrency.balanceOfSelf(pool.underlying);
+     uint256 actualSent = balBefore - balAfter;
      if (pullFromTracked) {
          uint256 tracked = pool.trackedBalance;
-         if (tracked < amount) {
-             revert InsufficientPrincipal(amount, tracked);
+         if (tracked < actualSent) {
+             revert InsufficientPrincipal(actualSent, tracked);
          }
-         pool.trackedBalance = tracked - amount;
+         pool.trackedBalance = tracked - actualSent;
          if (LibCurrency.isNative(pool.underlying)) {
-             LibAppStorage.s().nativeTrackedTotal -= amount;
+             LibAppStorage.s().nativeTrackedTotal -= actualSent;
          }
      }
-     LibCurrency.transfer(pool.underlying, treasury, amount);
  }
```

Note: The transfer is moved before the `trackedBalance` decrement so we can measure the actual balance change. For non-FoT tokens, `actualSent == amount`, so behavior is unchanged.

Also apply the same pattern to `_routeSystemShareToTreasury` which has a duplicate treasury transfer path.

---

**File**: `src/libraries/LibEdenRewardsEngine.sol`

**Function**: `_previewAccrual`

**Specific Changes**:
7. **Debit `fundedReserve` only for rewards actually indexed this round (Finding 4)**:

```diff
- // Do not debit fundedReserve yet. First resolve how much reward actually enters the index.
```

8. **Add remainder tracking for truncated index deltas (Finding 4)**:

```diff
  if (allocatedNet > 0) {
-     state.fundedReserve -= allocatedGross;
-     state.globalRewardIndex += Math.mulDiv(
-         allocatedNet, LibEdenRewardsStorage.REWARD_INDEX_SCALE, state.eligibleSupply
-     );
+     uint256 scaledReward = Math.mulDiv(allocatedNet, LibEdenRewardsStorage.REWARD_INDEX_SCALE, 1);
+     uint256 dividend = scaledReward + state.rewardIndexRemainder;
+     uint256 delta = dividend / state.eligibleSupply;
+     if (delta > 0) {
+         state.globalRewardIndex += delta;
+         state.rewardIndexRemainder = dividend - (delta * state.eligibleSupply);
+         uint256 indexedNet = Math.mulDiv(delta, state.eligibleSupply, LibEdenRewardsStorage.REWARD_INDEX_SCALE);
+         state.fundedReserve -= grossUpNetAmount(indexedNet, config.outboundTransferBps);
+     } else {
+         // Truncated to zero — carry forward remainder, do NOT deduct from fundedReserve
+         state.rewardIndexRemainder = dividend;
+     }
  }
```

Note: This requires adding a `rewardIndexRemainder` field to `LibEdenRewardsStorage.RewardProgramState`. The storage layout change must be compatible with existing deployed state (append-only struct extension).

### Dependencies

- Track A (Native Asset Tracking) should land first or concurrently — the `_transferTreasury` fix interacts with `nativeTrackedTotal` accounting
- Track B (ACI/Encumbrance) should land first or concurrently — the maintenance exemption fix depends on per-user encumbrance tracking being correct
- This spec is a prerequisite for the Phase 3 EDEN reward-backing redesign
- The `rewardIndexRemainder` storage addition must be append-only to avoid storage collision with existing deployed state

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real deposits, real swaps, real fee accruals, and real reward program lifecycles per workspace guidelines.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes. Confirm or refute the root cause analysis.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures and understand the root cause.

**Test Cases**:
1. **Maintenance Chargeable-Principal Overcharge Test**: Create a pool with 50% index-encumbered capital, accrue maintenance, settle users with mixed encumbrance, assert the fully or partially index-encumbered user is charged on full principal (will demonstrate finding 1 on unfixed code — maintenance should only hit chargeable principal).
2. **Curve Hardcoded Fee Split Test**: Set the canonical EqualX `makerBps` source to 5000 (50/50), execute a curve swap, assert maker receives 70% of fee (will demonstrate finding 2 on unfixed code — should receive 50%).
3. **Treasury Accounting Policy Consistency Test**: Create an exotic-token mock and execute every treasury helper path, assert the helpers do not share one explicit sender-side accounting rule (will demonstrate finding 3 on unfixed code if helpers diverge or future variants inherit the wrong policy).
4. **Reward Indexed-Liability Reserve Test**: Create an EDEN program with `outboundTransferBps > 0`, fund it, accrue rewards under parameters that cause partial index truncation, assert `fundedReserve` decreased by more than the gross backing associated with rewards that actually entered the index (will demonstrate finding 4 on unfixed code).
5. **Reward Truncation Loss Test**: Create an EDEN program with very large `eligibleSupply` and small reward rate, accrue, assert `fundedReserve` decreased but `globalRewardIndex` unchanged (will demonstrate finding 4b on unfixed code).

**Expected Counterexamples**:
- Finding 1: Maintenance charged on full principal instead of chargeable principal
- Finding 2: Maker received 70% of curve fee despite canonical EqualX setting 50%
- Finding 3: Treasury helper paths do not share one explicit sender-side accounting rule
- Finding 4: `fundedReserve` decreased by more than the gross backing associated with indexed rewards
- Finding 4b: `fundedReserve` decreased with zero index growth

### Fix Checking

**Goal**: Verify that for all inputs where each bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Finding 1
FOR ALL maintenanceAccrual WHERE indexEncumberedTotal > 0 DO
  result := _applyMaintenanceToIndex_fixed(amount, chargeableTvl)
  ASSERT indexDelta == scaledAmount / chargeableTvl
  // And in settle:
  FOR ALL user DO
    chargeablePrincipal := max(0, userPrincipal[user] - indexEncumbered[user])
    settle_fixed(pid, user)
    ASSERT maintenanceCharged[user] == maintenanceDelta * chargeablePrincipal / INDEX_SCALE
  END FOR
END FOR

// Finding 2
FOR ALL curveSwap WHERE feeAmount > 0 DO
  result := _applyQuoteSide_fixed(curveId, preview, amountIn)
  ASSERT makerFee == feeAmount * makerBps / 10_000
  ASSERT protocolFee == feeAmount - makerFee
END FOR

// Finding 3
FOR ALL treasuryTransfer WHERE isFoT(token) DO
  trackedBefore := pool.trackedBalance
  _transferTreasury_fixed(pool, amount, pullFromTracked)
  actualSent := balBefore - balAfter
  ASSERT pool.trackedBalance == trackedBefore - actualSent
END FOR

// Finding 4
FOR ALL rewardAccrual WHERE outboundTransferBps > 0 DO
  reserveBefore := state.fundedReserve
  state := _previewAccrual_fixed(config, state, timestamp)
  ASSERT reserveBefore - state.fundedReserve == grossBackingForIndexedNet
END FOR

// Finding 4b
FOR ALL rewardAccrual WHERE indexDelta truncates to 0 DO
  reserveBefore := state.fundedReserve
  state := _previewAccrual_fixed(config, state, timestamp)
  ASSERT state.fundedReserve == reserveBefore  // no deduction when truncated
  ASSERT state.rewardIndexRemainder > 0  // remainder carried forward
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

**Test Cases**:
1. **Maintenance Zero-Encumbrance Preservation**: Accrue maintenance on a pool with zero encumbered capital, verify index delta and `totalDeposits` reduction are identical to unfixed code
2. **Maintenance Pay Preservation**: Verify `_pay` transfers to foundation receiver identically
3. **Fee Index Settle Yield Preservation**: Verify fee yield computation is unchanged for non-encumbered users
4. **Curve Execution Mechanics Preservation**: Verify price computation, volume tracking, commitment updates, and position settlement are unchanged
5. **Fee Router Split Preservation**: Verify `previewSplit` and `routeSamePool` split ratios are unchanged
6. **Treasury Non-FoT Preservation**: Verify `_transferTreasury` for standard ERC-20 tokens decrements `trackedBalance` by full nominal amount (since `actualSent == amount`)
7. **EDEN Reward Settlement Preservation**: Verify `settleProgramPosition` claimable computation is unchanged
8. **EDEN Reward Short-Circuit Preservation**: Verify `_previewAccrual` short-circuits for zero supply, zero reserve, closed, disabled, paused programs
9. **EDEN Gross/Net Utility Preservation**: Verify `grossUpNetAmount` and `netFromGross` are unchanged

### Unit Tests

- `_applyMaintenanceToIndex` with `chargeableTvl < totalDeposits`: verify delta = `scaledAmount / chargeableTvl`
- `_applyMaintenanceToIndex` with `chargeableTvl == totalDeposits`: verify identical to unfixed behavior
- `LibFeeIndex.settle` for mixed encumbrance: verify maintenance deduction uses chargeable principal only
- `LibFeeIndex.settle` for non-encumbered user: verify maintenance deduction unchanged
- `_applyQuoteSide` with `makerBps = 5000`: verify 50/50 split
- `_applyQuoteSide` with `makerBps = 7000`: verify 70/30 split (same as hardcoded — regression)
- `_transferTreasury` with exotic token mock: verify `trackedBalance` follows the explicit pool-side balance-delta rule
- `_transferTreasury` with standard token: verify `trackedBalance` decremented by nominal amount
- `_previewAccrual` with `outboundTransferBps > 0`: verify `fundedReserve` decremented by gross backing for indexed rewards only
- `_previewAccrual` with `outboundTransferBps == 0`: verify behavior unchanged (gross == net)
- `_previewAccrual` with truncated index delta: verify remainder carried forward, no reserve deduction

### Integration Tests

- Full maintenance lifecycle with mixed encumbered/non-encumbered users: deposit → index-encumber → accrue maintenance → settle all users → verify chargeable-principal-only charging
- Curve swap with canonical fee-split change: create curve → change canonical `makerBps` source → execute swap → verify new split applied
- Treasury transfer lifecycle with exotic token accounting edge: deposit token → route fees → transfer treasury → verify `trackedBalance` accuracy under the explicit pool-side rule
- EDEN reward lifecycle with FoT reward token: create program → fund → accrue over multiple cycles → claim → verify `fundedReserve` tracks the gross liability created by indexed rewards
- EDEN reward truncation recovery: create program with large supply → accrue small amounts → verify remainder accumulates → accrue enough to produce non-zero delta → verify remainder consumed
