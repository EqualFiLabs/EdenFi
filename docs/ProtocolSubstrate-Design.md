# EqualFi Protocol Substrate - Design Document
## Encumbrance, Fee Index & Active Credit Index

**Version:** 1.0
**Module:** EqualFi Shared Liquidity & Fee Rails

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Pool System](#pool-system)
5. [Fee Index (FI)](#fee-index-fi)
6. [Active Credit Index (ACI)](#active-credit-index-aci)
7. [Encumbrance System](#encumbrance-system)
8. [Fee Router](#fee-router)
9. [Maintenance Fees](#maintenance-fees)
10. [Fee Base Normalization](#fee-base-normalization)
11. [Data Models](#data-models)
12. [Integration Guide](#integration-guide)
13. [Worked Examples](#worked-examples)
14. [Events](#events)
15. [Security Considerations](#security-considerations)

---

## Overview

The EqualFi Protocol Substrate is the shared infrastructure layer that enables every product — Self-Secured Credit, EqualIndex, stEVE, EqualScale, and future venues — to operate on the same liquidity pools and fee distribution rails. At its core are three interlocking systems:

1. **Fee Index (FI)** — distributes yield to all depositors proportional to their net equity
2. **Active Credit Index (ACI)** — distributes yield to active participants (borrowers, encumbered positions) with a 24-hour time gate
3. **Encumbrance System** — tracks locked principal across all venues with type-specific isolation

Together, these systems allow new protocol modules to plug into existing pools without fragmenting liquidity or building custom fee distribution. A flash loan fee, a penalty seizure, an index mint fee, and an EqualScale interest payment all flow through the same routing infrastructure.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Shared Liquidity** | All venues operate on the same per-asset pools |
| **Unified Fee Rails** | Every fee source routes through FI/ACI/Treasury splits |
| **1e18 Precision** | Both FI and ACI use 1e18-scaled global indexes |
| **Fee Base Normalization** | Borrowers earn reduced FI yield proportional to their debt |
| **24h Time Gate** | ACI requires 24-hour maturity to prevent flash-farming |
| **Weighted Dilution** | ACI uses weighted averaging to prevent dust-priming attacks |
| **Bucket-Based Maturity** | Hourly bucket ring for gas-efficient maturity tracking |
| **Multi-Type Encumbrance** | Five encumbrance types with per-venue isolation |
| **Maintenance Fees** | Annual pool-level fees reduce principal via a maintenance index |
| **Remainder Tracking** | Per-pool remainders prevent precision loss on small accruals |

### Why a Shared Substrate?

Traditional DeFi protocols build isolated liquidity silos for each product. EqualFi takes a different approach:

- **One pool per asset** → USDC deposited for self-secured credit is the same USDC backing EqualIndex tokens and stEVE lending
- **One fee index per pool** → Flash loan fees, penalty seizures, action fees, and index fees all accrue to the same depositor base
- **One encumbrance ledger** → Self-secured credit locks, index encumbrance, module encumbrance, and EqualScale commitments all tracked centrally
- **Additive venues** → New products plug into existing pools without migration or liquidity fragmentation

This is what makes EqualFi a protocol substrate rather than a collection of separate products.

---

## How It Works

### The Core Loop

Every fee-generating event in the protocol follows the same path:

```
Fee Event (flash loan, penalty, action fee, index fee, etc.)
    │
    ▼
Fee Router (LibFeeRouter)
    │
    ├── Treasury Share ──► Protocol Treasury
    │
    ├── Active Credit Share ──► ACI (LibActiveCreditIndex)
    │                              │
    │                              └── Distributed to mature active participants
    │
    └── Fee Index Share ──► FI (LibFeeIndex)
                               │
                               └── Distributed to all depositors by net equity
```

### Settlement

When a position interacts with the protocol, both indexes are settled:

```solidity
LibFeeIndex.settle(poolId, positionKey);        // Settle FI yield + maintenance
LibActiveCreditIndex.settle(poolId, positionKey); // Settle ACI yield
```

Settlement calculates pending yield since the position's last checkpoint and adds it to `userAccruedYield`.

---

## Architecture

### Library Structure

```
src/libraries/
├── LibFeeIndex.sol             # Fee Index: accrual, settlement, yield preview
├── LibActiveCreditIndex.sol    # Active Credit Index: time-gated accrual, bucket maturity
├── LibEncumbrance.sol          # Central encumbrance: 5 types, per-venue isolation
├── LibIndexEncumbrance.sol     # Index-specific encumbrance wrapper
├── LibModuleEncumbrance.sol    # Module-specific encumbrance wrapper
├── LibFeeRouter.sol            # Fee routing: Treasury/ACI/FI splits
├── LibMaintenance.sol          # Maintenance fees: daily accrual, index-based reduction
├── LibNetEquity.sol            # Fee base normalization (principal - sameAssetDebt)
└── Types.sol                   # Shared data structures (PoolData, etc.)
```

### How Venues Connect

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Protocol Venues                              │
│                                                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│  │  Self-   │  │  Equal   │  │  stEVE   │  │  Equal   │  ┌───────┐  │
│  │ Secured  │  │  Index   │  │          │  │  Scale   │  │Future │  │
│  │ Credit   │  │          │  │          │  │  Alpha   │  │Venues │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───┬───┘  │
│       │              │              │              │            │     │
│       └──────────────┼──────────────┼──────────────┼────────────┘     │
│                      │              │              │                  │
├──────────────────────┼──────────────┼──────────────┼──────────────────┤
│                      ▼              ▼              ▼                  │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                    Fee Router (LibFeeRouter)                    │  │
│  │  previewSplit() → Treasury / ACI / FI                          │  │
│  │  routeSamePool() / routeManagedShare()                         │  │
│  └──────────┬──────────────┬──────────────┬───────────────────────┘  │
│             │              │              │                           │
│             ▼              ▼              ▼                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│  │   Treasury   │  │     ACI      │  │      FI      │               │
│  │              │  │  (24h gate)  │  │  (net equity) │               │
│  └──────────────┘  └──────────────┘  └──────────────┘               │
│                           │              │                           │
│                           └──────┬───────┘                           │
│                                  ▼                                   │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                    Per-Pool State                               │  │
│  │  totalDeposits │ trackedBalance │ yieldReserve │ feeIndex      │  │
│  │  activeCreditIndex │ maintenanceIndex │ encumbrance             │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                    Per-Position State                           │  │
│  │  userPrincipal │ userFeeIndex │ userMaintenanceIndex           │  │
│  │  userAccruedYield │ sameAssetDebt │ encumbrance                │  │
│  │  activeCreditStateEncumbrance │ activeCreditStateDebt          │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Pool System

### One Pool Per Asset

Each underlying asset has a single canonical pool. All venues share this pool:

```
USDC Pool (pid=1):
  ├── Self-Secured Credit deposits and loans
  ├── EqualIndex constituent asset backing
  ├── EqualScale settlement and collateral
  └── Future venue deposits
```

### Pool State

Each pool tracks:

| Field | Purpose |
|-------|---------|
| `totalDeposits` | Sum of all user principal (reduced by maintenance) |
| `trackedBalance` | Actual token balance held by the contract for this pool |
| `yieldReserve` | Backing reserve for accrued FI and ACI yield |
| `feeIndex` | Global Fee Index (1e18 scale) |
| `feeIndexRemainder` | Precision remainder for FI accrual |
| `activeCreditIndex` | Global Active Credit Index (1e18 scale) |
| `activeCreditIndexRemainder` | Precision remainder for ACI accrual |
| `activeCreditMaturedTotal` | Total matured ACI-eligible principal |
| `activeCreditPrincipalTotal` | Total ACI principal (matured + pending) |
| `activeCreditPendingBuckets[24]` | Hourly bucket ring for pending maturity |
| `maintenanceIndex` | Cumulative maintenance fee index (1e18 scale) |
| `maintenanceIndexRemainder` | Precision remainder for maintenance |
| `pendingMaintenance` | Accrued maintenance fees awaiting payout |
| `indexEncumberedTotal` | Total index-encumbered principal in this pool |

---

## Fee Index (FI)

### Overview

The Fee Index is the primary yield distribution mechanism. It distributes fees to all depositors proportional to their fee base (principal minus same-asset debt). The FI uses a global index pattern at 1e18 precision.

### Accrual

When fees are routed to the FI:

```solidity
function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) {
    // 1. Enforce maintenance
    // 2. Verify backing: trackedBalance + activeCreditPrincipalTotal ≥ totalDeposits + yieldReserve + amount
    // 3. Reserve yield
    yieldReserve += amount;

    // 4. Calculate index delta with remainder tracking
    scaledAmount = amount × 1e18
    dividend = scaledAmount + feeIndexRemainder
    delta = dividend / totalDeposits
    feeIndexRemainder = dividend - (delta × totalDeposits)

    // 5. Advance global index
    feeIndex += delta
}
```

### Settlement

When a position settles:

```solidity
function settle(uint256 pid, bytes32 user) {
    // 1. Enforce maintenance
    // 2. Apply maintenance fee (reduce principal via maintenance index)
    maintenanceFee = principal × (maintenanceIndex - userMaintenanceIndex) / 1e18
    principal -= maintenanceFee

    // 3. Calculate fee base (net equity)
    feeBase = principal - sameAssetDebt

    // 4. Calculate pending yield
    added = feeBase × (feeIndex - userFeeIndex) / 1e18

    // 5. Credit yield and update checkpoint
    userAccruedYield += added
    userFeeIndex = feeIndex
}
```

### Fee Base Normalization

The fee base prevents borrowers from farming yield on borrowed capital:

```
feeBase = principal - sameAssetDebt
```

If you deposit 1,000 USDC and borrow 900 USDC (self-secured credit), your fee base is 100 USDC. You only earn FI yield on your net equity.

### Backing Verification

Before accruing, the FI verifies that the pool has sufficient backing:

```
backing = trackedBalance + activeCreditPrincipalTotal
reserved = totalDeposits + yieldReserve
available = backing - reserved
require(amount ≤ available)
```

This prevents over-accrual that would leave the pool unable to honor withdrawals.

### Fee Sources That Accrue to FI

| Source | Module |
|--------|--------|
| Flash loan fees (pool share) | Self-Secured Credit |
| Penalty seizures (FI share) | Self-Secured Credit |
| Action fees (FI share) | Self-Secured Credit |
| Index mint/burn fees (pool share) | EqualIndex |
| stEVE mint/burn fees (pool share) | stEVE |
| Index flash loan fees (pool share) | EqualIndex |
| ACI overflow (when no matured base) | Fee Router |

---

## Active Credit Index (ACI)

### Overview

The Active Credit Index rewards active protocol participants — borrowers and positions with encumbered principal. Unlike the FI which rewards passive depositors, the ACI rewards positions that are actively contributing to protocol utility.

The ACI has a critical differentiator: a 24-hour time gate. Positions must maintain their active status for 24 hours before earning ACI yield. This prevents flash-farming attacks.

### Time Gate Mechanics

```
TIME_GATE = 24 hours
BUCKET_SIZE = 1 hour
BUCKET_COUNT = 24
```

When a position becomes active (borrows, gets encumbered), it starts a timer. Only after 24 hours does the position's principal count toward the matured base that earns ACI yield.

### Weighted Dilution

When additional principal is added to an already-active position, the timer is diluted:

```solidity
newTimeCredit = (oldPrincipal × oldTimeCredit + newPrincipal × 0) / (oldPrincipal + newPrincipal)
newStartTime = currentTime - newTimeCredit
```

This prevents dust-priming attacks where a user starts the timer with a tiny amount, waits 24 hours, then adds a large amount to immediately earn on the full balance.

### Bucket Ring

The ACI uses a 24-slot hourly bucket ring for gas-efficient maturity tracking:

```
activeCreditPendingBuckets[24]:  hourly ring buffer
activeCreditPendingStartHour:    ring start hour
activeCreditPendingCursor:       current cursor position
activeCreditMaturedTotal:        sum of all matured principal
```

When a position becomes active, its principal is scheduled into the bucket corresponding to its maturity hour. Every time the ACI is touched, the `_rollMatured` function advances the cursor, moving matured buckets into `activeCreditMaturedTotal`.

### Accrual

ACI accrual only distributes to the matured base:

```solidity
function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) {
    _rollMatured(p);  // Advance bucket ring
    activeBase = activeCreditMaturedTotal;
    if (activeBase == 0) return;  // No matured participants

    // Same index math as FI, but against matured base
    delta = (amount × 1e18 + remainder) / activeBase
    activeCreditIndex += delta
}
```

### Two ACI States Per Position

Each position tracks two independent ACI states:

| State | Trigger | Purpose |
|-------|---------|---------|
| `userActiveCreditStateEncumbrance` | Index/module encumbrance changes | Rewards for locked collateral |
| `userActiveCreditStateDebt` | Same-asset debt changes (borrowing) | Rewards for active borrowing |

Both states are settled independently during `LibActiveCreditIndex.settle()`.

### Settlement

```solidity
function _settleState(p, state, pid, user) {
    if (!_isMature(state)) {
        state.indexSnapshot = globalIndex;  // Update checkpoint, no yield
        return;
    }

    if (globalIndex > prevIndex) {
        added = state.principal × (globalIndex - prevIndex) / 1e18
        userAccruedYield += added
    }
    state.indexSnapshot = globalIndex;
}
```

### Fee Sources That Accrue to ACI

| Source | Module |
|--------|--------|
| Flash loan fees (ACI share) | Self-Secured Credit |
| Penalty seizures (ACI share) | Self-Secured Credit |
| Action fees (ACI share) | Self-Secured Credit |
| Index fees (ACI share via router) | EqualIndex |
| stEVE fees (ACI share via router) | stEVE |

---

## Encumbrance System

### Overview

The encumbrance system is the central ledger that tracks how much of each position's principal is locked by various protocol venues. It provides a unified view across all lock types, ensuring that no venue can over-commit a position's capital.

### Encumbrance Types

```solidity
struct Encumbrance {
    uint256 directLocked;       // Self-secured credit: collateral locked for loans
    uint256 directLent;         // Self-secured credit: principal actively lent out
    uint256 directOfferEscrow;  // Direct lending: principal escrowed for pending offers
    uint256 indexEncumbered;    // EqualIndex: principal locked as index vault backing
    uint256 moduleEncumbered;   // Module: principal locked by arbitrary modules
}
```

### Total Encumbrance

```solidity
function total(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
    return directLocked + directLent + directOfferEscrow + indexEncumbered + moduleEncumbered;
}
```

Every withdrawal, burn, or transfer checks that the remaining principal exceeds total encumbrance.

### Per-Venue Isolation

Each encumbrance type is tracked independently with per-venue sub-accounting:

**Index Encumbrance:**
```solidity
// Per-index tracking
encumberedByIndex[positionKey][poolId][indexId] → amount
// Aggregate
encumbrance[positionKey][poolId].indexEncumbered → total across all indexes
// Pool-level
pool.indexEncumberedTotal → total across all positions
```

**Module Encumbrance:**
```solidity
// Per-module tracking
encumberedByModule[positionKey][poolId][moduleId] → amount
// Aggregate
encumbrance[positionKey][poolId].moduleEncumbered → total across all modules
```

### Module IDs

Each venue derives unique module IDs for encumbrance isolation:

| Venue | Module ID Derivation |
|-------|---------------------|
| EqualIndex Lending | `keccak256("equal.index.lending.module")` |
| stEVE Lending | `keccak256("EDEN_STEVE_LOAN_", loanId)` (per-loan) |
| stEVE Vault | `keccak256("EDEN_STEVE_ENCUMBRANCE")` |
| EqualScale Commitments | `keccak256("equalscale.alpha.commitment.", lineId)` |
| EqualScale Collateral | `keccak256("equalscale.alpha.collateral.", lineId)` |

### Encumbrance and ACI

Index and module encumbrance changes trigger ACI state updates:

```solidity
// On encumber:
LibActiveCreditIndex.applyEncumbranceIncrease(pool, pid, user, amount);

// On unencumber:
LibActiveCreditIndex.applyEncumbranceDecrease(pool, pid, user, amount);
```

This means positions with encumbered principal earn ACI yield (after the 24-hour gate).

### Wrapper Libraries

Two convenience wrappers provide venue-specific APIs:

```solidity
// For EqualIndex
LibIndexEncumbrance.encumber(positionKey, poolId, indexId, amount);
LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, amount);

// For modules (stEVE, EqualScale, etc.)
LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
LibModuleEncumbrance.unencumber(positionKey, poolId, moduleId, amount);
```

---

## Fee Router

### Overview

The Fee Router (`LibFeeRouter`) is the central distribution hub. Every fee in the protocol flows through it, getting split into three streams: Treasury, ACI, and FI.

### Split Configuration

```solidity
function previewSplit(uint256 amount) returns (
    uint256 toTreasury,
    uint256 toActiveCredit,
    uint256 toFeeIndex
) {
    toTreasury = amount × treasurySplitBps / 10,000
    toActiveCredit = amount × activeCreditSplitBps / 10,000
    toFeeIndex = amount - toTreasury - toActiveCredit
}
```

The FI receives the remainder after Treasury and ACI shares, ensuring no dust is lost.

### ACI Overflow

If the ACI has no matured base (no active participants have passed the 24-hour gate), the ACI share overflows to the FI:

```solidity
if (!LibActiveCreditIndex.hasMaturedBase(pid)) {
    toFeeIndex += toActiveCredit;
    toActiveCredit = 0;
}
```

This ensures fees are never stranded — they always reach depositors.

### Routing Modes

| Mode | Function | Use Case |
|------|----------|----------|
| `routeSamePool` | Route within a single pool | Self-secured credit fees, flash loans |
| `routeManagedShare` | Route with managed pool system share | Index/stEVE position fees |

### Managed Pool System Share

For managed pools, a configurable system share is routed to the base asset pool:

```
fee → systemShare (to base pool FI/ACI/Treasury) + managedShare (to managed pool FI/ACI/Treasury)
```

This allows managed pools to contribute to the broader protocol ecosystem.

---

## Maintenance Fees

### Overview

Maintenance fees are an annual pool-level charge that reduces depositor principal over time. They fund protocol operations via the foundation receiver.

### Accrual

Maintenance accrues daily:

```
epochs = elapsed / 1 day
chargeableTvl = totalDeposits - indexEncumberedTotal
amountAccrued = chargeableTvl × rateBps × epochs / (365 × 10,000)
```

Index-encumbered principal is exempt from maintenance (it's backing index tokens, not idle deposits).

### Maintenance Index

Like the FI, maintenance uses a global index to proportionally reduce all user principals:

```solidity
maintenanceIndex += (amountAccrued × 1e18) / oldTotalDeposits
```

During settlement, each position's principal is reduced:

```solidity
maintenanceFee = principal × (maintenanceIndex - userMaintenanceIndex) / 1e18
principal -= maintenanceFee
```

### Payout

Accrued maintenance is paid to the foundation receiver from the pool's tracked balance:

```solidity
paid = min(pendingMaintenance, trackedBalance, contractBalance)
trackedBalance -= paid
transfer(underlying, foundationReceiver, paid)
```

---

## Fee Base Normalization

### The Problem

Without normalization, a user could deposit 1,000 USDC, borrow 950 USDC (self-secured credit), and earn FI yield on the full 1,000 USDC — effectively farming yield on borrowed capital.

### The Solution

The fee base deducts same-asset debt from principal:

```solidity
feeBase = principal - sameAssetDebt
```

| Deposit | Debt | Fee Base | Yield Earned On |
|---------|------|----------|-----------------|
| 1,000 | 0 | 1,000 | Full deposit |
| 1,000 | 500 | 500 | Net equity only |
| 1,000 | 950 | 50 | Minimal yield |
| 1,000 | 1,000 | 0 | No yield |

### Where sameAssetDebt Comes From

| Venue | Increases sameAssetDebt | Decreases sameAssetDebt |
|-------|------------------------|------------------------|
| Self-Secured Credit | `openRollingFromPosition` | `makePaymentFromPosition`, `closeRolling` |
| EqualScale | `draw()` (borrower in settlement pool) | `repayLine()` |

---

## Data Models

### Per-Pool Fee State

```solidity
// Fee Index
uint256 feeIndex;                   // Global FI (1e18 scale)
uint256 feeIndexRemainder;          // Precision remainder
uint256 yieldReserve;               // Backing for accrued yield

// Active Credit Index
uint256 activeCreditIndex;          // Global ACI (1e18 scale)
uint256 activeCreditIndexRemainder; // Precision remainder
uint256 activeCreditPrincipalTotal; // Total ACI principal
uint256 activeCreditMaturedTotal;   // Matured ACI principal (earns yield)
uint64 activeCreditPendingStartHour;// Bucket ring start
uint8 activeCreditPendingCursor;    // Bucket ring cursor
uint256[24] activeCreditPendingBuckets; // Hourly maturity buckets

// Maintenance
uint256 maintenanceIndex;           // Global maintenance index (1e18 scale)
uint256 maintenanceIndexRemainder;  // Precision remainder
uint64 lastMaintenanceTimestamp;    // Last maintenance accrual
uint256 pendingMaintenance;         // Awaiting payout
```

### Per-Position Fee State

```solidity
mapping(bytes32 => uint256) userPrincipal;          // Deposit principal
mapping(bytes32 => uint256) userFeeIndex;            // FI checkpoint
mapping(bytes32 => uint256) userMaintenanceIndex;    // Maintenance checkpoint
mapping(bytes32 => uint256) userAccruedYield;        // Settled yield (FI + ACI)
mapping(bytes32 => uint256) userSameAssetDebt;       // Same-asset debt for fee base

// ACI per-position state (two independent states)
mapping(bytes32 => ActiveCreditState) userActiveCreditStateEncumbrance;
mapping(bytes32 => ActiveCreditState) userActiveCreditStateDebt;
```

### Active Credit State

```solidity
struct ActiveCreditState {
    uint256 principal;      // Current active principal
    uint40 startTime;       // Weighted dilution timestamp
    uint256 indexSnapshot;  // Last settled ACI value
}
```

### Encumbrance Storage

```solidity
struct EncumbranceStorage {
    // Per-position, per-pool encumbrance
    mapping(bytes32 => mapping(uint256 => Encumbrance)) encumbrance;
    // Per-index sub-accounting
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByIndex;
    // Per-module sub-accounting
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByModule;
}
```

---

## Integration Guide

### For New Venues (Adding a Fee Source)

```solidity
// Route fees through the standard split
LibFeeRouter.routeSamePool(poolId, feeAmount, keccak256("MY_VENUE_FEE"), true, 0);
// This automatically splits into Treasury / ACI / FI
```

### For New Venues (Locking Principal)

```solidity
// Lock principal via module encumbrance
uint256 moduleId = uint256(keccak256("my.venue.module"));
LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);

// Release when done
LibModuleEncumbrance.unencumber(positionKey, poolId, moduleId, amount);
```

### For New Venues (Tracking Active Credit)

```solidity
// When a position becomes active (borrows, locks collateral):
LibActiveCreditIndex.applyEncumbranceIncrease(pool, pid, user, amount);

// When a position becomes inactive:
LibActiveCreditIndex.applyEncumbranceDecrease(pool, pid, user, amount);
```

### For New Venues (Settling Before State Changes)

```solidity
// Always settle before changing a position's balance
LibFeeIndex.settle(poolId, positionKey);
LibActiveCreditIndex.settle(poolId, positionKey);

// Then modify principal, debt, encumbrance, etc.
```

---

## Worked Examples

### Example 1: Flash Loan Fee Distribution

**Scenario:** A 10,000 USDC flash loan with 0.1% fee generates 10 USDC.

**Fee Router Split (default: 10% treasury, 70% ACI, 20% FI):**
```
Treasury: 10 × 10% = 1 USDC → protocol treasury
ACI:      10 × 70% = 7 USDC → active credit index
FI:       10 × 20% = 2 USDC → fee index

Pool state:
  totalDeposits: 100,000 USDC
  activeCreditMaturedTotal: 50,000 USDC
```

**FI Accrual:**
```
delta = (2 × 1e18) / 100,000 = 2e13
feeIndex += 2e13

Alice (10,000 principal, 0 debt, feeBase = 10,000):
  yield = 10,000 × 2e13 / 1e18 = 0.2 USDC

Bob (10,000 principal, 8,000 debt, feeBase = 2,000):
  yield = 2,000 × 2e13 / 1e18 = 0.04 USDC
```

**ACI Accrual:**
```
delta = (7 × 1e18) / 50,000 = 1.4e14
activeCreditIndex += 1.4e14

Carol (5,000 encumbered, mature):
  yield = 5,000 × 1.4e14 / 1e18 = 0.7 USDC

Dave (5,000 encumbered, only 12 hours old):
  yield = 0 (not yet mature)
```

### Example 2: ACI Time Gate and Weighted Dilution

**Scenario:** Eve encumbers 100 USDC, waits 20 hours, then encumbers 900 more.

**Hour 0: Initial encumbrance**
```
Eve encumbers 100 USDC:
  state.principal = 100
  state.startTime = hour_0
  Scheduled in bucket for hour_24
```

**Hour 20: Additional encumbrance**
```
Eve encumbers 900 more USDC:
  oldCredit = 20 hours
  newCredit = (100 × 20h + 900 × 0) / 1000 = 2 hours
  state.principal = 1000
  state.startTime = hour_20 - 2h = hour_18
  Maturity: hour_18 + 24h = hour_42

Eve must wait until hour 42 to earn ACI yield on the full 1,000.
Without weighted dilution, she would earn at hour 24 on 1,000.
```

### Example 3: Multi-Venue Encumbrance

**Scenario:** Frank has 10,000 USDC principal with multiple venues locking portions.

```
Frank's encumbrance breakdown:
  directLocked:      2,000 (self-secured credit collateral)
  directLent:        0
  directOfferEscrow: 500 (pending direct offer)
  indexEncumbered:    3,000 (EqualIndex vault backing)
  moduleEncumbered:  1,500 (stEVE lending collateral)
  ─────────────────────────
  total:             7,000

Available for withdrawal: 10,000 - 7,000 = 3,000 USDC

Frank's ACI state (encumbrance):
  principal = 3,000 (index) + 1,500 (module) = tracked separately
  Only directLocked + directLent + directOfferEscrow count for direct ACI
```

### Example 4: Maintenance Fee Reduction

**Scenario:** A pool with 1% annual maintenance rate processes after 30 days.

```
Pool state:
  totalDeposits: 1,000,000 USDC
  indexEncumberedTotal: 200,000 USDC
  maintenanceRateBps: 100 (1%)

Accrual (30 days = 30 epochs):
  chargeableTvl = 1,000,000 - 200,000 = 800,000
  amountAccrued = 800,000 × 100 × 30 / (365 × 10,000) = 657.53 USDC

  totalDeposits: 1,000,000 - 657.53 = 999,342.47 USDC
  maintenanceIndex += (657.53 × 1e18) / 1,000,000

Per-position settlement (Alice with 10,000 principal):
  maintenanceFee = 10,000 × maintenanceDelta / 1e18 ≈ 6.58 USDC
  Alice's principal: 10,000 - 6.58 = 9,993.42 USDC
  (Index-encumbered positions are exempt from the chargeable base)
```

---

## Events

### Fee Index Events

```solidity
event FeeIndexAccrued(
    uint256 indexed pid,
    uint256 amount,
    uint256 delta,
    uint256 newIndex,
    bytes32 source
);

event YieldSettled(
    uint256 indexed pid,
    bytes32 indexed user,
    uint256 prevIndex,
    uint256 newIndex,
    uint256 addedYield,
    uint256 totalAccruedYield
);
```

### Active Credit Index Events

```solidity
event ActiveCreditIndexAccrued(
    uint256 indexed pid,
    uint256 amount,
    uint256 delta,
    uint256 newIndex,
    bytes32 source
);

event ActiveCreditSettled(
    uint256 indexed pid,
    bytes32 indexed user,
    uint256 prevIndex,
    uint256 newIndex,
    uint256 addedYield,
    uint256 totalAccruedYield
);

event ActiveCreditTimingUpdated(
    uint256 indexed pid,
    bytes32 indexed user,
    bool isDebtState,
    uint40 startTime,
    uint256 principal,
    bool isMature
);
```

### Encumbrance Events

```solidity
event EncumbranceIncreased(
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 indexed indexId,
    uint256 amount,
    uint256 totalEncumbered,
    uint256 indexEncumbered
);

event EncumbranceDecreased(
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 indexed indexId,
    uint256 amount,
    uint256 totalEncumbered,
    uint256 indexEncumbered
);

event ModuleEncumbranceIncreased(
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 indexed moduleId,
    uint256 amount,
    uint256 totalEncumbered,
    uint256 moduleEncumbered
);

event ModuleEncumbranceDecreased(
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 indexed moduleId,
    uint256 amount,
    uint256 totalEncumbered,
    uint256 moduleEncumbered
);
```

### Fee Router Events

```solidity
event ManagedPoolSystemShareRouted(
    uint256 indexed managedPid,
    uint256 indexed basePid,
    uint256 amount,
    bytes32 source
);
```

### Maintenance Events

```solidity
event MaintenanceCharged(
    uint256 indexed pid,
    address indexed receiver,
    uint256 epochsCharged,
    uint256 amountAccrued,
    uint256 amountPaid,
    uint256 outstanding
);
```

---

## Security Considerations

### 1. Backing Verification (FI)

FI accrual verifies that the pool can back the yield:

```solidity
backing = trackedBalance + activeCreditPrincipalTotal
reserved = totalDeposits + yieldReserve
require(amount ≤ backing - reserved)
```

This prevents phantom yield that would leave the pool insolvent.

### 2. 24-Hour Time Gate (ACI)

The ACI time gate prevents flash-farming:
- Positions must be active for 24 hours before earning
- Weighted dilution prevents dust-priming attacks
- Bucket ring provides gas-efficient maturity tracking

### 3. ACI Overflow to FI

When no participants have matured, ACI fees overflow to FI:

```solidity
if (!hasMaturedBase(pid)) {
    toFeeIndex += toActiveCredit;
    toActiveCredit = 0;
}
```

Fees are never stranded.

### 4. Remainder Tracking

Both FI and ACI track per-pool remainders to prevent precision loss:

```solidity
dividend = scaledAmount + remainder
delta = dividend / base
remainder = dividend - (delta × base)
```

Small accruals accumulate in the remainder until they produce a non-zero delta.

### 5. Encumbrance Underflow Protection

All unencumber operations check for underflow:

```solidity
if (amount > currentEncumbered) revert EncumbranceUnderflow(amount, currentEncumbered);
```

### 6. Per-Venue Encumbrance Isolation

Each venue's encumbrance is tracked independently. An EqualIndex unencumber cannot affect stEVE lending encumbrance, and vice versa.

### 7. Maintenance Exemption for Index-Encumbered Principal

Index-encumbered principal is exempt from maintenance fees:

```solidity
chargeableTvl = totalDeposits - indexEncumberedTotal
```

This prevents double-charging: index tokens already have their own fee structure.

### 8. Yield Reserve Accounting

The `yieldReserve` tracks all yield that has been accrued but not yet withdrawn. This ensures:
- Withdrawals can always be honored
- New accruals don't over-commit the pool
- The pool's solvency is deterministic

### 9. Settlement Before Mutation

Every balance-changing operation settles both FI and ACI first:

```solidity
LibFeeIndex.settle(poolId, positionKey);
LibActiveCreditIndex.settle(poolId, positionKey);
// Then modify state
```

This prevents stale checkpoints from causing incorrect yield calculations.

### 10. Maintenance Enforcement

Maintenance is enforced before every FI and ACI operation:

```solidity
LibMaintenance.enforce(pid);
```

This ensures the pool's `totalDeposits` and `maintenanceIndex` are current before any yield calculation.

---

## Appendix: Correctness Properties

### Property 1: FI Index Monotonicity
```
feeIndex only increases
feeIndex_new ≥ feeIndex_old
```

### Property 2: ACI Index Monotonicity
```
activeCreditIndex only increases
activeCreditIndex_new ≥ activeCreditIndex_old
```

### Property 3: Backing Solvency
```
trackedBalance + activeCreditPrincipalTotal ≥ totalDeposits + yieldReserve
```

### Property 4: Encumbrance Bound
```
∀ position: LibEncumbrance.total(positionKey, poolId) ≤ userPrincipal[positionKey]
```

### Property 5: Fee Base Non-Negativity
```
feeBase = max(0, principal - sameAssetDebt)
```

### Property 6: ACI Time Gate Enforcement
```
∀ state: if timeCredit(state) < 24 hours → activeWeight = 0
```

### Property 7: ACI Weighted Dilution
```
After adding P_new to existing P_old with credit T_old:
  T_new = (P_old × T_old) / (P_old + P_new)
  T_new < T_old (timer always regresses on addition)
```

### Property 8: Remainder Conservation
```
∀ accrual: remainder_new = dividend - (delta × base)
remainder_new < base
No precision is permanently lost
```

### Property 9: ACI Overflow Safety
```
If activeCreditMaturedTotal == 0:
  ACI share → FI (no fees stranded)
```

### Property 10: Maintenance Exemption
```
chargeableTvl = totalDeposits - indexEncumberedTotal
Index-encumbered principal pays no maintenance
```

### Property 11: Encumbrance Type Isolation
```
encumberIndex() only modifies indexEncumbered + encumberedByIndex
encumberModule() only modifies moduleEncumbered + encumberedByModule
No cross-type interference
```

### Property 12: Settlement Idempotency
```
settle(pid, user) called twice in same block:
  Second call produces zero additional yield
  Checkpoints already at current global index
```

---

**Document Version:** 1.0
**Module:** EqualFi Protocol Substrate — Encumbrance, Fee Index & Active Credit Index