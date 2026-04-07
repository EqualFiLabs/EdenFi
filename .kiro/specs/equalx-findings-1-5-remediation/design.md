# EqualX Findings 1-5 Remediation — Bugfix Design

## Overview

Five audit findings in the EqualX AMM contracts require targeted fixes across Solo AMM swap-time accounting, Solo AMM close-time reconciliation, Community AMM share economics, and Solo AMM cancel lifecycle. The fix strategy preserves the current EqualFi substrate model: keep pool accounting live during active markets, make close-time settlement a reconciliation step rather than the first time correctness is established, keep Community AMM share issuance proportional to current pool state, and align Solo AMM cancel semantics with market expectations once trading can occur.

Source report: `assets/findings/EdenFi-equalx-pashov-ai-audit-report-20260405-002000.md`
Remediation plan: `assets/remediation/EqualX-findings-1-5-remediation-plan.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across five findings that trigger incorrect accounting, share inflation, or lifecycle violations in EqualX AMM contracts
- **Property (P)**: The desired correct behavior for each finding — live fee backing, synchronized ACI, deterministic close, proportional shares, and guarded cancellation
- **Preservation**: Existing swap output computation, treasury fee handling, finalization flow, rebalance mechanics, community swap/join/leave flows, and access control that must remain unchanged
- **`trackedBalance`**: Per-pool accounting field in `Types.PoolData` that backs claimable yield and pool-isolated liquidity checks
- **`nativeTrackedTotal`**: Global accounting field in `LibAppStorage` tracking total native-token backing across all pools
- **`encumberedCapital`**: Per-position per-pool field in `LibEncumbrance.Encumbrance` tracking capital committed to AMM reserves
- **`activeCreditPrincipalTotal`**: Per-pool field in `Types.PoolData` tracking aggregate encumbrance for ACI weighting
- **ACI**: Active Credit Index — yield-weighting mechanism that distributes active-credit yield proportional to encumbrance duration and size
- **`_applyReserveDelta`**: Internal function in `EqualXSoloAmmFacet` that adjusts `encumberedCapital` when reserves change during swaps
- **`_closeMarket`**: Internal function in `EqualXSoloAmmFacet` that settles ACI, unlocks backing, reconciles principal, and deactivates a Solo AMM market
- **`routeSamePool`**: Function in `LibFeeRouter` that splits protocol fees into treasury, active-credit, and fee-index portions

## Bug Details

### Bug Condition

The bugs manifest across five distinct conditions in the EqualX AMM contracts. Together they represent stale live accounting, non-deterministic close reconciliation, inflationary share minting, and missing lifecycle guards.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 1: Solo swap routes non-treasury protocol fees but trackedBalance is not incremented
  IF input.finding == 1 THEN
    RETURN input.context.isSoloAmmSwap
           AND input.context.protocolFeeRouted > 0
           AND (input.context.toActive + input.context.toFeeIndex) > 0

  // Finding 2: Solo swap changes reserves but ACI is not updated
  IF input.finding == 2 THEN
    RETURN input.context.isSoloAmmSwap
           AND input.context.reserveDelta != 0

  // Finding 3: Close subtracts fees conditionally, skipping when reserve < fee
  IF input.finding == 3 THEN
    RETURN input.context.isSoloAmmClose
           AND (input.context.totalProtocolFeeSideA > input.context.reserveA
                OR input.context.totalProtocolFeeSideB > input.context.reserveB)

  // Finding 4: Join uses sqrt instead of proportional formula
  IF input.finding == 4 THEN
    RETURN input.context.isCommunityAmmJoin
           AND input.context.totalShares > 0

  // Finding 5: Cancel allowed at or after startTime
  IF input.finding == 5 THEN
    RETURN input.context.isSoloAmmCancel
           AND input.context.blockTimestamp >= input.context.marketStartTime

  RETURN false
END FUNCTION
```

### Examples

