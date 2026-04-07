# EqualIndex Collateral and Mint/Burn Integrity — Bugfix Design

## Overview

Nine remediation items in the EqualFi EqualIndex contracts require targeted fixes across position-mode burn encumbrance gating, position-mode burn encumbrance release, burn-fee rounding policy, fee-share governance setters, admin timelock fallback, recovery grace period, maintenance-exempt locked collateral, exact-pull wallet-mode mint, and position-mint fee-routing pre-credit. The fix strategy preserves the existing EqualIndex lifecycle model while correcting collateral bypass, accounting leaks, rounding bias, governance gaps, access-control inconsistency, maturity-boundary races, maintenance erosion of locked collateral, surplus token stranding, and false liquidity failures.

Canonical Track: Track G. EqualIndex Collateral and Mint/Burn Integrity
Phase: Phase 2. Product Lifecycle Fixes

Source report: `assets/findings/EdenFi-equalindex-pashov-ai-audit-report-20260405-020000.md`
Remediation plan: `assets/remediation/EqualIndex-findings-1-2-6-8-remediation-plan.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across nine items that trigger collateral bypass, encumbrance leak, rounding bias, governance lock, admin access failure, maturity-boundary race, maintenance erosion, surplus stranding, or false liquidity failure
- **Property (P)**: The desired correct behavior for each item
- **Preservation**: Existing mint, burn, borrow, repay, recovery, admin, fee routing, and flash loan flows that must remain unchanged
- **`availablePrincipal`**: Unencumbered index-pool principal computed via `LibPositionHelpers.availablePrincipal(pool, positionKey, poolId)`
- **`LibIndexEncumbrance`**: Library tracking index-encumbered principal per position and pool, wrapping `LibEncumbrance.encumberIndex/unencumberIndex`
- **`navOut`**: Payout-derived vault output computed as `mulDiv(payout, bundleOut, gross)` — currently used as the unencumbrance amount in position burn
- **`bundleOut`**: The actual underlying principal being removed from the index vault on a burn leg
- **`poolFeeShareBps`**: Fee-share parameter controlling what fraction of mint/burn fees goes to the underlying pool vs the fee pot
- **`mintBurnFeeIndexShareBps`**: Fee-share parameter controlling what fraction of wallet-mode fees goes to the index fee pot vs the pool
- **`onlyTimelock`**: EqualIndex's local modifier that requires `msg.sender == timelockAddress` with no owner fallback
- **`enforceTimelockOrOwnerIfUnset()`**: Shared `LibAccess` pattern that falls back to owner when timelock is `address(0)`
- **`RECOVERY_GRACE_PERIOD`**: New constant defining the post-maturity window before permissionless recovery becomes available
- **`userIndexEncumberedPrincipal`**: New per-user mapping tracking loan-locked collateral that is exempt from maintenance fee deduction during `LibFeeIndex` settlement and preview
- **`routeManagedShare`**: `LibFeeRouter` function that routes pool-share fees through treasury and downstream splits

## Bug Details

### Bug Condition

The bugs manifest across nine distinct conditions in the EqualIndex contracts. Together they represent collateral bypass, progressive encumbrance leak, systematic rounding bias, governance lock, access-control inconsistency, maturity-boundary race, maintenance erosion, surplus stranding, and false liquidity failure.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 1: burnFromPosition allows burn of encumbered index-pool principal
  IF input.finding == 1 THEN
    RETURN input.context.isBurnFromPosition
           AND input.context.units > input.context.availableUnencumbered

  // Finding 2: Position burn unencumbers navOut instead of bundleOut
  IF input.finding == 2 THEN
    RETURN input.context.isPositionBurn
           AND input.context.burnFeeBps > 0
           AND input.context.navOut < input.context.bundleOut

  // Finding 6: Burn fee uses floor rounding instead of ceil
  IF input.finding == 6 THEN
    RETURN (input.context.isWalletBurn OR input.context.isPositionBurn)
           AND input.context.burnFeeHasRemainder
           AND input.context.roundingDirection == FLOOR

  // Finding 8: Fee-share parameters have no setter
  IF input.finding == 8 THEN
    RETURN input.context.isSetFeeShareBps
           AND input.context.noSetterExists

  // Lead: Admin timelock fallback missing
  IF input.finding == 9 THEN
    RETURN (input.context.isSetPaused OR input.context.isConfigureLending OR input.context.isConfigureBorrowFeeTiers)
           AND input.context.timelockAddress == address(0)
           AND input.context.callerIsOwner

  // Lead: Recovery has no grace period
  IF input.finding == 10 THEN
    RETURN input.context.isRecoverExpiredIndexLoan
           AND input.context.blockTimestamp > input.context.loanMaturity
           AND input.context.blockTimestamp <= input.context.loanMaturity + RECOVERY_GRACE_PERIOD

  // Lead: Maintenance erodes locked index collateral
  IF input.finding == 11 THEN
    RETURN input.context.isMaintenanceSettle
           AND input.context.positionHasLockedIndexCollateral
           AND input.context.maintenanceAppliesToLockedPrincipal

  // Lead: Wallet mint pulls maxInputAmounts instead of leg.total
  IF input.finding == 12 THEN
    RETURN input.context.isWalletMintERC20
           AND input.context.maxInputAmount > input.context.legTotal

  // Lead: Position mint fee routing lacks pre-credit
  IF input.finding == 13 THEN
    RETURN input.context.isPositionMint
           AND input.context.poolShare > 0
           AND input.context.poolTrackedBalance < input.context.poolShare

  RETURN false
END FUNCTION
```

