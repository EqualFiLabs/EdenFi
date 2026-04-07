# EDEN Reward Backing Redesign — Bugfix Design

## Overview

Eight confirmed defects and architectural gaps in the EDEN by EqualFi reward system require targeted fixes across the reward facet, engine, consumer, and storage libraries. The fix strategy preserves the current EDEN reward model while hardening claim integrity (fail-closed semantics, exact FoT delivery), introducing per-program backing isolation, cleaning up lifecycle gas growth, and adding operational improvements (retroactive starts, manager rotation, ETH guard). The fail-closed claim fix is the highest priority item. Per-program backing isolation is the most architecturally significant change. Rebasing token support is captured as a design direction that the backing isolation enables but is not fully implemented in this spec.

Canonical Track: Track C. Fee Routing, Backing Isolation, and Exotic Token Policy
Phase: Phase 3. Architectural Redesign and Governance Hardening

Source reports:
- `assets/findings/EdenFi-eden-pashov-ai-audit-report-20260405-025500.md` (findings 3, 4, 6; leads)
- `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md` (finding 4 — root cause fixed in Phase 1)

Remediation plan:
- `assets/remediation/EqualFi-unified-remediation-plan.md` (Track C, Phase 3)
- `assets/remediation/EDEN-findings-3-4-5-6-remediation-plan.md`

Coding standards: `ETHSKILLS.md`

Rollout assumption:
- This spec is implementation-ready only for a clean-break EDEN rollout or for newly created programs after deployment
- If live programs must preserve existing claimability, a separate migration/bootstrap spec is required before `programBackingBalance` enforcement can be enabled

## Glossary

- **Bug_Condition (C)**: The set of conditions across eight items that trigger unbacked claim restoration, FoT overpayment, cross-program balance theft, ETH lock, gas growth, silent start-skip, and fixed manager authority
- **Property (P)**: The desired correct behavior — fail-closed claims, exact FoT delivery, per-program backing isolation, ETH rejection, bounded target arrays, retroactive starts, and rotatable managers
- **Preservation**: Existing reward creation, funding, accrual, settlement, lifecycle management, and view functions that must remain unchanged
- **`fundedReserve`**: Per-program field tracking gross tokens available for reward distribution (after Phase 1 fix, tracks net)
- **`programBackingBalance`**: New per-program field tracking actual token backing held in the diamond for this program, isolated from other programs
- **`accruedClaimLiability`**: New per-program field tracking total outstanding accrued rewards not yet claimed, representing the program's liability
- **`globalRewardIndex`**: Per-program cumulative index tracking net reward distribution per unit of eligible supply
- **`targetProgramIds`**: Per-target array of program IDs iterated by consumer hooks on every eligible-balance change
- **`outboundTransferBps`**: Per-program configured basis points for fee-on-transfer gross-up compensation
- **`grossUpNetAmount`**: Function converting net amount to gross for actual token transfer
- **`netFromGross`**: Function converting gross amount to net after configured outbound transfer fee deduction
- **`lastRewardUpdate`**: Per-program timestamp of last accrual, used to compute elapsed reward window

## Bug Details

### Bug Condition

The bugs manifest across eight distinct conditions in the EDEN reward system. Together they represent unbacked claim restoration, FoT overpayment, cross-program balance coupling, ETH lock, unbounded gas growth, silent start-skip, and fixed manager authority.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type {finding: uint, context: TxContext}
  OUTPUT: boolean

  // Finding 6: Partial claim restores unbacked accrued rewards
  IF input.finding == 6 THEN
    RETURN input.context.isRewardClaim
           AND input.context.grossClaimAmount > input.context.availableGross

  // FoT overpayment: Configured gross-up does not match actual transfer fee
  IF input.finding == 7 THEN
    RETURN input.context.isRewardClaim
           AND input.context.outboundTransferBps > 0
           AND input.context.netReceived != input.context.claimed

  // Cross-program backing: Claims check global balance instead of per-program backing
  IF input.finding == 8 THEN
    RETURN input.context.isRewardClaim
           AND input.context.programCount > 1
           AND input.context.sameRewardToken == true

  // Finding 3: fundRewardProgram missing assertZeroMsgValue
  IF input.finding == 3 THEN
    RETURN input.context.isFundRewardProgram
           AND input.context.msgValue > 0

  // Finding 4: Unbounded target program array
  IF input.finding == 4 THEN
    RETURN input.context.isCloseRewardProgram
           AND input.context.targetProgramIdsLength > input.context.activeProgramCount

  // Past-start: lastRewardUpdate initialized to block.timestamp instead of startTime
  IF input.finding == 9 THEN
    RETURN input.context.isCreateRewardProgram
           AND input.context.startTime < input.context.blockTimestamp

  // Manager rotation: No rotation function exists
  IF input.finding == 10 THEN
    RETURN input.context.isManagerRotation
           AND input.context.functionDoesNotExist

  RETURN false
