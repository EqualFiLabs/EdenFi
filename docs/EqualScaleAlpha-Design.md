# EqualScale Alpha V1 - Design Document

**Version:** 1.0
**Module:** EqualFi Agentic Financing Platform

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Borrower Identity](#borrower-identity)
5. [Credit Line Lifecycle](#credit-line-lifecycle)
6. [Commitment System](#commitment-system)
7. [Draw & Repayment](#draw--repayment)
8. [Refinancing](#refinancing)
9. [Delinquency & Charge-Off](#delinquency--charge-off)
10. [Collateral](#collateral)
11. [Data Models](#data-models)
12. [View Functions](#view-functions)
13. [Integration Guide](#integration-guide)
14. [Worked Examples](#worked-examples)
15. [Error Reference](#error-reference)
16. [Events](#events)
17. [Security Considerations](#security-considerations)

---

## Overview

EqualScale Alpha V1 is the first module of EqualFi's Agentic Financing Platform. It introduces on-chain credit lines where verified borrower agents propose terms, lenders commit capital from existing EqualFi pool positions, and draws settle through the protocol's pool infrastructure. Credit lines carry real APR-based interest, periodic payment schedules, facility terms, and refinancing windows.

Unlike self-secured credit (same-asset, zero-interest), EqualScale is a multi-party credit facility: borrowers and lenders are distinct participants, interest accrues continuously, and default resolution follows a charge-off model with collateral recovery and pro-rata loss allocation.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Agent-Identity Gated** | Borrowers must complete position-agent identity registration before proposing lines |
| **Lender Commitments** | Lenders pledge capital from existing pool positions via module encumbrance |
| **APR-Based Interest** | Continuous interest accrual on outstanding principal (basis-point APR) |
| **Periodic Payments** | Configurable payment intervals with minimum-due enforcement |
| **Facility Terms** | Fixed-duration credit facilities with refinancing windows |
| **Draw Pacing** | Per-period draw limits prevent sudden full utilization |
| **Collateral Modes** | Optional borrower-posted collateral from a separate pool position |
| **Charge-Off Resolution** | Delinquent lines are charged off with collateral recovery and loss write-down |
| **Position NFT Integration** | All participants interact through EqualFi Position NFTs |

### System Participants

| Role | Description |
|------|-------------|
| **Borrower Agent** | Position NFT owner with a completed agent identity and registered borrower profile |
| **Lender** | Position NFT owner who commits pool principal to back a credit line |
| **Enforcer** | Anyone who triggers delinquency marking or charge-off on eligible lines |
| **Timelock / Governance** | Admin that can freeze/unfreeze lines and configure charge-off thresholds |

### Why Agentic Financing?

Traditional DeFi lending is either:
- **Over-collateralized** — capital inefficient, requires oracles and liquidation infrastructure
- **Under-collateralized** — relies on off-chain trust with no on-chain enforcement

EqualScale bridges this gap:
- **On-chain identity** → Borrowers are verified agents with registered profiles, treasury wallets, and BANKR tokens
- **Structured credit** → Real payment schedules, interest accrual, and facility terms enforced by smart contracts
- **Lender protection** → Capital is encumbered at commitment, exposure is tracked per-lender, and losses are allocated pro-rata
- **No oracles** → Settlement uses same-pool liquidity; no external price feeds required for core operations
- **Composable** → Builds on EqualFi's existing pool, position NFT, fee index, and active credit index infrastructure

---

## How It Works

### The Core Model

1. **Register** a borrower profile (requires completed agent identity)
2. **Propose** a credit line with terms (APR, limits, payment schedule, facility duration)
3. **Attract commitments** from lenders during a solo window or pooled-open phase
4. **Activate** the line once commitments meet the minimum viable threshold
5. **Draw** funds to the borrower's treasury wallet within pacing limits
6. **Repay** principal and interest on schedule
7. **Refinance** at term end, or let the line enter runoff
8. **Close** the line when fully repaid

### Interest Accrual

Interest accrues continuously on outstanding principal:

```
accruedInterest += outstandingPrincipal × aprBps × elapsed / (10,000 × 365 days)
```

Interest is computed at every state-changing operation (draw, repay, refinance, delinquency check).

### Payment Schedule

Each payment period requires a minimum due:

```
minimumDue = max(interestAccruedSinceLastDue, minimumPaymentPerPeriod)
```

When the minimum due is satisfied, the due checkpoint advances by one payment interval. Payments are applied interest-first, then principal.

---

## Architecture

### Contract Structure

```
src/equalscale/
├── EqualScaleAlphaFacet.sol          # Core operations: profiles, proposals, commits, draws
├── EqualScaleAlphaAdminFacet.sol     # Governance: freeze/unfreeze, charge-off threshold
├── EqualScaleAlphaViewFacet.sol      # Read-only queries and previews
├── LibEqualScaleAlphaLifecycle.sol   # Lifecycle transitions: repay, refinance, delinquency, charge-off, close
├── LibEqualScaleAlphaShared.sol      # Shared helpers: interest, payments, recovery, finalization
├── IEqualScaleAlphaErrors.sol        # Error definitions
└── IEqualScaleAlphaEvents.sol        # Event definitions

src/libraries/
└── LibEqualScaleAlphaStorage.sol     # Diamond storage: enums, structs, mappings
```

### High-Level Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                    EqualScale Alpha V1                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │
│  │   EqualScale   │  │   EqualScale   │  │   EqualScale   │          │
│  │   Alpha Facet  │  │  Admin Facet   │  │  View Facet    │          │
│  │                │  │                │  │                │          │
│  │  • Profiles    │  │  • Freeze      │  │  • Previews    │          │
│  │  • Proposals   │  │  • Unfreeze    │  │  • Telemetry   │          │
│  │  • Commits     │  │  • Thresholds  │  │  • Queries     │          │
│  │  • Draws       │  │                │  │                │          │
│  │  • Lifecycle   │  │                │  │                │          │
│  └────────────────┘  └────────────────┘  └────────────────┘          │
│         │                                                            │
│         ▼                                                            │
│  ┌────────────────────────────────────────────────────┐              │
│  │              Shared Libraries                       │              │
│  │  LibEqualScaleAlphaShared  │  LibEqualScaleAlpha   │              │
│  │  LibEqualScaleAlphaLifecycle  Storage              │              │
│  └────────────────────────────────────────────────────┘              │
│                           │                                          │
├──────────────────────────────────────────────────────────────────────┤
│                    EqualFi Protocol Substrate                        │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────┐  ┌────────────┐  │
│  │ Position │  │    Pool      │  │  Fee Index /  │  │  Module    │  │
│  │   NFTs   │  │ Infrastructure│  │ Active Credit │  │ Encumbrance│  │
│  └──────────┘  └──────────────┘  └───────────────┘  └────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
         │                │                │                │
         ▼                ▼                ▼                ▼
   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
   │ Borrower │    │ Lender   │    │ Treasury │    │ Enforcer │
   │  Agent   │    │ Position │    │  Wallet  │    │ (Anyone) │
   └──────────┘    └──────────┘    └──────────┘    └──────────┘
```

---

## Borrower Identity

### Agent Registration Requirement

Before proposing a credit line, a borrower must:
1. Own a Position NFT
2. Complete agent identity registration (via the position-agent identity stack)
3. Register a borrower profile with EqualScale

### Borrower Profile

```solidity
struct BorrowerProfile {
    bytes32 borrowerPositionKey;    // Derived from Position NFT
    address treasuryWallet;         // Where drawn funds are sent
    address bankrToken;             // Associated BANKR token address
    bytes32 metadataHash;           // Off-chain metadata reference
    bool active;                    // Profile status
}
```

### Registration Flow

```solidity
// 1. Complete agent identity registration (prerequisite)
// positionAgentFacet.registerCanonical(positionId, agentId, ...);

// 2. Register borrower profile
equalScaleFacet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, metadataHash);

// 3. Update profile if needed
equalScaleFacet.updateBorrowerProfile(positionId, newTreasuryWallet, newBankrToken, newMetadataHash);
```

### Identity Checks

- `isRegistrationComplete(positionId)` must return `true`
- `getAgentId(positionId)` must return a non-zero agent ID
- Treasury wallet and BANKR token addresses must be non-zero

---

## Credit Line Lifecycle

### Status State Machine

```
                    ┌─────────────┐
                    │  SoloWindow │ ◄── createLineProposal()
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │ commitSolo()            │ transitionToPooledOpen()
              │ + activateLine()        │ (after solo window expires)
              │                         ▼
              │                  ┌─────────────┐
              │                  │ PooledOpen   │
              │                  └──────┬──────┘
              │                         │ commitPooled() + activateLine()
              │                         │
              ▼                         ▼
        ┌─────────────────────────────────────┐
        │               Active                │ ◄── cureLineIfCovered()
        └──────┬──────────┬──────────┬────────┘
               │          │          │
    closeLine()│   enterRefinancing()│   markDelinquent()
    (fully     │   (term expired)   │   (past grace period)
     repaid)   │          │          │
               │          ▼          ▼
               │   ┌────────────┐  ┌────────────┐
               │   │Refinancing │  │ Delinquent │
               │   └─────┬──────┘  └──────┬─────┘
               │         │                │
               │  resolveRefinancing()    chargeOffLine()
               │         │                │
               │    ┌────┴────┐           ▼
               │    │         │    ┌────────────┐
               │    ▼         ▼    │ ChargedOff │
               │  Active   Runoff  └──────┬─────┘
               │             │            │
               │             │            ▼
               ▼             ▼         ┌────────┐
           ┌────────────────────────── │ Closed │
           │                           └────────┘
           ▼
       ┌────────┐
       │ Frozen │ ◄── freezeLine() (governance)
       └────┬───┘
            │ unfreezeLine()
            ▼
          Active
```

### Status Definitions

| Status | Description |
|--------|-------------|
| **SoloWindow** | Initial proposal state. A single lender has exclusive 3-day window to commit the full target |
| **PooledOpen** | After solo window expires without a solo commitment. Multiple lenders can commit partial amounts |
| **Active** | Line is funded and operational. Borrower can draw, must make periodic payments |
| **Refinancing** | Facility term has ended. Lenders choose to roll or exit commitments |
| **Runoff** | Refinancing resolved with insufficient commitments. No new draws; repayment continues |
| **Delinquent** | Borrower missed a payment past the grace period |
| **Frozen** | Governance-paused. No draws allowed; repayments still accepted |
| **ChargedOff** | Delinquent line written off after charge-off threshold. Collateral recovered, losses allocated |
| **Closed** | Terminal state. All obligations settled, encumbrances released |

### Solo Window

Every new proposal enters a 3-day solo window:

```solidity
uint40 internal constant SOLO_WINDOW_DURATION = 3 days;
line.soloExclusiveUntil = uint40(block.timestamp) + SOLO_WINDOW_DURATION;
```

During this window:
- Only `commitSolo()` is available (one lender commits the full `requestedTargetLimit`)
- If no solo commitment is made, anyone can call `transitionToPooledOpen()` after expiry

---

## Commitment System

### How Commitments Work

Lenders back credit lines by committing principal from their existing pool positions. Committed capital is encumbered via `LibModuleEncumbrance`, preventing withdrawal or reuse until the commitment is released.

### Commitment Lifecycle

```solidity
enum CommitmentStatus {
    Active,         // Capital committed and encumbered
    Canceled,       // Lender withdrew commitment (PooledOpen only)
    Rolled,         // Lender opted to continue in refinancing
    Exited,         // Lender opted out during refinancing
    WrittenDown,    // Commitment absorbed a loss during charge-off
    Closed          // Line closed, encumbrance released
}
```

### Commitment Data

```solidity
struct Commitment {
    uint256 lenderPositionId;       // Lender's Position NFT token ID
    bytes32 lenderPositionKey;      // Derived position key
    uint256 settlementPoolId;       // Pool where capital is committed
    uint256 committedAmount;        // Amount of principal committed
    uint256 principalExposed;       // Principal currently at risk (from draws)
    uint256 principalRepaid;        // Principal returned via repayments
    uint256 interestReceived;       // Interest earned from repayments
    uint256 recoveryReceived;       // Collateral recovery received during charge-off
    uint256 lossWrittenDown;        // Unrecoverable loss absorbed
    CommitmentStatus status;        // Current commitment state
}
```

### Solo Commitment

```solidity
// Lender commits the full target limit during solo window
equalScaleFacet.commitSolo(lineId, lenderPositionId);
```

Requirements:
- Line must be in `SoloWindow` status
- Solo window must not have expired
- No existing commitment on the line
- Lender must have sufficient available principal in the settlement pool

### Pooled Commitments

```solidity
// Multiple lenders commit partial amounts
equalScaleFacet.commitPooled(lineId, lenderPositionId, amount);
```

Requirements:
- Line must be in `PooledOpen` or `Refinancing` status
- Amount must not exceed remaining capacity (`requestedTargetLimit - currentCommittedAmount`)
- Lender must have sufficient available principal

### Canceling Commitments

```solidity
// Lender cancels during PooledOpen phase
equalScaleFacet.cancelCommitment(lineId, lenderPositionId);
```

Only available during `PooledOpen` status. Encumbrance is released immediately.

### Exposure Allocation

When the borrower draws funds, exposure is allocated pro-rata across active commitments:

```
lenderExposure = drawAmount × (lenderCommitted / totalCommitted)
```

The last lender in the iteration absorbs any rounding remainder, ensuring exact allocation.

---

## Draw & Repayment

### Drawing Funds

```solidity
equalScaleFacet.draw(lineId, amount);
```

Draws transfer funds from the settlement pool to the borrower's registered treasury wallet.

**Requirements:**
- Line must be `Active`
- Amount must not exceed available line capacity (`activeLimit - outstandingPrincipal`)
- Amount must not exceed remaining period draw capacity (`maxDrawPerPeriod - currentPeriodDrawn`)
- Settlement pool must have sufficient liquidity

**Side Effects:**
- Borrower's `sameAssetDebt` increases in the settlement pool
- Active credit index weight increases for the borrower
- Draw exposure is allocated pro-rata across lender commitments
- Draw period resets automatically when the payment interval rolls over

### Draw Pacing

Each credit line has a `maxDrawPerPeriod` limit that resets every payment interval:

```solidity
// Period rolls over automatically
if (block.timestamp >= currentPeriodStartedAt + paymentIntervalSecs) {
    currentPeriodStartedAt = block.timestamp;
    currentPeriodDrawn = 0;
}
```

This prevents a borrower from drawing the entire facility instantly, giving lenders time to react.

### Repaying

```solidity
equalScaleFacet.repayLine(lineId, amount);
```

Repayments are pulled from `msg.sender` and applied interest-first:

```
interestComponent = min(effectiveAmount, accruedInterest)
principalComponent = effectiveAmount - interestComponent
```

**Payment Schedule Advancement:**
When `paidSinceLastDue >= minimumDue`, the due checkpoint advances:
- `nextDueAt += paymentIntervalSecs`
- `interestAccruedSinceLastDue` resets to 0
- `paidSinceLastDue` resets to 0

**Delinquency Cure:**
If a delinquent line receives a payment satisfying the minimum due, it is automatically cured back to `Active` (or `Runoff` if outstanding principal exceeds committed amount).

### Repayment Allocation

Interest and principal repayments are allocated pro-rata across lender commitments based on `principalExposed`:

```
lenderInterestShare = interestComponent × (lenderExposed / totalExposed)
lenderPrincipalShare = principalComponent × (lenderExposed / totalExposed)
```

---

## Refinancing

### Overview

When a credit line's facility term expires, it enters a refinancing window. During this window, lenders decide whether to continue (roll) or exit their commitments.

### Entering Refinancing

```solidity
equalScaleFacet.enterRefinancing(lineId);
```

Requirements:
- Line must be `Active` or `Frozen`
- `block.timestamp >= termEndAt`

### Lender Options During Refinancing

**Roll (continue):**
```solidity
equalScaleFacet.rollCommitment(lineId, lenderPositionId);
// Commitment status → Rolled
```

**Exit (withdraw):**
```solidity
equalScaleFacet.exitCommitment(lineId, lenderPositionId);
// Commitment status → Exited, encumbrance released
// line.currentCommittedAmount decreases
```

New lenders can also join during refinancing via `commitPooled()`.

### Resolving Refinancing

```solidity
equalScaleFacet.resolveRefinancing(lineId);
```

Called after `refinanceEndAt`. Three possible outcomes:

| Condition | Outcome |
|-----------|---------|
| `committedAmount >= requestedTargetLimit` | Line restarts at full target limit → `Active` |
| `committedAmount >= outstandingPrincipal` AND `committedAmount >= minimumViableLine` | Line restarts at committed amount → `Active` |
| Neither condition met | Line enters `Runoff` (no new draws, repayment continues) |

### Term Restart

When refinancing resolves successfully, the facility term resets:

```solidity
line.termStartedAt = block.timestamp;
line.termEndAt = block.timestamp + facilityTermSecs;
line.refinanceEndAt = termEndAt + refinanceWindowSecs;
line.missedPayments = 0;
line.delinquentSince = 0;
```

---

## Delinquency & Charge-Off

### Delinquency

A line becomes delinquent when the borrower fails to meet the minimum payment by the due date plus grace period.

```solidity
equalScaleFacet.markDelinquent(lineId);
```

**Requirements:**
- Line must be `Active`, `Frozen`, or `Runoff`
- `block.timestamp > nextDueAt + gracePeriodSecs`
- `paidSinceLastDue < minimumDue`

**Effects:**
- Status → `Delinquent`
- `delinquentSince` set to current timestamp
- `missedPayments` incremented

Delinquent lines can still accept repayments. If the minimum due is satisfied, the line is automatically cured.

### Charge-Off

If a delinquent line remains unresolved past the charge-off threshold, anyone can trigger a charge-off:

```solidity
equalScaleFacet.chargeOffLine(lineId);
```

**Requirements:**
- Line must be `Delinquent`
- `block.timestamp >= delinquentSince + chargeOffThresholdSecs`

**Default charge-off threshold:** 30 days (configurable by governance, range: 1–365 days)

### Charge-Off Resolution

The charge-off process follows three steps:

**Step 1: Collateral Recovery**
If the borrower posted collateral (`CollateralMode.BorrowerPosted`):
- Encumbered collateral is seized from the borrower's collateral pool position
- Recovery is capped at the lesser of: encumbered amount, borrower's principal, total exposed principal
- Recovered funds are transferred to the settlement pool's tracked balance
- Recovery is allocated pro-rata across lender commitments by `principalExposed`

**Step 2: Loss Write-Down**
Any remaining exposed principal after recovery is written down:
- Write-down is allocated pro-rata across lender commitments
- Commitment status → `WrittenDown`

**Step 3: Finalization**
- All commitment encumbrances are released
- Remaining borrower collateral encumbrance is released
- Line status → `Closed`
- `CreditLineChargedOff` and `CreditLineClosed` events emitted

### Loss Allocation Example

```
Line: 100,000 USDC outstanding across 3 lenders
Lender A: 50,000 exposed (50%)
Lender B: 30,000 exposed (30%)
Lender C: 20,000 exposed (20%)

Collateral recovery: 40,000 USDC
  → Lender A receives: 20,000
  → Lender B receives: 12,000
  → Lender C receives:  8,000

Remaining write-down: 60,000 USDC
  → Lender A absorbs: 30,000 loss
  → Lender B absorbs: 18,000 loss
  → Lender C absorbs: 12,000 loss
```

---

## Collateral

### Collateral Modes

```solidity
enum CollateralMode {
    None,               // Unsecured credit line
    BorrowerPosted      // Borrower posts collateral from a separate pool position
}
```

### Borrower-Posted Collateral

When `CollateralMode.BorrowerPosted` is selected:
- Borrower specifies a `borrowerCollateralPoolId` and `borrowerCollateralAmount` in the proposal
- At activation, the specified amount is encumbered from the borrower's position in the collateral pool
- Collateral pool's underlying asset must match the settlement pool's underlying asset
- Encumbrance uses a per-line module ID: `keccak256("equalscale.alpha.collateral.", lineId)`

### Collateral Lifecycle

| Event | Collateral Action |
|-------|-------------------|
| Line activated | Collateral encumbered from borrower's collateral pool position |
| Line closed (fully repaid) | Collateral encumbrance released |
| Line charged off | Collateral seized for recovery, remainder released |
| Proposal cancelled | No collateral action (not yet encumbered) |

---

## Data Models

### Credit Line

```solidity
struct CreditLine {
    // Identity
    bytes32 borrowerPositionKey;
    uint256 borrowerPositionId;

    // Proposal Terms
    uint256 settlementPoolId;           // Pool used for settlement
    uint256 requestedTargetLimit;       // Maximum credit facility size
    uint256 minimumViableLine;          // Minimum commitments to activate
    uint16 aprBps;                      // Annual percentage rate in basis points
    uint256 minimumPaymentPerPeriod;    // Floor for minimum due calculation
    uint256 maxDrawPerPeriod;           // Maximum draw per payment interval
    uint32 paymentIntervalSecs;         // Payment period duration
    uint32 gracePeriodSecs;             // Grace period after due date
    uint40 facilityTermSecs;            // Total facility duration
    uint40 refinanceWindowSecs;         // Refinancing window after term end
    CollateralMode collateralMode;      // None or BorrowerPosted
    uint256 borrowerCollateralPoolId;   // Collateral pool (if applicable)
    uint256 borrowerCollateralAmount;   // Collateral amount (if applicable)

    // Live Accounting
    uint256 activeLimit;                // Current effective credit limit
    uint256 currentCommittedAmount;     // Total committed by lenders
    uint256 outstandingPrincipal;       // Principal currently drawn
    uint256 accruedInterest;            // Unpaid accrued interest
    uint256 interestAccruedSinceLastDue;// Interest since last due checkpoint
    uint256 totalPrincipalRepaid;       // Cumulative principal repaid
    uint256 totalInterestRepaid;        // Cumulative interest repaid
    uint256 paidSinceLastDue;           // Payments in current period
    uint256 currentPeriodDrawn;         // Draws in current period
    uint40 currentPeriodStartedAt;      // Current draw period start
    uint40 interestAccruedAt;           // Last interest accrual timestamp
    uint40 nextDueAt;                   // Next payment due date
    uint40 termStartedAt;              // Facility term start
    uint40 termEndAt;                  // Facility term end
    uint40 refinanceEndAt;             // Refinancing window end
    uint40 soloExclusiveUntil;         // Solo window expiry
    uint40 delinquentSince;            // Delinquency start (0 if current)
    uint8 missedPayments;              // Missed payment counter
    CreditLineStatus status;           // Current lifecycle status
}
```

### Global Storage

```solidity
struct EqualScaleAlphaStorage {
    uint256 nextLineId;                                         // Monotonic line ID counter
    uint40 chargeOffThresholdSecs;                              // Configurable charge-off delay
    mapping(bytes32 => BorrowerProfile) borrowerProfiles;       // Position key → profile
    mapping(uint256 => CreditLine) lines;                       // Line ID → credit line
    mapping(bytes32 => uint256[]) borrowerLineIds;              // Position key → line IDs
    mapping(uint256 => mapping(uint256 => Commitment)) lineCommitments;  // Line × position → commitment
    mapping(uint256 => uint256[]) lineCommitmentPositionIds;    // Line → lender position IDs
    mapping(uint256 => mapping(uint256 => bool)) lineHasCommitmentPosition;  // Dedup guard
    mapping(uint256 => PaymentRecord[]) paymentRecords;         // Line → payment history
    mapping(uint256 => uint256[]) lenderPositionLineIds;        // Lender position → line IDs
    mapping(uint256 => mapping(uint256 => bool)) lenderPositionHasLine;  // Dedup guard
}
```

### Payment Record

```solidity
struct PaymentRecord {
    uint40 paidAt;                  // Payment timestamp
    uint256 amount;                 // Total payment amount
    uint256 principalComponent;     // Principal portion
    uint256 interestComponent;      // Interest portion
}
```

---

## View Functions

### Borrower Queries

```solidity
// Get borrower profile with live identity data
function getBorrowerProfile(uint256 borrowerPositionId)
    external view returns (BorrowerProfileView memory);

// Get all line IDs for a borrower
function getBorrowerLineIds(uint256 borrowerPositionId)
    external view returns (uint256[] memory);
```

### Credit Line Queries

```solidity
// Get full credit line state
function getCreditLine(uint256 lineId)
    external view returns (CreditLine memory);

// Get all commitments for a line
function getLineCommitments(uint256 lineId)
    external view returns (Commitment[] memory);

// Get all commitments for a lender position
function getLenderPositionCommitments(uint256 lenderPositionId)
    external view returns (LenderPositionCommitmentView[] memory);
```

### Draw & Repayment Previews

```solidity
// Preview a draw operation
function previewDraw(uint256 lineId, uint256 amount)
    external view returns (DrawPreview memory);

// Preview a repayment
function previewLineRepay(uint256 lineId, uint256 amount)
    external view returns (RepayPreview memory);

// Check draw eligibility
function isLineDrawEligible(uint256 lineId, uint256 amount)
    external view returns (bool);

// Get current minimum due
function currentMinimumDue(uint256 lineId)
    external view returns (uint256);
```

### Telemetry & Status

```solidity
// Treasury telemetry for monitoring
function getTreasuryTelemetry(uint256 lineId)
    external view returns (TreasuryTelemetryView memory);

// Refinancing status
function getRefinanceStatus(uint256 lineId)
    external view returns (RefinanceStatusView memory);

// Loss summary for a line
function getLineLossSummary(uint256 lineId)
    external view returns (LineLossSummaryView memory);
```

### Treasury Telemetry View

```solidity
struct TreasuryTelemetryView {
    uint256 treasuryBalance;        // Borrower treasury wallet balance
    uint256 outstandingPrincipal;   // Current outstanding principal
    uint256 accruedInterest;        // Current accrued interest (live)
    uint256 nextDueAmount;          // Current minimum due
    bool paymentCurrent;            // Whether payment is within grace period
    bool drawsFrozen;               // Whether draws are blocked
    uint256 currentPeriodDrawn;     // Draws in current period
    uint256 maxDrawPerPeriod;       // Period draw limit
    CreditLineStatus status;        // Current line status
}
```

---

## Integration Guide

### For Borrower Agents

#### Setting Up

```solidity
// 1. Ensure agent identity is registered on your Position NFT
// (via position-agent identity stack)

// 2. Register borrower profile
equalScaleFacet.registerBorrowerProfile(
    positionId,
    treasuryWallet,     // Where drawn funds will be sent
    bankrToken,         // Associated BANKR token
    metadataHash        // Off-chain metadata reference
);
```

#### Proposing a Credit Line

```solidity
EqualScaleAlphaFacet.LineProposalParams memory params = LineProposalParams({
    settlementPoolId: 1,                    // USDC pool
    requestedTargetLimit: 100_000e6,        // 100,000 USDC
    minimumViableLine: 50_000e6,            // Accept if at least 50,000 committed
    aprBps: 800,                            // 8% APR
    minimumPaymentPerPeriod: 1_000e6,       // At least 1,000 USDC per period
    maxDrawPerPeriod: 25_000e6,             // Max 25,000 per period
    paymentIntervalSecs: 30 days,           // Monthly payments
    gracePeriodSecs: 7 days,                // 7-day grace period
    facilityTermSecs: 365 days,             // 1-year facility
    refinanceWindowSecs: 30 days,           // 30-day refinancing window
    collateralMode: CollateralMode.BorrowerPosted,
    borrowerCollateralPoolId: 2,            // Collateral pool
    borrowerCollateralAmount: 20_000e6      // 20,000 USDC collateral
});

uint256 lineId = equalScaleFacet.createLineProposal(positionId, params);
```

#### Drawing and Repaying

```solidity
// Wait for activation, then draw
equalScaleFacet.draw(lineId, 10_000e6);

// Repay before due date
IERC20(usdc).approve(diamond, 5_000e6);
equalScaleFacet.repayLine(lineId, 5_000e6);

// Check telemetry
TreasuryTelemetryView memory telemetry = viewFacet.getTreasuryTelemetry(lineId);
```

### For Lenders

#### Committing Capital

```solidity
// During solo window (full commitment)
equalScaleFacet.commitSolo(lineId, lenderPositionId);

// During pooled phase (partial commitment)
equalScaleFacet.commitPooled(lineId, lenderPositionId, 25_000e6);

// Cancel if still in PooledOpen
equalScaleFacet.cancelCommitment(lineId, lenderPositionId);
```

#### Monitoring Commitments

```solidity
// Get all your commitments
LenderPositionCommitmentView[] memory commitments =
    viewFacet.getLenderPositionCommitments(lenderPositionId);

// Check loss summary
LineLossSummaryView memory losses = viewFacet.getLineLossSummary(lineId);
```

#### Refinancing Decisions

```solidity
// Roll commitment (continue backing the line)
equalScaleFacet.rollCommitment(lineId, lenderPositionId);

// Or exit (release encumbrance)
equalScaleFacet.exitCommitment(lineId, lenderPositionId);
```

### For Enforcers

```solidity
// Mark delinquent (after grace period)
equalScaleFacet.markDelinquent(lineId);

// Charge off (after charge-off threshold)
equalScaleFacet.chargeOffLine(lineId);
```

---

## Worked Examples

### Example 1: Basic Credit Line Lifecycle

**Scenario:** Alice (borrower agent) opens a 100,000 USDC credit line at 8% APR with monthly payments.

**Step 1: Profile Registration**
```
Alice owns Position NFT #42 with completed agent identity
Alice registers borrower profile:
  - treasuryWallet: 0xAliceTreasury
  - bankrToken: 0xAliceBankr
  - metadataHash: keccak256("alice-profile-v1")
```

**Step 2: Proposal**
```
Alice creates line proposal:
  - requestedTargetLimit: 100,000 USDC
  - minimumViableLine: 50,000 USDC
  - aprBps: 800 (8%)
  - minimumPaymentPerPeriod: 1,000 USDC
  - maxDrawPerPeriod: 25,000 USDC
  - paymentIntervalSecs: 30 days
  - gracePeriodSecs: 7 days
  - facilityTermSecs: 365 days
  - refinanceWindowSecs: 30 days
  - collateralMode: None

Line enters SoloWindow (3-day exclusive)
```

**Step 3: Commitment**
```
Bob (lender) commits 100,000 USDC from Position #99 during solo window
Bob's 100,000 USDC is encumbered via LibModuleEncumbrance
```

**Step 4: Activation**
```
activateLine() called:
  - activeLimit: 100,000 USDC
  - nextDueAt: now + 30 days
  - termEndAt: now + 365 days
  - refinanceEndAt: termEndAt + 30 days
  - Status → Active
```

**Step 5: Draw**
```
Alice draws 20,000 USDC:
  - 20,000 USDC transferred from settlement pool → Alice's treasury wallet
  - outstandingPrincipal: 20,000 USDC
  - currentPeriodDrawn: 20,000 USDC
  - Bob's commitment: principalExposed = 20,000 USDC
  - Alice's sameAssetDebt in pool increases by 20,000
```

**Step 6: Interest Accrual (15 days later)**
```
accruedInterest = 20,000 × 800 × (15 × 86400) / (10,000 × 365 × 86400)
               ≈ 65.75 USDC
```

**Step 7: Repayment (Day 28)**
```
Alice repays 2,000 USDC:
  - interestComponent: ~131.51 USDC (28 days of interest)
  - principalComponent: ~1,868.49 USDC
  - paidSinceLastDue: 2,000 USDC ≥ minimumDue → checkpoint advances
  - nextDueAt: now + 30 days (new period)
  - Bob's commitment: principalRepaid += 1,868.49, interestReceived += 131.51
```

### Example 2: Pooled Commitment with Partial Fill

**Scenario:** Carol proposes a 200,000 USDC line. No solo commitment. Multiple lenders participate.

**Step 1: Solo Window Expires**
```
3 days pass with no solo commitment
transitionToPooledOpen() called → Status: PooledOpen
```

**Step 2: Pooled Commitments**
```
Dave commits 80,000 USDC from Position #10
Eve commits 60,000 USDC from Position #20
Frank commits 40,000 USDC from Position #30
Total committed: 180,000 USDC
```

**Step 3: Activation (Borrower Accepts Partial Fill)**
```
180,000 < 200,000 (requestedTargetLimit)
180,000 ≥ minimumViableLine (e.g., 100,000)
Carol (borrower) calls activateLine():
  - activeLimit: 180,000 USDC
  - Status → Active
```

**Step 4: Draw Exposure Allocation**
```
Carol draws 90,000 USDC:
  Dave exposure: 90,000 × (80,000 / 180,000) = 40,000 USDC
  Eve exposure:  90,000 × (60,000 / 180,000) = 30,000 USDC
  Frank exposure: 90,000 - 40,000 - 30,000   = 20,000 USDC (remainder)
```

### Example 3: Charge-Off with Collateral Recovery

**Scenario:** Grace posts 30,000 USDC collateral. Line goes delinquent and is charged off.

**Initial State:**
```
Outstanding principal: 80,000 USDC
Lender A exposed: 48,000 (60%)
Lender B exposed: 32,000 (40%)
Borrower collateral: 30,000 USDC (encumbered in collateral pool)
Charge-off threshold: 30 days
```

**Day 0: Delinquency**
```
markDelinquent() called:
  - Grace period expired, minimum due not met
  - Status → Delinquent
  - delinquentSince = now
```

**Day 30: Charge-Off**
```
chargeOffLine() called:

Step 1 — Collateral Recovery (30,000 USDC):
  Lender A recovery: 30,000 × (48,000 / 80,000) = 18,000 USDC
  Lender B recovery: 30,000 × (32,000 / 80,000) = 12,000 USDC
  Remaining exposed: 80,000 - 30,000 = 50,000 USDC

Step 2 — Loss Write-Down (50,000 USDC):
  Lender A loss: 50,000 × (30,000 / 50,000) = 30,000 USDC
  Lender B loss: 50,000 × (20,000 / 50,000) = 20,000 USDC

Step 3 — Finalization:
  All encumbrances released
  Status → Closed (with loss)
  Lender A commitment status → WrittenDown
  Lender B commitment status → WrittenDown
```

### Example 4: Refinancing

**Scenario:** A 1-year facility reaches term end. Two of three lenders roll.

**Term End:**
```
enterRefinancing() called → Status: Refinancing
Lender A (50,000 committed): rollCommitment() → Rolled
Lender B (30,000 committed): rollCommitment() → Rolled
Lender C (20,000 committed): exitCommitment() → Exited
  - 20,000 encumbrance released
  - currentCommittedAmount: 80,000

New lender D joins: commitPooled(lineId, positionId, 20,000)
  - currentCommittedAmount: 100,000
```

**Refinance Resolution (after refinanceEndAt):**
```
resolveRefinancing() called:
  100,000 >= requestedTargetLimit (100,000)
  → Line restarts at full target
  → New term: now + facilityTermSecs
  → Status → Active
```

---

## Error Reference

### Identity & Profile Errors

| Error | Cause |
|-------|-------|
| `BorrowerPositionNotOwned(address, uint256)` | Caller doesn't own the borrower Position NFT |
| `LenderPositionNotOwned(address, uint256)` | Caller doesn't own the lender Position NFT |
| `BorrowerIdentityNotRegistered(uint256)` | Position lacks completed agent identity registration |
| `BorrowerProfileAlreadyActive(bytes32)` | Borrower profile already registered for this position |
| `BorrowerProfileNotActive(bytes32)` | Borrower profile not registered or inactive |
| `InvalidTreasuryWallet()` | Treasury wallet address is zero |
| `InvalidBankrToken()` | BANKR token address is zero |

### Proposal & Commitment Errors

| Error | Cause |
|-------|-------|
| `InvalidProposalTerms(string)` | Catch-all for proposal validation failures (reason string provides detail) |
| `InvalidCollateralMode(CollateralMode, uint256, uint256)` | Collateral parameters inconsistent with selected mode |
| `InsufficientLenderPrincipal(uint256, uint256, uint256)` | Lender lacks sufficient available principal for commitment |

### Draw & Repayment Errors

| Error | Cause |
|-------|-------|
| `InvalidDrawPacing(uint256, uint256, uint256)` | Draw would exceed per-period limit |
| `InsufficientPoolLiquidity(uint256, uint256)` | Settlement pool lacks sufficient balance for draw |

### Delinquency & Charge-Off Errors

| Error | Cause |
|-------|-------|
| `DelinquencyTooEarly(uint256, uint40, uint32, uint40)` | Grace period has not yet expired |
| `ChargeOffTooEarly(uint256, uint40, uint40, uint40)` | Charge-off threshold not yet reached |
| `InvalidWriteDownState(uint256, CreditLineStatus)` | Line not in correct status for charge-off |
| `NoExposedPrincipalToWriteDown(uint256)` | No exposed principal remaining to write down |
| `WriteDownAlreadyApplied(uint256, uint256)` | Write-down already applied for this commitment |

### Common InvalidProposalTerms Reasons

| Reason String | Context |
|---------------|---------|
| `"settlementPoolId == 0"` | Missing settlement pool |
| `"targetLimit == 0"` | Zero credit limit |
| `"minimumViableLine == 0"` | Zero minimum viable line |
| `"minimumViableLine > targetLimit"` | Minimum exceeds target |
| `"maxDrawPerPeriod == 0"` | Zero draw pacing |
| `"maxDrawPerPeriod > targetLimit"` | Draw limit exceeds facility |
| `"paymentIntervalSecs == 0"` | Zero payment interval |
| `"facilityTermSecs == 0"` | Zero facility term |
| `"refinanceWindowSecs == 0"` | Zero refinancing window |
| `"solo window expired"` | Solo commitment after window |
| `"solo commitment already exists"` | Duplicate solo commitment |
| `"solo window still active"` | Transition to pooled too early |
| `"commitment exceeds remaining capacity"` | Over-commitment |
| `"commitments below minimum viable line"` | Insufficient commitments at activation |
| `"draw exceeds available capacity"` | Draw exceeds active limit |
| `"line not active for draw"` | Draw on non-active line |
| `"line has no outstanding obligation"` | Repay on zero-balance line |
| `"line has outstanding obligation"` | Close with unpaid balance |
| `"facility term still active"` | Refinance before term end |
| `"refinance window still active"` | Resolve refinance too early |
| `"current minimum due satisfied"` | Delinquency on current line |

---

## Events

### Profile Events

```solidity
event BorrowerProfileRegistered(
    bytes32 indexed borrowerPositionKey,
    uint256 indexed borrowerPositionId,
    address treasuryWallet,
    address bankrToken,
    uint256 resolvedAgentId,
    bytes32 metadataHash
);

event BorrowerProfileUpdated(
    bytes32 indexed borrowerPositionKey,
    uint256 indexed borrowerPositionId,
    address treasuryWallet,
    address bankrToken,
    bytes32 metadataHash
);
```

### Proposal Events

```solidity
event LineProposalCreated(
    uint256 indexed lineId,
    uint256 indexed borrowerPositionId,
    bytes32 indexed borrowerPositionKey,
    uint256 settlementPoolId,
    uint256 requestedTargetLimit,
    uint256 minimumViableLine,
    uint16 aprBps,
    uint256 minimumPaymentPerPeriod,
    uint256 maxDrawPerPeriod,
    uint32 paymentIntervalSecs,
    uint32 gracePeriodSecs,
    uint40 facilityTermSecs,
    uint40 refinanceWindowSecs,
    CollateralMode collateralMode,
    uint256 borrowerCollateralPoolId,
    uint256 borrowerCollateralAmount
);

event LineProposalUpdated(/* same signature as LineProposalCreated */);

event ProposalCancelled(
    uint256 indexed lineId,
    uint256 indexed borrowerPositionId,
    bytes32 indexed borrowerPositionKey
);

event CreditLineEnteredSoloWindow(uint256 indexed lineId, uint40 soloExclusiveUntil);

event CreditLineOpenedToPool(uint256 indexed lineId);
```

### Commitment Events

```solidity
event CommitmentAdded(
    uint256 indexed lineId,
    uint256 indexed lenderPositionId,
    bytes32 indexed lenderPositionKey,
    uint256 amount,
    uint256 currentCommittedAmount
);

event CommitmentCancelled(
    uint256 indexed lineId,
    uint256 indexed lenderPositionId,
    bytes32 indexed lenderPositionKey,
    uint256 amount,
    uint256 currentCommittedAmount
);

event CommitmentRolled(
    uint256 indexed lineId,
    uint256 indexed lenderPositionId,
    bytes32 indexed lenderPositionKey,
    uint256 amount,
    uint256 currentCommittedAmount
);

event CommitmentExited(
    uint256 indexed lineId,
    uint256 indexed lenderPositionId,
    bytes32 indexed lenderPositionKey,
    uint256 amount,
    uint256 currentCommittedAmount
);
```

### Lifecycle Events

```solidity
event CreditLineActivated(
    uint256 indexed lineId,
    uint256 activeLimit,
    CollateralMode collateralMode,
    uint40 nextDueAt,
    uint40 termEndAt,
    uint40 refinanceEndAt
);

event CreditDrawn(
    uint256 indexed lineId,
    uint256 amount,
    uint256 outstandingPrincipal,
    uint256 currentPeriodDrawn
);

event CreditPaymentMade(
    uint256 indexed lineId,
    uint256 amount,
    uint256 principalComponent,
    uint256 interestComponent,
    uint256 outstandingPrincipal,
    uint256 accruedInterest,
    uint40 nextDueAt
);

event CreditLineEnteredRefinancing(
    uint256 indexed lineId,
    uint40 refinanceEndAt,
    uint256 currentCommittedAmount,
    uint256 outstandingPrincipal
);

event CreditLineRefinancingResolved(
    uint256 indexed lineId,
    CreditLineStatus outcomeStatus,
    uint256 activeLimit,
    uint256 currentCommittedAmount
);

event CreditLineEnteredRunoff(
    uint256 indexed lineId,
    uint256 outstandingPrincipal,
    uint256 currentCommittedAmount
);

event CreditLineMarkedDelinquent(
    uint256 indexed lineId,
    uint40 delinquentSince,
    uint256 currentMinimumDue,
    uint40 nextDueAt
);

event CreditLineChargedOff(
    uint256 indexed lineId,
    uint256 recoveryApplied,
    uint256 principalWrittenDown
);

event CreditLineClosed(
    uint256 indexed lineId,
    CreditLineStatus previousStatus,
    bool closedWithLoss
);
```

### Admin Events

```solidity
event CreditLineFreezeUpdated(uint256 indexed lineId, bool frozen, bytes32 reason);

event ChargeOffThresholdUpdated(uint40 previousThresholdSecs, uint40 newThresholdSecs);
```

---

## Security Considerations

### 1. Agent Identity Gate

All borrower operations require a completed position-agent identity:
- `isRegistrationComplete()` must return `true`
- `getAgentId()` must return a non-zero ID
- Profile must be explicitly registered and active

This prevents anonymous or unverified actors from proposing credit lines.

### 2. Encumbrance-Based Capital Locking

Lender capital is locked via `LibModuleEncumbrance` at commitment time:
- Each line gets a unique module ID: `keccak256("equalscale.alpha.commitment.", lineId)`
- Encumbered principal cannot be withdrawn, transferred, or reused
- Encumbrance is only released on commitment cancellation, exit, or line closure

```solidity
// Encumbrance at commitment
LibModuleEncumbrance.encumber(lenderPositionKey, poolId, moduleId, amount);

// Release at cancellation/exit/close
LibModuleEncumbrance.unencumber(lenderPositionKey, poolId, moduleId, amount);
```

### 3. Draw Pacing

Per-period draw limits prevent sudden full utilization:
- `maxDrawPerPeriod` caps draws within each payment interval
- Period resets automatically when the interval rolls over
- Gives lenders time to monitor and react to borrower behavior

### 4. Interest-First Repayment

Repayments are applied interest-first, then principal:
```solidity
interestComponent = min(effectiveAmount, accruedInterest);
principalComponent = effectiveAmount - interestComponent;
```

This ensures lenders receive their yield before principal reduction.

### 5. Pro-Rata Loss Allocation

All distributions (repayments, recovery, write-downs) are allocated pro-rata by `principalExposed`:
- No lender bears disproportionate loss
- Rounding remainder goes to the last lender in iteration (prevents dust loss)

### 6. Deterministic Delinquency

Delinquency is fully deterministic from on-chain state:
```
isDelinquent = block.timestamp > nextDueAt + gracePeriodSecs
            && paidSinceLastDue < minimumDue
```

No reliance on external triggers, oracles, or keepers for status determination.

### 7. Charge-Off Threshold

Configurable delay between delinquency and charge-off:
- Default: 30 days
- Range: 1–365 days (governance-controlled)
- Gives borrowers time to cure before irreversible loss recognition

### 8. Collateral Underlying Match

When borrower-posted collateral is used:
```solidity
require(collateralPool.underlying == settlementPool.underlying);
```

This ensures collateral recovery transfers are same-asset, avoiding oracle dependency.

### 9. Settlement Pool Integration

Draws reduce `trackedBalance` and increase `sameAssetDebt` in the settlement pool:
- Fee base normalization applies (borrower earns reduced yield on drawn amounts)
- Active credit index weight increases for the borrower
- Pool liquidity checks prevent over-drawing

### 10. Governance Controls

Admin facet provides narrow, timelock-gated controls:
- `freezeLine()` / `unfreezeLine()` — emergency pause for individual lines
- `setChargeOffThreshold()` — adjust charge-off delay within bounds
- All admin functions enforce `LibAccess.enforceTimelockOrOwnerIfUnset()`

---

## Appendix: Correctness Properties

### Property 1: Commitment Conservation
For any active line:
```
currentCommittedAmount = Σ(commitment.committedAmount) for Active/Rolled commitments
```

### Property 2: Exposure Conservation
For any line with draws:
```
Σ(commitment.principalExposed) = outstandingPrincipal
```

### Property 3: Repayment Accounting
For any repayment:
```
interestComponent + principalComponent = effectiveAmount
effectiveAmount ≤ outstandingPrincipal + accruedInterest
```

### Property 4: Interest Monotonicity
Accrued interest only increases between payments:
```
newAccruedInterest ≥ oldAccruedInterest (absent repayment)
```

### Property 5: Encumbrance Consistency
Lender encumbrance matches commitment:
```
moduleEncumbered(lenderPositionKey, poolId, moduleId) = commitment.committedAmount
```

### Property 6: Draw Pacing Invariant
Within any payment interval:
```
currentPeriodDrawn ≤ maxDrawPerPeriod
```

### Property 7: Collateral Recovery Bound
Recovery never exceeds the lesser of encumbered collateral, borrower principal, or total exposed:
```
recovered ≤ min(encumbered, borrowerPrincipal, totalExposedPrincipal)
```

### Property 8: Loss Allocation Completeness
After charge-off:
```
Σ(commitment.recoveryReceived) + Σ(commitment.lossWrittenDown) = totalExposedPrincipal (pre-chargeoff)
```

### Property 9: Status Transition Validity
Status transitions follow the defined state machine. No transition skips intermediate states.

### Property 10: Finalization Completeness
After line closure:
```
activeLimit = 0
currentCommittedAmount = 0
outstandingPrincipal = 0
accruedInterest = 0
All commitment encumbrances released
All borrower collateral encumbrances released
```

---

**Document Version:** 1.0
**Module:** EqualScale Alpha V1 — EqualFi Agentic Financing Platform