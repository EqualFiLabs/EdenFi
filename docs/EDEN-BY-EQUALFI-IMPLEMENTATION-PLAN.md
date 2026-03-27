# EDEN by EqualFi Implementation Plan

This document replaces the earlier assumption that EDEN should rebuild large
parts of its own accounting stack on top of the extracted substrate.

The new direction is:

- **EqualFi substrate stays canonical**
- **EqualIndex stays canonical**
- **EDEN is a product layer built on top**
- **stEVE yield is a dedicated EDEN reward system**
- **yield only applies to stEVE held inside Position NFTs**

In short:

- wallet users can still mint and burn
- Position NFT users get the richer accounting domain
- only Position NFT-held stEVE earns EDEN `EVE` emissions

## Core Decisions

### 1. EqualFi/EqualIndex Stay Intact

We should not invent a second pool/fee-index/encumbrance system for EDEN.

EDEN by EqualFi should reuse:

- pools
- pool membership
- Position NFTs
- encumbrance
- fee routing
- FI / ACI
- timelock / governance substrate

EDEN should add:

- basket product semantics
- stEVE token and product behavior
- EDEN-specific lending rules
- EDEN-specific views
- an EDEN `EVE` reward facet

### 2. EDEN Supports EOAs and Position NFTs

Like EqualIndex:

- EOAs can hold and use basket tokens and stEVE directly
- Position NFTs can also hold product balances through substrate principal

This gives two user modes:

- **wallet mode**: simpler spot ownership, no indexed EDEN yield
- **position mode**: richer accounting, composability, reward eligibility

### 3. Only Position-Held stEVE Earns EVE Yield

The EDEN emission base is not all stEVE in circulation.

It is only:

- stEVE deposited into a Position NFT
- tracked as position-owned principal in the stEVE/index pool domain

This aligns with EqualIndex:

- wallet balances remain simple balances
- Position NFT balances become economic principal

### 4. EDEN Rewards Use a Reward Index, Not TWAB

We still want the same product semantics:

- `X EVE per day`
- split pro rata among eligible stEVE holders

But implementation should use a cumulative reward index over Position NFT-held
stEVE principal, not a TWAB epoch system.

That means:

- rewards accrue continuously over time
- positions earn based on principal * time
- claims settle on interaction
- no epoch scanning is needed

### 5. Protocol Fee Routing and EDEN Emissions Stay Separate

Do not collapse these into one system.

- protocol fee routing remains a substrate / EqualIndex concern
- EDEN `EVE` emissions are a separate reward concern

This avoids mixing:

- fee revenue
- treasury routing
- unsupported fee assets
- EDEN token emissions

Unsupported fee-asset handling can be added later, but it should not distort the
core EDEN reward model.

## Target Architecture

### EqualFi Substrate Layer

Canonical primitives:

- `PositionNFT`
- `LibPositionHelpers`
- pool storage / pool membership
- `LibEncumbrance`
- `LibFeeRouter`
- `LibFeeIndex`
- `LibActiveCreditIndex`
- governance / diamond / timelock

### EqualIndex Layer

Canonical product/accounting layer:

- index mint/burn from wallet
- index mint/burn from position
- pool-backed fee routing
- position-owned principal accounting
- FI / ACI settlement

### EDEN by EqualFi Layer

EDEN-specific product layer:

- basket creation / metadata
- basket tokenization
- stEVE token behavior
- EDEN lending rules
- EDEN views / agent helpers
- EDEN `EVE` reward facet for PNFT-held stEVE

## Reward Model

### Economic Rule

Every day, the system emits a configured amount of `EVE`.

That daily emission is split pro rata among:

- all Position NFTs that currently hold eligible stEVE principal

Wallet-held stEVE does not participate.

### Accounting Model

Use:

- `rewardRatePerSecond`
- `globalRewardIndex`
- `lastRewardUpdate`
- `eligibleSupply`
- `positionRewardIndex[positionKey]`
- `accruedRewards[positionKey]`

Settlement rule:

1. Update the global reward index based on elapsed time and eligible supply.
2. Before any principal change for a position, settle that position.
3. Add newly accrued rewards to `accruedRewards[positionKey]`.
4. Update the position checkpoint index.

This gives the same economics as "daily pro rata rewards" but in a substrate-
native, gas-efficient form.

### Reward-Eligible Events

The reward system must settle around:

- deposit stEVE to position
- withdraw stEVE from position
- mint stEVE into a position
- burn stEVE from a position
- claim `EVE`
- transfer of a Position NFT if rewards travel with the position

## Product Rules To Lock Early

### Position Ownership Rule

Rewards accrue to the **position**, not directly to the wallet.

The current owner of the Position NFT controls claiming because they control the
position.

### Transfer Rule

If a Position NFT transfers, its unclaimed EDEN rewards transfer with it.

