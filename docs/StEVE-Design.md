# stEVE - Design Document

**Version:** 1.0
**Module:** EDEN by EqualFi — Staked EDEN Vault Engine

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [The stEVE Token](#the-steve-token)
5. [Minting & Burning](#minting--burning)
6. [Position-Based Operations](#position-based-operations)
7. [Deposit & Withdraw](#deposit--withdraw)
8. [Fee System](#fee-system)
9. [stEVE Lending](#steve-lending)
10. [EDEN Rewards Engine & stEVE](#eden-rewards-engine--steve)
11. [Data Models](#data-models)
12. [View Functions](#view-functions)
13. [Integration Guide](#integration-guide)
14. [Worked Examples](#worked-examples)
15. [Error Reference](#error-reference)
16. [Events](#events)
17. [Security Considerations](#security-considerations)

---

## Overview

stEVE (Staked EDEN Vault Engine) is the flagship product of EDEN by EqualFi. It is a single-asset vault token built on the EqualFi protocol substrate. stEVE wraps a single underlying asset into a basket token with fee accumulation, position-based staking, lending against collateral, and deep integration with the EDEN Rewards Engine.

Unlike multi-asset EqualIndex tokens, stEVE is a singleton product — there is exactly one stEVE instance per deployment. It is purpose-built as the core staking and rewards vehicle for the EDEN ecosystem.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Single-Asset Vault** | One underlying asset per stEVE instance |
| **Singleton Product** | Exactly one stEVE per deployment (product ID = 0) |
| **ERC-20 with Votes** | Transferable token with ERC-20 Votes (governance delegation) and Permit |
| **Fee Pot Accumulation** | Mint/burn fees grow a pot that increases redemption value over time |
| **Dual Access Modes** | Wallet-mode (direct ERC-20) and position-mode (via Position NFTs) |
| **Position Deposits** | Direct deposit/withdraw of underlying asset to stEVE pool positions |
| **Lending** | Borrow underlying assets against stEVE collateral with fixed duration |
| **EDEN Rewards** | Position holders earn from the EDEN Rewards Engine — the primary rewards mechanism |
| **Governance Ready** | ERC-20 Votes enables on-chain governance delegation |

### System Participants

| Role | Description |
|------|-------------|
| **Minter** | User who deposits the underlying asset to mint stEVE tokens |
| **Redeemer** | User who burns stEVE tokens to receive the underlying asset |
| **Position Holder** | User who holds stEVE via a Position NFT, earning pool yield and EDEN rewards |
| **Depositor** | Position holder who deposits the underlying asset directly into the stEVE pool |
| **Borrower** | Position holder who borrows the underlying asset against stEVE collateral |
| **Enforcer** | Anyone who recovers expired stEVE loans |
| **Governance** | Timelock/owner that configures the product, fees, and lending parameters |

### Why stEVE?

stEVE is the entry point to the EDEN ecosystem:
- **Single-asset simplicity** → Deposit one asset, receive one token, earn rewards
- **Governance power** → ERC-20 Votes enables delegation for on-chain governance
- **Reward accumulation** → Position holders earn from the EDEN Rewards Engine continuously
- **Fee pot growth** → Mint/burn fees compound into increasing redemption value
- **Lending utility** → Borrow against stEVE to access liquidity without selling
- **Protocol integration** → Builds on EqualFi's pool, fee index, and encumbrance infrastructure

---

## How It Works

### The Core Model

1. **Mint** stEVE by depositing the underlying asset (wallet or position mode)
2. **Hold** stEVE to benefit from fee pot accumulation
3. **Deposit** to a position to earn EDEN rewards
4. **Borrow** against position-held stEVE to access underlying liquidity
5. **Burn** stEVE to redeem the underlying asset plus fee pot share
6. **Claim** EDEN rewards accrued to your position

### Fee Pot Accumulation

Like EqualIndex, stEVE accumulates mint and burn fees into a per-asset fee pot. When burning, holders receive their proportional share of the pot on top of the base bundle amount:

```
redemptionValue = bundleAmount + (feePot × units / totalSupply)
```

New minters buy into the fee pot proportionally, preventing dilution of existing holders.

### Eligible Supply

The EDEN Rewards Engine tracks an "eligible supply" for stEVE — this is the total deposits in the stEVE pool (position-held stEVE only). Wallet-held stEVE does not earn EDEN rewards.

```
eligibleSupply = stEVE pool totalDeposits
eligibleBalance(position) = pool.userPrincipal[positionKey]
```

---

## Architecture

### Contract Structure

```
src/steve/
├── StEVEProductBase.sol        # Shared structs, constants, validation, modifiers
├── StEVELogic.sol              # Core mint/burn logic (wallet + position), fee distribution, product config
├── StEVEPoolHelpers.sol        # Pool interaction helpers (ownership, caps, limits)
├── StEVEActionFacet.sol        # Product creation, deposit, withdraw, eligibility queries
├── StEVEWalletFacet.sol        # Wallet-mode mint and burn
├── StEVEPositionFacet.sol      # Position-mode mint and burn
├── StEVELendingFacet.sol       # Borrow, repay, extend, recover, lending config
├── StEVELendingLogic.sol       # Lending internals: invariants, fee tiers, loan management
├── StEVEAdminFacet.sol         # Governance: metadata, fees, pause, timelock
├── StEVEViewFacet.sol          # Read-only queries, previews, portfolio views, action checks
└── IStEVELendingErrors.sol     # Lending error definitions

src/tokens/
├── StEVEToken.sol              # ERC-20 with Votes + Permit (extends BasketToken)
└── BasketToken.sol             # Base ERC-20 with restricted mint/burn

src/libraries/
├── LibStEVEStorage.sol             # Product storage: config, metadata, accounting
├── LibStEVELendingStorage.sol      # Lending storage: loans, tiers, config
├── LibStEVEEligibilityStorage.sol  # Eligibility flag
├── LibStEVERewards.sol             # EDEN Rewards Engine bridge for stEVE
├── LibStEVEAdminStorage.sol        # Admin metadata storage
└── LibEdenRewardsStorage.sol       # Shared rewards engine storage
```

### High-Level Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                              stEVE                                   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │
│  │   Wallet       │  │   Position     │  │   Action       │          │
│  │   Facet        │  │   Facet        │  │   Facet        │          │
│  │                │  │                │  │                │          │
│  │  • Wallet Mint │  │  • Position    │  │  • Create      │          │
│  │  • Wallet Burn │  │    Mint        │  │  • Deposit     │          │
│  │                │  │  • Position    │  │  • Withdraw    │          │
│  │                │  │    Burn        │  │  • Eligibility │          │
│  └────────────────┘  └────────────────┘  └────────────────┘          │
│         │                    │                    │                   │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │
│  │   Lending      │  │   Admin        │  │   View         │          │
│  │   Facet        │  │   Facet        │  │   Facet        │          │
│  │                │  │                │  │                │          │
│  │  • Borrow      │  │  • Fees        │  │  • Previews    │          │
│  │  • Repay       │  │  • Pause       │  │  • Portfolios  │          │
│  │  • Extend      │  │  • Metadata    │  │  • Rewards     │          │
│  │  • Recover     │  │  • Timelock    │  │  • Checks      │          │
│  └────────────────┘  └────────────────┘  └────────────────┘          │
│                              │                                       │
├──────────────────────────────────────────────────────────────────────┤
│                    stEVE Product State                                │
│  ┌──────────────────────────────────────────────────────────┐        │
│  │  Vault Balance  │  Fee Pot  │  Lending State  │  Locked  │        │
│  │  (underlying)   │ (underlying)│ (outstanding) │  Units   │        │
│  └──────────────────────────────────────────────────────────┘        │
│                              │                                       │
├──────────────────────────────────────────────────────────────────────┤
│                    EqualFi Protocol Substrate                        │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────┐  ┌────────────┐  │
│  │ Position │  │  stEVE Pool  │  │  Fee Index /  │  │  EDEN      │  │
│  │   NFTs   │  │              │  │  Fee Router   │  │  Rewards   │  │
│  └──────────┘  └──────────────┘  └───────────────┘  └────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## The stEVE Token

### Overview

stEVE is an ERC-20 token with governance capabilities. It extends `BasketToken` (restricted mint/burn) with `ERC20Votes` for on-chain governance delegation.

```solidity
contract StEVEToken is BasketToken, ERC20Votes {
    // Restricted mint/burn (diamond only)
    // ERC-20 Permit (gasless approvals)
    // ERC-20 Votes (delegation, checkpoints)
}
```

### Token Properties

| Property | Value |
|----------|-------|
| **Standard** | ERC-20 + ERC-20 Permit + ERC-20 Votes |
| **Minter** | Diamond contract (immutable) |
| **Decimals** | 18 |
| **Transferable** | Yes |
| **Delegatable** | Yes (ERC-20 Votes) |
| **Permit** | Yes (EIP-2612) |

### Governance Delegation

stEVE holders can delegate their voting power:

```solidity
// Delegate to self
stEVEToken.delegate(msg.sender);

// Delegate to another address
stEVEToken.delegate(delegatee);

// Check voting power
uint256 votes = stEVEToken.getVotes(account);
```

### stEVE Pool

At creation, stEVE automatically gets a dedicated EqualFi pool. This pool:
- Uses the stEVE token as its underlying asset
- Inherits default pool configuration
- Tracks position-held stEVE as principal
- Participates in fee index and active credit index systems
- Provides the eligible supply for EDEN rewards

---

## Minting & Burning

### Wallet-Mode Mint

```solidity
uint256 minted = walletFacet.mintStEVE(units, recipient, maxInputAmounts);
```

**Process:**
1. Calculate base deposit: `bundleAmount × units / 1e18` (first mint) or `vaultBalance × units / totalSupply` (subsequent)
2. Calculate fee pot buy-in: `feePot × units / totalSupply`
3. Calculate mint fee: `(baseDeposit + potBuyIn) × mintFeeBps / 10,000`
4. Total required: `baseDeposit + potBuyIn + fee`
5. Pull underlying asset from sender
6. Distribute fee (pot share + pool share)
7. Mint stEVE tokens to recipient

### Wallet-Mode Burn

```solidity
uint256[] memory assetsOut = walletFacet.burnStEVE(units, recipient);
```

**Process:**
1. Calculate bundle output: `bundleAmount × units / 1e18`
2. Calculate fee pot share: `feePot × units / totalSupply`
3. Calculate burn fee: `(bundleOut + potShare) × burnFeeBps / 10,000`
4. Payout: `bundleOut + potShare - fee`
5. Transfer payout to recipient
6. Burn stEVE tokens from sender

### Units

All mint/burn operations require whole units (multiples of 1e18). The bundle definition specifies the amount of underlying asset per unit.

---

## Position-Based Operations

### Position Mint

```solidity
uint256 minted = positionFacet.mintStEVEFromPosition(positionId, units);
```

Position-mode minting draws the underlying asset from the position's pool principal (the asset's EqualFi pool). The minted stEVE tokens are held by the diamond on behalf of the position, and the position's stEVE pool principal increases.

**Key differences from wallet mode:**
- Asset source is pool principal, not wallet
- Underlying principal is encumbered via `LibModuleEncumbrance`
- Fee pot buy-in and mint fee are deducted from pool principal
- Pool share of fees routed via `LibFeeRouter`
- EDEN Rewards Engine notified of balance change

### Position Burn

```solidity
uint256[] memory assetsOut = positionFacet.burnStEVEFromPosition(positionId, units);
```

Position-mode burning reverses the mint: stEVE tokens are burned from the diamond, the NAV portion is unencumbered from the underlying pool, and the fee pot payout is credited as new principal in the underlying pool.

### Position vs. Wallet Mode

| Aspect | Wallet Mode | Position Mode |
|--------|-------------|---------------|
| **Asset source** | User's wallet | Position's pool principal |
| **Token custody** | User's wallet | Diamond (on behalf of position) |
| **EDEN Rewards** | No | Yes |
| **Governance votes** | Yes (direct holding) | No (diamond holds tokens) |
| **Lending eligible** | No | Yes |
| **Fee routing** | Fee pot + pool (via `LibFeeRouter`) | Fee pot + pool (via `LibFeeRouter`) |

---

## Deposit & Withdraw

### Overview

In addition to minting/burning stEVE tokens, position holders can deposit and withdraw the underlying asset directly to/from the stEVE pool. This is the primary mechanism for building a position that earns EDEN rewards.

### Deposit

```solidity
uint256 received = actionFacet.depositStEVEToPosition(tokenId, amount, maxAmount);
```

**Process:**
1. Verify position ownership and stEVE configuration
2. Settle active credit index and EDEN rewards for the position
3. Pull underlying asset from sender
4. Enforce minimum deposit, deposit cap, and max user limits
5. Increase position's pool principal and pool totals
6. Notify EDEN Rewards Engine of balance change

### Withdraw

```solidity
uint256 withdrawn = actionFacet.withdrawStEVEFromPosition(tokenId, amount, minReceived);
```

**Process:**
1. Verify position ownership
2. Settle active credit index and EDEN rewards
3. Check that withdrawal doesn't exceed eligible balance or encumbered amount
4. Reduce position's pool principal and pool totals
5. Transfer underlying asset to sender
6. Notify EDEN Rewards Engine of balance change

### Encumbrance Check

Withdrawals are blocked if the remaining balance would be less than the total encumbrance:

```solidity
if (LibEncumbrance.total(positionKey, pid) > newEligible) {
    revert InsufficientUnencumberedPrincipal(amount, newEligible);
}
```

This protects active loans from being undermined by withdrawals.

---

## Fee System

### Fee Structure

| Fee Type | Scope | Cap | Distribution |
|----------|-------|-----|--------------|
| **Mint Fee** | Per asset, charged on gross input | 10% (1000 bps) | Fee pot + pool share |
| **Burn Fee** | Per asset, charged on gross output | 10% (1000 bps) | Fee pot + pool share |
| **Flash Fee** | Per asset (configurable) | 10% (1000 bps) | Fee pot + pool share |

### Fee Distribution

**Wallet-mode fees:**
```
poolShare = fee × poolFeeShareBps / 10,000    (default: 10%)
potFee = fee - poolShare                        (default: 90%)
```

**Position-mode fees:**
```
poolShare = fee × poolFeeShareBps / 10,000    (default: 10%)
potFee = fee - poolShare                        (default: 90%)
```

Pool shares are routed via `LibFeeRouter.routeManagedShare`, which distributes into treasury, active credit index, and fee index components.

### Fee Configuration

Governance can update fee rates:

```solidity
adminFacet.setProductFees(mintFeeBps, burnFeeBps, flashFeeBps);
adminFacet.setPoolFeeShareBps(newPoolFeeShareBps);
```

All fee rates are capped at 10% (1000 bps).

---

## stEVE Lending

### Overview

stEVE Lending allows position holders to borrow the underlying asset against their stEVE collateral. Like EqualIndex Lending, loans are zero-interest with a flat native-token fee, fixed-duration, and fully collateralized at 100% LTV.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **100% LTV** | Borrow the full underlying value of collateral units |
| **Zero Interest** | No interest accrues; flat fee paid upfront in native token |
| **Fixed Duration** | Loans have a maturity timestamp; extendable before expiry |
| **Tiered Flat Fees** | Fee tiers based on collateral size |
| **Redeemability Invariant** | Non-locked units must always remain fully redeemable |
| **Per-Loan Encumbrance** | Each loan gets a unique module ID for collateral locking |
| **Loan History** | Full loan lifecycle tracking (created, closed, close reason) |

### Lending Configuration

```solidity
struct LendingConfig {
    uint40 minDuration;     // Minimum loan duration
    uint40 maxDuration;     // Maximum loan duration
}
// LTV is fixed at 10,000 (100%)
```

### Borrow Fee Tiers

```solidity
struct BorrowFeeTier {
    uint256 minCollateralUnits;     // Minimum collateral for this tier
    uint256 flatFeeNative;          // Flat fee in native token
}
```

Tiers are ordered ascending. Collateral below the lowest tier is rejected.

### Borrowing

```solidity
uint256 loanId = lendingFacet.borrow(positionId, collateralUnits, duration);
```

**Process:**
1. Validate collateral units (whole 1e18 multiples), duration bounds, and fee tier
2. Collect flat native fee → treasury
3. Enforce redeemability invariant: after the borrow, non-locked units must remain fully redeemable from the vault
4. Create loan record with unique module encumbrance ID
5. Encumber collateral in the stEVE pool
6. Disburse underlying assets to borrower

### Redeemability Invariant

```solidity
// For each asset in the bundle:
uint256 redeemableUnits = totalUnits - lockedCollateralUnitsAfter;
uint256 requiredVault = redeemableUnits × bundleAmount / 1e18;
require(vaultBalance - borrowedPrincipal >= requiredVault);
```

### Repayment

```solidity
lendingFacet.repay(positionId, loanId);
```

**Process:**
1. Verify position ownership and loan-position match
2. Pull underlying assets from borrower (exact amounts, zero interest)
3. Restore vault balances and reduce outstanding principal
4. Release per-loan module encumbrance
5. Mark loan as closed (reason: 1 = repaid)

### Loan Extension

```solidity
lendingFacet.extend(positionId, loanId, addedDuration);
```

- Loan must not be expired
- New maturity must not exceed `block.timestamp + maxDuration`
- Flat fee charged again for the extension

### Expired Loan Recovery

```solidity
lendingFacet.recoverExpired(loanId);
```

Anyone can call after maturity. The process:
1. Settle EDEN rewards for the borrower's position
2. Reduce borrower's stEVE pool principal by collateral amount
3. Write off outstanding principal (vault does not recover assets)
4. Release per-loan module encumbrance
5. Burn collateral stEVE tokens from the diamond (reduces total supply)
6. Enforce post-recovery redeemability invariant
7. Mark loan as closed (reason: 2 = recovered)

### Loan Data

```solidity
struct Loan {
    bytes32 borrowerPositionKey;    // Borrower's position key
    uint256 collateralUnits;        // Locked stEVE units
    uint16 ltvBps;                  // LTV at origination (always 10,000)
    uint40 maturity;                // Loan expiry timestamp
}
```

### Loan Lifecycle Tracking

Each loan tracks:
- `loanCreatedAt[loanId]` — creation timestamp
- `loanClosed[loanId]` — whether the loan is closed
- `loanClosedAt[loanId]` — closure timestamp
- `loanCloseReason[loanId]` — 1 = repaid, 2 = recovered

### Per-Loan Module Encumbrance

Each loan gets a unique encumbrance module ID:

```solidity
function _loanModuleId(uint256 loanId) internal pure returns (uint256) {
    return uint256(keccak256(abi.encodePacked("EDEN_STEVE_LOAN_", loanId)));
}
```

This allows individual loan collateral to be tracked and released independently.

---

## EDEN Rewards Engine & stEVE

> A dedicated design document for the EDEN Rewards Engine will follow. This section explains how the engine drives stEVE rewards specifically.

### How stEVE Rewards Work

The EDEN Rewards Engine distributes reward tokens to stEVE position holders proportional to their eligible balance. This is the primary incentive mechanism for the EDEN ecosystem.

### Reward Target

stEVE has a dedicated reward target:

```solidity
RewardTarget({
    targetType: RewardTargetType.STEVE_POSITION,
    targetId: STEVE_TARGET_ID    // = 0
})
```

### Eligible Balance

Only position-held stEVE earns rewards. The eligible balance for a position is its principal in the stEVE pool:

```solidity
eligibleBalance = pool.userPrincipal[positionKey]
```

Wallet-held stEVE tokens do not participate in EDEN rewards.

### Eligible Supply

The total eligible supply is the stEVE pool's total deposits:

```solidity
eligibleSupply = pool.totalDeposits
```

### Reward Distribution

Rewards are distributed continuously at a configurable rate per second:

```
pendingRewards = eligibleBalance × (globalRewardIndex - positionRewardIndex)
globalRewardIndex += rewardRatePerSecond × elapsed / eligibleSupply
```

The global reward index increases over time proportional to the reward rate and inversely proportional to the eligible supply. Positions with larger balances earn proportionally more.

### Settlement Flow

Every balance-changing operation on stEVE triggers reward settlement:

1. **Before the change:** `LibStEVERewards.settleBeforeEligibleBalanceChange(positionKey)`
   - Settles the fee index for the position
   - Reads the current eligible balance (pool principal)
   - Calls `LibEdenRewardsConsumer.beforeTargetBalanceChange` which:
     - Updates the global reward index to current time
     - Settles pending rewards for the position
     - Records the position's new reward checkpoint

2. **After the change:** `LibStEVERewards.syncEligibleBalanceChange()`
   - Calls `LibEdenRewardsConsumer.afterTargetBalanceChange` which:
     - Updates the eligible supply to reflect the new total deposits

### Operations That Trigger Settlement

| Operation | Settles Before | Syncs After |
|-----------|---------------|-------------|
| `depositStEVEToPosition` | Yes | Yes |
| `withdrawStEVEFromPosition` | Yes | Yes |
| `mintStEVEFromPosition` | Yes | Yes |
| `burnStEVEFromPosition` | Yes | Yes |
| `recoverExpired` (lending) | Yes (via `_settleRecoveredStEVE`) | — |

### Reward Programs

Governance can create multiple reward programs targeting stEVE positions. Each program has:

| Property | Description |
|----------|-------------|
| `rewardToken` | Any ERC-20 token to distribute |
| `manager` | Address authorized to manage the program |
| `rewardRatePerSecond` | Distribution rate |
| `startTime` / `endTime` | Program duration |
| `enabled` / `paused` / `closed` | Lifecycle flags |
| `fundedReserve` | Tokens deposited to fund the program |
| `outboundTransferBps` | Transfer fee applied on claim (if any) |

### Reward Eligibility Summary

| Holding Method | Earns EDEN Rewards | Earns Fee Pot | Governance Votes |
|----------------|-------------------|---------------|------------------|
| Wallet-held stEVE | No | Yes (on burn) | Yes |
| Position-held stEVE (via mint from position) | Yes | Yes (on burn) | No |
| Position deposit (direct) | Yes | No (not stEVE tokens) | No |

### Why Position-Only Rewards?

Restricting EDEN rewards to position-held stEVE:
- **Prevents wash trading** — rewards require actual protocol participation via Position NFTs
- **Enables identity** — positions can be linked to agent identities for compliance
- **Supports encumbrance** — lending and other modules can lock position-held stEVE
- **Tracks eligibility** — the pool's `totalDeposits` provides a clean eligible supply metric

---

## Data Models

### Product Configuration

```solidity
struct ProductConfig {
    address[] assets;           // Single underlying asset
    uint256[] bundleAmounts;    // Amount per unit (1e18 scale)
    uint16[] mintFeeBps;        // Mint fee (basis points)
    uint16[] burnFeeBps;        // Burn fee (basis points)
    uint16 flashFeeBps;         // Flash loan fee (basis points)
    uint256 totalUnits;         // Total stEVE tokens in circulation
    address token;              // StEVEToken contract address
    uint256 poolId;             // Dedicated stEVE pool ID
    bool paused;                // Pause flag
}
```

### Product Metadata

```solidity
struct ProductMetadata {
    string name;                // Token name
    string symbol;              // Token symbol
    string uri;                 // Metadata URI
    address creator;            // Creator address
    uint64 createdAt;           // Creation timestamp
    uint8 productType;          // Product type identifier (1 = stEVE)
}
```

### Product Accounting

```solidity
struct ProductAccounting {
    mapping(address => uint256) vaultBalances;  // Underlying asset vault balance
    mapping(address => uint256) feePots;        // Accumulated fee pot
}
```

### Product Storage

```solidity
struct ProductStorage {
    bool productInitialized;        // Whether stEVE has been created
    uint16 poolFeeShareBps;         // Pool share of fees (default: 10%)
    ProductConfig product;          // Product configuration
    ProductMetadata productMetadata;// Product metadata
    ProductAccounting accounting;   // Vault and fee pot balances
}
```

### Lending Storage

```solidity
struct LendingStorage {
    uint256 nextLoanId;                                 // Monotonic loan ID counter
    LendingConfig lendingConfig;                        // Duration bounds
    BorrowFeeTier[] borrowFeeTiers;                     // Fee tier schedule
    uint256 lockedCollateralUnits;                      // Total locked collateral
    mapping(address => uint256) outstandingPrincipal;   // Per-asset outstanding
    mapping(uint256 => Loan) loans;                     // Loan ID → loan data
    mapping(bytes32 => uint256[]) borrowerLoanIds;      // Position → loan IDs
    mapping(uint256 => bool) loanClosed;                // Loan closure flag
    mapping(uint256 => uint256) loanClosedAt;           // Closure timestamp
    mapping(uint256 => uint8) loanCloseReason;          // 1=repaid, 2=recovered
    mapping(uint256 => uint256) loanCreatedAt;          // Creation timestamp
}
```

---

## View Functions

### Product Queries

```solidity
// Full product configuration
function getProductConfig() external view returns (ProductConfigView memory);

// Product pool ID
function getProductPoolId() external view returns (uint256);

// Fee configuration
function getProductFeeConfig() external view returns (ProductFeeConfigView memory);

// Vault balance for the underlying asset
function getProductVaultBalance(address asset) external view returns (uint256);

// Fee pot balance for the underlying asset
function getProductFeePot(address asset) external view returns (uint256);
```

### Reward Queries

```solidity
// Reward state overview
function getProductRewardState() external view returns (ProductRewardStateView memory);

// All reward programs targeting stEVE
function getProductRewardPrograms() external view returns (ProductRewardProgramView[] memory);

// Active reward program IDs
function getActiveProductRewardProgramIds() external view returns (uint256[] memory);
```

### Position Queries

```solidity
// Position product view (units, encumbered, available)
function getPositionProductView(uint256 positionId) external view returns (PositionProductView memory);

// Position reward view (eligible principal, claimable rewards)
function getPositionRewardView(uint256 positionId) external view returns (PositionRewardView memory);

// Per-program reward preview for a position
function previewPositionRewardPrograms(uint256 positionId)
    external view returns (PositionRewardProgramView[] memory, uint256 totalClaimableRewards);

// Full position portfolio (product + rewards + loans + agent)
function getPositionPortfolio(uint256 positionId) external view returns (PositionPortfolio memory);

// All position IDs for a user
function getUserPositionIds(address user) external view returns (uint256[] memory);

// Full user portfolio (all positions)
function getUserPortfolio(address user) external view returns (UserPortfolio memory);
```

### Eligibility Queries

```solidity
// Total eligible supply for EDEN rewards
function eligibleSupply() external view returns (uint256);

// Eligible principal for a specific position
function eligiblePrincipalOfPosition(uint256 tokenId) external view returns (uint256);
```

### Lending Queries

```solidity
// Loan details
function getLoanView(uint256 loanId) external view returns (LoanView memory);

// Loan IDs by borrower (all / active / paginated)
function getLoanIdsByBorrower(uint256 positionId) external view returns (uint256[] memory);
function getActiveLoanIdsByBorrower(uint256 positionId) external view returns (uint256[] memory);

// Full loan views by borrower
function getLoansByBorrower(uint256 positionId) external view returns (LoanView[] memory);
function getActiveLoansByBorrower(uint256 positionId) external view returns (LoanView[] memory);

// Borrow/repay/extend previews
function previewBorrow(uint256 positionId, uint256 collateralUnits, uint40 duration)
    external view returns (BorrowPreview memory);
function previewRepay(uint256 positionId, uint256 loanId) external view returns (RepayPreview memory);
function previewExtend(uint256 positionId, uint256 loanId, uint40 addedDuration)
    external view returns (ExtendPreview memory);

// Outstanding principal and locked collateral
function getOutstandingPrincipal(address asset) external view returns (uint256);
function getLockedCollateralUnits() external view returns (uint256);
function loanCount() external view returns (uint256);
function borrowerLoanCount(uint256 positionId) external view returns (uint256);
```

### Action Checks

Pre-flight validation for UI integration:

```solidity
function canMintStEVE(uint256 units) external view returns (ActionCheck memory);
function canBurnStEVE(address owner, uint256 units) external view returns (ActionCheck memory);
function canBorrow(uint256 positionId, uint256 collateralUnits, uint40 duration)
    external view returns (ActionCheck memory);
function canRepay(uint256 positionId, uint256 loanId) external view returns (ActionCheck memory);
function canExtend(uint256 positionId, uint256 loanId, uint40 addedDuration)
    external view returns (ActionCheck memory);
function canClaimRewards(uint256 positionId) external view returns (ActionCheck memory);
```

Action check codes:

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | `ACTION_OK` | Action is valid |
| 1 | `ACTION_UNKNOWN_BASKET` | Product not configured |
| 2 | `ACTION_BASKET_PAUSED` | Product is paused |
| 3 | `ACTION_INVALID_UNITS` | Invalid unit amount |
| 4 | `ACTION_INSUFFICIENT_BALANCE` | Insufficient balance or vault invariant failure |
| 5 | `ACTION_POSITION_MISMATCH` | Position doesn't match loan |
| 6 | `ACTION_LOAN_NOT_FOUND` | Loan doesn't exist |
| 7 | `ACTION_LOAN_EXPIRED` | Loan has expired |
| 8 | `ACTION_NOTHING_CLAIMABLE` | No rewards to claim |
| 9 | `ACTION_INVALID_DURATION` | Duration outside bounds |
| 10 | `ACTION_INSUFFICIENT_COLLATERAL` | Not enough available collateral |
| 11 | `ACTION_BELOW_MINIMUM_TIER` | Collateral below minimum fee tier |
| 12 | `ACTION_REWARDS_DISABLED` | No active reward programs |

---

## Integration Guide

### For Wallet-Mode Users

#### Minting stEVE

```solidity
// Approve underlying asset
IERC20(underlying).approve(diamond, type(uint256).max);

// Mint 10 stEVE units
uint256[] memory maxInputs = new uint256[](1);
maxInputs[0] = 10.5e18;  // slippage buffer

uint256 minted = walletFacet.mintStEVE(10e18, msg.sender, maxInputs);
// stEVE tokens now in wallet — can delegate governance votes
```

#### Burning stEVE

```solidity
// Approve stEVE token
IERC20(stEVEToken).approve(diamond, 10e18);

uint256[] memory assetsOut = walletFacet.burnStEVE(10e18, msg.sender);
```

### For Position Holders

#### Depositing to Earn Rewards

```solidity
// Deposit underlying asset directly to stEVE pool position
IERC20(underlying).approve(diamond, 100e18);
uint256 received = actionFacet.depositStEVEToPosition(positionId, 100e18, 100e18);
// EDEN rewards now accruing
```

#### Minting from Position

```solidity
// Mint stEVE from position's underlying pool principal
uint256 minted = positionFacet.mintStEVEFromPosition(positionId, 10e18);
// stEVE credited to position, EDEN rewards accruing
```

#### Checking Rewards

```solidity
// Check claimable rewards
PositionRewardView memory rewards = viewFacet.getPositionRewardView(positionId);
// rewards.claimableRewards — total claimable across all programs
// rewards.eligiblePrincipal — current eligible balance
```

#### Withdrawing

```solidity
uint256 withdrawn = actionFacet.withdrawStEVEFromPosition(positionId, 50e18, 49e18);
```

### For Borrowers

#### Borrowing Against stEVE

```solidity
// Preview the borrow
BorrowPreview memory preview = lendingFacet.previewBorrow(positionId, 5e18, 30 days);
// preview.feeNative — flat fee in ETH
// preview.invariantSatisfied — whether the borrow is safe

// Execute borrow
uint256 loanId = lendingFacet.borrow{value: preview.feeNative}(positionId, 5e18, 30 days);
```

#### Repaying

```solidity
// Preview repayment
RepayPreview memory preview = lendingFacet.previewRepay(positionId, loanId);

// Approve and repay
IERC20(underlying).approve(diamond, preview.principals[0]);
lendingFacet.repay(positionId, loanId);
```

#### Extending

```solidity
ExtendPreview memory preview = lendingFacet.previewExtend(positionId, loanId, 15 days);
lendingFacet.extend{value: preview.feeNative}(positionId, loanId, 15 days);
```

### For Enforcers

```solidity
// Recover expired loan (anyone can call)
lendingFacet.recoverExpired(loanId);
```

---

## Worked Examples

### Example 1: Deposit, Earn Rewards, Withdraw

**Scenario:** Alice deposits 1,000 USDC to a stEVE position and earns EDEN rewards over 30 days.

**Setup:**
```
stEVE underlying: USDC
Bundle: 1 USDC per unit (1e6 per 1e18 units)
Active reward program: 100 EDEN tokens/day
Total eligible supply: 100,000 USDC (before Alice)
```

**Day 0: Deposit**
```
Alice deposits 1,000 USDC to position #42:
  pool.userPrincipal[alice] = 1,000e6
  pool.totalDeposits = 101,000e6
  EDEN Rewards Engine notified: eligibleSupply = 101,000e6
```

**Day 30: Check Rewards**
```
Alice's share: 1,000 / 101,000 ≈ 0.99%
Total rewards distributed: 100 × 30 = 3,000 EDEN
Alice's rewards: 3,000 × 0.99% ≈ 29.7 EDEN

(Actual calculation uses globalRewardIndex for precision)
```

**Day 30: Withdraw**
```
Alice withdraws 1,000 USDC:
  EDEN rewards settled before withdrawal
  pool.userPrincipal[alice] = 0
  pool.totalDeposits = 100,000e6
  Alice receives: 1,000 USDC + 29.7 EDEN (claimed separately)
```

### Example 2: Mint, Fee Pot Growth, Burn

**Scenario:** Bob mints stEVE early, fees accumulate, Bob burns later.

**Step 1: Bob mints 100 stEVE (first minter)**
```
Bundle: 1 USDC per unit
Mint fee: 1%

Bob deposits: 100 USDC + 1 USDC fee = 101 USDC
vaultBalances[USDC]: 100e6
feePots[USDC]: 0.9e6 (90% of 1 USDC fee to pot)
Pool receives: 0.1e6 (10% pool share)
totalUnits: 100e18
```

**Step 2: Other users mint/burn, generating 50 USDC in fees**
```
feePots[USDC]: 0.9 + 45 = 45.9e6 (90% of fees to pot)
```

**Step 3: Bob burns 100 stEVE**
```
Bundle out: 100e6
Pot share: 45.9e6 × 100/100 = 45.9e6 (Bob is only holder)
Gross: 145.9e6
Burn fee (1%): 1.459e6
Payout: 144.441e6

Bob deposited ~101 USDC, receives ~144.44 USDC
Net gain: ~43.44 USDC from fee pot accumulation
```

### Example 3: Lending Lifecycle

**Scenario:** Carol borrows against 50 stEVE units for 30 days.

**Setup:**
```
stEVE underlying: USDC
Bundle: 1 USDC per unit
LTV: 100%
Fee tier: 10+ units → 0.005 ETH flat fee
totalUnits: 1,000e18
vaultBalances[USDC]: 1,000e6
```

**Borrow:**
```
Collateral: 50e18 stEVE units
Flat fee: 0.005 ETH → treasury

Borrowed: 50 × 1 × 100% = 50 USDC

After borrow:
  vaultBalances[USDC]: 950e6
  outstandingPrincipal[USDC]: 50e6
  lockedCollateralUnits: 50e18
  Carol's position: 50e18 encumbered via loan module ID

Redeemability check:
  redeemableUnits = 1,000 - 50 = 950
  requiredVault = 950 × 1 = 950 USDC
  actualVault = 950 USDC ✓
```

**Repay (Day 25):**
```
Carol returns 50 USDC (exact, zero interest)
vaultBalances[USDC]: 1,000e6
outstandingPrincipal[USDC]: 0
lockedCollateralUnits: 0
Loan closed (reason: 1 = repaid)
```

### Example 4: Expired Loan Recovery

**Scenario:** Dave's loan expires without repayment.

**State at expiry:**
```
Loan: 20e18 collateral units
Outstanding: 20 USDC
totalUnits: 500e18
vaultBalances[USDC]: 480e6
```

**Recovery:**
```
recoverExpired(loanId):

1. Settle EDEN rewards for Dave's position
2. Reduce Dave's pool principal by 20e18
3. Write off outstanding: outstandingPrincipal[USDC] -= 20e6
4. Release module encumbrance
5. Burn 20e18 stEVE tokens from diamond
   totalUnits: 480e18

6. Post-recovery invariant:
   redeemableUnits = 480 - lockedCollateral
   requiredVault = redeemableUnits × 1
   actualVault = 480 USDC ✓

Loan closed (reason: 2 = recovered)

Economic effect:
  Dave keeps 20 USDC (borrowed)
  Dave loses 20e18 stEVE (collateral)
  Remaining 480 units backed by 480 USDC vault
  Per-unit value preserved
```

---

## Error Reference

### Product Errors

| Error | Cause |
|-------|-------|
| `UnknownIndex(uint256)` | Product not initialized |
| `IndexPaused(uint256)` | Product is paused |
| `InvalidUnits()` | Units are zero or not a multiple of 1e18 |
| `InvalidBundleDefinition()` | Zero bundle amount or invalid asset |
| `InvalidArrayLength()` | Array length mismatch |
| `NoPoolForAsset(address)` | Underlying asset has no EqualFi pool |
| `InvalidParameterRange(string)` | Various validation failures |

### Position Errors

| Error | Cause |
|-------|-------|
| `InsufficientPrincipal(uint256, uint256)` | Insufficient principal for operation |
| `InsufficientUnencumberedPrincipal(uint256, uint256)` | Withdrawal would violate encumbrance |
| `InsufficientIndexTokens(uint256, uint256)` | Position holds fewer stEVE than burn request |
| `NotMemberOfRequiredPool(bytes32, uint256)` | Position not a member of required pool |
| `DepositBelowMinimum(uint256, uint256)` | Deposit below pool minimum |
| `DepositCapExceeded(uint256, uint256)` | Deposit exceeds pool cap |
| `MaxUserCountExceeded(uint256)` | Pool user limit reached |

### Lending Errors

| Error | Cause |
|-------|-------|
| `InvalidDuration(uint256, uint256, uint256)` | Duration outside configured bounds |
| `InvalidTierConfiguration()` | Fee tier ordering invalid |
| `UnexpectedNativeFee(uint256, uint256)` | Incorrect native fee amount |
| `InsufficientVaultBalance(address, uint256, uint256)` | Vault lacks balance for borrow |
| `RedeemabilityInvariantBroken(address, uint256, uint256)` | Borrow would break redeemability |
| `LoanNotFound(uint256)` | Loan doesn't exist or already closed |
| `LoanExpired(uint256, uint40)` | Extension attempted after maturity |
| `LoanNotExpired(uint256, uint40)` | Recovery attempted before maturity |
| `BelowMinimumTier(uint256)` | Collateral below lowest fee tier |
| `PositionMismatch(bytes32, bytes32)` | Caller's position doesn't match loan |

---

## Events

### Product Events

```solidity
event StEVEConfigured(uint256 indexed basketId, address indexed token);
event StEVEProductConfigured(address indexed token, address[] assets, uint256[] bundleAmounts);
event ProductPausedUpdated(uint256 indexed productId, bool paused);
event ProductMetadataUpdated(uint256 indexed productId, string oldUri, string newUri, uint8 oldType, uint8 newType);
event ProductFeeConfigUpdated(uint256 indexed productId, uint16[] mintFeeBps, uint16[] burnFeeBps, uint16 flashFeeBps);
event PoolFeeShareUpdated(uint16 oldBps, uint16 newBps);
```

### Wallet Events

```solidity
event StEVEMinted(address indexed caller, address indexed to, uint256 units);
event StEVEBurned(address indexed caller, address indexed to, uint256 units);
```

### Position Events

```solidity
event StEVEDepositedToPosition(uint256 indexed tokenId, bytes32 indexed positionKey, uint256 amount);
event StEVEWithdrawnFromPosition(uint256 indexed tokenId, bytes32 indexed positionKey, uint256 amount);
```

### Lending Events

```solidity
event LendingConfigUpdated(uint256 indexed productId, uint40 minDuration, uint40 maxDuration, uint16 ltvBps);
event BorrowFeeTiersUpdated(uint256 indexed productId, uint256[] minCollateralUnits, uint256[] flatFeeNative);

event LoanCreated(
    uint256 indexed loanId,
    uint256 indexed productId,
    bytes32 indexed borrowerPositionKey,
    uint256 collateralUnits,
    address[] assets,
    uint256[] principals,
    uint16 ltvBps,
    uint40 maturity
);

event LoanRepaid(uint256 indexed loanId, bytes32 indexed borrowerPositionKey);
event LoanExtended(uint256 indexed loanId, uint40 newMaturity, uint256 feeNative);

event LoanRecovered(
    uint256 indexed loanId,
    bytes32 indexed borrowerPositionKey,
    uint256 collateralUnits,
    address[] assets,
    uint256[] principals
);
```

### Admin Events

```solidity
event ProtocolURIUpdated(string oldUri, string newUri);
event ContractVersionUpdated(string oldVersion, string newVersion);
event FacetVersionUpdated(address indexed facet, string oldVersion, string newVersion);
event TimelockControllerUpdated(address indexed oldTimelock, address indexed newTimelock);
```

---

## Security Considerations

### 1. Singleton Enforcement

stEVE can only be created once per deployment:

```solidity
if (LibStEVEEligibilityStorage.s().configured) revert InvalidParameterRange("stEVE already configured");
```

This prevents duplicate products and ensures a single canonical stEVE instance.

### 2. Single-Asset Constraint

stEVE is restricted to exactly one underlying asset:

```solidity
if (params.assets.length != 1) revert InvalidBundleDefinition();
if (params.basketType != 1) revert InvalidParameterRange("stEVE basketType");
```

### 3. Fee Caps

All fee rates are capped at 10% (1000 bps):

```solidity
if (mintFeeBps[i] > 1000 || burnFeeBps[i] > 1000) revert InvalidParameterRange("product fee too high");
if (flashFeeBps > 1000) revert InvalidParameterRange("flashFeeBps too high");
```

### 4. Reentrancy Protection

All state-changing functions use `nonReentrant` modifier.

### 5. Redeemability Invariant (Lending)

Before any borrow, the system verifies that non-locked units remain fully redeemable:

```solidity
redeemableUnits = totalUnits - lockedCollateralUnitsAfter;
requiredVault = redeemableUnits × bundleAmount / 1e18;
require(vaultBalance - borrowedPrincipal >= requiredVault);
```

A post-recovery invariant is also enforced after expired loan recovery.

### 6. Per-Loan Encumbrance Isolation

Each loan gets a unique module encumbrance ID derived from the loan ID:

```solidity
uint256(keccak256(abi.encodePacked("EDEN_STEVE_LOAN_", loanId)))
```

This prevents cross-loan interference and allows individual loan collateral to be released independently.

### 7. Withdrawal Encumbrance Check

Withdrawals verify that the remaining balance covers all encumbrances:

```solidity
if (LibEncumbrance.total(positionKey, pid) > newEligible) {
    revert InsufficientUnencumberedPrincipal(amount, newEligible);
}
```

### 8. EDEN Rewards Settlement Ordering

Rewards are always settled before any balance change to prevent reward manipulation:

```solidity
// 1. Settle rewards (captures current eligible balance)
LibStEVERewards.settleBeforeEligibleBalanceChange(positionKey);
// 2. Perform balance change
// 3. Sync eligible supply
LibStEVERewards.syncEligibleBalanceChange();
```

### 9. Whole Unit Enforcement

All mint/burn/borrow operations require whole units:

```solidity
if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();
```

### 10. Governance Controls

Admin operations are gated by timelock or owner:

```solidity
LibAccess.enforceTimelockOrOwnerIfUnset();
```

Configurable parameters:
- Product fees (mint, burn, flash)
- Pool fee share percentage
- Lending duration bounds
- Borrow fee tiers
- Product pause state
- Metadata and versioning

### 11. Loan Lifecycle Auditability

Every loan tracks creation time, closure time, and close reason:
- Reason 1 = repaid by borrower
- Reason 2 = recovered after expiry

This provides a complete audit trail for all lending activity.

### 12. Asset Pool Requirement

The underlying asset must have an existing EqualFi pool:

```solidity
if (LibAppStorage.s().assetToPoolId[params.assets[0]] == 0) revert NoPoolForAsset(params.assets[0]);
```

---

## Appendix: Correctness Properties

### Property 1: Singleton Invariant
```
stEVE can only be created once per deployment
LibStEVEEligibilityStorage.s().configured == true after creation
```

### Property 2: Vault Conservation
For stEVE with no outstanding loans:
```
vaultBalances[underlying] ≥ totalUnits × bundleAmount / 1e18
```

### Property 3: Fee Pot Monotonicity (Between Burns)
Between burn operations, the fee pot only increases:
```
feePots[underlying]_new ≥ feePots[underlying]_old  (absent burns)
```

### Property 4: Redeemability Invariant
```
redeemableUnits = totalUnits - lockedCollateralUnits
vaultBalances[underlying] ≥ redeemableUnits × bundleAmount / 1e18
```

### Property 5: Eligible Supply Consistency
```
eligibleSupply = stEVE pool totalDeposits
eligibleBalance(position) = pool.userPrincipal[positionKey]
Σ(eligibleBalance) for all positions = eligibleSupply
```

### Property 6: Reward Settlement Ordering
For any balance-changing operation:
```
settleBeforeEligibleBalanceChange() called BEFORE balance change
syncEligibleBalanceChange() called AFTER balance change
```

### Property 7: Encumbrance Consistency
```
∀ position: LibEncumbrance.total(positionKey, poolId) ≤ pool.userPrincipal[positionKey]
```

### Property 8: Loan Collateral Conservation
```
lockedCollateralUnits = Σ(loan.collateralUnits) for all active loans
lockedCollateralUnits ≤ totalUnits
```

### Property 9: Lending LTV Constraint
```
∀ loan: ltvBps == 10,000 (100%)
borrowedPrincipal = collateralUnits × bundleAmount × ltvBps / (1e18 × 10,000)
```

### Property 10: Recovery Neutrality
After expired loan recovery:
```
totalUnits_new = totalUnits_old - loan.collateralUnits
outstandingPrincipal reduced by loan principals
Per-unit vault claim preserved for remaining holders
```

### Property 11: Loan Lifecycle Completeness
```
∀ closed loan: loanClosed[loanId] == true
                loanClosedAt[loanId] > 0
                loanCloseReason[loanId] ∈ {1, 2}
```

### Property 12: Position-Only Reward Eligibility
```
Wallet-held stEVE: eligibleBalance = 0 (no EDEN rewards)
Position-held stEVE: eligibleBalance = pool.userPrincipal[positionKey]
```

---

**Document Version:** 1.0
**Module:** stEVE — EDEN by EqualFi Staked Vault Engine