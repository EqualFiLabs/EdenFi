# Design Document

## Overview

This design rebuilds Self-Secured Credit as a native EqualFi venue on top of
the shared substrate already present in this workspace.

The design keeps the product thesis:

- same-asset borrowing
- deterministic LTV
- no oracle
- no liquidation auction
- ACI rewards for active SSC debt

The design changes the runtime shape:

- SSC becomes a small native venue rather than a broad generic lending facet
- canonical substrate settlement remains the source of truth for principal,
  maintenance, FI, ACI, and availability
- SSC adds only the venue-native state needed to explain why the position has
  same-asset debt and how future ACI should be routed

The key economic principle is that SSC is not free perpetual leverage.
Maintenance continues to reduce principal over time. ACI makes SSC attractive,
but it does not remove the need for active management.

The clean rebuild therefore treats SSC as:

1. a deterministic same-asset debt line
2. a management-sensitive position under maintenance pressure
3. a user-routable ACI stream with an optional self-pay mode
4. a deterministic self-settling position if safe backing is exhausted

## Design Goals

- Keep SSC native to the EqualFi substrate
- Minimize the SSC surface to one clear same-asset rolling line model
- Reuse canonical same-asset debt and principal-availability rules
- Preserve ACI rewards for active SSC debt
- Introduce a prospective ACI self-pay mode without ambiguous accounting
- Keep maintenance pressure explicit rather than hidden
- Avoid monolithic legacy lending abstractions
- Make service and terminal behavior deterministic and testable

## Non-Goals

This design does not attempt to:

- port the old sibling `LendingFacet` shape into this repo
- reintroduce fixed-term SSC or payment-cadence-heavy generic lending state
- make SSC a cross-asset product
- make SSC rely on oracle-triggered liquidations or liquidation markets
- solve every future credit product in the SSC implementation

## Architecture

### Native Venue Rule

SSC is a first-party native EqualFi venue.

That means:

1. substrate accounting remains canonical
2. SSC storage remains venue-native
3. canonical principal availability still comes from substrate state
4. SSC-specific storage answers why debt exists and how ACI should route

### Proposed Facet and Library Split

```text
src/equallend/
├── PositionManagementFacet.sol        # existing substrate entrypoints
├── PoolManagementFacet.sol            # existing substrate pool config
├── SelfSecuredCreditFacet.sol         # draw, repay, close, service, set mode
└── SelfSecuredCreditViewFacet.sol     # previews and line views

src/libraries/
├── LibFeeIndex.sol                    # existing FI settlement
├── LibActiveCreditIndex.sol           # existing ACI settlement
├── LibEncumbrance.sol                 # existing canonical availability
├── LibSelfSecuredCreditStorage.sol    # SSC-native storage
├── LibSelfSecuredCreditAccounting.sol # shared SSC accounting transitions
└── Types.sol                          # shared structs, may gain SSC views
```

`SelfSecuredCreditFacet` should stay small and orchestration-focused.
Principal, debt, lock, and ACI-routing mutations should live in a shared
accounting library, in the same spirit as the clean EqualLend Direct rebuild.

## SSC State Model

### Canonical Substrate State Used by SSC

SSC reuses:

- `p.userPrincipal[positionKey]`
- `p.userSameAssetDebt[positionKey]`
- `p.userActiveCreditStateDebt[positionKey]`
- `p.activeCreditPrincipalTotal`
- `LibEncumbrance.position(positionKey, pid).lockedCapital`
- `p.trackedBalance`
- FI / ACI / maintenance checkpoints

### SSC-Native State

SSC still needs venue-native storage to answer product questions that the
substrate should not own.

Representative shape:

```solidity
enum SscAciMode {
    Yield,
    SelfPay
}

struct SscLine {
    uint256 outstandingDebt;
    uint256 requiredLockedCapital;
    SscAciMode aciMode;
    bool active;
}

struct SscStorage {
    mapping(bytes32 => mapping(uint256 => SscLine)) lines;
    mapping(bytes32 => mapping(uint256 => uint256)) claimableAciYield;
    mapping(bytes32 => mapping(uint256 => uint256)) totalAciAppliedToDebt;
}
```

Notes:

- `outstandingDebt` is SSC-native product state
- `userSameAssetDebt` remains the canonical substrate debt overlay used by FI
  and ACI debt accounting
- `requiredLockedCapital` is stored for viewability and symmetry, but can also
  be recomputed from debt and LTV
- `claimableAciYield` is source-separated from FI yield

## Core Accounting Rules

### 1. Required Lock Formula

SSC uses deterministic same-asset backing with a required lock derived from LTV.

```text
requiredLock = ceil(outstandingDebt * 10_000 / depositorLTVBps)
```

Examples:

- 95% LTV, 95 debt -> 100 required lock
- 95% LTV, 47.5 debt -> 50 required lock

This lock is represented through canonical `lockedCapital`.

This is important because:

- `sameAssetDebt` captures fee and ACI economics
- `lockedCapital` captures principal availability for withdrawal safety

The protocol should not pretend these are the same thing.

### 2. FI Economics

FI fee base remains:

```text
feeBase = principal - sameAssetDebt
```

SSC debt therefore reduces passive FI earnings automatically.

### 3. ACI Economics

SSC debt remains ACI-eligible through the canonical debt-side ACI state:

- open or increase SSC debt -> increase debt-side ACI principal
- repay or auto-pay SSC debt -> decrease debt-side ACI principal

SSC should not also award encumbrance-side ACI for the same line if that would
double count the same economic exposure.

### 4. Maintenance Economics

