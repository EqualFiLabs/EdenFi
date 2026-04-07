# Requirements Document

## Introduction

EDEN is a basket product built on the EqualFi substrate and EqualIndex
accounting model. The goal is not to recreate EDEN as a standalone architecture,
but to launch EDEN on top of reusable EqualFi primitives: Position NFTs, pools,
encumbrance, fee routing, fee indexes, and timelocked governance.

This spec formalizes the product direction:

- EqualFi substrate is canonical
- EqualIndex pool and fee-index accounting is canonical
- EDEN is a product layer on top
- EOAs remain supported for simple mint/burn and holding flows
- only Position NFT-held stEVE earns EDEN `EVE` emissions
- EDEN rewards use index-based accounting rather than TWAB epochs

## Glossary

- **EqualFi Substrate**: Shared protocol primitives including Position NFTs, pools, encumbrance, fee routing, fee indexes, and governance
- **EqualIndex**: EqualFi’s existing index product and accounting system, including wallet and position-owned flows
- **EDEN**: The basket product built on top of EqualFi
- **Position NFT / PNFT**: The ERC-721 account container used by EqualFi to own principal, debt, and yield-bearing positions
- **positionKey**: The canonical bytes32 position identifier derived from a Position NFT
- **Pool Principal**: Position-owned accounting balance tracked in EqualFi pools and eligible for FI / ACI settlement
- **FI**: Fee Index accounting used to distribute routed fee yield to position principal
- **ACI**: Active Credit Index accounting used for credit-side economic adjustments on encumbered principal
- **Encumbrance**: Accounting locks against position-owned principal used by EDEN lending and future modules
- **Basket**: A tokenized bundle of assets with mint/burn semantics and EDEN metadata
- **BasketToken**: The ERC-20 token representing a basket
- **stEVE**: The single-asset EDEN basket token used as the reward-bearing product token for EDEN emissions
- **Reward Index**: A cumulative accounting index that distributes configured `EVE` emissions over eligible PNFT-held stEVE principal
- **Eligible Supply**: Total stEVE principal held in Position NFTs and opted into EDEN reward accrual
- **Wallet Mode**: Product use directly from EOAs without PNFT-owned principal
- **Position Mode**: Product use through Position NFTs with substrate-native principal, fee index, and encumbrance semantics

## Requirements

### Requirement 1: EqualFi Substrate Is Canonical

**User Story:** As a protocol architect, I want EDEN to reuse EqualFi primitives rather than creating a parallel accounting stack, so that EDEN can launch without becoming a dead-end architecture.

#### Acceptance Criteria

1. THE implementation SHALL treat EqualFi substrate contracts and storage as the canonical source of truth for positions, pools, encumbrance, fee routing, fee indexes, and governance
2. THE implementation SHALL treat EqualIndex accounting as canonical for pool-backed index principal and fee-index settlement
3. THE EDEN product layer SHALL NOT introduce a separate long-lived pool, fee-index, or encumbrance subsystem that duplicates EqualFi substrate responsibilities
4. THE EDEN product layer SHALL be implemented as a product-specific surface on top of EqualFi substrate primitives

### Requirement 2: EDEN Supports Wallet Mode and Position Mode

**User Story:** As a user, I want to use EDEN either directly from my wallet or through a Position NFT, so that simple users and advanced users can use the same product with different levels of sophistication.

#### Acceptance Criteria

1. THE system SHALL support wallet-held basket tokens and stEVE balances for simple user flows
2. THE system SHALL support position-owned EDEN balances through Position NFTs and `positionKey` accounting where product flows require substrate-native principal
3. THE system SHALL preserve EOA mint/burn support for simple EDEN product usage
4. THE system SHALL expose position-native flows for EDEN product interactions that require principal ownership, fee index accrual, or encumbrance semantics

### Requirement 3: Position-Owned Principal Management

**User Story:** As a user or integrator, I want Position NFTs to hold EDEN-relevant principal cleanly, so that reward-bearing and encumberable balances are tracked in the EqualFi-native way.

#### Acceptance Criteria

1. THE EqualFi substrate SHALL support minting Position NFTs and deriving canonical `positionKey` values
2. THE EqualFi substrate SHALL support deposit of pool principal into a Position NFT
3. THE EqualFi substrate SHALL support withdrawal of pool principal from a Position NFT
4. THE EqualFi substrate SHALL settle FI accounting around position principal changes
5. THE EqualFi substrate SHALL maintain pool membership semantics for positions that hold principal in a pool
6. THE EqualFi substrate SHALL expose the minimum helper layer needed by EDEN to validate position ownership and use `positionKey`-owned balances safely

### Requirement 4: EDEN Basket Product Layer

**User Story:** As a user, I want EDEN baskets to exist as a product on top of EqualFi, so that I can create, mint, burn, and inspect baskets without losing the benefits of the underlying substrate.

#### Acceptance Criteria

1. THE EDEN product layer SHALL support basket creation with metadata, assets, bundle amounts, and fee configuration
2. THE EDEN product layer SHALL support basket mint and burn semantics compatible with EqualFi substrate accounting
3. THE EDEN product layer SHALL preserve fee-on-transfer-safe inbound token accounting for token-funded state changes
4. THE EDEN product layer SHALL preserve EDEN-specific basket metadata separately from generic pool accounting concerns
5. THE EDEN product layer SHALL support wallet-mode and position-mode entry points where product semantics require both

### Requirement 5: stEVE Product Semantics