### Examples

- **Finding 1**: Position mints 100e18 index units, borrows with `collateralUnits = 50e18`. `positionIndexBalance = 100e18`, `availableUnencumbered = 50e18`. Calls `burnFromPosition(100e18)`. Expected: revert with `InsufficientUnencumberedPrincipal(100e18, 50e18)`. Actual: burn succeeds because only `positionIndexBalance` is checked.
- **Finding 2**: Position mints, encumbering 120 underlying. Burns with 10% fee. `gross = bundleOut + potShare = 120`, `payout = 108`, `navOut = mulDiv(108, 100, 120) = 90`. Unencumbers 90 instead of 100 (the `bundleOut`). Residual = 10 permanently stuck.
- **Finding 6**: Wallet burn with `gross = 1000003`, `burnFeeBps = 100`. Floor: `fee = mulDiv(1000003, 100, 10000) = 10000`. Ceil: `fee = 10001`. 1 wei leaked per burn per asset.
- **Finding 8**: After `createIndex` sets `poolFeeShareBps = 1000`, governance wants to change it to 2000. No setter exists. Value is permanently locked.
- **Lead (timelock)**: Timelock is `address(0)`. Owner calls `setPaused(indexId, true)`. Expected: succeed (owner fallback). Actual: revert because `onlyTimelock` requires `msg.sender == address(0)`.
- **Lead (grace)**: Loan matures at `T`. At `T + 1`, MEV bot calls `recoverExpiredIndexLoan`. Borrower's `repayFromPosition` in the same block loses the race. Expected: recovery blocked until `T + 1 hours`.
- **Lead (maintenance)**: Loan locks 50e18 index-pool principal. Over 30 days, maintenance erodes the position's settled principal from 100e18 to 40e18. Recovery tries to burn 50e18 collateral but only 40e18 remains. Revert.
- **Lead (exact-pull)**: Wallet mint quotes `leg.total = 100e18`. User sets `maxInputAmounts[i] = 200e18`. `pullAtLeast(asset, sender, 100e18, 200e18)` transfers 200e18. Only 100e18 is booked. 100e18 stranded.
- **Lead (fee routing)**: Position mint computes `poolShare = 5e18`. Pool has `trackedBalance = 2e18`. `routeManagedShare(poolId, 5e18, ..., true, 0)` tries to pull 5e18 from tracked balance. Revert despite sufficient unencumbered principal.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Position-mode mint with valid parameters, sufficient unencumbered underlying principal, and active index must continue to encumber, credit vaults, deduct fees, route pool-share, mint tokens, and credit index-pool principal correctly
- Position-mode burn with valid parameters and sufficient unencumbered index-pool principal must continue to compute burn legs, burn tokens, release vault assets, route fees, and update accounting correctly
- Wallet-mode mint and burn must continue to pull/transfer assets, charge fees, and distribute correctly
- Native wallet-mode mint must continue to require exact `msg.value`
- Borrow, repay, and recovery flows must continue to validate, encumber/unencumber, disburse/collect, and emit events correctly
- Admin functions must continue to work for authorized callers
- Fee routing and distribution must continue to split fees using configured parameters
- Flash loan flow must continue to execute, validate, settle, and finalize correctly
- Insufficient principal, insufficient index tokens, and other existing revert conditions must remain unchanged

