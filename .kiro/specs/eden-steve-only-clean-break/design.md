# Design Document

## Overview

This design rewrites EDEN into a singleton product surface.

The core rule is simple:

- **EqualFi** owns substrate primitives
- **EqualIndex** owns generic baskets / indexes
- **EDEN** owns one product: `stEVE`

That means EDEN must stop carrying any public or internal shape that implies:

- arbitrary basket creation
- arbitrary basket mint / burn
- basket catalogs
- basket-parameterized admin
- basket-parameterized lending
- registry-shaped basket storage

This is a clean break. Nothing is live. There is no migration-compatibility layer.

The target state is explicitly:

- **EqualFi substrate** as the shared protocol base
- **EqualIndex** as the generic basket / index layer
- **EDEN** as a singleton product centered on `stEVE`

EDEN is therefore a product lane, not a generic issuance lane. Legacy EDEN file
names may still contain "basket" while the refactor is in flight, but the target
architecture must not preserve basket-registry behavior, `basketId`-driven public
interfaces, or any EDEN-side multi-product catalog.

## Non-Goals

This rewrite does not:

- redesign EqualIndex
- redesign EqualFi substrate
- redesign flash loans
- preserve EDEN generic-basket compatibility surfaces
- add migration shims for the old EDEN shape

## Target Architecture

### Layering

1. **EqualFi substrate**
   - pools
   - Position NFTs
   - `positionKey`
   - encumbrance
   - fee routing
   - FI / ACI
   - governance
   - pool flash loans

2. **EqualIndex**
   - generic basket / index construction
   - wallet-mode index mint / burn
   - position-mode index mint / burn
   - index flash loans

3. **EDEN**
   - singleton product token: `stEVE`
   - EDEN-specific `EVE` reward accounting
   - EDEN-specific lending against the canonical EDEN product
   - EDEN-specific views/admin for the singleton product

### Boundary Rules

1. **EqualFi substrate owns substrate primitives**
   - EDEN reuses Position NFT, `positionKey`, principal, encumbrance, and fee-routing patterns already present in the substrate.
   - EDEN does not introduce a second accounting system for PNFT-owned `stEVE`.
   - pool flash loans remain in the substrate layer

2. **EqualIndex owns generic structured exposure**
   - generic basket/index construction stays in EqualIndex
   - wallet-mode generic mint / burn stays in EqualIndex
   - position-mode generic mint / burn stays in EqualIndex
   - index flash loans stay in EqualIndex

3. **EDEN owns only the singleton product**
   - the canonical EDEN product is `stEVE`
   - rewards mean `EVE` emissions for PNFT-held `stEVE`
   - lending means lending against the canonical EDEN product only
   - EDEN does not expose arbitrary product creation, arbitrary `basketId` routing, or registry/catalog views

## Design Decisions

### 1. Delete Duplicate Legacy EDEN Facets

`EdenBasketFacet.sol` and `EdenStEVEFacet.sol` are duplicate drift surfaces.
They should be deleted instead of harmonized.

### 2. Rewrite Storage First-Class as Singleton Product Storage

The old EDEN storage is basket-registry-shaped. That shape is itself part of the problem.

The rewrite should replace registry storage with explicit singleton product state.
There is no target-state EDEN registry, no EDEN catalog, and no EDEN-side
token-to-product discovery map for arbitrary products.

Representative target shape:

```solidity
struct EdenProductConfig {
    string name;
    string symbol;
    string uri;
    bool paused;
    uint256 poolId;
    address token;
    address rewardToken;
    uint16[] mintFeeBps;
    uint16[] burnFeeBps;
    uint16 flashFeeBps;
}

struct EdenProductAccounting {
    mapping(address => uint256) vaultBalances;
    mapping(address => uint256) feePots;
}

struct EdenStorage {
    EdenProductConfig product;
    EdenProductAccounting accounting;
    uint16 poolFeeShareBps;
}
```

Exact field names may differ, but the shape must be singleton.
Storage must read like one product with one reward path and one lending path,
not like a generic protocol awaiting more EDEN baskets.

