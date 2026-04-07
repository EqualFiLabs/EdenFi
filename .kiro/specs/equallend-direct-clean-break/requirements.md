# Requirements Document

## Introduction

EqualLend Direct is the EqualFi bilateral credit layer for position-owned,
peer-to-peer lending.

It is also a bilateral rights-and-settlement layer with embedded option-like
behavior. Borrower and lender rights such as early repay, early exercise,
lender call, rolling cure, and recovery make EqualLend Direct more than a
simple loan ledger.

This spec defines a clean-break rebuild of EqualLend Direct inside the EqualFi
substrate. The goal is not to port old code mechanically. The goal is to keep
the product surface that matters:

- fixed-term direct lending
- rolling direct lending
- lender-posted and borrower-posted offers
- lender-posted and borrower-posted ratio tranches
- Position NFT ownership and transfer semantics

The rebuild must eliminate drift between product variants. Fixed, rolling, and
ratio-tranche flows must share one accounting model for:

- lender principal leaving and returning to the lender pool
- borrower debt tracking
- collateral encumbrance
- same-asset active-credit treatment
- offer and agreement indexing

The rebuild must also preserve the fact that direct agreements are contingent
rights structures, not just debt balances. The implementation should therefore
reuse EqualFi’s collateral-lock and settlement discipline in the same spirit as
other capital-encumbering products.

Rolling and ratio tranches are mandatory scope. They may be implemented after
the fixed-term baseline, but they must ship on the same clean accounting
foundation.

## Glossary

- **EqualFi Substrate**: The canonical pool, Position NFT, encumbrance,
  fee-index, active-credit, and governance system.
- **Position NFT / PNFT**: The ERC-721 account container that owns principal,
  debt, and module state.
- **positionKey**: The canonical bytes32 identity derived from a Position NFT.
- **Direct Offer**: A fixed-term bilateral lending offer posted by a lender or
  borrower position.
- **Rolling Offer**: A bilateral rolling-loan offer with payment cadence,
  arrears, and optional amortization.
- **Ratio Tranche Offer**: A partially fillable direct offer priced by
  principal/collateral ratio rather than one fixed collateral amount.
- **Lender Pool**: The pool whose principal is lent out as the borrow asset.
- **Collateral Pool**: The pool whose principal is locked as collateral.
- **Direct Encumbrance**: Direct-lending usage of `lockedCapital`,
  `offerEscrowedCapital`, and `encumberedCapital`.
- **Borrowed Principal Ledger**: The canonical direct-debt principal tracked per
  borrower position and lender pool.
- **Same-Asset Debt Ledger**: The canonical debt overlay used when borrow asset
  and collateral asset are the same pool asset.

## Requirements

### Requirement 1: EqualFi Substrate Is Canonical

**User Story:** As a protocol architect, I want EqualLend Direct to reuse the
EqualFi substrate instead of introducing a parallel accounting stack, so that
direct credit remains composable with the rest of EqualFi.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL treat Position NFT ownership,
   `positionKey`, pool principal, fee index, active credit, encumbrance, and
   timelock governance as EqualFi-native substrate concerns.
2. THE EqualLend_Direct_System SHALL NOT introduce a second long-lived balance,
   debt, or collateral subsystem that duplicates EqualFi substrate
   responsibilities.
3. THE EqualLend_Direct_System SHALL reuse the existing EqualFi encumbrance
   primitive as the canonical collateral-and-capacity lock mechanism for direct
   lending.
4. THE EqualLend_Direct_System SHALL NOT introduce parallel product-specific
   encumbrance storage, shadow lock ledgers, or variant-specific encumbrance
   methods for fixed, rolling, or ratio-tranche flows.
5. THE EqualLend_Direct_System SHALL reuse existing pool settlement discipline
   before any direct offer posting, acceptance, repayment, exercise, or
   recovery flow that mutates principal-sensitive state.
6. THE implementation SHALL preserve Position NFT transfer semantics as the
   canonical ownership rail for direct offers, agreements, rights, and
   obligations.

### Requirement 2: One Accounting Model Across Fixed, Rolling, and Ratio

**User Story:** As a protocol architect, I want every direct-lending variant to
share one accounting model, so that rolling and ratio tranches do not drift from
fixed direct behavior.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL use one canonical direct encumbrance model:
   - borrower collateral locks use `lockedCapital`
   - unfunded lender offer capacity uses `offerEscrowedCapital`
   - funded live lender exposure uses `encumberedCapital`
2. THE EqualLend_Direct_System SHALL use one canonical borrowed-principal ledger
   keyed by borrower `positionKey` and lender pool ID for all active direct
   debt.
3. WHEN a direct agreement uses the same asset for borrow and collateral, THE
   EqualLend_Direct_System SHALL use one canonical same-asset debt path across
   fixed, rolling, and ratio variants.
4. WHEN lender capital leaves a lender pool at origination, THE
   EqualLend_Direct_System SHALL reduce lender pool principal and tracked
   liquidity consistently across all direct variants.
5. WHEN borrower payments or recoveries return value to the lender side, THE
   EqualLend_Direct_System SHALL restore lender-side pool accounting
   consistently across all direct variants.