**Scope:**
All inputs that do NOT match any of the nine bug conditions should be completely unaffected by these fixes.

## Hypothesized Root Cause

1. **Finding 1 — Missing encumbrance check**: `burnFromPosition` checks `units <= positionIndexBalance` (the user's total index-pool principal) but never checks `LibPositionHelpers.availablePrincipal` which subtracts encumbered principal. The function was written before EqualIndex lending was added, so the encumbrance dimension was not considered.

2. **Finding 2 — Payout-derived unencumbrance**: `_applyPositionBurnLeg` computes `navOut = mulDiv(payout, bundleOut, gross)` where `payout = gross - burnFee`. Since `navOut < bundleOut` whenever burn fees are nonzero, the unencumbrance amount is systematically less than the actual vault principal being removed. The fee is economically charged but the encumbrance accounting does not reflect that the full `bundleOut` has left the vault.

3. **Finding 6 — Default floor rounding**: Both `_quoteBurnLeg` and `_quotePositionBurnLeg` use `Math.mulDiv(gross, burnFeeBps, 10_000)` without specifying a rounding direction, defaulting to floor. Mint-side fees correctly use `Math.Rounding.Ceil`. The asymmetry was likely an oversight when the burn path was written.

4. **Finding 8 — No setter functions**: `poolFeeShareBps` is written once in `createIndex` via a zero-check guard and never again. `mintBurnFeeIndexShareBps` is never written at all — it always returns the hardcoded default of 4000. No admin or timelock setter was implemented for either parameter.

5. **Lead (timelock fallback)**: EqualIndex uses a local `onlyTimelock` modifier that strictly requires `msg.sender == timelockAddress`. Other EqualFi modules use `LibAccess.enforceTimelockOrOwnerIfUnset()` which falls back to owner when timelock is `address(0)`. The EqualIndex modifier was written independently without the fallback pattern.

6. **Lead (grace period)**: `recoverExpiredIndexLoan` checks `block.timestamp <= loan.maturity` and is permissionless. There is no buffer between maturity and recovery availability, creating a mempool race at the exact boundary.

7. **Lead (maintenance erosion)**: EqualIndex loans store fixed nominal `collateralUnits`. The index-token pool applies maintenance fees to all user principal including locked collateral. Over time, settled principal can fall below `collateralUnits`, making recovery impossible because it tries to burn/reconcile the original fixed amount.

8. **Lead (exact-pull)**: `_prepareMint` calls `LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.total, maxInputAmounts[i])`. The `pullAtLeast` function transfers `maxInputAmounts[i]` (the max bound) rather than `leg.total` (the quoted requirement). The surplus is never booked.

9. **Lead (fee routing pre-credit)**: `_applyPositionMintLeg` calls `LibFeeRouter.routeManagedShare(leg.poolId, poolShare, ..., true, 0)` with `pullFromTracked = true` but does not pre-credit `pool.trackedBalance` by `poolShare`. The router tries to consume tracked balance that does not yet exist. Position burn already follows the correct pattern of pre-crediting before routing.

## Correctness Properties

Property 1: Bug Condition — Burn gated against active index-loan encumbrance (Finding 1)

_For any_ call to `burnFromPosition` where `units > availableUnencumbered`, the fixed function SHALL revert with `InsufficientUnencumberedPrincipal`. Burns where `units <= availableUnencumbered` SHALL succeed normally.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — Deterministic encumbrance release on position burn (Finding 2)

_For any_ position-mode burn with nonzero burn fees, the fixed `_applyPositionBurnLeg` SHALL unencumber `leg.bundleOut` instead of `navOut`, ensuring a full exit leaves no residual index-related encumbrance.

**Validates: Requirements 2.3, 2.4**

Property 3: Bug Condition — Protocol-safe burn fee rounding (Finding 6)

_For any_ wallet-mode or position-mode burn where the fee computation has a remainder, the fixed quote functions SHALL use `Math.Rounding.Ceil`, rounding burn fees up by 1 wei. Exact-division cases SHALL be unchanged.

**Validates: Requirements 2.5, 2.6**

Property 4: Bug Condition — Governance setters for fee-share parameters (Finding 8)

_For any_ call to `setEqualIndexPoolFeeShareBps` or `setEqualIndexMintBurnFeeIndexShareBps` by the timelock with valid BPS values, the fixed code SHALL update the parameter and emit the corresponding event. Non-timelock callers and values above 10_000 SHALL revert.

**Validates: Requirements 2.7, 2.8, 2.9, 2.10**

Property 5: Bug Condition — Admin timelock fallback (Lead)

_For any_ call to `setPaused`, `configureLending`, or `configureBorrowFeeTiers` when the timelock is unset, the fixed code SHALL allow the owner to call these functions. When the timelock is configured, only the timelock SHALL be authorized.

**Validates: Requirements 2.11, 2.12**

Property 6: Bug Condition — Recovery grace period (Lead)

_For any_ call to `recoverExpiredIndexLoan` where `block.timestamp <= loan.maturity + RECOVERY_GRACE_PERIOD`, the fixed function SHALL revert. Recovery SHALL succeed after the grace period. Repayment SHALL remain available during the grace period.

**Validates: Requirements 2.13, 2.14, 2.15**

Property 7: Bug Condition — Maintenance-exempt locked index collateral (Lead)

_For any_ active EqualIndex loan, the fixed maintenance settlement SHALL apply only to unlocked index-pool principal. Locked collateral SHALL remain at its fixed nominal amount. Recovery SHALL succeed after long maintenance accrual periods.

**Validates: Requirements 2.16, 2.17, 2.18, 2.19**

Property 8: Bug Condition — Exact-pull mint inputs (Lead)

_For any_ ERC20 wallet-mode mint where `maxInputAmounts[i] > leg.total`, the fixed `_prepareMint` SHALL pull only `leg.total`, not the user-supplied max bound. No surplus tokens SHALL be stranded.

**Validates: Requirements 2.20, 2.21, 2.22**

Property 9: Bug Condition — Position mint fee routing pre-credit (Lead)

_For any_ position-mode mint where `poolShare > 0`, the fixed `_applyPositionMintLeg` SHALL pre-credit `pool.trackedBalance` by `poolShare` before calling `routeManagedShare`. Minting SHALL not revert solely due to missing pre-credit backing.

**Validates: Requirements 2.23, 2.24**

Property 10: Preservation — Position-mode mint and burn mechanics

_For any_ position-mode mint or burn that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code, preserving encumbrance, vault accounting, fee routing, index-pool principal updates, and token minting/burning.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4**

Property 11: Preservation — Wallet-mode mint and burn mechanics

_For any_ wallet-mode mint or burn that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code, preserving asset transfers, vault accounting, fee distribution, and token minting/burning.

**Validates: Requirements 3.5, 3.6, 3.7**

Property 12: Preservation — Lending, admin, fee routing, and flash loan flows

_For any_ borrow, repay, recovery, admin, fee routing, or flash loan operation that does NOT trigger the bug conditions, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.8, 3.9, 3.10, 3.11, 3.12, 3.13, 3.14, 3.15, 3.16**


## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

---

**File**: `src/equalindex/EqualIndexPositionFacet.sol`

**Function**: `burnFromPosition`

**Specific Changes**:
1. **Encumbrance check (Finding 1)**: After settling `positionIndexBalance` and before proceeding with burn, add:
   ```
   uint256 available = LibPositionHelpers.availablePrincipal(indexPool, positionKey, indexPoolId);
   if (units > available) revert InsufficientUnencumberedPrincipal(units, available);
   ```
   This reuses the existing `InsufficientUnencumberedPrincipal` error path for consistency with lending checks.

**Function**: `_applyPositionBurnLeg`

**Specific Changes**:
2. **Unencumber `bundleOut` instead of `navOut` (Finding 2)**: Replace the `navOut`-based unencumbrance with `bundleOut`:
   ```
   // Before:
   // uint256 navOut = Math.mulDiv(leg.payout, leg.bundleOut, gross);
   // LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, navOut);
   
   // After:
   if (leg.bundleOut > 0) {
       LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, leg.bundleOut);
   }
   ```
   Remove the `navOut` computation and the `if (navOut > 0)` guard. Define `potOut` deterministically as:
   ```
   uint256 potOut = leg.payout > leg.bundleOut ? leg.payout - leg.bundleOut : 0;
   ```
   This keeps fee charging explicit through fee-pot and routed-fee accounting: the vault-side unencumbrance always matches the actual underlying `bundleOut`, and only the excess user payout above `bundleOut` is re-credited as pool principal.

**Function**: `_quotePositionBurnLeg`

**Specific Changes**:
3. **Ceil rounding for position burn fee (Finding 6)**: Change:
   ```
   // Before:
   leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);
   
   // After:
   leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000, Math.Rounding.Ceil);
   ```

---

**File**: `src/equalindex/EqualIndexActionsFacetV3.sol`

**Function**: `_quoteBurnLeg`

**Specific Changes**:
4. **Ceil rounding for wallet burn fee (Finding 6)**: Change:
   ```
   // Before:
   leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);
   
   // After:
   leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000, Math.Rounding.Ceil);
   ```

**Function**: `_prepareMint`

**Specific Changes**:
5. **Exact-pull for ERC20 mint (Lead)**: Change the ERC20 pull path to transfer only the quoted `leg.total`:
   ```
   // Before:
   uint256 received = LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.total, maxInputAmounts[i]);
   
   // After:
   uint256 received = LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.total, leg.total);
   ```
   Keep the existing max-bound check that requires `maxInputAmounts[i] >= leg.total` (already present as the revert condition). This ensures `maxInputAmounts` remains a user protection bound without being the transfer amount.

---

**File**: `src/equalindex/EqualIndexPositionFacet.sol`

**Function**: `_applyPositionMintLeg`

**Specific Changes**:
6. **Pre-credit tracked balance for position mint fee routing (Lead)**: Before calling `routeManagedShare`, pre-credit the pool's tracked balance:
   ```
   if (poolShare > 0) {
       pool.trackedBalance += poolShare;  // pre-credit before routing
       LibFeeRouter.routeManagedShare(leg.poolId, poolShare, POSITION_INDEX_FEE_SOURCE, true, 0);
   }
   ```
   This matches the pattern already used in `_applyPositionBurnLeg` where `pool.trackedBalance += leg.poolShare` is credited before `routeManagedShare`.

---

**File**: `src/equalindex/EqualIndexAdminFacetV3.sol`

**Specific Changes**:
7. **Fee-share governance setters (Finding 8)**: Add two new functions:
   ```
   function setEqualIndexPoolFeeShareBps(uint16 newBps) external onlyTimelock {
       if (newBps > 10_000) revert InvalidParameterRange("poolFeeShareBps");
       uint16 oldBps = s().poolFeeShareBps;
       s().poolFeeShareBps = newBps;
       emit EqualIndexPoolFeeShareBpsUpdated(oldBps, newBps);
   }

   function setEqualIndexMintBurnFeeIndexShareBps(uint16 newBps) external onlyTimelock {
       if (newBps > 10_000) revert InvalidParameterRange("mintBurnFeeIndexShareBps");
       uint16 oldBps = s().mintBurnFeeIndexShareBps;
       s().mintBurnFeeIndexShareBps = newBps;
       emit EqualIndexMintBurnFeeIndexShareBpsUpdated(oldBps, newBps);
   }
   ```
   Declare events:
   - `EqualIndexPoolFeeShareBpsUpdated(uint16 oldBps, uint16 newBps)`
   - `EqualIndexMintBurnFeeIndexShareBpsUpdated(uint16 oldBps, uint16 newBps)`

   Final intended policy: these setters SHALL use `LibAccess.enforceTimelockOrOwnerIfUnset()` along with the other EqualIndex admin functions. The initial `onlyTimelock` sketch is only an intermediate implementation waypoint until the shared fallback pattern is applied in the later access-control task.

---

**File**: `src/equalindex/EqualIndexBaseV3.sol`

**Specific Changes**:
8. **Replace `onlyTimelock` with shared fallback pattern (Lead)**: Replace the local `onlyTimelock` modifier:
   ```
   // Before:
   modifier onlyTimelock() {
       if (msg.sender != LibAppStorage.timelockAddress(LibAppStorage.s())) revert Unauthorized();
       _;
   }
   
   // After: Remove the modifier entirely. Update all call sites to use:
   LibAccess.enforceTimelockOrOwnerIfUnset();
   ```
   Update `setPaused`, `configureLending`, `configureBorrowFeeTiers`, and the new fee-share setters to call `LibAccess.enforceTimelockOrOwnerIfUnset()` instead of using the `onlyTimelock` modifier.

---

**File**: `src/equalindex/EqualIndexLendingFacet.sol`

**Function**: `recoverExpiredIndexLoan`

**Specific Changes**:
9. **Recovery grace period (Lead)**: Add a constant and update the maturity check:
   ```
   uint256 constant RECOVERY_GRACE_PERIOD = 1 hours;
   
   // Before:
   if (block.timestamp <= loan.maturity) {
       revert LibEqualIndexLending.LoanNotExpired(loanId, loan.maturity);
   }
   
   // After:
   if (block.timestamp <= uint256(loan.maturity) + RECOVERY_GRACE_PERIOD) {
       revert LibEqualIndexLending.LoanNotExpired(loanId, loan.maturity);
   }
   ```

**Function**: `borrowFromPosition`

**Specific Changes**:
10. **Track maintenance-exempt collateral on borrow (Lead)**: After encumbering index-pool principal, increment the per-user exempt amount while continuing to rely on the existing pool-level `indexEncumberedTotal` aggregate for maintenance accrual exclusion:
    ```
    LibIndexEncumbrance.encumber(positionKey, indexPoolId, indexId, collateralUnits);
    indexPool.userIndexEncumberedPrincipal[positionKey] += collateralUnits;
    ```

**Function**: `repayFromPosition`

**Specific Changes**:
11. **Remove maintenance exemption on repay (Lead)**: After unencumbering, decrement the per-user maintenance-exempt amount:
    ```
    LibIndexEncumbrance.unencumber(positionKey, indexPoolId, loan.indexId, loan.collateralUnits);
    indexPool.userIndexEncumberedPrincipal[positionKey] -= loan.collateralUnits;
    ```

**Function**: `recoverExpiredIndexLoan`

**Specific Changes**:
12. **Remove maintenance exemption on recovery (Lead)**: In `_releaseRecoveredCollateral` or after it, decrement the per-user maintenance-exempt amount:
    ```
    uint256 indexPoolId = s().indexToPoolId[loan.indexId];
    Types.PoolData storage indexPool = LibAppStorage.s().pools[indexPoolId];
    indexPool.userIndexEncumberedPrincipal[loan.positionKey] -= loan.collateralUnits;
    ```

---

**File**: `src/libraries/Types.sol`

**Specific Changes**:
13. **Add per-user exemption mapping only where needed**: Do not add a new pool-level aggregate because `PoolData.indexEncumberedTotal` already exists and is already excluded from the maintenance accrual base. Instead, add `mapping(bytes32 => uint256) userIndexEncumberedPrincipal;` to `PoolData` so `LibFeeIndex` can exempt the correct borrower's locked collateral during settlement and preview.

---

**Maintenance settlement update** (in the relevant maintenance library):
14. **Apply maintenance only to unlocked principal**: Keep the existing pool-level accrual exclusion through `indexEncumberedTotal`, and update `LibFeeIndex` preview and settlement logic so that each user's maintenance-chargeable base is `userPrincipal[positionKey] - userIndexEncumberedPrincipal[positionKey]` rather than the full `userPrincipal[positionKey]`. The key invariant is that locked collateral does not decay either at pool accrual time or at borrower settlement time.

## Testing Strategy

### Validation Approach

The testing strategy follows the bug-condition methodology: first surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real deposits, real index creation, real position-mode mint and burn, real borrow and repay, real recovery, and real withdrawal per workspace guidelines.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures.

**Test Cases**:
1. **Burn encumbered collateral test**: Mint index units, borrow with collateral, attempt burn of full position including encumbered units, assert revert. On unfixed code this will FAIL because burn succeeds.
2. **Encumbrance leak test**: Mint then full burn with nonzero burn fee, assert zero residual encumbrance. On unfixed code this will FAIL because `navOut < bundleOut` leaves residual.
3. **Burn fee rounding test**: Wallet-mode and position-mode burn with parameters producing non-exact fee division, assert fee uses ceiling rounding. On unfixed code this will FAIL because floor rounding underpays.
4. **Fee-share setter test**: Call `setEqualIndexPoolFeeShareBps` and `setEqualIndexMintBurnFeeIndexShareBps`, assert they exist and work. On unfixed code this will FAIL because no setter exists.
5. **Timelock fallback test**: With timelock unset, call `setPaused` as owner, assert success. On unfixed code this will FAIL because `onlyTimelock` reverts. The same final fallback policy must also apply to the new fee-share setter functions.
6. **Recovery grace period test**: Create loan, warp to `maturity + 1`, attempt recovery, assert revert during grace period. On unfixed code this will FAIL because recovery succeeds immediately.
7. **Maintenance erosion test**: Create loan, advance time to accrue significant maintenance, attempt recovery, assert success. On unfixed code this will FAIL because maintenance erodes locked collateral below `collateralUnits`.
8. **Exact-pull mint test**: Wallet-mode ERC20 mint with `maxInputAmounts[i] > leg.total`, assert only `leg.total` transferred. On unfixed code this will FAIL because full `maxInputAmounts[i]` is pulled.
9. **Position mint fee routing test**: Position mint when pool has low tracked balance but sufficient unencumbered principal, assert success. On unfixed code this will FAIL because `routeManagedShare` reverts on insufficient tracked balance.

### Fix Checking

**Goal**: Verify that for all inputs where each bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Finding 1
FOR ALL burnFromPosition WHERE units > availableUnencumbered DO
  ASSERT REVERTS burnFromPosition_fixed(positionId, indexId, units)
END FOR

// Finding 2
FOR ALL positionBurn WHERE burnFeeBps > 0 DO
  encumbranceBefore := getEncumbrance(positionKey, poolId, indexId)
  burnFromPosition_fixed(positionId, indexId, units)
  encumbranceAfter := getEncumbrance(positionKey, poolId, indexId)
  ASSERT encumbranceBefore - encumbranceAfter == sum(leg.bundleOut for each leg)
END FOR

// Finding 6
FOR ALL burn WHERE gross * burnFeeBps % 10_000 != 0 DO
  fee := quoteBurnLeg_fixed(params).fee
  ASSERT fee == ceil(gross * burnFeeBps / 10_000)
END FOR

// Finding 8
FOR ALL setFeeShare WHERE callerIsTimelock AND newBps <= 10_000 DO
  setEqualIndexPoolFeeShareBps_fixed(newBps)
  ASSERT poolFeeShareBps == newBps
END FOR

// Lead: timelock fallback
FOR ALL adminCall WHERE timelockAddress == address(0) AND callerIsOwner DO
  ASSERT NO REVERT adminFunction_fixed(params)
END FOR

// Lead: grace period
FOR ALL recovery WHERE blockTimestamp <= maturity + RECOVERY_GRACE_PERIOD DO
  ASSERT REVERTS recoverExpiredIndexLoan_fixed(loanId)
END FOR

// Lead: maintenance exemption
FOR ALL maintenanceSettle WHERE positionHasLockedCollateral DO
  lockedBefore := lockedCollateralPrincipal
  applyMaintenance_fixed()
  lockedAfter := lockedCollateralPrincipal
  ASSERT lockedAfter == lockedBefore
END FOR

// Lead: exact-pull
FOR ALL walletMintERC20 WHERE maxInputAmounts[i] > legTotal DO
  balanceBefore := token.balanceOf(contract)
  mint_fixed(params)
  balanceAfter := token.balanceOf(contract)
  ASSERT balanceAfter - balanceBefore == sum(leg.total for each leg)
END FOR

// Lead: fee routing pre-credit
FOR ALL positionMint WHERE poolShare > 0 AND poolTrackedBalance < poolShare DO
  ASSERT NO REVERT mintFromPosition_fixed(positionId, indexId, units)
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug conditions do NOT hold, the fixed functions produce the same result as the original functions.

**Test Cases**:
1. **Position mint preservation**: Mint with valid parameters, verify encumbrance, vault accounting, fee routing, index-pool principal unchanged
2. **Position burn preservation**: Burn with sufficient unencumbered principal, verify burn legs, token burning, vault release, fee routing unchanged
3. **Wallet mint preservation**: Mint with `maxInputAmounts == leg.total`, verify asset pulls, vault accounting, fee distribution unchanged
4. **Wallet burn preservation**: Burn with exact-division fees, verify fee amounts, payout, distribution unchanged
5. **Borrow preservation**: Borrow with valid parameters, verify collateral encumbrance, loan creation, asset disbursement unchanged
6. **Repay preservation**: Repay active loan, verify asset collection, vault restoration, encumbrance release unchanged
7. **Recovery preservation**: Recover expired loan after grace period, verify write-off, collateral release, loan deletion unchanged
8. **Admin preservation**: Call admin functions with authorized caller, verify state changes unchanged
9. **Flash loan preservation**: Execute flash loan, verify execution, validation, settlement unchanged

### Integration Tests

- Full position lifecycle: create index → deposit → position mint → borrow → attempt burn of encumbered (revert) → repay → burn (success) → withdraw
- Encumbrance integrity: position mint → full burn with nonzero fees → verify zero residual encumbrance → verify pool membership clearable
- Repeated mint/burn cycles: position mint → burn → mint → burn with nonzero fees → verify no accumulated stranded encumbrance
- Burn rounding consistency: wallet burn and position burn with same parameters → verify both use ceiling rounding → verify fee routing matches
- Fee-share governance: set fee-share parameters → mint → burn → verify updated parameters reflected in fee routing
- Admin access: test all admin functions with timelock set, timelock unset, owner, and unauthorized caller
- Recovery grace: create loan → warp to maturity → attempt recovery (revert) → repay during grace (success)
- Recovery grace: create loan → warp past grace → recovery (success)
- Maintenance exemption: create loan → advance time for maintenance → verify locked collateral unchanged → recovery succeeds
- Exact-pull mint: wallet mint with loose max bounds → verify only quoted amount transferred → verify no stranded balance
- Position mint fee routing: position mint with low pool tracked balance → verify success after pre-credit fix