### 3. Wallet Flow Is stEVE-Only

EDEN wallet mode should expose only the canonical `stEVE` product.

Allowed:
- wallet-mode `stEVE` mint
- wallet-mode `stEVE` burn

Disallowed:
- generic basket creation
- generic basket mint / burn

### 4. Position Flow Is stEVE-Only

EDEN position mode should expose only PNFT-mode `stEVE` flows.

Allowed:
- deposit `stEVE` into a Position NFT
- withdraw `stEVE` from a Position NFT
- position-owned reward accounting for `stEVE`

Disallowed:
- generic position-mode basket mint / burn in EDEN

### 5. Views Must Be Product Views, Not Catalog Views

Delete the idea that EDEN has a basket registry UI/API.

Views should answer questions like:
- what is the canonical EDEN product token?
- what pool backs it?
- what are the fees?
- is the product paused?
- what is a position’s eligible `stEVE` principal?
- what rewards has a position accrued?

Views should not answer questions like:
- how many EDEN baskets exist?
- what are all basket IDs?
- what baskets belong to a user?
- what arbitrary `basketId` is configured for lending or admin state

### 6. Admin Must Configure the Product, Not Basket IDs

Admin methods should be about the EDEN product itself.

Examples:
- set product metadata
- set product pause state
- set product fee config
- set reward token / reward rate if applicable

No arbitrary `basketId` config writes.
No EDEN-side registry maintenance.
No EDEN-side catalog lifecycle.

### 7. Lending Must Be Product Lending

EDEN lending should be explicitly tied to the canonical EDEN product.

Public APIs should not accept `basketId`.
Target-state lending views and config are product-scoped, not catalog-scoped.

Lending config and accounting should be singleton-product state.

The lending logic may preserve useful internal behavior such as:
- repay
- extend
- expired recovery
- redeemability checks

But only insofar as that behavior applies to the singleton EDEN product.

### 8. Reward Semantics Must Stay Narrow

The reward rule is:

- only PNFT-held `stEVE` earns `EVE`
- wallet-held `stEVE` does not
- rewards accrue to the position

The system must not imply that EDEN can later “just” support arbitrary reward-bearing basket products by default.

### 9. Keep Canonical Non-EDEN Capability Out of EDEN

Pool flash loans remain in substrate.
Index flash loans remain in EqualIndex.
Generic structured exposure remains in EqualIndex.

EDEN gets smaller. Other canonical layers remain intact.

## File-Level Refactor Plan

### Delete
- `src/eden/EdenBasketFacet.sol`
- `src/eden/EdenStEVEFacet.sol`
- `src/eden/EdenBasketDataFacet.sol`

### Rewrite Heavily
- `src/libraries/LibEdenBasketStorage.sol`
- `src/eden/EdenBasketWalletFacet.sol`
- `src/eden/EdenBasketPositionFacet.sol`
- `src/eden/EdenViewFacet.sol`
- `src/eden/EdenAdminFacet.sol`
- `src/libraries/LibEdenLendingStorage.sol`
- `src/eden/EdenLendingFacet.sol`
- `src/eden/EdenBasketLogic.sol`
- `script/DeployEdenByEqualFi.s.sol`
- `test/DeployEdenByEqualFi.t.sol`

### Audit / Tighten
- `src/eden/EdenRewardFacet.sol`
- `src/eden/EdenStEVEActionFacet.sol`
- tests around wallet-mode and PNFT-mode `stEVE`

These file paths describe the current codebase, not the target public shape.
If legacy names survive temporarily during the refactor, the exposed architecture
must still resolve to EqualFi substrate + EqualIndex generic layer + singleton EDEN product.

## Validation Strategy

The rewrite is done only when tests prove:

- EDEN generic basket behavior is gone
- `stEVE` wallet flows still work
- `stEVE` PNFT flows still work
- PNFT-held `stEVE` alone earns `EVE`
- EDEN lending is singleton-product lending
- EqualIndex generic basket/index behavior still works
- substrate / index flash loans still work
- deployment wiring matches the new boundary