6. THE EqualLend_Direct_System SHALL reject any implementation path where one
   direct variant mutates active-credit debt state or same-asset debt ledgers
   differently from the others for the same economic situation.
7. THE EqualLend_Direct_System SHALL reject any implementation path where fixed,
   rolling, or ratio-tranche products bypass `LibEncumbrance` in favor of
   bespoke lock or exposure mutation methods.

### Requirement 3: Fixed-Term Direct Offers

**User Story:** As a lender or borrower, I want to post fixed-term direct offers
from a Position NFT, so that bilateral fixed-term credit can be expressed
without pooled underwriting.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL support lender-posted fixed offers from a
   lender Position NFT.
2. THE EqualLend_Direct_System SHALL support borrower-posted fixed offers from a
   borrower Position NFT.
3. WHEN an offer is posted, THE EqualLend_Direct_System SHALL validate:
   - Position NFT authority
   - lender-pool and collateral-pool existence
   - borrow-asset and collateral-asset alignment with those pools
   - non-zero principal, duration, and collateral lock
   - available lender or borrower principal after existing encumbrances
4. WHEN a lender-posted offer is posted, THE EqualLend_Direct_System SHALL
   escrow lender capacity through `offerEscrowedCapital`.
5. WHEN a borrower-posted offer is posted, THE EqualLend_Direct_System SHALL
   lock borrower collateral capacity through `lockedCapital`.
6. THE EqualLend_Direct_System SHALL support manual cancellation and
   transfer-triggered cleanup of open fixed offers.

### Requirement 4: Fixed-Term Agreement Origination and Lifecycle

**User Story:** As a borrower or lender, I want fixed-term agreements to
originate and settle cleanly, so that principal, fees, and collateral behave
predictably.

#### Acceptance Criteria

1. WHEN a fixed offer is accepted, THE EqualLend_Direct_System SHALL re-check
   live lender solvency, borrower solvency, and pool liquidity before principal
   leaves the lender pool.
2. WHEN a fixed agreement originates, THE EqualLend_Direct_System SHALL:
   - move lender offer escrow into funded lender exposure
   - increase borrower borrowed principal
   - apply same-asset debt treatment only when borrow asset equals collateral
     asset
   - record a due timestamp and agreement status
3. THE EqualLend_Direct_System SHALL support borrower repayment subject to the
   agreed early-repay rules and grace-period rules.
4. THE EqualLend_Direct_System SHALL support borrower exercise / surrender
   subject to the agreed early-exercise rules and grace-period rules.
5. THE EqualLend_Direct_System SHALL support recovery after grace-period expiry.
6. WHEN a fixed agreement reaches a terminal state, THE EqualLend_Direct_System
   SHALL fully clear lender exposure, borrower debt, collateral locks, and
   same-asset debt overlays for that agreement.

### Requirement 5: Rolling Direct Offers and Agreement Initialization

**User Story:** As a lender or borrower, I want rolling direct loans to exist as
first-class EqualFi products, so that recurring-payment bilateral credit is
available without losing substrate consistency.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL support lender-posted rolling offers.
2. THE EqualLend_Direct_System SHALL support borrower-posted rolling offers.
3. A rolling offer SHALL include at minimum:
   - principal
   - collateral lock amount
   - payment interval
   - rolling APY
   - grace period
   - payment-count cap
   - upfront premium
   - allow-amortization flag
   - allow-early-repay flag
   - allow-early-exercise flag
4. WHEN a rolling agreement originates, THE EqualLend_Direct_System SHALL use
   the same lender-capital departure, borrower-debt origination, and same-asset
   debt treatment model as fixed direct.
5. WHEN a rolling agreement originates, THE EqualLend_Direct_System SHALL
   initialize next due timestamp, payment count, arrears state, outstanding
   principal, and rolling status fields.
6. THE EqualLend_Direct_System SHALL reject rolling-origination paths that skip
   lender solvency checks, borrower solvency checks, or pool-liquidity checks
   required by the shared direct accounting model.

### Requirement 6: Rolling Payment and Terminal Lifecycle

**User Story:** As a borrower or lender, I want rolling agreements to handle
scheduled payments, amortization, closeout, exercise, and recovery correctly,
so that the product is economically usable.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL support recurring rolling payments that can
   pay arrears, current-period interest, and optionally principal.
2. IF amortization is disabled, THEN THE EqualLend_Direct_System SHALL reject
   principal-reducing payments while still allowing interest and arrears
   payments.
3. WHEN a rolling payment reduces principal, THE EqualLend_Direct_System SHALL
   update lender funded exposure, borrower borrowed principal, and same-asset
   debt overlays using the shared direct accounting model.
4. THE EqualLend_Direct_System SHALL support full rolling closeout through
   borrower repayment.
5. THE EqualLend_Direct_System SHALL support borrower early exercise when the
   agreement allows it.
6. THE EqualLend_Direct_System SHALL support lender / permissionless recovery
   after the recovery window opens.
7. WHEN a rolling agreement reaches a terminal state, THE
   EqualLend_Direct_System SHALL restore or clear all lender, borrower, and
   indexing state symmetrically with origination.