END FUNCTION
```

### Examples

- **Finding 6 — Partial claim**: Program has 100e18 `accruedRewards` for a user. Diamond holds only 80e18 of the reward token. `grossClaimAmount = 100e18 > availableGross = 80e18`. Current: pays 80e18, restores 20e18 to `accruedRewards` with no reserve backing. Expected: revert.

- **FoT overpayment**: Program has `outboundTransferBps = 500` (5% fee). User claims 100e18 net. `grossUpNetAmount(100e18) ≈ 105.27e18` sent. Actual token fee is 2% (not 5%). Recipient receives `105.27e18 * 0.98 ≈ 103.16e18` — overpaid by 3.16e18. Expected: revert because `netReceived (103.16e18) != claimed (100e18)`.

- **Cross-program backing**: Program A has 500e18 backing, Program B has 500e18 backing, both use USDC. Program A's accounting desyncs, leaving 600e18 of claims against 500e18 backing. Current: Program A claims succeed by consuming 100e18 of Program B's backing from the shared 1000e18 diamond balance. Expected: Program A claims fail because Program A's own backing is insufficient.

- **Finding 3 — ETH lock**: Operator calls `fundRewardProgram{value: 1 ether}(programId, 1000e18, 1100e18)`. Current: 1 ether locked in diamond, ERC20 funding proceeds normally. Expected: revert.

- **Finding 4 — Gas growth**: 50 programs created for the same EqualIndex target over time, 45 closed. Every EqualIndex mint/burn iterates all 50 programs. Expected: only 5 live programs iterated.

- **Past-start**: `createRewardProgram(startTime = block.timestamp - 1 day)`. Current: `lastRewardUpdate = block.timestamp`, 1 day of rewards silently skipped. Expected: `lastRewardUpdate = startTime`, retroactive accrual from configured start.

- **Manager rotation**: Program manager key compromised. Current: no way to rotate. Expected: `setRewardProgramManager(programId, newManager)` callable by current manager or governance.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Reward program creation with future `startTime` must continue to initialize `lastRewardUpdate` to `block.timestamp` and wait until `startTime`
- Reward program creation validation (zero address, zero rate, invalid window) must remain unchanged
- Reward program funding with zero `msg.value` and valid ERC20 parameters must continue to pull tokens, accrue, increment `fundedReserve`, and emit events identically
- Reward accrual must continue to compute eligible supply, preview accrual, and store updated state identically
- Reward settlement must continue to compute claimable rewards from index delta and accumulate into `accruedRewards` identically
- Successful claims (sufficient backing, correct FoT config) must continue to settle, transfer, and emit events identically
- Lifecycle mutations (`setRewardProgramEnabled`, `pauseRewardProgram`, `resumeRewardProgram`, `endRewardProgram`) must continue to accrue before mutation and update config identically
- `closeRewardProgram` must continue to require past `endTime`, and after this redesign it must additionally require zero live backing before closure
- View functions (`previewRewardProgramPosition`, `previewRewardProgramsForPosition`, `getRewardProgram`, `previewRewardProgramState`) must continue to compute previews identically
- Consumer hooks must continue to settle positions and update eligible supply for active programs identically

**Scope:**
All inputs that do NOT match any of the eight bug conditions should be completely unaffected by these fixes. This includes:
- Claims with sufficient per-program backing and correct FoT configuration
- Single-program deployments (no cross-program coupling possible)
- Programs with future `startTime`
- All access-control checks and parameter validation not related to manager rotation

## Hypothesized Root Cause

Based on the audit findings and code analysis:

1. **Finding 6 — Partial claim restoration**: `claimRewardProgram` was designed with a "best effort" claim model: if `grossClaimAmount > availableGross`, it caps to `availableGross` and restores the shortfall. This was likely intended as a graceful degradation, but it creates unbacked liabilities because `fundedReserve` was already consumed during accrual. The restored `accruedRewards` has no corresponding reserve. The fix is to make claims fail closed: revert if the program cannot fully honor the claim.

2. **FoT claim overpayment**: The claim path sends `grossUpNetAmount(claimed)` tokens and then checks `netReceived >= claimed`. The `>=` check only catches under-delivery. When actual transfer fees are lower than configured `outboundTransferBps`, the recipient receives more than `claimed`, which is an overpayment. The fix is to require `netReceived == claimed` (exact match). Additionally, the under-delivery path currently restores the shortfall to `accruedRewards` — this should also revert instead of creating unbacked liabilities.

3. **Cross-program backing isolation**: `claimRewardProgram` checks `availableGross = LibCurrency.balanceOfSelf(program.config.rewardToken)` — the diamond's total balance for that token. Multiple programs sharing the same reward token are implicitly coupled through this shared balance. The fix is to introduce per-program backing accounting: track `programBackingBalance` per program, increment on funding, decrement on successful claims, and check claims against per-program backing instead of global balance.

4. **Finding 3 — Missing `assertZeroMsgValue`**: Every other state-mutating function in `EdenRewardsFacet` calls `LibCurrency.assertZeroMsgValue()`. `fundRewardProgram` was missed, likely because it is `payable` (needed for the `pullAtLeast` pattern). The fix is to add the guard at the top of the function.

5. **Finding 4 — Unbounded target array**: `LibEdenRewardsStorage.registerProgramTarget` pushes to `targetProgramIds` on creation, but no function ever removes entries. `closeRewardProgram` marks the program closed but does not clean up the target array. The fix is to add a swap-and-pop removal in `closeRewardProgram` and optionally skip closed programs in consumer loops as a defense-in-depth measure.

6. **Past-start semantics**: `createRewardProgram` always sets `state.lastRewardUpdate = block.timestamp`. The accrual engine uses `max(lastRewardUpdate, startTime)` as the accrual start, so when `startTime < block.timestamp`, the window `[startTime, block.timestamp)` is silently skipped. The fix is to set `lastRewardUpdate = startTime` when `startTime < block.timestamp`.

7. **Manager rotation**: The `manager` field is set once in `createRewardProgram` and never updated. No rotation function exists. The fix is to add `setRewardProgramManager(programId, newManager)` callable by the current manager or governance.

## Correctness Properties

Property 1: Bug Condition — Claims fail closed on insufficient backing

_For any_ call to `claimRewardProgram` where `grossClaimAmount > availableGross` (either global balance or per-program backing is insufficient), the fixed function SHALL revert instead of partially paying and restoring unbacked `accruedRewards`.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition — FoT claims require exact net delivery

_For any_ call to `claimRewardProgram` where `outboundTransferBps > 0` and the post-transfer `netReceived != claimed`, the fixed function SHALL revert, preventing both overpayment and underpayment.

**Validates: Requirements 2.3, 2.4**

Property 3: Bug Condition — Per-program backing isolation

_For any_ call to `claimRewardProgram`, the fixed function SHALL check claim availability against the program's own `programBackingBalance` rather than the diamond's total token balance. Two programs sharing the same reward token SHALL NOT be able to consume each other's backing.

**Validates: Requirements 2.5, 2.6, 2.7**

Property 4: Bug Condition — `fundRewardProgram` rejects nonzero `msg.value`

_For any_ call to `fundRewardProgram` with `msg.value > 0`, the fixed function SHALL revert via `LibCurrency.assertZeroMsgValue()`.

**Validates: Requirements 2.8**

Property 5: Bug Condition — Closed programs removed from target arrays only after full drain

_For any_ call to `closeRewardProgram`, the fixed function SHALL require `fundedReserve == 0` and `programBackingBalance == 0`, then remove the program from `targetProgramIds` using swap-and-pop. Consumer hooks SHALL NOT iterate closed programs.

**Validates: Requirements 2.9, 2.10, 2.11**

Property 6: Bug Condition — Retroactive start support

_For any_ call to `createRewardProgram` where `startTime < block.timestamp`, the fixed function SHALL initialize `lastRewardUpdate` to `startTime`, enabling retroactive accrual from the configured start.

**Validates: Requirements 2.12, 2.13**

Property 7: Bug Condition — Manager rotation

_For any_ call to `setRewardProgramManager` by the current manager or governance, the fixed function SHALL update the program's manager and emit `RewardProgramManagerUpdated`. Unauthorized callers SHALL be rejected.

**Validates: Requirements 2.14, 2.15**

Property 8: Preservation — Reward creation, funding, accrual, settlement, lifecycle, and views

_For any_ input that does NOT trigger any of the eight bug conditions, the fixed code SHALL produce exactly the same behavior as the original code, preserving creation, funding, accrual, settlement, lifecycle management, view functions, and consumer hooks.

**Validates: Requirements 3.1–3.10**

## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

---

**File**: `src/eden/EdenRewardsFacet.sol`

**Function**: `fundRewardProgram`

**Specific Changes**:
1. **Add `assertZeroMsgValue` guard (Finding 3)**: Add `LibCurrency.assertZeroMsgValue();` as the first line of the function, before any state reads or accrual. This matches every other state-mutating function in the facet.

```diff
  function fundRewardProgram(uint256 programId, uint256 amount, uint256 maxAmount)
      external
      payable
      nonReentrant
      returns (uint256 funded)
  {
+     LibCurrency.assertZeroMsgValue();
      if (amount == 0) revert InvalidParameterRange("amount=0");
```

---

**Function**: `claimRewardProgram`

**Specific Changes**:
2. **Fail-closed claim semantics (Finding 6)**: Replace the partial-claim fallback with a revert when backing is insufficient.

3. **Per-program backing check (Cross-program isolation)**: Replace `LibCurrency.balanceOfSelf(rewardToken)` with a check against the program's own `programBackingBalance`.

4. **Exact FoT delivery (FoT overpayment)**: Replace `netReceived < claimed` with `netReceived != claimed` and revert instead of restoring.

```diff
  function claimRewardProgram(uint256 programId, uint256 positionId, address to)
      external
      nonReentrant
      returns (uint256 claimed)
  {
      LibCurrency.assertZeroMsgValue();
      LibPositionHelpers.requireOwnership(positionId);
      bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
      claimed = _settleRewardProgramPosition(programId, positionKey);
      if (claimed == 0) revert InvalidParameterRange("nothing claimable");

      LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
      uint256 grossClaimAmount =
          LibEdenRewardsEngine.grossUpNetAmount(claimed, program.config.outboundTransferBps);

-     uint256 availableGross = LibCurrency.balanceOfSelf(program.config.rewardToken);
-     if (grossClaimAmount > availableGross) {
-         grossClaimAmount = availableGross;
-     }
-     if (grossClaimAmount == 0) revert InvalidParameterRange("programBalance");
+     // Per-program backing isolation: check against program's own backing, not global balance
+     if (grossClaimAmount > program.state.programBackingBalance) {
+         revert InvalidParameterRange("insufficientProgramBacking");
+     }

      uint256 recipientBalanceBefore = IERC20(program.config.rewardToken).balanceOf(to);
      LibEdenRewardsStorage.s().accruedRewards[programId][positionKey] = 0;
+     program.state.programBackingBalance -= grossClaimAmount;
      LibCurrency.transfer(program.config.rewardToken, to, grossClaimAmount);
      uint256 recipientBalanceAfter = IERC20(program.config.rewardToken).balanceOf(to);
      uint256 netReceived = recipientBalanceAfter - recipientBalanceBefore;
-     if (netReceived < claimed) {
-         LibEdenRewardsStorage.s().accruedRewards[programId][positionKey] = claimed - netReceived;
-         claimed = netReceived;
-     }
+     // Exact delivery required: revert on both over-delivery and under-delivery
+     if (netReceived != claimed) {
+         revert InvalidParameterRange("claimDeliveryMismatch");
+     }

      emit RewardProgramClaimed(programId, positionId, positionKey, to, claimed);
  }
```

---

**Function**: `fundRewardProgram`

**Specific Changes**:
5. **Increment per-program backing on funding**: After pulling tokens, increment `programBackingBalance`.

```diff
  funded = LibCurrency.pullAtLeast(program.config.rewardToken, msg.sender, amount, maxAmount);
  program.state.fundedReserve = stateAfterAccrual.fundedReserve + funded;
+ program.state.programBackingBalance += funded;
```

---

**Function**: `closeRewardProgram`

**Specific Changes**:
6. **Remove program from target arrays on close (Finding 4)**: `closeRewardProgram` must require both `fundedReserve == 0` and `programBackingBalance == 0`. After marking the program closed, remove it from `targetProgramIds`.

```diff
  program.config.closed = true;
  program.config.enabled = false;
  program.config.paused = false;
+ LibEdenRewardsStorage.removeProgramFromTarget(
+     LibEdenRewardsStorage.s(), programId, program.config.target
+ );

  emit RewardProgramClosed(programId);
```

---

**Function**: `createRewardProgram`

**Specific Changes**:
7. **Retroactive start support (Past-start semantics)**: Initialize `lastRewardUpdate` to `startTime` when `startTime < block.timestamp`.

```diff
- store.programs[programId].state.lastRewardUpdate = block.timestamp;
+ store.programs[programId].state.lastRewardUpdate =
+     startTime < block.timestamp ? startTime : block.timestamp;
```

---

**New Function**: `setRewardProgramManager`

**Specific Changes**:
8. **Manager rotation**: Add a new external function for manager rotation.

```solidity
function setRewardProgramManager(uint256 programId, address newManager) external nonReentrant {
    LibCurrency.assertZeroMsgValue();
    if (newManager == address(0)) revert InvalidParameterRange("manager");
    LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
    _enforceManagerOrGovernance(program.config.manager);
    if (program.config.closed) revert InvalidParameterRange("programClosed");
    address oldManager = program.config.manager;
    program.config.manager = newManager;
    emit RewardProgramManagerUpdated(programId, oldManager, newManager);
}
```

Add the event declaration:
```solidity
event RewardProgramManagerUpdated(
    uint256 indexed programId, address indexed oldManager, address indexed newManager
);
```

---

**File**: `src/libraries/LibEdenRewardsStorage.sol`

**Struct**: `RewardProgramState`

**Specific Changes**:
9. **Add per-program backing fields**: Append new fields for backing isolation.

```diff
  struct RewardProgramState {
      uint256 fundedReserve;
      uint256 lastRewardUpdate;
      uint256 globalRewardIndex;
      uint256 eligibleSupply;
+     uint256 rewardIndexRemainder;    // Phase 1 addition (from fee-routing-accounting-cleanup)
+     uint256 programBackingBalance;   // Phase 3: actual token backing held for this program
  }
```

Note: `rewardIndexRemainder` is added by the Phase 1 spec. `programBackingBalance` is the Phase 3 addition. Storage layout must be append-only for compatibility.

**New Function**: `removeProgramFromTarget`

**Specific Changes**:
10. **Swap-and-pop removal for target arrays (Finding 4)**:

```solidity
function removeProgramFromTarget(
    RewardsStorage storage store,
    uint256 programId,
    RewardTarget memory target
) internal {
    uint256[] storage programIds = store.targetProgramIds[targetKey(target)];
    uint256 len = programIds.length;
    for (uint256 i = 0; i < len; i++) {
        if (programIds[i] == programId) {
            programIds[i] = programIds[len - 1];
            programIds.pop();
            return;
        }
    }
}
```

---

**File**: `src/libraries/LibEdenRewardsConsumer.sol`

**Function**: `beforeTargetBalanceChange` / `afterTargetBalanceChange`

**Specific Changes**:
11. **Skip closed programs in consumer loops (defense-in-depth)**: Add a closed-program check inside the iteration loops as a secondary guard in case any historical entries remain.

```diff
  for (uint256 i = 0; i < len; i++) {
      uint256 programId = programIds[i];
+     if (store.programs[programId].config.closed) continue;
      LibEdenRewardsEngine.settleProgramPosition(programIds[i], positionKey, eligibleBalance);
  }
```

```diff
  for (uint256 i = 0; i < len; i++) {
      uint256 programId = programIds[i];
+     if (store.programs[programId].config.closed) continue;
      store.programs[programId].state.eligibleSupply = eligibleSupply;
  }
```

### Dependencies

- Phase 1 `equalfi-fee-routing-accounting-cleanup` must land first — it adds `rewardIndexRemainder` to `RewardProgramState` and fixes the double gross-up. This spec's `programBackingBalance` field must be appended after `rewardIndexRemainder` in the struct.
- Track A (Native Asset Tracking) should land first — `LibCurrency.transfer` behavior affects claim delivery measurement.
- Track B (ACI/Encumbrance) should land first — eligible supply and settlement semantics should be stable before EDEN changes.

### Rebasing Token Design Direction

This spec introduces per-program backing isolation (`programBackingBalance`) which is the prerequisite for rebasing-safe reward support. The full rebasing reconciliation is not implemented here but the design direction is:

- On funding: `programBackingBalance += funded` (already implemented)
- On claim: `programBackingBalance -= grossClaimAmount` (already implemented)
- Future: add a `reconcileRewardProgramBacking(programId)` function that measures actual token balance attributable to the program and adjusts `programBackingBalance` accordingly
- Positive drift (rebase up): treat as additional reserve
- Negative drift (rebase down): impair reserve, fail closed if liabilities exceed backing
- This reconciliation function would be called before accrual and before claims in a rebasing-aware deployment

The backing isolation implemented in this spec makes this future reconciliation possible without further structural changes.

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bugs on unfixed code, then verify the fixes work correctly and preserve existing behavior. All tests use real reward-program creation, real ERC20 approvals, real funding calls, and real EqualIndex position mint/burn flows to exercise EDEN target hooks per workspace guidelines.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fixes. Confirm or refute the root cause analysis.

**Test Plan**: Write Foundry tests that exercise each bug condition on the UNFIXED code to observe failures and understand the root cause.

**Test Cases**:
1. **Partial Claim Restoration Test**: Create a reward program, fund it, accrue rewards, then manipulate available balance so `grossClaimAmount > availableGross`. Claim and assert that `accruedRewards` was restored with unbacked amount (will demonstrate finding 6 on unfixed code).
2. **FoT Overpayment Test**: Create a reward program with `outboundTransferBps > 0` using a mock FoT token where actual fee < configured. Claim and assert `netReceived > claimed` (will demonstrate FoT overpayment on unfixed code).
3. **Cross-Program Balance Theft Test**: Create two reward programs sharing the same reward token. Fund both. Drain one program's backing via claims. Attempt to claim from the drained program using the other program's backing. Assert the claim succeeds (will demonstrate cross-program coupling on unfixed code).
4. **ETH Lock Test**: Call `fundRewardProgram` with nonzero `msg.value`. Assert the call succeeds (will demonstrate finding 3 on unfixed code — should revert).
5. **Target Array Growth Test**: Create multiple programs for the same target, close them, assert `targetProgramIds` length includes closed programs (will demonstrate finding 4 on unfixed code).
6. **Past-Start Skip Test**: Create a program with `startTime` 1 day in the past. Assert `lastRewardUpdate == block.timestamp` (will demonstrate past-start skip on unfixed code — should be `startTime`).

**Expected Counterexamples**:
- Finding 6: `accruedRewards` restored with unbacked amount after partial claim
- FoT: `netReceived > claimed` when actual fee < configured
- Cross-program: claim succeeds using another program's backing
- Finding 3: `fundRewardProgram` accepts nonzero `msg.value`
- Finding 4: closed programs remain in `targetProgramIds`
- Past-start: `lastRewardUpdate` set to `block.timestamp` instead of `startTime`

### Fix Checking

**Goal**: Verify that for all inputs where each bug condition holds, the fixed functions produce the expected behavior.

**Pseudocode:**
```
// Finding 6 — Fail-closed claims
FOR ALL claim WHERE grossClaimAmount > programBackingBalance DO
  ASSERT REVERTS claimRewardProgram_fixed(programId, positionId, to)
END FOR

// FoT — Exact delivery
FOR ALL claim WHERE outboundTransferBps > 0 AND netReceived != claimed DO
  ASSERT REVERTS claimRewardProgram_fixed(programId, positionId, to)
END FOR

// Cross-program isolation
FOR ALL (programA, programB) WHERE sameRewardToken DO
  ASSERT claimRewardProgram_fixed(programA, ...) bounded by programA.programBackingBalance
  ASSERT claimRewardProgram_fixed(programB, ...) bounded by programB.programBackingBalance
END FOR

// Finding 3 — ETH guard
FOR ALL fundCall WHERE msg.value > 0 DO
  ASSERT REVERTS fundRewardProgram_fixed{value: msg.value}(...)
END FOR

// Finding 4 — Target cleanup
FOR ALL closeCall DO
  lenBefore := targetProgramIds.length
  closeRewardProgram_fixed(programId)
  ASSERT targetProgramIds.length == lenBefore - 1
END FOR

// Past-start
FOR ALL createCall WHERE startTime < block.timestamp DO
  createRewardProgram_fixed(...)
  ASSERT program.state.lastRewardUpdate == startTime
END FOR

// Manager rotation
FOR ALL rotateCall BY manager OR governance DO
  setRewardProgramManager_fixed(programId, newManager)
  ASSERT program.config.manager == newManager
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
1. **Creation Preservation**: Create programs with future `startTime`, verify `lastRewardUpdate == block.timestamp` and all other state identical
2. **Funding Preservation**: Fund programs with zero `msg.value`, verify `fundedReserve` and `programBackingBalance` increment correctly
3. **Accrual Preservation**: Accrue programs, verify eligible supply, index growth, and reserve deduction identical
4. **Settlement Preservation**: Settle positions, verify claimable computation identical
5. **Successful Claim Preservation**: Claim with sufficient backing and correct FoT config, verify transfer and events identical
6. **Lifecycle Preservation**: Enable/disable/pause/resume/end programs, verify config mutations identical
7. **Close Preservation**: Close programs with zero reserve after endTime, verify closed state identical
8. **View Preservation**: Preview positions and programs, verify computed values identical
9. **Consumer Hook Preservation**: Trigger EqualIndex mint/burn, verify settlement and supply updates for live programs identical

### Unit Tests

- `fundRewardProgram` reverts on nonzero `msg.value`
- `fundRewardProgram` with zero `msg.value` increments both `fundedReserve` and `programBackingBalance`
- `claimRewardProgram` reverts when `grossClaimAmount > programBackingBalance`
- `claimRewardProgram` reverts when `netReceived != claimed` (FoT mismatch)
- `claimRewardProgram` succeeds and decrements `programBackingBalance` on exact delivery
- `claimRewardProgram` with two same-token programs: each bounded by own backing
- `closeRewardProgram` removes program from `targetProgramIds`
- `closeRewardProgram` on last program in array: array becomes empty
- `closeRewardProgram` on middle program: swap-and-pop preserves other entries
- Consumer hooks skip closed programs in iteration
- `createRewardProgram` with past `startTime`: `lastRewardUpdate == startTime`
- `createRewardProgram` with future `startTime`: `lastRewardUpdate == block.timestamp`
- `setRewardProgramManager` by current manager: succeeds
- `setRewardProgramManager` by governance: succeeds
- `setRewardProgramManager` by unauthorized caller: reverts
- `setRewardProgramManager` with `address(0)`: reverts
- `setRewardProgramManager` on closed program: reverts

### Integration Tests

- Full EDEN lifecycle: create → fund → accrue → settle → claim → end → close — proves backing isolation and fail-closed claims end-to-end
- Two-program same-token lifecycle: create two programs with same reward token → fund both → accrue both → claim from each → verify isolation
- Past-start lifecycle: create with past `startTime` → fund → accrue → verify retroactive rewards accrued from `startTime`
- Target cleanup lifecycle: create 3 programs for same target → close 2 → verify consumer hooks only iterate 1 live program
- Manager rotation lifecycle: create → rotate manager → verify new manager controls lifecycle → verify old manager rejected
- FoT claim lifecycle: create with `outboundTransferBps` → fund → accrue → claim with matching FoT token → verify exact delivery