- **Finding 1**: Solo AMM swap routes 100 USDC protocol fee → `toActive=40, toFeeIndex=40, toTreasury=20`. Expected: fee-pool `trackedBalance` increases by 80. Actual: `trackedBalance` unchanged until `_closeMarket`.
- **Finding 2**: Solo AMM swap moves reserveA from 1000 to 1050 (+50 delta). Expected: `activeCreditPrincipalTotal` increases by 50 via `applyEncumbranceIncrease`. Actual: `activeCreditPrincipalTotal` unchanged; only `enc.encumberedCapital` moves.
- **Finding 3**: After heavy one-sided trading, reserveA = 30, `feeIndexFeeAAccrued = 25`, `activeCreditFeeAAccrued = 20`. Total protocol fee = 45 > 30. Expected: `reserveAForPrincipal = 0` (clamped). Actual: first conditional subtracts 25 → 5, second conditional skips (5 < 20), `reserveAForPrincipal = 5` with 20 of protocol fee left inside principal.
- **Finding 4**: Community AMM market has `reserveA=1100, reserveB=1100, totalShares=1000` after fee growth. Joiner contributes `amountA=100, amountB=100`. Expected: `share = min(100*1000/1100, 100*1000/1100) ≈ 90`. Actual: `share = sqrt(100*100) = 100`, diluting existing makers.
- **Finding 5**: Maker calls `cancelEqualXSoloAmmMarket` at `block.timestamp = startTime + 1`. Expected: revert. Actual: market cancelled, liquidity pulled from live trading.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Solo AMM swap output computation, fee splitting, maker fee accrual, and recipient payout must continue to work exactly as before
- Solo AMM treasury fee accrual must continue to NOT increment `trackedBalance`
- Solo AMM `_closeMarket` with zero accrued protocol fees must settle ACI, unlock backing, decrease encumbrance, and reconcile principal identically
- Solo AMM `finalizeEqualXSoloAmmMarket` after `endTime` must continue to close the market normally
- Solo AMM cancel before `startTime` must continue to be allowed
- Non-owner cancel must continue to revert with ownership error
- Solo AMM rebalance scheduling and execution must continue to apply reserve and baseline deltas correctly
- Community AMM swap fee routing with live `trackedBalance` increments must remain unchanged
- Community AMM initial join (`totalShares == 0`) must continue to use `sqrt(amountA * amountB)` bootstrap formula
- Community AMM join must continue to lock backing, update reserves, snapshot fee indexes, and emit events
- Community AMM leave must continue to burn shares, unlock backing, settle fees, and return capital

**Scope:**
All inputs that do NOT match any of the five bug conditions should be completely unaffected by these fixes. This includes:
- Solo AMM swaps that route zero protocol fees
- Solo AMM close with zero accrued fees
- Community AMM swaps (already have live `trackedBalance` increments)
- Community AMM initial liquidity provision
- All access-control checks and parameter validation

## Hypothesized Root Cause

Based on the audit findings and code analysis:

1. **Finding 1 — Missing live `trackedBalance` increment**: `swapEqualXSoloAmmExactIn` calls `_accrueProtocolFees` which only records fee amounts on the market struct (`activeCreditFeeAAccrued`, `feeIndexFeeAAccrued`). Unlike `swapEqualXCommunityAmmExactIn` which increments `feePool.trackedBalance += toActive + toIndex` inline, the Solo path has no equivalent increment. The deferred top-up in `_closeMarket` was likely intended as the settlement point but leaves pool accounting stale during the market's lifetime.

2. **Finding 2 — Missing ACI sync in `_applyReserveDelta`**: The function adjusts `enc.encumberedCapital` directly but does not call `LibActiveCreditIndex.applyEncumbranceIncrease/Decrease`. The Community AMM does not have this issue because its reserves are not tracked via per-position encumbrance in the same way. The Solo AMM's `_applyReserveDelta` was written as a pure encumbrance bookkeeping function without awareness of the ACI dependency.

3. **Finding 3 — Conditional per-fee subtraction**: `_closeMarket` subtracts `feeIndexFeeAccrued` and `activeCreditFeeAccrued` in two separate conditional blocks, each guarded by `reserve >= feeAccrued`. When cumulative fees exceed the reserve, the first subtraction succeeds but leaves insufficient reserve for the second, which is then skipped. The protocol fee amount that was skipped remains inside `reserveForPrincipal`, inflating the maker's returned principal.

4. **Finding 4 — `sqrt` share formula on subsequent joins**: `joinEqualXCommunityAmmMarket` always uses `Math.sqrt(Math.mulDiv(amountA, amountB, 1))` regardless of whether `totalShares > 0`. This formula is correct for the initial bootstrap case but does not account for reserve growth from retained fees on subsequent joins, granting new joiners disproportionate ownership.

5. **Finding 5 — Missing time guard on cancel**: `cancelEqualXSoloAmmMarket` checks ownership and market existence but does not check `block.timestamp < market.startTime`. The Community AMM has equivalent guards, but the Solo AMM cancel path was not similarly protected.

