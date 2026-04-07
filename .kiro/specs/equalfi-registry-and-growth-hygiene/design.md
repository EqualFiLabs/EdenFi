# Registry and Growth Hygiene — Bugfix Design

## Overview

Four storage-layer bugs across the EqualFi shared libraries require targeted fixes to prevent sentinel collision, unexercisable options, discovery duplication, and unbounded gas growth. The fix strategy preserves existing lifecycle semantics while making ID allocation sentinel-safe, initializing safe defaults, preserving historical discovery semantics, adding deduplication guards, and bounding iteration arrays to active entries only.

Canonical Track: Track H. Discovery, Storage Growth, and Registry Hygiene
Phase: Phase 3. Architectural Redesign and Governance Hardening

Source report: `assets/findings/EdenFi-libraries-phase4-pashov-ai-audit-report-20260406-210000.md`
Unified plan: `assets/remediation/EqualFi-unified-remediation-plan.md`

## Glossary

- **Bug_Condition (C)**: The set of conditions across five findings that trigger sentinel collision, zero-tolerance exercise windows, discovery-semantic drift, duplicate registry entries, and unbounded commitment iteration
- **Property (P)**: The desired correct behavior — one-based IDs, safe tolerance default, preserved historical discovery semantics, deduplicated registration, and bounded arrays
- **Preservation**: Existing reward program lifecycle, options exercise validation, discovery query results, and commitment allocation that must remain unchanged
- **`allocateProgramId`**: Function in `LibEdenRewardsStorage` that assigns unique program IDs to new EDEN reward programs
- **`europeanToleranceSeconds`**: Storage field in `LibOptionsStorage.OptionsStorage` defining the exercise window around European option expiry
- **`MarketPointer`**: Struct in `LibEqualXTypes` containing `marketType` and `marketId`, used as entries in discovery arrays
- **`marketsByPosition`**: Discovery array mapping position keys to their associated market pointers
- **`marketsByPair`**: Discovery array mapping token-pair keys to their associated market pointers
- **`activeMarketsByType`**: Discovery array mapping market types to their active market pointers
- **`lineCommitmentPositionIds`**: Storage array in `LibEqualScaleAlphaStorage` mapping line IDs to lender position IDs with active commitments
- **`lineHasCommitmentPosition`**: Boolean mapping tracking whether a lender currently has an active commitment position on a line after this remediation

## Bug Details

### Bug Condition

The bugs manifest across five distinct conditions in the EqualFi storage libraries. Together they represent sentinel collision, unsafe defaults, discovery-semantic drift, missing deduplication, and unbounded growth.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: StorageContext}
  OUTPUT: boolean

  // Finding 1: First reward program gets ID 0, colliding with sentinel
  IF input.finding == 1 THEN
    RETURN input.context.isCreateRewardProgram
           AND input.context.store.nextProgramId == 0

  // Finding 2: European tolerance uninitialized, exercise window is single-second
  IF input.finding == 2 THEN
    RETURN input.context.isDiamondInit
           AND input.context.europeanToleranceSeconds == 0

  // Finding 3: Historical and live discovery registries must remain distinct
  IF input.finding == 3 THEN
    RETURN input.context.isDiscoveryCleanupChange
           AND input.context.proposedRemovalTouchesHistoricalArrays

  // Finding 4: registerMarket pushes without dedup check
  IF input.finding == 4 THEN
    RETURN input.context.isRegisterMarket
           AND input.context.marketAlreadyRegistered

  // Finding 5: Commitment terminal transition does not prune position ID array
  IF input.finding == 5 THEN
    RETURN input.context.isCommitmentTerminalTransition
           AND input.context.positionIdStillInArray

  RETURN false
