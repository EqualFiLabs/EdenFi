# Requirements Document

## Introduction

EDEN must stop acting like a second generic basket protocol.

This spec defines a **clean-break rewrite** where:

- **EqualFi** remains the canonical substrate
- **EqualIndex** remains the canonical generic basket / index layer
- **EDEN** becomes a **singleton product surface** centered on:
  - `stEVE`
  - EDEN-specific `EVE` rewards
  - EDEN-specific lending against the canonical EDEN product

Nothing is live. Backwards compatibility is explicitly out of scope.

The system must not preserve arbitrary `basketId` APIs, registry-shaped EDEN storage,
or migration scaffolding for old generic-basket behavior.

## Clean-Break Boundary

The clean-break boundary is explicit and architectural, not cosmetic:

- **EDEN is not a generic basket protocol.**
- **EqualIndex owns the generic basket / index lane.**
- **EDEN is a singleton product surface centered on `stEVE`.**
- **EDEN rewards are `EVE` emissions for PNFT-held `stEVE`.**
- **EDEN lending exists only against the canonical EDEN product.**
- **Pool flash loans stay in the EqualFi substrate, while index flash loans stay in EqualIndex.**

Any EDEN surface that implies arbitrary product creation, arbitrary `basketId`
routing, EDEN-side catalog enumeration, or EDEN-side generic structured exposure
is outside the intended architecture and must be removed.

## Glossary

- **EqualFi Substrate**: The canonical base layer containing pools, Position NFTs, `positionKey` accounting, encumbrance, fee routing, FI / ACI, governance, and pool flash loans.
- **EqualIndex**: The canonical generic basket / index layer for non-EDEN structured exposure and index flash loans.
- **EDEN Product**: The singleton EDEN product surface built around `stEVE`.
- **stEVE**: The canonical EDEN product token.
- **EVE Rewards**: EDEN-specific token emissions that accrue only to PNFT-held `stEVE`.
- **PNFT-held stEVE**: `stEVE` held through Position NFT-owned substrate principal and therefore eligible for EDEN reward accounting.
- **Wallet-held stEVE**: Direct wallet balance of `stEVE`; transferable and usable, but not reward-eligible by default.
- **Singleton Product Storage**: EDEN storage shaped for one canonical product rather than an arbitrary basket registry.

## Requirements

### Requirement 1: EDEN Must Not Expose a Generic Basket Surface

**User Story:** As a protocol architect, I want EDEN to be a single-product surface so it does not duplicate EqualIndex.

#### Acceptance Criteria

1. THE EDEN_System SHALL NOT expose generic basket creation.
2. THE EDEN_System SHALL NOT expose arbitrary basket mint / burn APIs.
3. THE EDEN_System SHALL NOT expose basket-registry catalog views such as basket enumeration or basket summary lists.
4. THE EDEN_System SHALL NOT expose admin or lending APIs parameterized by arbitrary `basketId`.
5. THE EqualIndex_System SHALL remain the canonical generic basket / index lane.
6. THE EDEN_System SHALL present itself as a singleton product surface, not as a framework for future arbitrary EDEN baskets.

### Requirement 2: EDEN Storage Must Be Singleton Product Storage

**User Story:** As a protocol architect, I want EDEN storage to model one canonical product so the code matches the intended architecture.

#### Acceptance Criteria

1. THE EDEN_System SHALL replace registry-shaped basket storage with singleton product storage.
2. THE EDEN_System SHALL NOT keep `basketCount` or arbitrary `baskets[basketId]` mappings.
3. THE EDEN_System SHALL NOT keep arbitrary `basketMetadata[basketId]` mappings.
4. THE EDEN_System SHALL NOT keep arbitrary `tokenToBasketIdPlusOne` mappings.
5. THE EDEN_System SHALL store vault, fee-pot, metadata, and config state for the canonical EDEN product only.

### Requirement 3: Wallet Mode Must Be stEVE-Only

**User Story:** As a wallet user, I want EDEN wallet flows to interact only with the canonical EDEN product.

#### Acceptance Criteria

1. THE EDEN_System SHALL provide wallet-mode flows only for `stEVE`.
2. THE EDEN_System SHALL NOT provide generic wallet basket creation.
3. THE EDEN_System SHALL NOT provide arbitrary wallet basket mint / burn.
4. Wallet-mode `stEVE` mint and burn SHALL remain supported.
5. Wallet-mode EDEN flows SHALL be described as operations on the canonical EDEN product, not as instances of a generic basket workflow.

### Requirement 4: Position Mode Must Be stEVE-Only

**User Story:** As a Position NFT user, I want EDEN position flows to operate only on `stEVE`.

#### Acceptance Criteria

1. THE EDEN_System SHALL provide PNFT-mode flows only for `stEVE`.
2. THE EDEN_System SHALL NOT provide arbitrary position-mode basket mint / burn.
3. PNFT-held `stEVE` SHALL remain substrate-native principal.
4. PNFT-held `stEVE` SHALL remain eligible for EDEN reward accounting.
5. PNFT-mode EDEN flows SHALL reuse the existing substrate position / encumbrance model rather than introducing a second EDEN accounting lane.