That is the cleanest substrate-native rule because the position is the account.

### Wallet Rule

Wallet-held stEVE:

- remains useful and transferable
- can still be minted and burned
- does not earn EDEN `EVE` emissions until deposited into a Position NFT

## Implementation Phases

## Phase 0 - Architecture Lock

- Confirm EDEN uses EqualIndex and substrate primitives as-is wherever possible
- Lock the rule that only PNFT-held stEVE earns EDEN `EVE`
- Lock the rule that rewards accrue to positions, not wallets
- Freeze the decision to use reward-index accounting instead of TWAB epochs

## Phase 1 - Finish The Minimum EqualFi Substrate Needed By EDEN

- complete minimal `LibPositionHelpers`
- complete minimal pool membership helpers
- complete trimmed `PositionManagementFacet`
- ensure position-owned deposit / withdraw / principal settlement works
- ensure FI / ACI substrate paths needed by EDEN are live

Definition of done:

- a position can hold principal in a pool
- principal settles correctly through FI
- encumbrance works against position-owned balances

## Phase 2 - Bring EqualIndex Across Cleanly

- port the needed EqualIndex contracts and helpers intact
- preserve wallet mint/burn and position mint/burn
- preserve fee router behavior and pool-native accounting
- avoid EDEN-specific forking inside EqualIndex internals

Definition of done:

- EqualIndex behavior works inside the EdenFi/EqualFi workspace
- both EOA and PNFT flows are available

## Phase 3 - Build EDEN Basket Primitives On Top

- port basket storage and metadata
- port basket token contracts
- port basket creation
- port mint/burn for EDEN baskets
- support:
  - wallet-mode mint/burn
  - position-mode mint/burn where needed

Definition of done:

- EDEN baskets function as a product layer without replacing EqualIndex

## Phase 4 - Build stEVE As An EDEN Product Token

- implement stEVE token/product semantics
- define how stEVE maps into the EqualFi pool domain
- add deposit-to-position and withdraw-from-position flows for stEVE
- ensure PNFT-held stEVE becomes eligible principal for EDEN rewards

Definition of done:

- stEVE can exist in wallets
- stEVE can be deposited into positions
- only position-held stEVE is marked reward-eligible

## Phase 5 - Build The EDEN EVE Reward Facet

- create EDEN reward storage
- implement global reward index updates
- implement position settlement
- implement funding flow for `EVE`
- implement reward claims
- implement reward preview/read surfaces

Definition of done:

- configured `EVE/day` emissions accrue correctly to PNFT-held stEVE
- rewards remain claimable and do not depend on epoch scanning

## Phase 6 - Build EDEN Lending On Positions

- port EDEN basket lending to `positionKey`
- use encumbrance instead of address-owned collateral scans
- implement borrow / repay / extend / recovery
- keep EDEN-specific lending semantics, but make EqualFi substrate own the
  position accounting

Definition of done:

- basket lending is position-owned
- no address-scan-based collateral model remains

## Phase 7 - Rebuild EDEN Views And Agent Surfaces

- rebuild metadata views
- rebuild portfolio views
- rebuild position-aware user views
- rebuild action-check / agent surfaces
- add EDEN-specific views for reward state

Definition of done:

- EDEN by EqualFi has a clean read surface over positions, baskets, loans, and
  rewards

## Phase 8 - Governance, Deployment, And Hardening

- wire EDEN admin/config surfaces into EqualFi governance
- keep 7-day timelock as canonical governance
- port deployment/bootstrap scripts
- assemble the EDEN-only launch facet/module set
- keep unrelated future EqualFi modules out of the launch bundle

Definition of done:

- EDEN by EqualFi can be deployed cleanly without dragging in unfinished product
  modules

## Recommended Immediate Build Order

1. Finish trimmed `PositionManagementFacet`
2. Finish minimal pool membership
3. Port the minimum EqualIndex surface needed by EDEN
4. Implement stEVE deposit/withdraw to Position NFT
5. Implement EDEN `EVE` reward facet with reward-index accounting
6. Port EDEN basket mint/burn
7. Port EDEN lending to `positionKey`
8. Rebuild views and deployment

## Explicit Non-Goals

This plan does **not** attempt to:

- port all EqualFi modules
- ship options / AMMs / auctions
- preserve the old EDEN TWAB epoch system
- create a second EDEN-specific pool/index substrate beside EqualFi

## Acceptance Criteria

This plan is complete when:

- EqualFi substrate remains the canonical accounting layer
- EqualIndex remains the canonical pool / FI / ACI consumer for index behavior
- EDEN by EqualFi exists as a product layer on top
- only PNFT-held stEVE earns EDEN `EVE`
- rewards use index-based accounting instead of TWAB epochs
- wallet users remain supported for simple ownership flows
- future EqualFi modules can still be added without rewriting EDEN again