END FUNCTION
```

### Examples

- **Finding 1**: First call to `createRewardProgram` → `allocateProgramId` returns 0 → `_poolIdForTarget` returns 0 for "not found" → program 0 is indistinguishable from nonexistent.
- **Finding 2**: Diamond deployed → `europeanToleranceSeconds = 0` → European option with `expiry = 1700000000` → exercise window is `[1700000000, 1700000000]` → practically impossible to hit exact second.
- **Finding 3**: Solo AMM market 42 created by position `0xabc...` for pair USDC/WETH → market finalized → `activeMarketsByType[SOLO_AMM]` cleaned → `marketsByPosition[0xabc...]` still intentionally contains pointer to market 42 because the position/pair registry is historical, not active-only.
- **Finding 4**: `registerMarket` called twice for market 42 → `marketsByPosition[0xabc...]` contains two identical `MarketPointer{SOLO_AMM, 42}` entries → duplicate in query results.
- **Finding 5**: Lender position 7 commits to line 3 → commitment canceled → `lineCommitmentPositionIds[3]` still contains 7 → `allocateRepayment` iterates position 7 and skips it (non-active status) → wasted gas on every future allocation.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- EDEN reward program creation, funding, accrual, claim, end, and close lifecycle must continue to work correctly with the new one-based IDs
- `targetProgramIds` queries must continue to return all registered program IDs
- `setEuropeanTolerance` must continue to override the tolerance value when called by governance
- American option exercise must remain unaffected by `europeanToleranceSeconds`
- European option exercise window validation logic (`[expiry - tolerance, expiry + tolerance]`) must remain unchanged
- New market registration must continue to add pointers to all three discovery arrays
- Discovery queries must continue to distinguish historical position/pair registries from live active registries
- Active markets must continue to appear in all three discovery arrays until closed
- New lender commitments must continue to be tracked in `lineCommitmentPositionIds`
- Allocation helpers must continue to correctly distribute repayment, recovery, write-down, and close amounts
- `lineHasCommitmentPosition` must stay aligned with active commitment membership so terminal transitions allow future recommitment

**Scope:**
All inputs that do NOT match any of the five bug conditions should be completely unaffected by these fixes.

## Hypothesized Root Cause

1. **Finding 1 — Zero-based ID allocation**: `allocateProgramId` uses `programId = store.nextProgramId; store.nextProgramId = programId + 1` (return-then-increment). Since `nextProgramId` starts at 0 in uninitialized storage, the first program gets ID 0. Every other ID allocator in the codebase (e.g., `allocateMarketId` in EqualX) uses increment-then-return, starting at 1. The inconsistency means program 0 collides with Solidity's default `uint256` mapping value, making it invisible to sentinel-based existence checks like `_poolIdForTarget` which returns 0 for "not found".

2. **Finding 2 — Uninitialized tolerance**: `europeanToleranceSeconds` is a `uint64` in `OptionsStorage` that defaults to 0 in uninitialized storage. `DiamondInit.init` does not set it. The exercise validation in `OptionsFacet._validateExerciseWindow` computes `lowerBound = series.expiry > tolerance ? series.expiry - tolerance : 0` and `upperBound = series.expiry + tolerance`. With tolerance = 0, both bounds equal `series.expiry`, creating a single-second exercise window.

3. **Finding 3 — Discovery scope confusion**: `removeActiveMarket` only operates on `activeMarketsByType`, and that is correct for the current EqualFi discovery design. The mistake is treating historical `marketsByPosition` and `marketsByPair` arrays as stale-active registries. The remediation must preserve that distinction while fixing duplicate registration and active-set hygiene.

4. **Finding 4 — No deduplication**: `registerMarket` unconditionally pushes a new `MarketPointer` into all three arrays without checking whether the market already exists. While the current facet code only calls `registerMarket` once per market creation, there is no guard against duplicate registration at the library level.

5. **Finding 5 — Append-only commitment tracking**: `lineCommitmentPositionIds` is populated via `store.lineCommitmentPositionIds[lineId].push(lenderPositionId)` when a lender commits. No lifecycle transition (cancel, exit, writedown, close) ever removes entries from this array. The `lineHasCommitmentPosition` boolean guard prevents duplicate pushes but does not support removal. All allocation helpers iterate the full array and skip non-active commitments, but the gas cost grows with total historical commitments.

## Correctness Properties

Property 1: Bug Condition — One-based reward program ID allocation

_For any_ call to `allocateProgramId`, the returned program ID SHALL be >= 1, ensuring ID 0 is never assigned and can safely serve as a "not found" sentinel.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — Safe default European tolerance

_For any_ diamond initialization via `DiamondInit.init`, `europeanToleranceSeconds` SHALL be set to 300 (5 minutes) so that European options are exercisable from deployment.

**Validates: Requirements 2.3**

Property 3: Bug Condition — Discovery semantics preserved during hygiene work

_For any_ market close or finalization, the market pointer SHALL be removed only from live discovery sets, while historical `marketsByPosition` and `marketsByPair` behavior remains intact.

**Validates: Requirements 2.4, 2.6**

Property 4: Bug Condition — Deduplicated discovery registration

_For any_ call to `registerMarket` where the market already exists in a discovery array, the system SHALL skip the duplicate push.

**Validates: Requirements 2.5**

Property 5: Bug Condition — Bounded commitment position ID tracking

_For any_ commitment terminal transition (Canceled, Exited, WrittenDown, Closed), the lender position ID SHALL be removed from `lineCommitmentPositionIds[lineId]` via swap-and-pop and `lineHasCommitmentPosition` SHALL be cleared so future recommitment is possible.

**Validates: Requirements 2.7, 2.8**

Property 6: Preservation — EDEN reward program lifecycle

_For any_ reward program creation, funding, accrual, claim, end, or close operation, the fixed code SHALL produce exactly the same behavior as the original code (except that program IDs start at 1 instead of 0).

**Validates: Requirements 3.1, 3.2, 3.3**

Property 7: Preservation — Options exercise lifecycle

_For any_ option exercise, `setEuropeanTolerance` call, or American option exercise, the fixed code SHALL produce exactly the same behavior as the original code (except that the default tolerance is 300 instead of 0).

**Validates: Requirements 3.4, 3.5, 3.6**

Property 8: Preservation — Discovery registry queries and registration

_For any_ market creation, registration, or discovery query on active markets, the fixed code SHALL produce exactly the same behavior as the original code.

**Validates: Requirements 3.7, 3.8, 3.9**

Property 9: Preservation — EqualScale commitment lifecycle

_For any_ new lender commitment or allocation operation, the fixed code SHALL produce exactly the same behavior as the original code. For `lineHasCommitmentPosition`, the fixed code SHALL track active membership rather than historical-ever-committed membership so recommitment remains possible after terminal transitions.

**Validates: Requirements 3.10, 3.11, 3.12**


## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

---

**File**: `src/libraries/LibEdenRewardsStorage.sol`

**Function**: `allocateProgramId`

**Specific Changes**:
1. **One-based ID allocation (Finding 1)**: Change from return-then-increment to increment-then-return:
   ```solidity
   function allocateProgramId(RewardsStorage storage store) internal returns (uint256 programId) {
       store.nextProgramId++;
       programId = store.nextProgramId;
   }
   ```
   This ensures the first program ID is 1, not 0, consistent with every other ID allocator in the codebase. ID 0 remains available as a "not found" sentinel.

---

**File**: `src/core/DiamondInit.sol`

**Function**: `init`

**Specific Changes**:
2. **Safe default European tolerance (Finding 2)**: Add initialization of `europeanToleranceSeconds` to 300 seconds (5 minutes):
   ```solidity
   import {LibOptionsStorage} from "../libraries/LibOptionsStorage.sol";
   // ...
   LibOptionsStorage.s().europeanToleranceSeconds = 300;
   ```
   This ensures European options are exercisable from deployment without requiring a separate admin call. Governance can still override via `setEuropeanTolerance`.

---

**File**: `src/libraries/LibEqualXDiscoveryStorage.sol`

**Functions**: `registerMarket`, `removeActiveMarket` (renamed/expanded)

**Specific Changes**:
3. **Deduplicated registration (Finding 4)**: Add deduplication checks to `registerMarket` before each push:
   - Before pushing to `marketsByPosition[positionKey]`, check if the market already exists
   - Before pushing to `marketsByPair[pairKey]`, check if the market already exists
   - Before pushing to `activeMarketsByType[marketType]`, check if the market already exists
   - Use a private `_containsMarket` helper to avoid code duplication

4. **Preserve historical registry semantics (Finding 3)**: Do NOT add close-time removal for `marketsByPosition` or `marketsByPair`. The remediation SHALL keep those arrays historical and limit cleanup work to live registries.

5. **Callers in facets**: Keep existing close-time `removeActiveMarket` usage for live registry cleanup. Do not add position/pair removal calls in `EqualXSoloAmmFacet`, `EqualXCommunityAmmFacet`, or `LibEqualXCurveEngine`.

---

**File**: `src/libraries/LibEqualScaleAlphaStorage.sol`

**New function**: `removeCommitmentPositionId`

**Specific Changes**:
6. **Bounded commitment tracking (Finding 5)**: Add a swap-and-pop removal function:
   ```solidity
   function removeCommitmentPositionId(
       EqualScaleAlphaStorage storage store,
       uint256 lineId,
       uint256 lenderPositionId
   ) internal {
       uint256[] storage ids = store.lineCommitmentPositionIds[lineId];
       uint256 len = ids.length;
       for (uint256 i; i < len; ++i) {
           if (ids[i] == lenderPositionId) {
               uint256 last = len - 1;
               if (i != last) {
                   ids[i] = ids[last];
               }
               ids.pop();
               return;
           }
       }
   }
   ```

7. **Callers in facets/shared**: Call `removeCommitmentPositionId` when a commitment transitions to a terminal status:
   - In `EqualScaleAlphaFacet` or `LibEqualScaleAlphaShared` where commitment status is set to `Canceled`, `Exited`, `WrittenDown`, or `Closed`
   - Clear `lineHasCommitmentPosition[lineId][lenderPositionId] = false` so the mapping represents active membership and the lender can re-commit if needed
   - The `closeAllCommitments` helper should handle bulk removal efficiently

## Testing Strategy

### Validation Approach

The testing strategy follows the same two-phase approach as the model spec: first, surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real program creation, real option series, real market creation, and real commitment flows per workspace guidelines.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures.

**Test Cases**:
1. **Program ID Zero Test**: Create the first EDEN reward program, assert the returned program ID is NOT 0. On unfixed code this will FAIL because `allocateProgramId` returns 0.
2. **European Tolerance Default Test**: Deploy a fresh diamond via `DiamondInit.init`, read `europeanToleranceSeconds`, assert it is nonzero. On unfixed code this will FAIL because the field is uninitialized.
3. **Discovery Stale Pointer Test**: Create a Solo AMM market, finalize it, query `marketsByPosition` for the maker's position key, assert the finalized market is NOT in the results. On unfixed code this will FAIL because `removeActiveMarket` does not clean position/pair arrays.
4. **Discovery Duplicate Test**: Call `registerMarket` twice for the same market, query the relevant array, assert no duplicates. On unfixed code this will FAIL because there is no dedup guard.
5. **Commitment Pruning Test**: Create a credit line, add a lender commitment, cancel the commitment, query `lineCommitmentPositionIds`, assert the canceled lender is NOT in the array. On unfixed code this will FAIL because the array is append-only.

### Fix Checking

**Pseudocode:**
```
// Finding 1
FOR ALL createRewardProgram WHERE store.nextProgramId == 0 DO
  programId := allocateProgramId'(store)
  ASSERT programId >= 1