### Requirement 5: EDEN Views Must Describe a Singleton Product

**User Story:** As an integrator, I want EDEN views to describe the canonical EDEN product rather than a basket registry.

#### Acceptance Criteria

1. THE EDEN_System SHALL provide product-specific views for the canonical EDEN product.
2. THE EDEN_System SHALL NOT provide basket enumeration, basket registry summaries, or arbitrary basket detail views.
3. THE EDEN_System SHALL provide explicit views for product config, product fee state, product pool identity, and reward eligibility state.
4. The public view layer SHALL make clear that EDEN is a singleton product.
5. The public view layer SHALL make clear that generic structured exposure belongs to EqualIndex, not EDEN.

### Requirement 6: EDEN Admin Must Configure the Product, Not a Basket Catalog

**User Story:** As governance, I want to configure the canonical EDEN product directly.

#### Acceptance Criteria

1. THE EDEN_System SHALL expose admin/config methods for the singleton EDEN product only.
2. THE EDEN_System SHALL NOT expose arbitrary `basketId` admin methods.
3. Product metadata, pause state, fee config, and reward config SHALL be configurable without basket catalog semantics.
4. Governance-wide metadata such as protocol URI, contract version, and timelock config MAY remain if still valid.
5. EDEN admin/config methods SHALL NOT imply that governance can instantiate or manage multiple EDEN products.

### Requirement 7: EDEN Lending Must Be Singleton-Product Lending

**User Story:** As a borrower, I want EDEN lending to clearly be lending against the canonical EDEN product, not arbitrary EDEN baskets.

#### Acceptance Criteria

1. THE EDEN_System SHALL remove `basketId` from public EDEN lending APIs.
2. THE EDEN_System SHALL replace per-basket lending config with EDEN-product lending config.
3. THE EDEN_System SHALL replace per-basket fee tiers with EDEN-product fee tiers.
4. Repay, extend, recovery, and redeemability logic SHALL remain only insofar as they apply to the canonical EDEN product.
5. THE EDEN_System SHALL NOT retain lending state whose only purpose was arbitrary basket support.
6. THE EDEN_System SHALL make clear that EDEN lending is lending against the canonical EDEN product only, while generic index exposure remains in EqualIndex.

### Requirement 8: Rewards Must Be Explicitly PNFT-held stEVE -> EVE

**User Story:** As a user, I want the reward rule to be unambiguous.

#### Acceptance Criteria

1. Only PNFT-held `stEVE` SHALL earn EDEN `EVE` rewards.
2. Wallet-held `stEVE` SHALL NOT earn EDEN `EVE` rewards by default.
3. Reward accounting SHALL accrue to the position, not directly to the wallet.
4. THE EDEN_System SHALL NOT imply that arbitrary EDEN products can become reward-bearing.
5. EDEN rewards SHALL remain product-specific emissions layered onto the canonical `stEVE` position flow.

### Requirement 9: EDEN Cleanup Must Not Amputate Canonical Non-EDEN Capabilities

**User Story:** As a protocol architect, I want the EDEN clean break to narrow EDEN without damaging the canonical layers.

#### Acceptance Criteria

1. Pool flash loans SHALL remain in the EqualFi substrate.
2. Index flash loans SHALL remain in EqualIndex.
3. Generic structured exposure SHALL remain in EqualIndex, not EDEN.
4. EDEN cleanup SHALL NOT delete or orphan selectors/tests for canonical non-EDEN capabilities.
5. EDEN cleanup SHALL narrow only the EDEN product surface and SHALL NOT collapse the architectural boundary between substrate, EqualIndex, and EDEN.

### Requirement 10: Deployment Must Match the Clean-Break Boundary

**User Story:** As an operator, I want launch/deploy wiring to match the intended architecture exactly.

#### Acceptance Criteria

1. Deploy selector wiring SHALL remove deleted EDEN generic-basket surfaces.
2. Deploy selector wiring SHALL remove deleted duplicate legacy EDEN facets.
3. The launch diamond SHALL include only the intended EDEN singleton-product facets.
4. Tests SHALL prove the selector set matches the clean-break architecture.

### Requirement 11: Tests Must Enforce the Clean Break

**User Story:** As a maintainer, I want the architecture enforced by tests, not memory.

#### Acceptance Criteria

1. Tests SHALL prove arbitrary EDEN basket creation is impossible.
2. Tests SHALL prove arbitrary EDEN wallet mint / burn is impossible.
3. Tests SHALL prove arbitrary EDEN position mint / burn is impossible.
4. Tests SHALL prove wallet-mode `stEVE` mint / burn still works.
5. Tests SHALL prove PNFT-mode `stEVE` deposit / withdraw still works.
6. Tests SHALL prove only PNFT-held `stEVE` earns EDEN `EVE`.
7. Tests SHALL prove EDEN lending works only against the singleton EDEN product.
8. Tests SHALL prove pool flash loans and index flash loans still work.
9. Tests SHALL prove EqualIndex generic mint / burn still works for non-EDEN products.