## Correctness Properties

Property 1: Bug Condition — Solo AMM live fee-backing accounting

_For any_ Solo AMM swap where `LibFeeRouter.routeSamePool` routes non-treasury protocol fees (`toActive + toFeeIndex > 0`), the fixed `swapEqualXSoloAmmExactIn` SHALL increment the fee-pool `trackedBalance` by `toActive + toFeeIndex` (and `nativeTrackedTotal` when the fee pool underlying is native) immediately at swap time, and `_closeMarket` SHALL NOT re-credit these amounts.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — Solo AMM live ACI synchronization

_For any_ Solo AMM swap where `_applyReserveDelta` changes `enc.encumberedCapital`, the fixed `_applyReserveDelta` SHALL call `LibActiveCreditIndex.applyEncumbranceIncrease` on reserve increases and `LibActiveCreditIndex.applyEncumbranceDecrease` on reserve decreases, keeping `activeCreditPrincipalTotal` synchronized with encumbrance.

**Validates: Requirements 2.3, 2.4**

Property 3: Bug Condition — Solo AMM deterministic close-time fee subtraction

_For any_ Solo AMM market close where cumulative protocol fees on a side exceed the remaining reserve, the fixed `_closeMarket` SHALL compute `reserveForPrincipal = reserve > totalProtocol ? reserve - totalProtocol : 0` using a single clamped subtraction per side, preventing protocol-fee amounts from remaining inside maker principal.

**Validates: Requirements 2.5**

Property 4: Bug Condition — Community AMM proportional share minting

_For any_ Community AMM join where `totalShares > 0`, the fixed `joinEqualXCommunityAmmMarket` SHALL mint shares using `share = min(amountA * totalShares / reserveA, amountB * totalShares / reserveB)` instead of `sqrt(amountA * amountB)`, ensuring proportional ownership relative to current pool state.

**Validates: Requirements 2.6**

Property 5: Bug Condition — Solo AMM cancel time guard

_For any_ call to `cancelEqualXSoloAmmMarket` where `block.timestamp >= market.startTime`, the fixed function SHALL revert, preventing cancellation of a market once trading can occur.

**Validates: Requirements 2.7**

Property 6: Preservation — Solo AMM swap mechanics

_For any_ Solo AMM swap that does NOT trigger the bug conditions (e.g., swaps with zero protocol fees, or the swap output/fee-split/maker-fee/payout path), the fixed code SHALL produce exactly the same behavior as the original code, preserving swap output computation, fee splitting, treasury accrual, maker fee accrual, and recipient payout.

**Validates: Requirements 3.1, 3.2**

Property 7: Preservation — Solo AMM close/finalize/cancel lifecycle

_For any_ Solo AMM close with zero accrued protocol fees, finalization after `endTime`, cancel before `startTime`, or non-owner cancel attempt, the fixed code SHALL produce exactly the same behavior as the original code, preserving settlement, access control, and lifecycle semantics.

**Validates: Requirements 3.3, 3.4, 3.5, 3.6**

Property 8: Preservation — Community AMM flows

_For any_ Community AMM swap, initial join (`totalShares == 0`), subsequent join mechanics (backing, reserves, snapshots), or leave, the fixed code SHALL produce exactly the same behavior as the original code, preserving swap routing, bootstrap share formula, join bookkeeping, and leave settlement.

**Validates: Requirements 3.8, 3.9, 3.10, 3.11**


## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

**File**: `src/equalx/EqualXSoloAmmFacet.sol`

**Function**: `swapEqualXSoloAmmExactIn`

**Specific Changes**:
1. **Live `trackedBalance` increment (Finding 1)**: After `LibFeeRouter.routeSamePool(...)` returns `(toTreasury, toActive, toFeeIndex)`, add:
   - Load the fee pool via `LibPositionHelpers.pool(ctx.feePoolId)`
   - Compute `backingIncrease = toActive + toFeeIndex`
   - If `backingIncrease > 0`, increment `feePool.trackedBalance += backingIncrease`
   - If the fee pool underlying is native, increment `LibAppStorage.s().nativeTrackedTotal += backingIncrease`
   - This mirrors the existing pattern in `swapEqualXCommunityAmmExactIn`

**Function**: `_applyReserveDelta`

