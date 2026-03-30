# EqualIndex & EqualIndex Lending - Design Document

**Version:** 1.0
**Module:** EqualFi Index Token Platform

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Index Tokens](#index-tokens)
5. [Minting & Burning](#minting--burning)
6. [Position-Based Operations](#position-based-operations)
7. [Fee System](#fee-system)
8. [Flash Loans](#flash-loans)
9. [EqualIndex Lending](#equalindex-lending)
10. [EDEN Rewards Engine (Overview)](#eden-rewards-engine-overview)
11. [Data Models](#data-models)
12. [View Functions](#view-functions)
13. [Integration Guide](#integration-guide)
14. [Worked Examples](#worked-examples)
15. [Error Reference](#error-reference)
16. [Events](#events)
17. [Security Considerations](#security-considerations)

---

## Overview

EqualIndex is EqualFi's on-chain index token system. It allows the creation of multi-asset basket tokens — each index token represents a fixed bundle of underlying assets held in protocol-managed vaults. Users mint index tokens by depositing the constituent assets in the correct proportions, and redeem them by burning tokens to receive the underlying basket back.

EqualIndex Lending extends this by allowing position holders to borrow the underlying basket assets against their index token collateral, creating a leverage primitive on top of index exposure.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Multi-Asset Baskets** | Each index defines a fixed bundle of underlying assets with precise amounts |
| **ERC-20 Index Tokens** | Fully transferable tokens with ERC-20 Permit support |
| **Per-Asset Fees** | Independent mint and burn fee rates per constituent asset |
| **Fee Pot Mechanism** | Accumulated fees create a growing pot that benefits long-term holders |
| **Dual Access Modes** | Wallet-mode (direct ERC-20) and position-mode (via Position NFTs) |
| **Flash Loans** | Borrow full basket units within a single transaction |
| **Index Lending** | Borrow underlying assets against index token collateral with fixed duration |
| **Redeemability Invariant** | Lending enforces that non-locked units always remain fully redeemable |
| **EDEN Rewards Integration** | Position-mode holders earn from the EDEN Rewards Engine |

### System Participants

| Role | Description |
|------|-------------|
| **Minter** | User who deposits constituent assets to mint index tokens |
| **Redeemer** | User who burns index tokens to receive underlying assets |
| **Position Holder** | User who mints/burns via Position NFTs, earning pool yield and EDEN rewards |
| **Borrower** | Position holder who borrows underlying assets against index token collateral |
| **Flash Borrower** | Contract that borrows basket units within a single transaction |
| **Index Creator** | Governance (free) or fee-paying user who defines new indexes |
| **Enforcer** | Anyone who recovers expired index loans |

### Why Index Tokens?

Index tokens solve several problems in DeFi portfolio management:
- **Single-token exposure** → Hold one token instead of managing multiple positions
- **Deterministic composition** → Bundle amounts are fixed at creation, no rebalancing drift
- **Fee accumulation** → Mint/burn fees flow into a pot that increases redemption value over time
- **Composable collateral** → Index tokens can be deposited into EqualFi pools, used as lending collateral, or traded freely
- **No oracle dependency** → Pricing is derived from the fixed bundle definition and vault balances

---

## How It Works

### The Core Model

1. **Create** an index defining constituent assets and bundle amounts
2. **Mint** index tokens by depositing the required assets in proportion
3. **Hold** tokens to benefit from fee pot accumulation
4. **Burn** tokens to redeem the underlying basket plus a share of the fee pot
5. **Lend** against index token collateral to access underlying liquidity

### Bundle Definition

Each index unit (1e18) represents a fixed basket:

```
Index "EDEN-LST" = {
    1.0 stETH (1e18 wei),
    1.0 rETH  (1e18 wei),
    1000 USDC (1000e6)
}
```

Minting 2 units requires exactly 2× each bundle amount, plus fees.

### Economic Balance

When lending is active, the vault balance alone doesn't reflect the full backing. The economic balance includes outstanding loans:

```
economicBalance = vaultBalance + outstandingPrincipal
```

This ensures mint pricing accounts for lent-out assets that will be returned.

---

## Architecture

### Contract Structure

```
src/equalindex/
├── EqualIndexBaseV3.sol            # Shared storage, structs, helpers, modifiers
├── EqualIndexAdminFacetV3.sol      # Index creation, pause, configuration, views
├── EqualIndexActionsFacetV3.sol    # Wallet-mode mint, burn, flash loans
├── EqualIndexPositionFacet.sol     # Position-mode mint, burn (via Position NFTs)
├── EqualIndexLendingFacet.sol      # Borrow, repay, extend, recover against index collateral
└── IndexToken.sol                  # ERC-20 token with restricted mint/burn

src/libraries/
├── LibEqualIndexLending.sol        # Lending storage, types, events, errors
├── LibEqualIndexRewards.sol        # EDEN Rewards Engine integration bridge
├── LibIndexEncumbrance.sol         # Index-specific encumbrance tracking
└── LibEdenRewardsStorage.sol       # Rewards engine storage (shared)

src/interfaces/
└── IEqualIndexFlashReceiver.sol    # Flash loan callback interface
```

### High-Level Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                         EqualIndex V3                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │
│  │   Actions      │  │   Position     │  │   Lending      │          │
│  │   Facet V3     │  │   Facet        │  │   Facet        │          │
│  │                │  │                │  │                │          │
│  │  • Wallet Mint │  │  • Position    │  │  • Borrow      │          │
│  │  • Wallet Burn │  │    Mint        │  │  • Repay       │          │
│  │  • Flash Loans │  │  • Position    │  │  • Extend      │          │
│  │                │  │    Burn        │  │  • Recover     │          │
│  └────────────────┘  └────────────────┘  └────────────────┘          │
│         │                    │                    │                   │
│         └────────────────────┼────────────────────┘                   │
│                              │                                       │
│  ┌────────────────┐  ┌──────────────┐                                │
│  │   Admin        │  │  Index       │                                │
│  │   Facet V3     │  │  Token       │                                │
│  │                │  │  (ERC-20)    │                                │
│  │  • Create      │  │              │                                │
│  │  • Pause       │  │  • Mint/Burn │                                │
│  │  • Views       │  │  • Permit    │                                │
│  └────────────────┘  └──────────────┘                                │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│                    Per-Index State                                    │
│  ┌──────────────────────────────────────────────────────────┐        │
│  │  Vault Balances  │  Fee Pots  │  Lending State  │ Locked │        │
│  │  (per asset)     │ (per asset)│ (outstanding)   │ Units  │        │
│  └──────────────────────────────────────────────────────────┘        │
│                              │                                       │
├──────────────────────────────────────────────────────────────────────┤
│                    EqualFi Protocol Substrate                        │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────┐  ┌────────────┐  │
│  │ Position │  │    Pool      │  │  Fee Index /  │  │  EDEN      │  │
│  │   NFTs   │  │ Infrastructure│  │ Fee Router   │  │  Rewards   │  │
│  └──────────┘  └──────────────┘  └───────────────┘  └────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Index Tokens

### Overview

Each index is backed by an ERC-20 `IndexToken` contract deployed at creation time. The token:
- Has restricted `mint`/`burn` (only the diamond can call)
- Supports ERC-20 Permit (gasless approvals)
- Stores immutable bundle metadata (assets, amounts, bundle hash)
- Tracks cumulative mint and burn fees collected

### Token Properties

```solidity
contract IndexToken is ERC20, ERC20Permit {
    address public immutable minter;        // Diamond address
    uint256 public immutable indexId;       // Index identifier

    address[] internal _assets;             // Constituent asset addresses
    uint256[] internal _bundleAmounts;      // Amount per asset per unit
    uint256 public flashFeeBps;             // Flash loan fee rate
    uint256 public bundleCount;             // Number of constituent assets
    bytes32 public bundleHash;              // keccak256(assets, bundleAmounts)

    uint256 public totalMintFeesCollected;  // Cumulative mint fees (units)
    uint256 public totalBurnFeesCollected;  // Cumulative burn fees (units)
}
```

### Bundle Hash

The bundle hash provides an immutable fingerprint of the index composition:

```solidity
bundleHash = keccak256(abi.encode(assets, bundleAmounts));
```

This allows off-chain verification that an index token matches an expected composition.

### Index Pool

Each index token automatically gets a dedicated EqualFi pool at creation. This pool:
- Uses the index token as its underlying asset
- Inherits default pool configuration (LTV, fees, maintenance rate)
- Enables position-mode operations (deposit, yield, lending)
- Participates in the fee index and active credit index systems

---

## Minting & Burning

### Wallet-Mode Mint

Direct minting from a wallet (no Position NFT required):

```solidity
uint256 minted = actionsFacet.mint(indexId, units, recipient, maxInputAmounts);
```

**Process per constituent asset:**
1. Calculate vault input: `vaultIn = bundleAmount × units / 1e18` (first mint) or `economicBalance × units / totalSupply` (subsequent mints)
2. Calculate fee pot buy-in: `potBuyIn = feePot × units / totalSupply` (pro-rata share of accumulated fees)
3. Calculate mint fee: `fee = (vaultIn + potBuyIn) × mintFeeBps / 10,000`
4. Total required: `vaultIn + potBuyIn + fee`
5. Pull assets from sender (ERC-20 transfer or native ETH)

**Units must be whole multiples of 1e18** — fractional units are not allowed.

### Wallet-Mode Burn

```solidity
uint256[] memory assetsOut = actionsFacet.burn(indexId, units, recipient);
```

**Process per constituent asset:**
1. Calculate bundle output: `bundleOut = bundleAmount × units / 1e18`
2. Calculate fee pot share: `potShare = feePot × units / totalSupply`
3. Calculate burn fee: `fee = (bundleOut + potShare) × burnFeeBps / 10,000`
4. Payout: `bundleOut + potShare - fee`
5. Transfer payout to recipient

### Fee Pot Buy-In (Minting)

When minting into an index that has accumulated fees, new minters must buy into the fee pot proportionally. This prevents dilution of existing holders' fee pot share:

```
potBuyIn = feePot[asset] × units / totalSupply
```

The buy-in amount is added to the fee pot, maintaining each holder's pro-rata claim.

### Fee Pot Share (Burning)

When burning, holders receive their proportional share of the fee pot on top of the base bundle:

```
potShare = feePot[asset] × units / totalSupply
```

This means long-term holders benefit from fees accumulated since their mint.

---

## Position-Based Operations

### Overview

Position-mode operations allow users to mint and burn index tokens through their EqualFi Position NFTs. Instead of transferring raw assets, the system moves principal between the user's pool positions and the index vaults. This integrates index tokens into the broader EqualFi ecosystem — enabling yield accrual, encumbrance tracking, and EDEN rewards.

### Position Mint

```solidity
uint256 minted = positionFacet.mintFromPosition(positionId, indexId, units);
```

**Process per constituent asset:**
1. Verify the position has membership in the asset's pool
2. Calculate required amounts (same formula as wallet mint)
3. Encumber the vault input from the position's pool principal via `LibIndexEncumbrance`
4. Deduct fee pot buy-in and mint fee from the position's pool principal
5. Route the pool share of fees via `LibFeeRouter`
6. Remaining fee goes to the index fee pot

**After all legs complete:**
- Index tokens are minted to the diamond (held in custody)
- Position's index pool principal increases by the minted units
- EDEN Rewards Engine is notified of the balance change

### Position Burn

```solidity
uint256[] memory assetsOut = positionFacet.burnFromPosition(positionId, indexId, units);
```

**Process per constituent asset:**
1. Calculate bundle output, fee pot share, and burn fee
2. Unencumber the NAV portion from the position's pool principal
3. Credit the fee pot payout portion as new principal in the asset's pool
4. Route the pool share of burn fees via `LibFeeRouter`

**After all legs complete:**
- Index tokens are burned from the diamond
- Position's index pool principal decreases by the burned units
- EDEN Rewards Engine is notified of the balance change

### Position vs. Wallet Mode

| Aspect | Wallet Mode | Position Mode |
|--------|-------------|---------------|
| **Asset source** | User's wallet (ERC-20 transfer) | Position's pool principal |
| **Token custody** | User's wallet | Diamond (on behalf of position) |
| **Fee routing** | Fee pot + pool fee index | Fee pot + `LibFeeRouter` |
| **Yield accrual** | None | Pool fee index yield |
| **EDEN Rewards** | No | Yes |
| **Encumbrance** | None | `LibIndexEncumbrance` tracks locked principal |
| **Lending eligible** | No (tokens in wallet) | Yes (tokens in index pool) |

---

## Fee System

### Fee Structure

Each index has independent fee rates per constituent asset:

| Fee Type | Scope | Cap | Distribution |
|----------|-------|-----|--------------|
| **Mint Fee** | Per asset, charged on gross input | 10% (1000 bps) | Fee pot + pool share |
| **Burn Fee** | Per asset, charged on gross output | 10% (1000 bps) | Fee pot + pool share |
| **Flash Loan Fee** | Per asset, charged on loan amount | 10% (1000 bps) | Fee pot + pool share |

### Fee Distribution Split

Fees are split between the index fee pot and the underlying asset pools:

**Mint/Burn fees (wallet mode):**
```
feeIndexShare = fee × mintBurnFeeIndexShareBps / 10,000    (default: 40%)
poolShare = fee - feeIndexShare                              (default: 60%)
```

- `feeIndexShare` → added to the index fee pot (benefits index holders)
- `poolShare` → routed to the underlying asset pool via `LibFeeRouter` (benefits pool depositors)

**Mint/Burn fees (position mode):**
```
poolShare = fee × poolFeeShareBps / 10,000                  (default: 10%)
potShare = fee - poolShare                                    (default: 90%)
```

- `potShare` → added to the index fee pot
- `poolShare` → routed via `LibFeeRouter.routeManagedShare`

**Flash loan fees:**
```
poolShare = fee × poolFeeShareBps / 10,000                  (default: 10%)
potShare = fee - poolShare                                    (default: 90%)
```

Pool shares are further split by `LibFeeRouter` into treasury, active credit index, and fee index components.

### Fee Pot Growth

The fee pot is a per-index, per-asset accumulator. It grows from:
- Mint fees (portion not routed to pools)
- Burn fees (portion not routed to pools)
- Flash loan fees (portion not routed to pools)
- Fee pot buy-ins from new minters

The fee pot creates a compounding benefit for long-term holders: as fees accumulate, each unit's redemption value increases beyond the base bundle amount.

---

## Flash Loans

### Overview

Flash loans allow borrowing full basket units from an index within a single transaction. The borrower receives the underlying assets, executes arbitrary logic, and must return the assets plus fees before the transaction ends.

### Usage

```solidity
actionsFacet.flashLoan(indexId, units, receiverContract, data);
```

The receiver must implement:

```solidity
interface IEqualIndexFlashReceiver {
    function onEqualIndexFlashLoan(
        uint256 indexId,
        uint256 units,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata data
    ) external;
}
```

### Fee Calculation

Per constituent asset:
```
fee = loanAmount × flashFeeBps / 10,000
```

### Settlement

After the callback, the contract verifies that each asset's balance has increased by at least the fee amount:

```solidity
actualBalance >= balanceBefore + fee
```

Loan amounts are restored to vault balances. Fees are distributed via the standard fee split.

---

## EqualIndex Lending

### Overview

EqualIndex Lending allows position holders to borrow the underlying basket assets against their index token collateral. This creates a leverage primitive: hold index exposure while accessing the underlying liquidity.

Loans are zero-interest with a flat native-token fee, fixed-duration, and fully collateralized at 100% LTV. If a loan expires without repayment, anyone can trigger recovery — the collateral index tokens are burned and the outstanding principal is written off.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **100% LTV** | Borrow the full underlying basket value of collateral units |
| **Zero Interest** | No interest accrues; flat fee paid upfront in native token |
| **Fixed Duration** | Loans have a maturity timestamp; extendable before expiry |
| **Tiered Flat Fees** | Fee tiers based on collateral size (larger loans = different fee) |
| **Redeemability Invariant** | Non-locked units must always remain fully redeemable |
| **Collateral Recovery** | Expired loans: collateral burned, principal written off |
| **Module Encumbrance** | Collateral locked via `LibModuleEncumbrance` |

### Lending Configuration

```solidity
struct LendingConfig {
    uint16 ltvBps;          // Must be 10,000 (100%)
    uint40 minDuration;     // Minimum loan duration
    uint40 maxDuration;     // Maximum loan duration
}
```

Lending must be explicitly configured per index by governance before borrowing is available.

### Borrow Fee Tiers

```solidity
struct BorrowFeeTier {
    uint256 minCollateralUnits;     // Minimum collateral for this tier
    uint256 flatFeeNative;          // Flat fee in native token (ETH)
}
```

Tiers are ordered by ascending `minCollateralUnits`. The borrower pays the fee matching their collateral size. Collateral below the lowest tier is rejected.

### Borrowing

```solidity
uint256 loanId = lendingFacet.borrowFromPosition(positionId, indexId, collateralUnits, duration);
```

**Process:**
1. Validate ownership, collateral units (must be whole 1e18 multiples), and duration bounds
2. Collect flat native fee → treasury
3. Verify available collateral in the index pool position
4. Check redeemability invariant: `totalUnits - lockedCollateralUnits >= redeemableUnits` and per-asset vault balances remain sufficient for non-locked redemptions
5. Create loan record
6. Encumber collateral via `LibModuleEncumbrance` (lending module ID)
7. Update active credit index weight
8. Disburse underlying assets to borrower (proportional to bundle amounts × LTV)

### Redeemability Invariant

The critical safety check ensures that after a borrow, all non-locked index units can still be fully redeemed:

```solidity
uint256 redeemableUnits = totalUnits - lockedCollateralUnitsAfter;

// Per asset check:
uint256 requiredVaultAfter = redeemableUnits × bundleAmount / 1e18;
uint256 vaultAfter = vaultBalance - borrowedPrincipal;
require(vaultAfter >= requiredVaultAfter);
```

This prevents lending from making the index partially insolvent for non-borrowing holders.

### Repayment

```solidity
lendingFacet.repayFromPosition(positionId, loanId);
```

**Process:**
1. Verify position ownership and loan-position match
2. Calculate required repayment per asset (same formula as borrow: `bundleAmount × collateralUnits × ltvBps / 1e18 / 10,000`)
3. Pull assets from borrower (ERC-20 + native ETH)
4. Restore vault balances and reduce outstanding principal
5. Release collateral encumbrance and update active credit index
6. Delete loan record

### Loan Extension

```solidity
lendingFacet.extendFromPosition(positionId, loanId, addedDuration);
```

- Loan must not be expired
- New maturity must not exceed `block.timestamp + maxDuration`
- Flat fee is charged again for the extension

### Expired Loan Recovery

```solidity
lendingFacet.recoverExpiredIndexLoan(loanId);
```

Anyone can call this after loan maturity. The process:
1. Write off outstanding principal per asset (reduces `outstandingPrincipal`, does not restore vault)
2. Burn the collateral index tokens from the diamond
3. Reduce the position's index pool principal by the collateral amount
4. Release module encumbrance and update active credit index
5. Notify EDEN Rewards Engine of the balance change
6. Delete loan record

**Economic effect:** The borrower keeps the borrowed assets. The index absorbs the loss — remaining holders' units now represent a slightly larger share of the remaining vault. The collateral burn reduces total supply proportionally.

### Loan Data

```solidity
struct IndexLoan {
    bytes32 positionKey;        // Borrower's position key
    uint256 indexId;            // Index the loan is against
    uint256 collateralUnits;    // Locked index token units
    uint16 ltvBps;              // LTV at origination (always 10,000)
    uint40 maturity;            // Loan expiry timestamp
}
```

---

## EDEN Rewards Engine (Overview)

> A dedicated design document for the EDEN Rewards Engine will follow. This section provides a brief overview of its integration with EqualIndex.

### What It Is

The EDEN Rewards Engine is a configurable, multi-program reward distribution system built into the EqualFi protocol substrate. It allows governance to create reward programs that distribute tokens to eligible participants based on their position balances in specific targets.

### How It Integrates with EqualIndex

Position-mode index token holders are eligible for EDEN rewards. The integration works through `LibEqualIndexRewards`:

1. **Before any balance change** (mint or burn from position), the rewards engine is notified via `beforeTargetBalanceChange`, which settles any pending rewards for the position
2. **After the balance change**, `afterTargetBalanceChange` is called to update the eligible supply for the reward target

### Reward Targets

Each index has a reward target:

```solidity
RewardTarget({
    targetType: RewardTargetType.EQUAL_INDEX_POSITION,
    targetId: indexId
})
```

Governance can create reward programs targeting specific indexes, distributing any ERC-20 token at a configurable rate per second to position holders proportional to their index pool principal.

### Key Properties

| Property | Description |
|----------|-------------|
| **Target type** | `EQUAL_INDEX_POSITION` for index holders |
| **Eligible balance** | Position's index pool principal (index tokens held via position) |
| **Distribution** | Pro-rata by eligible balance, continuous accrual |
| **Settlement** | Automatic before any balance-changing operation |
| **Reward tokens** | Any ERC-20, configured per program |
| **Rate** | `rewardRatePerSecond`, configurable by program manager |

> Wallet-mode index token holders do not participate in EDEN rewards — only position-mode holders are eligible.

---

## Data Models

### Index

```solidity
struct Index {
    address[] assets;           // Constituent asset addresses
    uint256[] bundleAmounts;    // Amount per asset per 1e18 units
    uint16[] mintFeeBps;        // Mint fee per asset (basis points)
    uint16[] burnFeeBps;        // Burn fee per asset (basis points)
    uint16 flashFeeBps;         // Flash loan fee (basis points)
    uint256 totalUnits;         // Total index tokens in circulation
    address token;              // IndexToken contract address
    bool paused;                // Pause flag
}
```

### Index Storage

```solidity
struct EqualIndexStorage {
    uint256 indexCount;                                         // Total indexes created
    mapping(uint256 => Index) indexes;                          // Index ID → index data
    mapping(uint256 => mapping(address => uint256)) vaultBalances;  // Index × asset → vault balance
    mapping(uint256 => mapping(address => uint256)) feePots;    // Index × asset → fee pot balance
    mapping(uint256 => uint256) indexToPoolId;                  // Index ID → pool ID
    uint16 poolFeeShareBps;                                     // Pool share of flash/position fees (default: 10%)
    uint16 mintBurnFeeIndexShareBps;                            // Index share of wallet mint/burn fees (default: 40%)
}
```

### Lending Storage

```solidity
struct LendingStorage {
    mapping(uint256 => IndexLoan) loans;                        // Loan ID → loan data
    uint256 nextLoanId;                                         // Monotonic loan ID counter
    mapping(uint256 => mapping(address => uint256)) outstandingPrincipal;  // Index × asset → lent principal
    mapping(uint256 => uint256) lockedCollateralUnits;          // Index → locked collateral units
    mapping(uint256 => LendingConfig) lendingConfigs;           // Index → lending configuration
    mapping(uint256 => BorrowFeeTier[]) borrowFeeTiers;         // Index → fee tier schedule
}
```

### Index Creation Parameters

```solidity
struct CreateIndexParams {
    string name;                // Token name
    string symbol;              // Token symbol
    address[] assets;           // Constituent assets (must have existing pools)
    uint256[] bundleAmounts;    // Amount per asset per unit
    uint16[] mintFeeBps;        // Mint fee per asset (max 1000 = 10%)
    uint16[] burnFeeBps;        // Burn fee per asset (max 1000 = 10%)
    uint16 flashFeeBps;         // Flash loan fee (max 1000 = 10%)
}
```

---

## View Functions

### Index Queries

```solidity
// Get full index state
function getIndex(uint256 indexId) external view returns (IndexView memory);

// Get vault balance for a specific asset
function getVaultBalance(uint256 indexId, address asset) external view returns (uint256);

// Get fee pot balance for a specific asset
function getFeePot(uint256 indexId, address asset) external view returns (uint256);

// Get the pool ID associated with an index
function getIndexPoolId(uint256 indexId) external view returns (uint256);
```

### Lending Queries

```solidity
// Get loan details
function getLoan(uint256 loanId) external view returns (IndexLoan memory);

// Get outstanding principal for an asset in an index
function getOutstandingPrincipal(uint256 indexId, address asset) external view returns (uint256);

// Get total locked collateral units for an index
function getLockedCollateralUnits(uint256 indexId) external view returns (uint256);

// Get lending configuration
function getLendingConfig(uint256 indexId) external view returns (LendingConfig memory);

// Get economic balance (vault + outstanding)
function economicBalance(uint256 indexId, address asset) external view returns (uint256);

// Get maximum borrowable amount for an asset given collateral
function maxBorrowable(uint256 indexId, address asset, uint256 collateralUnits) external view returns (uint256);

// Quote the full borrow basket for given collateral
function quoteBorrowBasket(uint256 indexId, uint256 collateralUnits)
    external view returns (address[] memory assets, uint256[] memory principals);

// Quote the flat borrow fee
function quoteBorrowFee(uint256 indexId, uint256 collateralUnits) external view returns (uint256);

// Get borrow fee tier schedule
function getBorrowFeeTiers(uint256 indexId)
    external view returns (uint256[] memory minCollateralUnits, uint256[] memory flatFeeNative);

// Get the lending module encumbrance ID
function lendingModuleId() external pure returns (uint256);
```

### Index Token Queries

```solidity
// Standard ERC-20 queries (balanceOf, totalSupply, allowance, etc.)

// Bundle introspection
function assets() external view returns (address[] memory);
function bundleAmounts() external view returns (uint256[] memory);
function bundleCount() external view returns (uint256);
function bundleHash() external view returns (bytes32);
function flashFeeBps() external view returns (uint256);
function totalMintFeesCollected() external view returns (uint256);
function totalBurnFeesCollected() external view returns (uint256);
```

---

## Integration Guide

### For Index Creators

#### Governance Path (Free)

```solidity
EqualIndexBaseV3.CreateIndexParams memory params = CreateIndexParams({
    name: "EDEN LST Index",
    symbol: "iLST",
    assets: [stETH, rETH, cbETH],
    bundleAmounts: [1e18, 1e18, 1e18],     // 1 of each per unit
    mintFeeBps: [50, 50, 50],               // 0.5% mint fee per asset
    burnFeeBps: [50, 50, 50],               // 0.5% burn fee per asset
    flashFeeBps: 30                          // 0.3% flash loan fee
});

(uint256 indexId, address token) = adminFacet.createIndex(params);
```

#### Permissionless Path (Fee Required)

```solidity
(uint256 indexId, address token) = adminFacet.createIndex{value: creationFee}(params);
```

Requirements:
- All constituent assets must have existing EqualFi pools
- No duplicate assets in the bundle
- All bundle amounts must be non-zero
- Fee rates capped at 10% (1000 bps)

### For Wallet-Mode Users

#### Minting

```solidity
// Approve each constituent asset
IERC20(stETH).approve(diamond, type(uint256).max);
IERC20(rETH).approve(diamond, type(uint256).max);

// Mint 5 units with slippage protection
uint256[] memory maxInputs = new uint256[](3);
maxInputs[0] = 5.1e18;  // stETH max
maxInputs[1] = 5.1e18;  // rETH max
maxInputs[2] = 5.1e18;  // cbETH max

uint256 minted = actionsFacet.mint(indexId, 5e18, msg.sender, maxInputs);
```

#### Burning

```solidity
// Approve index token
IERC20(indexToken).approve(diamond, 5e18);

// Burn 5 units
uint256[] memory assetsOut = actionsFacet.burn(indexId, 5e18, msg.sender);
```

### For Position-Mode Users

#### Minting from Position

```solidity
// Position must have pool membership and sufficient principal in each asset's pool
uint256 minted = positionFacet.mintFromPosition(positionId, indexId, 5e18);
// Index tokens credited to position's index pool principal
// EDEN rewards begin accruing
```

#### Burning from Position

```solidity
uint256[] memory assetsOut = positionFacet.burnFromPosition(positionId, indexId, 5e18);
// Underlying assets returned to position's pool principals
// EDEN rewards updated
```

### For Borrowers

#### Borrowing Against Index Collateral

```solidity
// Quote the fee first
uint256 fee = lendingFacet.quoteBorrowFee(indexId, 10e18);

// Borrow with 30-day duration
uint256 loanId = lendingFacet.borrowFromPosition{value: fee}(
    positionId,
    indexId,
    10e18,          // 10 index units as collateral
    30 days         // duration
);
```

#### Repaying

```solidity
// Quote repayment basket
(address[] memory assets, uint256[] memory principals) =
    lendingFacet.quoteBorrowBasket(indexId, 10e18);

// Approve each asset and send native ETH for native components
lendingFacet.repayFromPosition{value: nativeAmount}(positionId, loanId);
```

#### Extending

```solidity
uint256 fee = lendingFacet.quoteBorrowFee(indexId, 10e18);
lendingFacet.extendFromPosition{value: fee}(positionId, loanId, 15 days);
```

### For Enforcers

```solidity
// Recover expired loan (anyone can call)
lendingFacet.recoverExpiredIndexLoan(loanId);
```

---

## Worked Examples

### Example 1: Basic Mint and Burn

**Scenario:** Alice mints 10 units of an index with 2 assets (stETH, USDC). No prior supply.

**Index Definition:**
```
Bundle: 1 stETH (1e18) + 1000 USDC (1000e6) per unit
Mint fee: 1% per asset
Burn fee: 1% per asset
```

**Mint (first mint, no fee pot):**
```
Per unit: 1 stETH + 1000 USDC
10 units vault input:
  stETH: 10e18
  USDC:  10,000e6

Fees (1% of gross):
  stETH fee: 0.1e18
  USDC fee:  100e6

Total pulled from Alice:
  stETH: 10.1e18
  USDC:  10,100e6

After mint:
  totalUnits: 10e18
  vaultBalances[stETH]: 10e18
  vaultBalances[USDC]: 10,000e6
  feePots[stETH]: ~0.06e18 (60% to pot at default wallet split)
  feePots[USDC]: ~60e6
  Pool receives: ~0.04e18 stETH, ~40e6 USDC (routed via LibFeeRouter)
```

**Burn (10 units, with fee pot):**
```
Bundle output:
  stETH: 10e18
  USDC:  10,000e6

Fee pot share (100% of pot for 10/10 units):
  stETH: ~0.06e18
  USDC:  ~60e6

Gross output:
  stETH: ~10.06e18
  USDC:  ~10,060e6

Burn fee (1% of gross):
  stETH: ~0.1006e18
  USDC:  ~100.6e6

Payout to Alice:
  stETH: ~9.96e18
  USDC:  ~9,959.4e6
```

### Example 2: Fee Pot Accumulation Benefit

**Scenario:** Bob mints early, Carol mints later after fees accumulate, both burn.

**Step 1: Bob mints 100 units (first minter)**
```
vaultBalances[stETH]: 100e18
feePots[stETH]: 0.6e18 (from Bob's mint fees, 60% to pot)
totalUnits: 100e18
```

**Step 2: External flash loans generate 5 stETH in fees**
```
feePots[stETH]: 0.6 + 4.5 = 5.1e18 (90% of flash fees to pot)
Pool receives: 0.5e18 (10% pool share)
```

**Step 3: Carol mints 100 units**
```
Vault input: economicBalance × 100 / 200 = 100 × 100 / 200 = 50e18
  (Wait — totalSupply is 100, so Carol mints 100 more)
  vaultIn = 100e18 × 100e18 / 100e18 = 100e18

Fee pot buy-in: 5.1e18 × 100e18 / 100e18 = 5.1e18
  Carol pays 5.1e18 stETH to buy into the pot

Mint fee: (100 + 5.1) × 1% = 1.051e18

After Carol's mint:
  totalUnits: 200e18
  vaultBalances[stETH]: 200e18
  feePots[stETH]: 5.1 + 5.1 + 0.63 = 10.83e18
```

**Step 4: Bob burns 100 units**
```
Bundle out: 100e18
Pot share: 10.83 × 100/200 = 5.415e18
Gross: 105.415e18
Fee: 1.054e18
Payout: ~104.36e18

Bob deposited ~100.6e18 total, receives ~104.36e18
Net gain: ~3.76 stETH (from flash loan fees accumulated)
```

### Example 3: Index Lending Lifecycle

**Scenario:** Dave borrows against 5 index units for 30 days.

**Index:**
```
Bundle: 1 ETH + 2000 USDC per unit
LTV: 100%
Fee tier: 5+ units → 0.01 ETH flat fee
```

**Borrow:**
```
Collateral: 5e18 index units
Flat fee: 0.01 ETH → treasury

Borrowed basket (100% LTV):
  ETH:  5 × 1 = 5e18
  USDC: 5 × 2000 = 10,000e6

After borrow:
  vaultBalances[ETH]: reduced by 5e18
  vaultBalances[USDC]: reduced by 10,000e6
  outstandingPrincipal[ETH]: 5e18
  outstandingPrincipal[USDC]: 10,000e6
  lockedCollateralUnits: 5e18
  Dave's position: 5e18 encumbered via LENDING_MODULE_ID
```

**Repay (Day 25):**
```
Dave returns: 5 ETH + 10,000 USDC (exact amounts, zero interest)
Vault balances restored
Outstanding principal cleared
Collateral encumbrance released
Loan deleted
```

### Example 4: Expired Loan Recovery

**Scenario:** Eve's loan expires without repayment.

**State at expiry:**
```
Loan: 3e18 collateral units
Outstanding: 3 ETH + 6,000 USDC
totalUnits: 100e18
```

**Recovery:**
```
recoverExpiredIndexLoan(loanId):

1. Write off outstanding principal:
   outstandingPrincipal[ETH] -= 3e18
   outstandingPrincipal[USDC] -= 6,000e6

2. Burn collateral:
   IndexToken.burn(diamond, 3e18)
   totalUnits: 97e18

3. Reduce Eve's index pool principal by 3e18

4. Release encumbrance

Economic effect:
  - Eve keeps 3 ETH + 6,000 USDC (borrowed assets)
  - Eve loses 3e18 index tokens (collateral)
  - Remaining 97 units now backed by same vault (minus written-off amounts)
  - economicBalance drops, but so does totalSupply → per-unit value preserved
```

---

## Error Reference

### Index Errors

| Error | Cause |
|-------|-------|
| `UnknownIndex(uint256)` | Index ID does not exist |
| `IndexPaused(uint256)` | Index is paused |
| `InvalidUnits()` | Units are zero or not a multiple of 1e18 |
| `InvalidBundleDefinition()` | Zero bundle amount or duplicate assets |
| `InvalidArrayLength()` | Array length mismatch in parameters |
| `NoPoolForAsset(address)` | Constituent asset has no EqualFi pool |
| `InvalidMinter()` | Zero address passed as minter |
| `NotMinter()` | Caller is not the authorized minter (diamond) |

### Fee Errors

| Error | Cause |
|-------|-------|
| `InvalidParameterRange(string)` | Fee exceeds 10% cap or invalid configuration |
| `InsufficientIndexCreationFee(uint256, uint256)` | Incorrect creation fee amount |
| `IndexCreationFeeTransferFailed()` | Fee transfer to treasury failed |
| `TreasuryNotSet()` | Protocol treasury not configured |

### Flash Loan Errors

| Error | Cause |
|-------|-------|
| `FlashLoanUnderpaid(uint256, address, uint256, uint256)` | Receiver did not return sufficient assets + fee |
| `InsufficientPoolLiquidity(uint256, uint256)` | Vault lacks sufficient balance for loan |

### Position Errors

| Error | Cause |
|-------|-------|
| `InsufficientUnencumberedPrincipal(uint256, uint256)` | Position lacks sufficient available principal |
| `NotMemberOfRequiredPool(bytes32, uint256)` | Position not a member of required asset pool |
| `InsufficientIndexTokens(uint256, uint256)` | Position holds fewer index tokens than burn request |
| `InsufficientPrincipal(uint256, uint256)` | Insufficient principal for deduction |
| `DepositCapExceeded(uint256, uint256)` | Index pool deposit cap exceeded |
| `MaxUserCountExceeded(uint256)` | Index pool user limit reached |

### Lending Errors

| Error | Cause |
|-------|-------|
| `LendingNotConfigured(uint256)` | Lending not enabled for this index |
| `LoanNotFound(uint256)` | Loan ID does not exist |
| `LoanNotExpired(uint256, uint40)` | Recovery attempted before maturity |
| `LoanExpired(uint256, uint40)` | Extension attempted after maturity |
| `RedeemabilityViolation(address, uint256, uint256)` | Borrow would make non-locked units unredeemable |
| `InvalidDuration(uint40, uint40, uint40)` | Duration outside configured min/max |
| `MaxDurationExceeded(uint40, uint40)` | Extension would exceed max duration from now |
| `PositionMismatch(bytes32, bytes32)` | Caller's position doesn't match loan's position |
| `InvalidAsset(address)` | Asset not in index bundle |
| `FlatFeePaymentMismatch(uint256, uint256)` | Incorrect native fee amount sent |
| `FlatFeeTreasuryNotSet()` | Treasury not configured for fee collection |

---

## Events

### Index Lifecycle Events

```solidity
event IndexCreated(
    uint256 indexed indexId,
    address token,
    address[] assets,
    uint256[] bundleAmounts,
    uint16 flashFeeBps
);

event IndexPauseUpdated(uint256 indexed indexId, bool paused);
```

### Index Token Events

```solidity
// Emitted by IndexToken on mint
event MintDetails(
    address indexed user,
    uint256 units,
    address[] assets,
    uint256[] assetAmounts,
    uint256[] feeAmounts
);

// Emitted by IndexToken on burn
event BurnDetails(
    address indexed user,
    uint256 units,
    address[] assets,
    uint256[] assetAmounts,
    uint256[] feeAmounts
);
```

### Flash Loan Events

```solidity
event FlashLoaned(
    uint256 indexed indexId,
    address indexed receiver,
    uint256 units,
    uint256[] loanAmounts,
    uint256[] fees
);
```

### Lending Events

```solidity
event LoanCreated(
    uint256 indexed loanId,
    bytes32 indexed positionKey,
    uint256 indexed indexId,
    uint256 collateralUnits,
    uint16 ltvBps,
    uint40 maturity
);

event LoanAssetDelta(
    uint256 indexed loanId,
    address indexed borrowAsset,
    uint256 principal,
    uint256 fee,
    bool outgoing             // true = disbursement, false = repayment/write-off
);

event LoanRepaid(uint256 indexed loanId, uint256 indexed indexId);

event LoanExtended(uint256 indexed loanId, uint40 newMaturity, uint256 totalFee);

event LoanRecovered(
    uint256 indexed loanId,
    uint256 indexed indexId,
    uint256 collateralUnits,
    uint256 writtenOffPrincipalTotal
);

event LendingConfigured(
    uint256 indexed indexId,
    uint16 ltvBps,
    uint40 minDuration,
    uint40 maxDuration
);

event BorrowFeeTiersConfigured(
    uint256 indexed indexId,
    uint256[] minCollateralUnits,
    uint256[] flatFeeNative
);

event BorrowFlatFeePaid(
    uint256 indexed loanId,
    uint256 indexed indexId,
    uint256 collateralUnits,
    uint256 feeNative
);

event LoanExtendFlatFeePaid(
    uint256 indexed loanId,
    uint256 indexed indexId,
    uint256 collateralUnits,
    uint40 addedDuration,
    uint256 feeNative
);
```

---

## Security Considerations

### 1. Fixed Bundle Composition

Index bundle definitions (assets and amounts) are immutable after creation:
- Stored in both the `Index` struct and the `IndexToken` contract
- `bundleHash` provides a verifiable fingerprint
- No rebalancing, no governance override of composition

### 2. Fee Caps

All fee rates are capped at 10% (1000 bps) at creation time:
```solidity
if (mintFeeBps[i] > 1000) revert InvalidParameterRange("mintFeeBps too high");
if (burnFeeBps[i] > 1000) revert InvalidParameterRange("burnFeeBps too high");
if (flashFeeBps > 1000) revert InvalidParameterRange("flashFeeBps too high");
```

### 3. Reentrancy Protection

All state-changing functions use `nonReentrant` modifier. This is critical because:
- Mint/burn involve external ERC-20 transfers
- Flash loans execute arbitrary external code
- Position operations interact with multiple pool contracts

### 4. Redeemability Invariant (Lending)

The most critical safety property in EqualIndex Lending. Before any borrow:

```solidity
// Total units that must remain redeemable
uint256 redeemableUnits = totalUnits - lockedCollateralUnitsAfter;

// Per-asset vault must cover full redemption of non-locked units
uint256 requiredVaultAfter = redeemableUnits × bundleAmount / 1e18;
require(vaultAfter >= requiredVaultAfter);
```

This ensures that non-borrowing holders can always redeem their index tokens at full bundle value, regardless of how much lending is outstanding.

### 5. Economic Balance Pricing

Mint pricing uses economic balance (vault + outstanding) rather than vault balance alone:

```solidity
economicBalance = vaultBalance + outstandingPrincipal
vaultIn = economicBalance × units / totalSupply
```

This prevents new minters from getting a discount when assets are lent out, and prevents existing holders from being diluted.

### 6. Flash Loan Settlement

Flash loan repayment is verified by comparing contract balances before and after:

```solidity
uint256 expectedBalance = balanceBefore + fee;
uint256 actualBalance = LibCurrency.balanceOfSelf(asset);
require(actualBalance >= expectedBalance);
```

Vault balances are restored atomically. Any shortfall reverts the entire transaction.

### 7. Collateral Recovery (Lending)

Expired loan recovery is permissionless and deterministic:
- Outstanding principal is written off (vault does not recover the assets)
- Collateral index tokens are burned (reducing total supply)
- The burn proportionally increases remaining holders' per-unit claim
- No oracle, no auction, no liquidation cascade

### 8. Asset Pool Requirement

Every constituent asset must have an existing EqualFi pool:

```solidity
if (LibAppStorage.s().assetToPoolId[p.assets[i]] == 0) {
    revert NoPoolForAsset(p.assets[i]);
}
```

This ensures fee routing, position operations, and lending all have the required pool infrastructure.

### 9. Whole Unit Enforcement

All operations require whole units (multiples of 1e18):

```solidity
if (units == 0 || units % INDEX_SCALE != 0) revert InvalidUnits();
```

This prevents dust attacks and ensures clean bundle arithmetic.

### 10. No Duplicate Assets

Index creation rejects duplicate constituent assets:

```solidity
for (uint256 j = i + 1; j < p.assets.length; j++) {
    if (p.assets[i] == p.assets[j]) revert InvalidBundleDefinition();
}
```

### 11. Position Encumbrance Isolation

Position-mode operations use `LibIndexEncumbrance` to track per-index, per-pool encumbrance separately from other encumbrance types (direct lending, module encumbrance). This prevents cross-feature interference.

### 12. Lending Module Encumbrance

Index lending uses a dedicated module ID for collateral locking:

```solidity
uint256 internal constant LENDING_MODULE_ID = uint256(keccak256("equal.index.lending.module"));
```

This isolates lending encumbrance from index encumbrance and other module encumbrances.

---

## Appendix: Correctness Properties

### Property 1: Bundle Conservation
For any index with no outstanding loans:
```
vaultBalances[asset] ≥ totalUnits × bundleAmount / 1e18
```

### Property 2: Economic Balance Conservation
For any index:
```
economicBalance[asset] = vaultBalances[asset] + outstandingPrincipal[asset]
economicBalance[asset] ≥ totalUnits × bundleAmount / 1e18
```

### Property 3: Fee Pot Monotonicity (Between Burns)
Between burn operations, fee pots only increase:
```
feePots[asset]_new ≥ feePots[asset]_old  (absent burns)
```

### Property 4: Redeemability Invariant
For any index with lending:
```
redeemableUnits = totalUnits - lockedCollateralUnits
∀ asset: vaultBalances[asset] ≥ redeemableUnits × bundleAmount / 1e18
```

### Property 5: Collateral Lock Conservation
```
lockedCollateralUnits = Σ(loan.collateralUnits) for all active loans
lockedCollateralUnits ≤ totalUnits
```

### Property 6: Mint/Burn Supply Consistency
```
After mint:  totalUnits_new = totalUnits_old + mintedUnits
After burn:  totalUnits_new = totalUnits_old - burnedUnits
IndexToken.totalSupply() == Index.totalUnits
```

### Property 7: Fee Pot Buy-In Fairness
New minters pay proportional fee pot buy-in:
```
potBuyIn = feePot × units / totalSupply
```
This ensures no dilution of existing holders' fee pot claims.

### Property 8: Flash Loan Atomicity
For any flash loan:
```
∀ asset: contractBalance_after ≥ contractBalance_before + fee
vaultBalances restored to pre-loan values
```

### Property 9: Lending LTV Constraint
```
∀ loan: ltvBps == 10,000 (100%)
borrowedPrincipal[asset] = collateralUnits × bundleAmount × ltvBps / (1e18 × 10,000)
```

### Property 10: Recovery Neutrality
After expired loan recovery:
```
totalUnits_new = totalUnits_old - loan.collateralUnits
outstandingPrincipal[asset] reduced by loan principals
Per-unit vault claim preserved for remaining holders
```

### Property 11: Position Balance Consistency
For position-mode operations:
```
indexPool.userPrincipal[positionKey] = index tokens held via position
indexPool.totalDeposits = Σ(userPrincipal) for all positions
```

### Property 12: EDEN Rewards Settlement
Before any position balance change:
```
settleBeforeEligibleBalanceChange() called → pending rewards settled
afterTargetBalanceChange() called → eligible supply updated
```

---

**Document Version:** 1.0
**Module:** EqualIndex V3 & EqualIndex Lending — EqualFi Index Token Platform