**User Story:** As a user, I want stEVE to behave like an EDEN product token while still integrating cleanly with the EqualFi substrate, so that I can hold it in my wallet or move it into a Position NFT when I want yield-bearing behavior.

#### Acceptance Criteria

1. THE system SHALL define stEVE as an EDEN product token built on the EqualFi substrate
2. THE system SHALL support wallet-held stEVE for simple user ownership and transfers
3. THE system SHALL support deposit of stEVE into Position NFTs
4. THE system SHALL support withdrawal of stEVE from Position NFTs
5. THE system SHALL make a clear distinction between wallet-held stEVE and PNFT-held stEVE for reward eligibility

### Requirement 6: Only PNFT-Held stEVE Earns EDEN EVE

**User Story:** As a protocol architect, I want only stEVE deposited into Position NFTs to earn EDEN `EVE`, so that the reward-bearing base matches EqualFi’s position-owned principal model.

#### Acceptance Criteria

1. THE EDEN reward system SHALL treat only Position NFT-held stEVE principal as reward-eligible
2. THE EDEN reward system SHALL NOT grant EDEN `EVE` emissions to wallet-held stEVE balances
3. THE eligible reward base SHALL be the total stEVE principal deposited into Position NFTs and marked reward-eligible
4. THE current owner of a Position NFT SHALL control the rewards accrued by that position
5. IF a Position NFT transfers, THEN the associated unclaimed EDEN rewards SHALL remain with the position and transfer with the NFT

### Requirement 7: EDEN Rewards Use Index-Based Accounting

**User Story:** As a user, I want EDEN to emit a configured amount of `EVE` per day split pro rata across eligible stEVE positions, so that rewards are fair without relying on a TWAB epoch system.

#### Acceptance Criteria

1. THE EDEN reward system SHALL support a configured `EVE` emission rate over time
2. THE EDEN reward system SHALL calculate rewards using a cumulative reward index over eligible PNFT-held stEVE principal
3. THE system SHALL maintain a global reward index, per-position reward checkpoint, and per-position accrued reward balance
4. THE system SHALL settle a position’s reward state before any change to that position’s eligible stEVE principal
5. THE system SHALL support reward funding, reward preview, and reward claiming without epoch scanning
6. THE reward system SHALL preserve the product semantics of “X EVE per day split pro rata among eligible stEVE holders”
7. THE reward system SHALL avoid silently burning accrued rewards due to funding edge cases

### Requirement 8: Protocol Fee Routing and EDEN Emissions Remain Separate

**User Story:** As a protocol architect, I want protocol fee routing and EDEN token emissions to remain separate concerns, so that product rewards do not distort generic substrate accounting.

#### Acceptance Criteria

1. THE implementation SHALL preserve EqualFi fee routing as a substrate-level concern
2. THE implementation SHALL treat EDEN `EVE` emissions as a product-level concern distinct from generic fee routing
3. THE EDEN reward system SHALL NOT require protocol fee assets to be reinterpreted as EDEN token emissions
4. THE design SHALL leave room for unsupported fee-asset handling later without coupling it to EDEN `EVE` reward math

### Requirement 9: EDEN Lending Is Position-Owned

**User Story:** As a user, I want EDEN lending to belong to my Position NFT rather than my wallet address, so that collateral locks, debt, and future module interactions all use the EqualFi-native account model.

#### Acceptance Criteria

1. THE EDEN lending system SHALL associate loans with `positionKey`, not wallet addresses
2. THE EDEN lending system SHALL use EqualFi encumbrance primitives to represent collateral locks
3. THE EDEN lending system SHALL support borrow, repay, extend, and expiry/recovery flows against positions
4. THE EDEN lending system SHALL preserve deterministic previews and durable loan views
5. THE EDEN lending system SHALL remove dependence on address-scan-based collateral or loan ownership logic
6. THE EDEN lending system SHALL remain minimal and scoped to EDEN basket lending only

### Requirement 10: EDEN View, Portfolio, and Agent Surfaces

**User Story:** As a frontend or agent, I want EDEN to expose clear metadata, portfolio, loan, and action-check views, so that the product remains queryable even though the accounting model is position-based.

#### Acceptance Criteria

1. THE EDEN product layer SHALL expose basket summaries, metadata, and protocol-level reads
2. THE EDEN product layer SHALL expose position-aware portfolio views
3. THE EDEN product layer SHALL expose position-aware loan views and previews
4. THE EDEN product layer SHALL expose EDEN reward state for PNFT-held stEVE
5. THE EDEN product layer SHALL expose action-check surfaces for mint, burn, borrow, repay, extend, and reward-claim actions
6. THE read surface SHALL preserve the useful EDEN product introspection model even though the underlying accounting is position-owned

### Requirement 11: Governance and Product Assembly

**User Story:** As an operator, I want EDEN to launch with hardened governance and a minimal deployment surface, so that the shipped product includes only what EDEN needs while remaining extensible later.

#### Acceptance Criteria

1. THE deployed EDEN product SHALL use the EqualFi timelock-governed path as the canonical governance path
2. THE implementation SHALL preserve a real 7-day timelock for privileged product actions
3. THE EDEN deployment assembly SHALL include only the facets/modules needed for the EDEN product
4. THE EDEN deployment assembly SHALL exclude unrelated future EqualFi modules from the launch bundle
5. THE system SHALL preserve enough modularity that future EqualFi modules can be added later without forcing a rewrite of the EDEN product