**Specific Changes**:
2. **ACI sync on encumbrance changes (Finding 2)**: Modify `_applyReserveDelta` to accept `poolId` as a resolvable pool reference and call ACI:
   - Load `Types.PoolData storage pool = LibPositionHelpers.pool(poolId)`
   - When `newReserve > previousReserve`: after incrementing `enc.encumberedCapital`, call `LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, makerPositionKey, delta)`
   - When `newReserve < previousReserve`: after decrementing `enc.encumberedCapital`, call `LibActiveCreditIndex.applyEncumbranceDecrease(pool, poolId, makerPositionKey, delta)`

**Function**: `_closeMarket`

**Specific Changes**:
3. **Remove deferred `trackedBalance` top-up (Finding 1 close-side)**: Remove the `protocolYieldA`/`protocolYieldB` blocks that increment `trackedBalance` at close time, since this backing is now recognized live during swaps.

4. **Clamped total-fee subtraction (Finding 3)**: Replace the four conditional per-fee subtraction blocks with:
   ```
   uint256 totalProtocolA = market.feeIndexFeeAAccrued + market.activeCreditFeeAAccrued;
   reserveAForPrincipal = market.reserveA > totalProtocolA ? market.reserveA - totalProtocolA : 0;

   uint256 totalProtocolB = market.feeIndexFeeBAccrued + market.activeCreditFeeBAccrued;
   reserveBForPrincipal = market.reserveB > totalProtocolB ? market.reserveB - totalProtocolB : 0;
   ```

**Function**: `cancelEqualXSoloAmmMarket`

**Specific Changes**:
5. **Time guard (Finding 5)**: Add before `_closeMarket` call:
   ```
   if (block.timestamp >= market.startTime) {
       revert EqualXSoloAmm_MarketStarted(marketId);
   }
   ```

---

**File**: `src/equalx/EqualXCommunityAmmFacet.sol`

**Function**: `joinEqualXCommunityAmmMarket`

**Specific Changes**:
6. **Proportional share formula (Finding 4)**: Replace `uint256 share = Math.sqrt(Math.mulDiv(amountA, amountB, 1))` with:
   ```
   uint256 share;
   if (market.totalShares == 0) {
       share = Math.sqrt(Math.mulDiv(amountA, amountB, 1));
   } else {
       uint256 shareA = Math.mulDiv(amountA, market.totalShares, market.reserveA);
       uint256 shareB = Math.mulDiv(amountB, market.totalShares, market.reserveB);
       share = shareA < shareB ? shareA : shareB;
   }
   ```

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real deposits, real market creation, real swaps, real joins, real leaves, real finalization, and real yield claims per workspace guidelines.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes. Confirm or refute the root cause analysis. If we refute, we will need to re-hypothesize.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures and understand the root cause.

**Test Cases**:
1. **Solo Swap TrackedBalance Test**: Create a Solo AMM market, execute a swap, check that `trackedBalance` did NOT increase by protocol fees (will demonstrate finding 1 on unfixed code)
2. **Solo Swap ACI Sync Test**: Create a Solo AMM market, execute a swap, check that `activeCreditPrincipalTotal` did NOT change despite reserve movement (will demonstrate finding 2 on unfixed code)
3. **Solo Close Skewed Fees Test**: Create a Solo AMM market, execute many one-sided swaps to skew reserves, close the market, check that `reserveForPrincipal` retains protocol-fee amounts (will demonstrate finding 3 on unfixed code)
4. **Community Join After Growth Test**: Create a Community AMM market, execute swaps to grow reserves, join with new maker, check that shares are disproportionate (will demonstrate finding 4 on unfixed code)
5. **Solo Cancel After Start Test**: Create a Solo AMM market, warp past `startTime`, attempt cancel, check that it succeeds (will demonstrate finding 5 on unfixed code)

**Expected Counterexamples**:
- Finding 1: `trackedBalance` unchanged after swap despite non-zero `toActive + toFeeIndex`
- Finding 2: `activeCreditPrincipalTotal` unchanged after swap despite reserve delta
- Finding 3: `reserveForPrincipal > 0` when it should be 0 due to cumulative fees exceeding reserve
- Finding 4: New joiner receives `sqrt`-based shares exceeding proportional ownership
- Finding 5: Cancel succeeds after `startTime`

### Fix Checking