END FOR

// Finding 2
FOR ALL diamondInit DO
  init'(timelock, treasury, nft)
  ASSERT LibOptionsStorage.s().europeanToleranceSeconds == 300
END FOR

// Finding 3
FOR ALL marketClose WHERE marketExistsInPositionOrPairArray DO
  removeMarket'(store, positionKey, tokenA, tokenB, marketType, marketId)
  ASSERT NOT containsMarket(store.marketsByPosition[positionKey], marketType, marketId)
  ASSERT NOT containsMarket(store.marketsByPair[pairKey(tokenA, tokenB)], marketType, marketId)
END FOR

// Finding 4
FOR ALL registerMarket WHERE marketAlreadyRegistered DO
  registerMarket'(store, positionKey, tokenA, tokenB, marketType, marketId)
  ASSERT countOccurrences(store.marketsByPosition[positionKey], marketType, marketId) == 1
END FOR

// Finding 5
FOR ALL commitmentTerminalTransition DO
  transitionCommitment'(store, lineId, lenderPositionId, terminalStatus)
  ASSERT NOT contains(store.lineCommitmentPositionIds[lineId], lenderPositionId)
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
1. **EDEN Program Lifecycle Preservation**: Create multiple reward programs, verify IDs are sequential starting from 1, verify funding/accrual/claim lifecycle works unchanged
2. **Options Tolerance Override Preservation**: Deploy diamond, verify default is 300, call `setEuropeanTolerance(600)`, verify override works, verify American options unaffected
3. **Discovery Registration Preservation**: Create markets, verify all three arrays populated correctly, verify queries return correct results for active markets
4. **Discovery Active Market Preservation**: Create market, verify it appears in all three arrays, verify it remains until closed
5. **Commitment Tracking Preservation**: Create line, add multiple lender commitments, verify all active commitments appear in `lineCommitmentPositionIds`, verify allocation helpers distribute correctly

### Test Files

- `test/EdenRewardsStorage.t.sol` — Finding 1 (program ID allocation)
- `test/OptionsFacet.t.sol` or `test/DiamondInit.t.sol` — Finding 2 (tolerance default)
- `test/EqualXStorage.t.sol` or `test/EqualXDiscovery.t.sol` — Findings 3, 4 (discovery registry)
- `test/EqualScaleAlphaFacet.t.sol` — Finding 5 (commitment pruning)

### Test Commands

```bash
forge test --match-path test/EdenRewardsStorage.t.sol
forge test --match-path test/OptionsFacet.t.sol
forge test --match-path test/EqualXStorage.t.sol
forge test --match-path test/EqualScaleAlphaFacet.t.sol
```