Maintenance continues to reduce principal through the existing substrate path.

That means SSC safe state can worsen even if the user does nothing:

- principal declines
- same-asset debt does not decline automatically unless repaid or auto-paid
- required lock may eventually exceed available principal

This is not a bug. It is the core management pressure in SSC.

## ACI Routing Model

### Source Separation

The clean SSC rebuild should not rely on one blended accrued-yield bucket to
decide whether future ACI is claimable or debt-paying.

Instead:

- FI yield remains claimable FI yield
- SSC ACI yield becomes either:
  - claimable ACI yield in yield mode
  - debt reduction in self-pay mode

This implies a source-aware settlement path for SSC.

### Mode Semantics

#### Yield Mode

Future SSC-earned ACI accrues into SSC-native claimable ACI state.

Use cases:

- user wants cashflow
- user wants optional manual debt management

#### Self-Pay Mode

Future SSC-earned ACI is applied to outstanding SSC debt at service time or any
SSC lifecycle touch that settles ACI.

Use cases:

- user wants automatic de-risking
- user wants FI fee base to recover over time
- user wants required lock to shrink over time

### Prospective Toggle Rule

Mode changes must be prospective.

At toggle time:

1. settle maintenance
2. settle FI and ACI under the old mode
3. apply any self-pay effect generated by the old mode
4. switch `aciMode`
5. future ACI follows the new mode

This prevents retroactive reclassification of already-earned ACI.

### Overflow Rule

If self-pay ACI exceeds outstanding SSC debt:

1. reduce debt to zero
2. release the excess required lock
3. route overflow to claimable ACI yield by default

Overflow should not be burned.

## Lifecycle Flows

### Open / Draw

```text
1. verify Position NFT ownership and pool membership
2. settle maintenance, FI, and ACI
3. apply any pending self-pay effect under the current mode
4. validate min draw and tracked liquidity
5. compute new outstanding debt
6. compute new required lock from LTV
7. increase canonical same-asset debt
8. increase canonical debt-side ACI state
9. increase or adjust canonical lockedCapital to the new required lock
10. store SSC line state
11. reduce tracked liquidity and transfer borrowed asset out
```

### Repay

```text
1. verify Position NFT ownership
2. settle maintenance, FI, and ACI
3. apply pending self-pay effect under the current mode
4. pull repayment funds
5. restore tracked liquidity
6. reduce outstanding SSC debt
7. reduce canonical same-asset debt
8. reduce canonical debt-side ACI state
9. recompute required lock
10. reduce canonical lockedCapital by the released amount
11. clear line if debt reaches zero
```

### Service

Service is not a traditional scheduled payment.

It is the deterministic upkeep path for an SSC line:

```text
1. settle maintenance
2. settle FI
3. settle ACI
4. if in self-pay mode, apply claimable SSC ACI to debt
5. recompute required lock
6. update safety status and previews
7. if unsafe after settlement, allow deterministic self-settlement path
```

This can be owner-only or permissionless depending on the final product choice.
If permissionless, the function should not expose third-party extraction beyond
the protocol's deterministic accounting effects.

### Terminal Self-Settlement

If, after settlement and self-pay application, the position cannot support the
required lock:

1. consume locked principal against SSC debt
2. reduce outstanding SSC debt
3. reduce same-asset debt
4. reduce debt-side ACI principal
5. reduce `lockedCapital`
6. reduce user principal and pool totals as required by the consumed backing
7. close the line or leave the residual line in a smaller safe state

This is not a liquidation auction.

It is deterministic self-resolution against the user's own same-asset backing.

## Preview and View Surface

### Core Views

Representative read surface:

```solidity
function getSscLine(uint256 tokenId, uint256 pid) external view returns (SscLineView memory);
function previewSscDraw(uint256 tokenId, uint256 pid, uint256 amount) external view returns (SscDrawPreview memory);
function previewSscRepay(uint256 tokenId, uint256 pid, uint256 amount) external view returns (SscRepayPreview memory);
function previewSscService(uint256 tokenId, uint256 pid) external view returns (SscServicePreview memory);
function previewSscTerminalSettlement(uint256 tokenId, uint256 pid) external view returns (SscTerminalPreview memory);
function claimableSscAciYield(uint256 tokenId, uint256 pid) external view returns (uint256);
function sscAciMode(uint256 tokenId, uint256 pid) external view returns (SscAciMode);
```

### Important View Outputs

The view surface should expose at least:

- settled principal preview
- outstanding debt
- required lock
- free equity
- max additional draw
- claimable FI yield
- claimable SSC ACI yield
- pending self-pay effect
- post-service debt
- post-service required lock
- whether the line is unsafe after service

## Security and Correctness Notes

1. SSC debt and required lock must mutate symmetrically on draw, repay,
   self-pay, and terminal settlement.
2. Any line touch must settle maintenance first, otherwise safe-state previews
   will drift from reality.
3. Self-pay must be source-explicit and prospective-only.
4. Source-separated ACI accounting is preferable to overloaded
   `userAccruedYield` semantics because it keeps debt-paydown auditable.
5. SSC should not double-count one exposure across both debt-side and
   encumbrance-side ACI reward paths.
6. Terminal self-settlement should remain deterministic and same-asset only.

## Implementation Notes

The cleanest implementation order is:

1. establish SSC-native storage and view structs
2. centralize draw / repay / lock / same-asset-debt transitions
3. add source-separated SSC ACI routing
4. add service flow
5. add terminal self-settlement
6. wire view surfaces and launch tests

This keeps the accounting foundation stable before the self-pay mode is layered
on top.