**Goal**: Verify that for all inputs where each bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Finding 1
FOR ALL soloSwap WHERE protocolFeeRouted > 0 DO
  trackedBefore := feePool.trackedBalance
  result := swapEqualXSoloAmmExactIn_fixed(soloSwap)
  ASSERT feePool.trackedBalance == trackedBefore + toActive + toFeeIndex
END FOR

// Finding 2
FOR ALL soloSwap WHERE reserveDelta != 0 DO
  aciTotalBefore := pool.activeCreditPrincipalTotal
  result := swapEqualXSoloAmmExactIn_fixed(soloSwap)
  ASSERT pool.activeCreditPrincipalTotal == aciTotalBefore + reserveDelta (signed)
END FOR

// Finding 3
FOR ALL soloClose WHERE totalProtocolFee > reserve DO
  result := _closeMarket_fixed(market)
  ASSERT reserveForPrincipal == 0
END FOR

// Finding 4
FOR ALL communityJoin WHERE totalShares > 0 DO
  result := joinEqualXCommunityAmmMarket_fixed(join)
  ASSERT share == min(amountA * totalShares / reserveA, amountB * totalShares / reserveB)
END FOR

// Finding 5
FOR ALL soloCancel WHERE block.timestamp >= startTime DO
  ASSERT REVERTS cancelEqualXSoloAmmMarket_fixed(cancel)
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

**Test Plan**: Observe behavior on UNFIXED code first for non-bug inputs, then write property-based tests capturing that behavior.

**Test Cases**:
1. **Solo Swap Output Preservation**: Verify swap output amounts, fee splits, maker fee accrual, and recipient payouts are identical before and after fix for any valid swap
2. **Solo Treasury Fee Preservation**: Verify treasury fee accrual does not touch `trackedBalance` before or after fix
3. **Solo Close Zero-Fee Preservation**: Verify close with zero accrued fees produces identical settlement before and after fix
4. **Solo Finalize Preservation**: Verify finalization after `endTime` works identically
5. **Solo Cancel Before Start Preservation**: Verify cancel before `startTime` works identically
6. **Community Swap Preservation**: Verify community swap fee routing and `trackedBalance` increments are identical
7. **Community Initial Join Preservation**: Verify `sqrt` bootstrap formula still used when `totalShares == 0`
8. **Community Leave Preservation**: Verify leave burns shares, unlocks backing, settles fees identically

### Unit Tests

- Solo AMM swap `trackedBalance` increment for each fee-pool side (tokenA fee pool, tokenB fee pool)
- Solo AMM swap `trackedBalance` increment with native underlying
- Solo AMM `_applyReserveDelta` ACI sync on increase and decrease
- Solo AMM `_applyReserveDelta` ACI sync with alternating swap directions
- Solo AMM `_closeMarket` clamped subtraction when fees exceed reserve on side A, side B, and both sides
- Solo AMM `_closeMarket` no double-count of `trackedBalance` after live swap accounting
- Community AMM proportional share minting after reserve growth
- Community AMM proportional share minting preserves existing maker ownership
- Solo AMM cancel revert at `startTime`, after `startTime`
- Solo AMM cancel success before `startTime`

### Property-Based Tests

- Generate random Solo AMM swap sequences and verify `trackedBalance` invariant: `trackedBalance` increases by exactly `sum(toActive + toFeeIndex)` across all swaps
- Generate random Solo AMM swap sequences and verify ACI invariant: `activeCreditPrincipalTotal` matches sum of all position encumbrances
- Generate random fee/reserve ratios for Solo AMM close and verify `reserveForPrincipal <= max(0, reserve - totalProtocolFee)` always holds
- Generate random Community AMM join amounts after random swap sequences and verify `newShare / totalSharesAfter <= amountA / reserveA` (no dilution)
- Generate random timestamps around `startTime` boundary and verify cancel reverts iff `timestamp >= startTime`

### Integration Tests

- Full Solo AMM lifecycle: create → swap (verify live accounting) → finalize → claim yield — proves finding 1 and 2 fixes end-to-end
- Solo AMM skewed lifecycle: create → many one-sided swaps → finalize — proves finding 3 fix with real reserve depletion
- Community AMM post-growth join: create → swap → join → leave — proves finding 4 fix with real fee-driven reserve growth
- Solo AMM cancel lifecycle: create → warp past start → attempt cancel (revert) → warp before start → cancel (success) — proves finding 5 fix
- Multi-swap Solo AMM with alternating directions: create → swap A→B → swap B→A → swap A→B → finalize — proves ACI stays consistent through direction changes
