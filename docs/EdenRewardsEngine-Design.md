# EDEN Rewards Engine - Design Document

**Version:** 1.0
**Module:** EDEN by EqualFi — Rewards Distribution Engine

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Reward Programs](#reward-programs)
5. [Accrual Mechanics](#accrual-mechanics)
6. [Settlement & Claiming](#settlement--claiming)
7. [Consumer Integration](#consumer-integration)
8. [Transfer Fee Support](#transfer-fee-support)
9. [Program Lifecycle](#program-lifecycle)
10. [Data Models](#data-models)
11. [View Functions](#view-functions)
12. [Integration Guide](#integration-guide)
13. [Worked Examples](#worked-examples)
14. [Error Reference](#error-reference)
15. [Events](#events)
16. [Security Considerations](#security-considerations)

---

## Overview

The EDEN Rewards Engine is the configurable, multi-program reward distribution system at the heart of the EDEN by EqualFi ecosystem. It distributes any ERC-20 reward token to eligible participants based on their position balances in specific protocol targets — currently stEVE positions and EqualIndex positions.

The engine uses a global reward index pattern (similar to Synthetix StakingRewards) scaled to 1e27 precision, with continuous per-second accrual, funded reserves, and automatic settlement hooks that integrate seamlessly with the protocol's balance-changing operations.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Multi-Program** | Unlimited reward programs, each with independent configuration |
| **Multi-Target** | Programs target stEVE positions or specific EqualIndex positions |
| **Any ERC-20 Reward** | Each program distributes its own configurable reward token |
| **Continuous Accrual** | Rewards accrue per-second based on a configurable rate |
| **Funded Reserve** | Programs must be funded; accrual stops when reserve is exhausted |
| **Automatic Settlement** | Consumer hooks settle rewards before any balance change |
| **Transfer Fee Aware** | Supports reward tokens with on-transfer fees (tax tokens) |
| **Manager + Governance** | Programs managed by a designated manager or governance |
| **1e27 Precision** | Global reward index uses 1e27 scale for dust-free accounting |

### System Participants

| Role | Description |
|------|-------------|
| **Position Holder** | User with a Position NFT whose eligible balance earns rewards |
| **Program Manager** | Address authorized to manage a specific reward program's lifecycle |
| **Governance** | Timelock/owner that creates programs and can override manager actions |
| **Funder** | Anyone who deposits reward tokens to fund a program's reserve |
| **Claimer** | Position owner who claims accrued rewards |

### Reward Targets

The engine supports two target types:

| Target Type | Description | Eligible Balance Source |
|-------------|-------------|----------------------|
| `STEVE_POSITION` | stEVE position holders | stEVE pool `userPrincipal[positionKey]` |
| `EQUAL_INDEX_POSITION` | EqualIndex position holders (per index) | Index pool `userPrincipal[positionKey]` |

Multiple programs can target the same target. Each program distributes independently.

---

## How It Works

### The Core Model

The engine uses a global reward index that increases over time proportional to the reward rate and inversely proportional to the eligible supply:

```
globalRewardIndex += (allocatedNet × 1e27) / eligibleSupply
```

Each position tracks a checkpoint of the global index at its last settlement. The pending rewards for a position are:

```
pendingRewards = eligibleBalance × (globalRewardIndex - positionCheckpoint) / 1e27
```

### Lifecycle

1. **Create** a reward program targeting stEVE or an EqualIndex
2. **Fund** the program by depositing reward tokens
3. **Accrual** happens automatically — the global index advances each second
4. **Settlement** happens automatically before any balance change, or manually
5. **Claim** accrued rewards to any address

### Why This Pattern?

The global reward index pattern is gas-efficient:
- Accrual is O(1) — one storage update regardless of participant count
- Settlement is O(1) per position per program
- No iteration over all participants needed
- Precision is maintained via 1e27 scaling

---

## Architecture

### Contract Structure

```
src/eden/
└── EdenRewardsFacet.sol            # Full public API: create, manage, fund, settle, claim, views

src/libraries/
├── LibEdenRewardsEngine.sol        # Core math: accrual, settlement, preview, transfer fee logic
├── LibEdenRewardsConsumer.sol       # Integration hooks: beforeBalanceChange, afterBalanceChange
├── LibEdenRewardsStorage.sol        # Diamond storage: programs, positions, targets
├── LibStEVERewards.sol             # stEVE-specific reward bridge
└── LibEqualIndexRewards.sol        # EqualIndex-specific reward bridge
```

### Integration Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                      EDEN Rewards Engine                             │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                    EdenRewardsFacet                             │  │
│  │  • createRewardProgram    • fundRewardProgram                  │  │
│  │  • setEnabled / pause / resume / end / close                   │  │
│  │  • accrueRewardProgram    • settleRewardProgramPosition        │  │
│  │  • claimRewardProgram     • preview views                      │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                              │                                       │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                   LibEdenRewardsEngine                         │  │
│  │  • accrueProgram          • settleProgramPosition              │  │
│  │  • previewProgramState    • grossUpNetAmount / netFromGross    │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                              │                                       │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                  LibEdenRewardsConsumer                        │  │
│  │  • beforeTargetBalanceChange (settle all programs for target)  │  │
│  │  • afterTargetBalanceChange  (sync eligible supply)            │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                              │                                       │
├──────────────────────────────────────────────────────────────────────┤
│                    Consumer Bridges                                   │
│  ┌──────────────────┐              ┌──────────────────────┐          │
│  │ LibStEVERewards  │              │ LibEqualIndexRewards │          │
│  │                  │              │                      │          │
│  │ settleBeforeElig │              │ settleBeforeElig     │          │
│  │ syncEligibleBal  │              │ syncEligibleBal      │          │
│  └────────┬─────────┘              └──────────┬───────────┘          │
│           │                                   │                      │
├───────────┼───────────────────────────────────┼──────────────────────┤
│           ▼                                   ▼                      │
│  ┌──────────────────┐              ┌──────────────────────┐          │
│  │  stEVE Facets    │              │  EqualIndex Facets   │          │
│  │  (deposit, mint, │              │  (mintFromPosition,  │          │
│  │   withdraw, burn)│              │   burnFromPosition)  │          │
│  └──────────────────┘              └──────────────────────┘          │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Reward Programs

### Program Configuration

Each reward program is defined by:

```solidity
struct RewardProgramConfig {
    RewardTarget target;            // What positions earn from this program
    address rewardToken;            // ERC-20 token to distribute
    address manager;                // Authorized manager address
    uint16 outboundTransferBps;     // Transfer fee compensation (for tax tokens)
    uint256 rewardRatePerSecond;    // Distribution rate (net rewards per second)
    uint256 startTime;              // Accrual start (0 = immediate)
    uint256 endTime;                // Accrual end (0 = indefinite)
    bool enabled;                   // Whether accrual is active
    bool paused;                    // Temporary pause
    bool closed;                    // Permanent closure
}
```

### Program State

```solidity
struct RewardProgramState {
    uint256 fundedReserve;          // Remaining reward tokens available
    uint256 lastRewardUpdate;       // Last accrual timestamp
    uint256 globalRewardIndex;      // Cumulative reward per unit of eligible supply (1e27 scale)
    uint256 eligibleSupply;         // Current total eligible supply
}
```

### Reward Target

```solidity
enum RewardTargetType {
    STEVE_POSITION,             // stEVE position holders
    EQUAL_INDEX_POSITION        // EqualIndex position holders (per index ID)
}

struct RewardTarget {
    RewardTargetType targetType;
    uint256 targetId;           // 0 for stEVE, indexId for EqualIndex
}
```

### Creating a Program

```solidity
uint256 programId = rewardsFacet.createRewardProgram(
    targetType,             // STEVE_POSITION or EQUAL_INDEX_POSITION
    targetId,               // 0 for stEVE, indexId for EqualIndex
    rewardToken,            // ERC-20 reward token address
    manager,                // Manager address
    rewardRatePerSecond,    // Distribution rate
    startTime,              // 0 for immediate start
    endTime,                // 0 for indefinite
    enabled                 // true to start accruing immediately
);
```

Requirements:
- Caller must be governance (timelock or owner)
- Reward token must be non-zero address
- Manager must be non-zero address
- Reward rate must be non-zero
- If endTime is set, it must be after startTime

### Program Constraints

| Constraint | Rule |
|------------|------|
| **stEVE target** | `targetId` must be 0 (`STEVE_TARGET_ID`) |
| **EqualIndex target** | Any valid `indexId` |
| **Transfer fee** | Can only be set before first accrual (`globalRewardIndex == 0`) |
| **Closure** | Requires `endTime` to have passed and `fundedReserve` to be 0 |

---

## Accrual Mechanics

### How Accrual Works

Every time the engine is touched (explicitly or via consumer hooks), it advances the global reward index:

```solidity
function _previewAccrual(config, state, timestamp) {
    // 1. Determine effective timestamp (capped at endTime)
    effectiveNow = min(timestamp, endTime)

    // 2. Skip if no time elapsed, or program is inactive
    if (effectiveNow <= lastRewardUpdate) return
    if (closed || !enabled || paused || rate == 0) {
        lastRewardUpdate = effectiveNow
        return
    }

    // 3. Calculate accrual window
    accrualStart = max(lastRewardUpdate, startTime)
    if (effectiveNow <= accrualStart) return

    // 4. Skip if no eligible supply or no funded reserve
    if (eligibleSupply == 0 || fundedReserve == 0) {
        lastRewardUpdate = effectiveNow
        return
    }

    // 5. Calculate rewards
    elapsed = effectiveNow - accrualStart
    maxNetRewards = elapsed × rewardRatePerSecond
    requiredGross = grossUpNetAmount(maxNetRewards, outboundTransferBps)
    allocatedGross = min(requiredGross, fundedReserve)
    allocatedNet = (requiredGross > fundedReserve)
        ? netFromGross(allocatedGross, outboundTransferBps)
        : maxNetRewards

    // 6. Update state
    fundedReserve -= allocatedGross
    globalRewardIndex += (allocatedNet × 1e27) / eligibleSupply
    lastRewardUpdate = effectiveNow
}
```

### Key Accrual Properties

| Property | Behavior |
|----------|----------|
| **Time-bounded** | Accrual respects `startTime` and `endTime` |
| **Reserve-bounded** | Accrual stops when `fundedReserve` is exhausted |
| **Supply-weighted** | Index advances inversely proportional to eligible supply |
| **Idempotent** | Multiple accruals in the same block produce the same result |
| **Transfer-fee-aware** | Gross amounts are deducted from reserve; net amounts drive the index |

### Eligible Supply Resolution

The eligible supply is resolved from the target's pool:

| Target | Pool | Supply Source |
|--------|------|---------------|
| `STEVE_POSITION` | stEVE pool | `pool.totalDeposits` (after maintenance) |
| `EQUAL_INDEX_POSITION` | Index pool | `pool.totalDeposits` (after maintenance) |

Maintenance fees are enforced before reading the supply, ensuring the eligible supply reflects the latest state.

### Accrual Triggers

The global index is advanced:
- Explicitly via `accrueRewardProgram(programId)`
- During settlement via `settleProgramPosition()`
- During funding via `fundRewardProgram()`
- Before any lifecycle mutation (enable, pause, resume, end)
- Implicitly via consumer hooks during balance-changing operations

---

## Settlement & Claiming

### Settlement

Settlement calculates a position's pending rewards and records them as claimable:

```solidity
function settleProgramPosition(programId, positionKey, eligibleBalance) {
    // 1. Accrue the program to current time
    state = accrueProgram(programId)

    // 2. Calculate pending rewards since last checkpoint
    checkpoint = positionRewardIndex[programId][positionKey]
    if (globalRewardIndex > checkpoint && eligibleBalance > 0) {
        pending = eligibleBalance × (globalRewardIndex - checkpoint) / 1e27
        accruedRewards[programId][positionKey] += pending
    }

    // 3. Update checkpoint
    positionRewardIndex[programId][positionKey] = globalRewardIndex
}
```

Settlement can be triggered:
- Explicitly via `settleRewardProgramPosition(programId, positionId)`
- Automatically via consumer hooks before any balance change

### Claiming

```solidity
uint256 claimed = rewardsFacet.claimRewardProgram(programId, positionId, to);
```

**Process:**
1. Verify position ownership
2. Settle the position (accrue + calculate pending)
3. Determine gross transfer amount (accounting for transfer fees)
4. Cap at available contract balance
5. Transfer reward tokens to recipient
6. Verify net received matches expected (handles tax tokens)
7. If net received is less than expected, re-accrue the difference
8. Clear accrued rewards (or leave remainder if partial)

### Transfer Fee Handling on Claim

For reward tokens with on-transfer fees:

```solidity
// 1. Gross up the net claimable amount
grossClaimAmount = grossUpNetAmount(claimed, outboundTransferBps)

// 2. Cap at available balance
grossClaimAmount = min(grossClaimAmount, contractBalance)

// 3. Transfer gross amount
transfer(rewardToken, to, grossClaimAmount)

// 4. Verify net received
netReceived = balanceAfter - balanceBefore
if (netReceived < claimed) {
    // Re-accrue the shortfall
    accruedRewards[programId][positionKey] = claimed - netReceived
    claimed = netReceived
}
```

This ensures the recipient receives the expected net amount even when the token has transfer fees.

---

## Consumer Integration

### How Products Integrate

Products (stEVE, EqualIndex) integrate with the rewards engine through consumer bridges. These bridges are called automatically during balance-changing operations.

### Before Balance Change

Called before any operation that changes a position's eligible balance:

```solidity
LibEdenRewardsConsumer.beforeTargetBalanceChange(target, positionKey, eligibleBalance);
```

This settles all reward programs for the target, ensuring pending rewards are captured at the old balance before it changes.

**Internally:**
1. Iterates all program IDs registered for the target
2. Calls `settleProgramPosition()` for each, which:
   - Accrues the program to current time
   - Calculates and records pending rewards for the position
   - Updates the position's reward checkpoint

### After Balance Change

Called after the balance change is complete:

```solidity
LibEdenRewardsConsumer.afterTargetBalanceChange(target);
```

This updates the eligible supply for all programs targeting this target.

**Internally:**
1. Reads the current eligible supply from the target's pool
2. Updates `eligibleSupply` in each program's state

### Integration Flow

```
User calls depositStEVEToPosition(tokenId, amount)
  │
  ├─ 1. settleBeforeEligibleBalanceChange(positionKey)
  │     ├─ LibFeeIndex.settle(poolId, positionKey)
  │     ├─ Read eligibleBalance = pool.userPrincipal[positionKey]
  │     └─ LibEdenRewardsConsumer.beforeTargetBalanceChange(target, positionKey, eligibleBalance)
  │           └─ For each program targeting stEVE:
  │                 └─ settleProgramPosition(programId, positionKey, eligibleBalance)
  │
  ├─ 2. Execute deposit (increase pool.userPrincipal)
  │
  └─ 3. syncEligibleBalanceChange()
        └─ LibEdenRewardsConsumer.afterTargetBalanceChange(target)
              └─ For each program targeting stEVE:
                    └─ program.state.eligibleSupply = pool.totalDeposits
```

### Consumer Bridges

| Bridge | Target | Used By |
|--------|--------|---------|
| `LibStEVERewards` | `STEVE_POSITION` (targetId=0) | StEVEActionFacet, StEVEPositionFacet |
| `LibEqualIndexRewards` | `EQUAL_INDEX_POSITION` (targetId=indexId) | EqualIndexPositionFacet |

---

## Transfer Fee Support

### Problem

Some ERC-20 tokens charge a fee on every transfer (tax tokens). If a reward program distributes such a token, the recipient would receive less than the accrued amount.

### Solution

The engine supports an `outboundTransferBps` configuration per program. This value represents the expected transfer fee in basis points.

### How It Works

**During accrual:**
The engine calculates the gross amount needed from the reserve to deliver the target net rewards:

```solidity
requiredGross = grossUpNetAmount(maxNetRewards, outboundTransferBps)
```

The gross amount is deducted from the funded reserve, but only the net amount drives the global reward index.

**During claim:**
The engine grosses up the net claimable amount before transferring:

```solidity
grossClaimAmount = grossUpNetAmount(netClaimable, outboundTransferBps)
```

After transfer, it verifies the recipient received the expected net amount. Any shortfall is re-accrued.

### Gross-Up Math

```solidity
// Net from gross
netAmount = grossAmount - (grossAmount × outboundTransferBps / 10,000)

// Gross from net (inverse, with ceiling)
grossAmount = netAmount × 10,000 / (10,000 - outboundTransferBps)
// Refined iteratively to find the minimum gross that yields the target net
```

### Constraints

- `outboundTransferBps` can only be set before the first accrual (`globalRewardIndex == 0`)
- Must be less than 10,000 (100%)
- Setting to 0 disables transfer fee handling (standard ERC-20 behavior)

---

## Program Lifecycle

### State Machine

```
                    ┌──────────────┐
                    │   Created    │ ◄── createRewardProgram()
                    │  (enabled    │     (enabled=true or false)
                    │   or not)    │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
     setEnabled(true)      │     setEnabled(false)
              │            │            │
              ▼            │            ▼
        ┌──────────┐       │      ┌──────────┐
        │ Accruing │ ◄─────┘      │ Disabled │
        │          │ ◄────────────│          │
        └────┬─────┘  setEnabled  └──────────┘
             │        (true)
    ┌────────┼────────┐
    │        │        │
  pause()    │    endRewardProgram()
    │        │        │
    ▼        │        ▼
┌────────┐   │   ┌──────────┐
│ Paused │   │   │  Ended   │
└───┬────┘   │   └────┬─────┘
    │        │        │
 resume()    │   closeRewardProgram()
    │        │   (reserve must be 0)
    ▼        │        │
  Accruing   │        ▼
             │   ┌──────────┐
             │   │  Closed  │  (terminal)
             │   └──────────┘
             │
        fundRewardProgram()
        (adds to reserve)
```

### Lifecycle Operations

| Operation | Who | Requirements | Effect |
|-----------|-----|-------------|--------|
| `createRewardProgram` | Governance | Valid target, non-zero rate | Creates program, registers target |
| `setRewardProgramEnabled` | Manager or governance | Not closed | Enables/disables accrual |
| `pauseRewardProgram` | Manager or governance | Not closed, not already paused | Temporarily stops accrual |
| `resumeRewardProgram` | Manager or governance | Not closed, currently paused | Resumes accrual |
| `endRewardProgram` | Manager or governance | Not closed, not already ended | Sets endTime to now, disables |
| `closeRewardProgram` | Manager or governance | Not closed, ended, reserve = 0 | Permanently closes |
| `fundRewardProgram` | Anyone | Not closed | Deposits reward tokens to reserve |
| `setRewardProgramTransferFeeBps` | Manager or governance | Not closed, no accrual yet | Sets transfer fee compensation |

### Accrual Before Mutation

Every lifecycle mutation (enable, pause, resume, end) accrues the program first:

```solidity
_accrueBeforeLifecycleMutation(programId, program);
```

This ensures rewards are correctly distributed up to the moment of the state change.

---

## Data Models

### Rewards Storage

```solidity
struct RewardsStorage {
    uint256 nextProgramId;                                          // Monotonic program ID counter
    mapping(uint256 => RewardProgram) programs;                     // Program ID → program
    mapping(uint256 => mapping(bytes32 => uint256)) positionRewardIndex;  // Program × position → checkpoint
    mapping(uint256 => mapping(bytes32 => uint256)) accruedRewards; // Program × position → claimable
    mapping(bytes32 => uint256[]) targetProgramIds;                 // Target key → program IDs
}
```

### Target Key Derivation

```solidity
function targetKey(RewardTarget memory target) internal pure returns (bytes32) {
    return keccak256(abi.encode(uint8(target.targetType), target.targetId));
}
```

### Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `REWARD_INDEX_SCALE` | 1e27 | Global reward index precision |
| `STEVE_TARGET_ID` | 0 | stEVE target identifier |
| `TRANSFER_FEE_BPS_SCALE` | 10,000 | Basis point denominator for transfer fees |
| `STORAGE_POSITION` | `keccak256("equalfi.eden.rewards.engine.storage")` | Diamond storage slot |

---

## View Functions

### Program Queries

```solidity
// Get program configuration and state
function getRewardProgram(uint256 programId)
    external view returns (RewardProgramConfig memory config, RewardProgramState memory state);

// Preview program state with accrual projected to current time
function previewRewardProgramState(uint256 programId)
    external view returns (RewardProgramState memory state);

// Get all program IDs for a target
function getRewardProgramIdsByTarget(RewardTargetType targetType, uint256 targetId)
    external view returns (uint256[] memory programIds);
```

### Position Queries

```solidity
// Preview a position's reward state for a specific program
function previewRewardProgramPosition(uint256 programId, uint256 positionId)
    external view returns (RewardProgramPositionView memory);

// Preview claimable rewards across multiple programs for a position
function previewRewardProgramsForPosition(uint256 positionId, uint256[] calldata programIds)
    external view returns (RewardProgramClaimPreview[] memory previews, uint256 totalClaimable);
```

### Position View Structs

```solidity
struct RewardProgramPositionView {
    uint256 eligibleBalance;            // Position's current eligible balance
    uint256 rewardCheckpoint;           // Position's last settled index
    uint256 accruedRewards;             // Already-settled claimable rewards
    uint256 pendingRewards;             // Unsettled rewards since last checkpoint
    uint256 claimableRewards;           // Total: accrued + pending
    uint256 previewGlobalRewardIndex;   // Projected global index at current time
    address rewardToken;                // Reward token address
}

struct RewardProgramClaimPreview {
    uint256 programId;
    address rewardToken;
    uint256 claimableRewards;
}
```

---

## Integration Guide

### For Governance (Creating Programs)

#### Create a stEVE Reward Program

```solidity
uint256 programId = rewardsFacet.createRewardProgram(
    RewardTargetType.STEVE_POSITION,    // Target stEVE holders
    0,                                   // STEVE_TARGET_ID
    edenToken,                           // Reward token
    managerAddress,                      // Program manager
    1e18,                                // 1 EDEN per second
    block.timestamp,                     // Start now
    block.timestamp + 365 days,          // End in 1 year
    true                                 // Enabled immediately
);
```

#### Create an EqualIndex Reward Program

```solidity
uint256 programId = rewardsFacet.createRewardProgram(
    RewardTargetType.EQUAL_INDEX_POSITION,  // Target index holders
    indexId,                                 // Specific index ID
    rewardToken,                             // Any ERC-20
    managerAddress,                          // Program manager
    0.5e18,                                  // 0.5 tokens per second
    block.timestamp + 7 days,                // Start in 1 week
    0,                                       // No end time (indefinite)
    true                                     // Enabled
);
```

#### Fund a Program

```solidity
IERC20(rewardToken).approve(diamond, 1_000_000e18);
uint256 funded = rewardsFacet.fundRewardProgram(programId, 1_000_000e18, 1_000_000e18);
```

Anyone can fund a program — it doesn't require governance or manager access.

### For Program Managers

#### Pause and Resume

```solidity
// Pause accrual temporarily
rewardsFacet.pauseRewardProgram(programId);

// Resume accrual
rewardsFacet.resumeRewardProgram(programId);
```

#### End and Close

```solidity
// End the program (sets endTime to now)
rewardsFacet.endRewardProgram(programId);

// After all rewards are claimed (reserve = 0):
rewardsFacet.closeRewardProgram(programId);
```

#### Configure Transfer Fee (Before First Accrual Only)

```solidity
// For tax tokens with 2% transfer fee
rewardsFacet.setRewardProgramTransferFeeBps(programId, 200);
```

### For Position Holders (Claiming)

#### Check Claimable Rewards

```solidity
// Preview for a single program
RewardProgramPositionView memory view_ =
    rewardsFacet.previewRewardProgramPosition(programId, positionId);
// view_.claimableRewards = accrued + pending

// Preview across multiple programs
uint256[] memory programIds = new uint256[](2);
programIds[0] = 0;
programIds[1] = 1;
(RewardProgramClaimPreview[] memory previews, uint256 totalClaimable) =
    rewardsFacet.previewRewardProgramsForPosition(positionId, programIds);
```

#### Claim Rewards

```solidity
// Claim from a specific program
uint256 claimed = rewardsFacet.claimRewardProgram(programId, positionId, msg.sender);
```

Requirements:
- Caller must own the Position NFT
- There must be claimable rewards
- The contract must hold sufficient reward tokens

#### Manual Settlement (Optional)

```solidity
// Settle without claiming (useful for updating checkpoint)
uint256 claimable = rewardsFacet.settleRewardProgramPosition(programId, positionId);
```

### For Integrators

#### Triggering Accrual

```solidity
// Manually accrue a program (useful for off-chain monitoring)
RewardProgramState memory state = rewardsFacet.accrueRewardProgram(programId);
```

---

## Worked Examples

### Example 1: Basic Reward Distribution

**Scenario:** A stEVE reward program distributes 100 EDEN tokens per day to position holders.

**Setup:**
```
Program: 100 EDEN/day = ~0.001157 EDEN/second
Eligible supply: 1,000,000 stEVE
Alice: 10,000 stEVE (1% of supply)
Bob: 50,000 stEVE (5% of supply)
Funded reserve: 36,500 EDEN (1 year of rewards)
```

**Day 1: Accrual**
```
elapsed = 86,400 seconds
maxNetRewards = 86,400 × 0.001157 ≈ 100 EDEN
allocatedNet = 100 EDEN (reserve sufficient)
fundedReserve: 36,500 - 100 = 36,400 EDEN

globalRewardIndex += (100 × 1e27) / 1,000,000
                   = 1e23 (0.0001 EDEN per unit)
```

**Day 1: Alice Settles**
```
eligibleBalance = 10,000
pending = 10,000 × (1e23 - 0) / 1e27 = 1.0 EDEN
accruedRewards[alice] = 1.0 EDEN
positionRewardIndex[alice] = 1e23
```

**Day 1: Bob Settles**
```
eligibleBalance = 50,000
pending = 50,000 × (1e23 - 0) / 1e27 = 5.0 EDEN
accruedRewards[bob] = 5.0 EDEN
positionRewardIndex[bob] = 1e23
```

**Verification:** Alice (1%) + Bob (5%) = 6 EDEN out of 100 total. The remaining 94 EDEN is distributed to other position holders proportionally.

### Example 2: Supply Change Mid-Period

**Scenario:** Carol deposits stEVE halfway through a reward period, diluting the per-unit rate.

**Day 0:**
```
Eligible supply: 100,000 stEVE
Alice: 10,000 stEVE (10%)
Rate: 100 EDEN/day
```

**Day 5: Carol deposits 100,000 stEVE**
```
Before deposit — settlement triggers:
  elapsed = 5 days = 432,000 seconds
  allocated = 500 EDEN
  globalRewardIndex += (500 × 1e27) / 100,000 = 5e24

  Alice settled: 10,000 × 5e24 / 1e27 = 50 EDEN ✓ (10% of 500)

After deposit:
  Eligible supply: 200,000 stEVE
  afterTargetBalanceChange() updates all programs:
    program.state.eligibleSupply = 200,000
```

**Day 10: Alice settles again**
```
elapsed since Day 5 = 5 days
allocated = 500 EDEN
globalRewardIndex += (500 × 1e27) / 200,000 = 2.5e24

Alice pending: 10,000 × 2.5e24 / 1e27 = 25 EDEN (5% of 500)
Alice total: 50 + 25 = 75 EDEN over 10 days

Carol pending: 100,000 × 2.5e24 / 1e27 = 250 EDEN (50% of 500)
```

### Example 3: Reserve Exhaustion

**Scenario:** A program runs out of funded reserve mid-period.

**Setup:**
```
Rate: 1,000 EDEN/day
Funded reserve: 500 EDEN (only half a day of rewards)
Eligible supply: 100,000 stEVE
```

**Accrual:**
```
elapsed = 86,400 seconds (1 day)
maxNetRewards = 1,000 EDEN
requiredGross = 1,000 EDEN (no transfer fee)
allocatedGross = min(1,000, 500) = 500 EDEN (reserve-bounded)
allocatedNet = 500 EDEN

fundedReserve: 0 EDEN (exhausted)
globalRewardIndex += (500 × 1e27) / 100,000

Subsequent accruals: no allocation (fundedReserve == 0)
Program continues to exist but distributes nothing until re-funded.
```

### Example 4: Tax Token Rewards

**Scenario:** A program distributes a token with a 2% transfer fee.

**Setup:**
```
outboundTransferBps = 200 (2%)
Rate: 100 tokens/day (net)
Funded reserve: 10,200 tokens (gross, accounting for fees)
```

**Accrual (1 day):**
```
maxNetRewards = 100 tokens
requiredGross = grossUpNetAmount(100, 200)
             = 100 × 10,000 / (10,000 - 200)
             = 100 × 10,000 / 9,800
             ≈ 102.04 tokens

allocatedGross = 102.04 tokens (deducted from reserve)
allocatedNet = 100 tokens (drives the index)
fundedReserve: 10,200 - 102.04 = 10,097.96 tokens
```

**Claim (Alice has 10 net tokens accrued):**
```
grossClaimAmount = grossUpNetAmount(10, 200) ≈ 10.204 tokens
Transfer 10.204 tokens to Alice
Alice receives: 10.204 - (10.204 × 2%) = 10.204 - 0.204 ≈ 10.0 tokens ✓

Verification: balanceAfter - balanceBefore = 10.0 ≥ 10.0 ✓
```

---

## Error Reference

### Program Errors

| Error | Cause |
|-------|-------|
| `RewardProgramNotFound(uint256)` | Program ID does not exist |
| `InvalidParameterRange("rewardRatePerSecond")` | Zero reward rate |
| `InvalidParameterRange("rewardWindow")` | End time before or equal to start time |
| `InvalidParameterRange("manager")` | Zero address manager |
| `InvalidParameterRange("steveTargetId")` | stEVE target with non-zero target ID |
| `InvalidParameterRange("targetType")` | Unknown target type |
| `InvalidUnderlying()` | Zero address reward token |

### Lifecycle Errors

| Error | Cause |
|-------|-------|
| `InvalidParameterRange("programClosed")` | Operation on a closed program |
| `InvalidParameterRange("programPaused")` | Pause on already-paused program |
| `InvalidParameterRange("programNotPaused")` | Resume on non-paused program |
| `InvalidParameterRange("programEnded")` | End on already-ended program |
| `InvalidParameterRange("programNotEnded")` | Close on program that hasn't ended |
| `InvalidParameterRange("programReserve")` | Close with non-zero funded reserve |
| `InvalidParameterRange("programAccrued")` | Set transfer fee after accrual started |
| `InvalidParameterRange("outboundTransferBps")` | Transfer fee ≥ 100% |

### Claim Errors

| Error | Cause |
|-------|-------|
| `InvalidParameterRange("nothing claimable")` | No accrued rewards to claim |
| `InvalidParameterRange("programBalance")` | Contract has no reward tokens to transfer |
| `InvalidParameterRange("amount=0")` | Zero funding amount |
| `Unauthorized()` | Caller is not manager or governance |

---

## Events

### Program Lifecycle Events

```solidity
event RewardProgramCreated(
    uint256 indexed programId,
    uint8 indexed targetType,
    uint256 indexed targetId,
    address rewardToken,
    address manager,
    uint256 rewardRatePerSecond,
    uint256 startTime,
    uint256 endTime,
    bool enabled
);

event RewardProgramEnabledUpdated(uint256 indexed programId, bool enabled);
event RewardProgramPaused(uint256 indexed programId);
event RewardProgramResumed(uint256 indexed programId);
event RewardProgramEnded(uint256 indexed programId, uint256 endTime);
event RewardProgramClosed(uint256 indexed programId);
event RewardProgramTransferFeeUpdated(uint256 indexed programId, uint16 outboundTransferBps);
```

### Funding & Accrual Events

```solidity
event RewardProgramFunded(
    uint256 indexed programId,
    address indexed funder,
    uint256 amount
);

event RewardProgramAccrued(
    uint256 indexed programId,
    uint256 allocated,              // Gross tokens consumed from reserve
    uint256 globalRewardIndex,      // Updated global index
    uint256 fundedReserve,          // Remaining reserve
    uint256 lastRewardUpdate        // Accrual timestamp
);
```

### Settlement & Claim Events

```solidity
event RewardProgramPositionSettled(
    uint256 indexed programId,
    bytes32 indexed positionKey,
    uint256 eligibleBalance,        // Position's eligible balance at settlement
    uint256 claimable,              // Total claimable after settlement
    uint256 rewardCheckpoint        // Updated position checkpoint
);

event RewardProgramClaimed(
    uint256 indexed programId,
    uint256 indexed positionId,
    bytes32 indexed positionKey,
    address to,                     // Recipient address
    uint256 amount                  // Net amount received
);
```

---

## Security Considerations

### 1. 1e27 Precision Scale

The global reward index uses 1e27 scaling to prevent precision loss:

```solidity
uint256 internal constant REWARD_INDEX_SCALE = 1e27;
globalRewardIndex += (allocatedNet × 1e27) / eligibleSupply;
pending = eligibleBalance × (globalRewardIndex - checkpoint) / 1e27;
```

This provides sufficient precision even with very large eligible supplies and very small reward rates.

### 2. Reserve-Bounded Accrual

Rewards can never exceed the funded reserve:

```solidity
allocatedGross = min(requiredGross, fundedReserve);
```

If the reserve is exhausted, accrual stops. The program continues to exist but distributes nothing until re-funded. This prevents unbacked reward promises.

### 3. Settlement Before Balance Change

Consumer hooks ensure rewards are settled at the old balance before any change:

```solidity
// 1. Settle at old balance (captures pending rewards)
beforeTargetBalanceChange(target, positionKey, oldBalance);
// 2. Change balance
// 3. Update eligible supply
afterTargetBalanceChange(target);
```

This prevents a user from depositing a large amount and immediately claiming rewards that should have been distributed to existing holders.

### 4. Accrual Before Lifecycle Mutation

Every lifecycle change (enable, pause, resume, end) accrues first:

```solidity
_accrueBeforeLifecycleMutation(programId, program);
```

This ensures rewards are correctly distributed up to the exact moment of the state change.

### 5. Transfer Fee Safety Net

For tax tokens, the claim function verifies net receipt:

```solidity
uint256 netReceived = balanceAfter - balanceBefore;
if (netReceived < claimed) {
    accruedRewards[programId][positionKey] = claimed - netReceived;
    claimed = netReceived;
}
```

If the actual transfer fee differs from the configured `outboundTransferBps`, the shortfall is re-accrued rather than lost.

### 6. Transfer Fee Immutability After Accrual

`outboundTransferBps` can only be set when `globalRewardIndex == 0`:

```solidity
if (program.state.globalRewardIndex != 0) revert InvalidParameterRange("programAccrued");
```

This prevents mid-program changes that could create accounting inconsistencies.

### 7. Governance-Only Program Creation

Only governance (timelock or owner) can create reward programs:

```solidity
LibAccess.enforceTimelockOrOwnerIfUnset();
```

Program management (pause, resume, end) can be done by the designated manager or governance.

### 8. Closure Requires Empty Reserve

Programs can only be closed when the funded reserve is zero:

```solidity
if (program.state.fundedReserve != 0) revert InvalidParameterRange("programReserve");
```

This ensures all funded tokens are either distributed or the program has ended and rewards have been claimed.

### 9. Eligible Supply from Authoritative Pool State

The eligible supply is derived from the pool's `totalDeposits` after maintenance enforcement:

```solidity
LibMaintenance.enforce(poolId);
return pool.totalDeposits;
```

This ensures the supply reflects the latest maintenance fee deductions, preventing stale supply from inflating per-unit rewards.

### 10. Reentrancy Protection

All facet functions use `nonReentrant` modifier, protecting against reentrancy during ERC-20 transfers (funding, claiming).

### 11. Position Ownership on Claim

Only the Position NFT owner can claim rewards:

```solidity
LibPositionHelpers.requireOwnership(positionId);
```

Settlement (without claiming) is permissionless, allowing anyone to update a position's checkpoint.

### 12. Idempotent Accrual

Multiple accruals within the same block produce identical results because `effectiveNow <= lastRewardUpdate` causes an early return:

```solidity
if (effectiveNow <= state.lastRewardUpdate) return state;
```

---

## Appendix: Correctness Properties

### Property 1: Index Monotonicity
The global reward index only increases:
```
globalRewardIndex_new ≥ globalRewardIndex_old
```

### Property 2: Reserve Conservation
Funded reserve only decreases via accrual or never goes negative:
```
fundedReserve_new = fundedReserve_old - allocatedGross
fundedReserve ≥ 0
```

### Property 3: Accrual Boundedness
Allocated rewards never exceed the funded reserve:
```
allocatedGross ≤ fundedReserve
```

### Property 4: Settlement Idempotency
Settling a position twice in the same block produces no additional rewards:
```
settle(programId, positionKey, balance) → claimable_1
settle(programId, positionKey, balance) → claimable_2
claimable_1 == claimable_2 (checkpoint already updated)
```

### Property 5: Pro-Rata Distribution
For any two positions settled at the same index:
```
rewards_A / rewards_B = eligibleBalance_A / eligibleBalance_B
```

### Property 6: Time-Bounded Accrual
Accrual respects program time bounds:
```
effectiveNow = min(block.timestamp, endTime)
No accrual before startTime
No accrual after endTime
```

### Property 7: Supply Consistency
After `afterTargetBalanceChange`:
```
program.state.eligibleSupply = pool.totalDeposits (after maintenance)
```

### Property 8: Checkpoint Consistency
After settlement:
```
positionRewardIndex[programId][positionKey] == program.state.globalRewardIndex
```

### Property 9: Claim Completeness
After a successful claim:
```
accruedRewards[programId][positionKey] == 0
(or remainder if net received < expected due to transfer fee mismatch)
```

### Property 10: Transfer Fee Accounting
For programs with `outboundTransferBps > 0`:
```
grossAllocated = grossUpNetAmount(netRewards, outboundTransferBps)
netFromGross(grossAllocated, outboundTransferBps) ≥ netRewards
fundedReserve decremented by grossAllocated (not netRewards)
```

### Property 11: Inactive Program Safety
Closed, disabled, or paused programs do not accrue:
```
if (closed || !enabled || paused) → globalRewardIndex unchanged
lastRewardUpdate still advances (prevents retroactive accrual on resume)
```

### Property 12: Multi-Program Independence
Programs targeting the same target accrue and settle independently:
```
∀ programId_A, programId_B targeting same target:
  globalRewardIndex_A independent of globalRewardIndex_B
  accruedRewards[A][position] independent of accruedRewards[B][position]
```

---

**Document Version:** 1.0
**Module:** EDEN Rewards Engine — EDEN by EqualFi Rewards Distribution System