### Requirement 7: Lender-Posted Ratio Tranche Offers

**User Story:** As a lender, I want to post partially fillable ratio-tranche
offers, so that I can expose reusable principal capacity under one commercial
ratio.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL support lender-posted ratio-tranche offers
   with:
   - principal cap
   - principal remaining
   - price numerator
   - price denominator
   - minimum principal per fill
   - APR and duration
2. WHEN a lender ratio-tranche offer is posted, THE EqualLend_Direct_System
   SHALL escrow the full principal cap in `offerEscrowedCapital`.
3. WHEN a lender ratio-tranche fill occurs, THE EqualLend_Direct_System SHALL:
   - consume only the filled principal from the escrowed cap
   - compute collateral required from the ratio
   - originate a direct agreement using the shared fixed/direct accounting model
4. THE EqualLend_Direct_System SHALL support multiple fills until the principal
   cap is exhausted or the offer is canceled.
5. THE EqualLend_Direct_System SHALL support cancellation that releases only the
   remaining unfilled principal cap.

### Requirement 8: Borrower-Posted Ratio Tranche Offers

**User Story:** As a borrower, I want to post partially fillable ratio-tranche
offers, so that I can advertise reusable collateral capacity under one
commercial ratio.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL support borrower-posted ratio-tranche
   offers with:
   - collateral cap
   - collateral remaining
   - price numerator
   - price denominator
   - minimum collateral per fill
   - APR and duration
2. WHEN a borrower ratio-tranche offer is posted, THE EqualLend_Direct_System
   SHALL lock the collateral cap in `lockedCapital`.
3. WHEN a borrower ratio-tranche fill occurs, THE EqualLend_Direct_System SHALL:
   - consume only the filled collateral amount from the locked cap
   - compute principal from the ratio
   - originate a direct agreement using the shared fixed/direct accounting model
4. THE EqualLend_Direct_System SHALL support multiple fills until the
   collateral cap is exhausted or the offer is canceled.
5. THE EqualLend_Direct_System SHALL support cancellation that releases only the
   remaining unfilled collateral cap.

### Requirement 9: Position-Native Ownership, Indexing, and Transfer Semantics

**User Story:** As a user or integrator, I want all direct rights and
obligations to remain position-native, so that transfer and view behavior stays
coherent.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL key active offers and agreements to
   position-owned state rather than wallet-address-only state.
2. THE current owner or approved operator of a Position NFT SHALL be able to act
   on that position’s direct offers and agreements where product rules allow.
3. IF a Position NFT transfers, THEN open offers and active agreements SHALL
   continue to belong to that position unless a specific transfer guard blocks
   the transfer.
4. THE EqualLend_Direct_System SHALL expose borrower-side and lender-side
   indexing for fixed, rolling, and ratio-tranche state.
5. THE EqualLend_Direct_System SHALL keep generic and product-specific agreement
   indexes consistent, with symmetric add/remove behavior across every terminal
   state.
6. THE Position NFT transfer hook SHALL either block transfers with open offers
   or deterministically cancel them according to the configured direct-offer
   rules.

### Requirement 10: Views, Config, and Governance

**User Story:** As a frontend, agent, or operator, I want a durable view and
config surface for EqualLend Direct, so that direct credit is queryable and
governable without bespoke offchain inference.

#### Acceptance Criteria

1. THE EqualLend_Direct_System SHALL expose read functions for fixed offers,
   fixed agreements, rolling offers, rolling agreements, lender ratio-tranche
   offers, and borrower ratio-tranche offers.
2. THE EqualLend_Direct_System SHALL expose position-scoped lookups for active
   borrower offers, lender offers, borrower agreements, lender agreements,
   rolling exposure, and tranche status.
3. THE EqualLend_Direct_System SHALL expose rolling payment previews and status
   reads derived from onchain state.
4. THE EqualLend_Direct_System SHALL expose direct configuration writes only
   through owner-or-timelock-governed surfaces.
5. THE EqualLend_Direct_System SHALL validate rolling-config and direct-config
   bounds before storing them.

### Requirement 11: Test Fidelity and Greenfield Port Discipline

**User Story:** As a protocol maintainer, I want the EqualLend Direct rebuild to
prove real behavior rather than synthetic shortcuts, so that the greenfield port
does not recreate hidden accounting drift.

#### Acceptance Criteria

1. THE implementation SHALL include real-flow tests for every value-moving
   lifecycle in fixed, rolling, lender-ratio-tranche, and borrower-ratio-tranche
   flows.
2. THE implementation SHALL include tests proving lender principal departure and
   return are symmetric across fixed and rolling paths.
3. THE implementation SHALL include tests proving same-asset debt origination
   and cleanup behave identically across fixed, rolling, and ratio-tranche
   agreements.
4. THE implementation SHALL include tests proving open-offer indexing and
   active-agreement indexing remain coherent through creation, transfer,
   cancelation, fill, repayment, exercise, and recovery.
5. Synthetic harness tests MAY exist for narrow state-machine edges, but they
   SHALL NOT be treated as end-to-end confidence for value-moving behavior.
