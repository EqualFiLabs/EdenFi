# Requirements Document

## Introduction

Self-Secured Credit is the deterministic EqualFi credit primitive for borrowing
an asset against principal already deposited in that same asset's pool.

This spec defines a clean greenfield rebuild of Self-Secured Credit inside the
EqualFi substrate in this workspace.

The goal is not to port the old sibling implementation mechanically. The goal
is to preserve the product that matters:

- same-asset borrowing through Position NFTs
- deterministic LTV with no oracle dependency
- Active Credit Index rewards for active SSC debt
- maintenance-driven active management rather than oracle liquidations
- optional ACI self-pay routing that lets future ACI reduce debt instead of
  accruing as claimable yield

The rebuild must treat the shared EqualFi substrate as canonical:

- Position NFT ownership and transfer semantics
- per-pool principal and tracked liquidity
- fee index, active credit index, and maintenance settlement
- canonical encumbrance buckets and withdrawal safety

The rebuild must also be honest about SSC economics. A 0% same-asset line with
ACI rewards is still an actively managed position because maintenance keeps
reducing principal over time. The protocol therefore needs deterministic
servicing and terminal-state behavior rather than hand-wavy assumptions that
users will always repay voluntarily.

## Glossary

- **Self-Secured Credit / SSC**: Same-asset borrowing against a position's own
  deposited principal.
- **SSC Line**: The active rolling same-asset debt state for one position in
  one pool.
- **Required Lock**: The portion of principal that must remain unavailable
  while SSC debt is open so the line stays within deterministic LTV.
- **Free Equity**: Principal not consumed by required lock or same-asset debt.
- **ACI Self-Pay Mode**: A routing mode where future SSC-earned ACI reduces SSC
  debt instead of accruing as claimable ACI yield.
- **Yield Mode**: A routing mode where future SSC-earned ACI accrues as
  claimable ACI yield rather than auto-paying debt.
- **Prospective Toggle**: A mode change that applies only to future ACI after
  settlement at the toggle point.
- **Service Operation**: A lifecycle action that settles maintenance, FI, and
  ACI and then applies the current SSC routing rules.
- **Terminal Self-Settlement**: A deterministic close path where locked
  principal is consumed to close or reduce SSC debt once the position can no
  longer safely support the line.

## Requirements

### Requirement 1: EqualFi Substrate Is Canonical

**User Story:** As a protocol architect, I want SSC to reuse the EqualFi
substrate instead of introducing a parallel lending stack, so that SSC remains
composable with the rest of EqualFi.

#### Acceptance Criteria

1. THE Self_Secured_Credit_System SHALL treat Position NFT ownership,
   `positionKey`, pool principal, tracked liquidity, fee index, active credit,
   maintenance, and governance as EqualFi-native substrate concerns.
2. THE Self_Secured_Credit_System SHALL NOT introduce a second long-lived pool,
   yield, debt, or collateral subsystem that duplicates EqualFi substrate
   responsibilities.
3. THE Self_Secured_Credit_System SHALL settle the relevant pool indexes before
   any SSC operation that changes principal-sensitive or debt-sensitive state.
4. THE implementation SHALL preserve Position NFT transfer semantics as the
   canonical ownership rail for SSC debt, rights, and obligations.

### Requirement 2: SSC Must Use Canonical Same-Asset Debt and Native Locking

**User Story:** As a protocol architect, I want SSC to use one canonical debt
and locking model, so withdrawals and fee behavior stay coherent with the rest
of EqualFi.

#### Acceptance Criteria

1. THE Self_Secured_Credit_System SHALL use the canonical `userSameAssetDebt`
   path for SSC debt economics.
2. THE Self_Secured_Credit_System SHALL use canonical `lockedCapital` for SSC
   withdrawal safety and required collateral reservation.
3. THE Self_Secured_Credit_System SHALL NOT rely on bespoke SSC-only shadow
   lock accounting to answer how much principal is unavailable.
4. THE Self_Secured_Credit_System SHALL maintain a required-lock amount that is
   derived from current SSC debt and pool LTV.
5. Position withdrawal rules SHALL remain governed by canonical substrate
   principal-availability checks after SSC state is applied.

### Requirement 3: SSC Must Remain Deterministic and Same-Asset

**User Story:** As a user, I want SSC to remain a deterministic same-asset
credit primitive, so I can use it without oracle or auction risk.

#### Acceptance Criteria

1. THE Self_Secured_Credit_System SHALL allow borrowing only from the same pool
   whose principal secures the debt.
2. THE Self_Secured_Credit_System SHALL enforce deterministic LTV using pool
   config and onchain substrate state only.
3. THE Self_Secured_Credit_System SHALL NOT depend on external price oracles,
   liquidation auctions, or third-party liquidation markets.
4. THE Self_Secured_Credit_System SHALL disburse borrow proceeds from tracked
   pool liquidity and restore tracked liquidity on repayment or debt
   auto-paydown.

### Requirement 4: SSC Must Reward Active Debt Through ACI

**User Story:** As a user, I want SSC debt to remain ACI-eligible, so there is
  a real reason to use the product.

#### Acceptance Criteria

1. WHEN SSC debt is opened or increased, THE Self_Secured_Credit_System SHALL
   increase same-asset debt and borrower debt-side ACI state through one
   canonical path.
2. WHEN SSC debt is repaid or auto-paid down, THE Self_Secured_Credit_System
   SHALL decrease same-asset debt and borrower debt-side ACI state through one
   canonical path.
3. THE Self_Secured_Credit_System SHALL preserve the existing ACI time-gating
   and weighted-dilution behavior for SSC debt state.
4. THE Self_Secured_Credit_System SHALL NOT double-count SSC collateral lock as
   separate encumbrance-side ACI reward if the same exposure is already being
   rewarded through debt-side ACI.

### Requirement 5: Maintenance Must Continue To Pressure SSC Positions

**User Story:** As a protocol architect, I want maintenance to remain real for
SSC positions, so SSC users must actively manage the line rather than receiving
free perpetual leverage.

#### Acceptance Criteria

1. THE Self_Secured_Credit_System SHALL keep maintenance charges on the pool
   principal according to EqualFi substrate rules.
2. THE Self_Secured_Credit_System SHALL support SSC lines whose safe state can
   degrade over time as maintenance reduces principal.
3. THE Self_Secured_Credit_System SHALL expose sufficient view data for a user
   or observer to understand maintenance pressure, required lock, free equity,
   and remaining line runway.
4. THE Self_Secured_Credit_System SHALL provide deterministic servicing or
   terminal behavior when maintenance pressure causes the line to approach or
   exceed safe backing limits.

### Requirement 6: ACI Self-Pay Must Be a Prospective User-Routing Choice

**User Story:** As an SSC user, I want to choose whether future SSC-earned ACI
reduces my debt or accrues as yield, so I can switch between cashflow and
de-risking postures.

#### Acceptance Criteria

1. THE Self_Secured_Credit_System SHALL support at least two SSC ACI routing
   modes:
   - yield mode
   - self-pay mode
2. THE Self_Secured_Credit_System SHALL allow the Position NFT owner to switch
   routing mode while SSC debt is open.
3. WHEN the routing mode changes, THE Self_Secured_Credit_System SHALL settle
   relevant SSC state before the mode change takes effect.
4. THE routing mode SHALL apply only prospectively to future ACI after the
   settlement point and SHALL NOT retroactively reclassify already accrued ACI.
5. IF self-pay ACI exceeds outstanding SSC debt, THEN THE system SHALL apply a
   deterministic overflow rule rather than silently burning value.

### Requirement 7: Yield and Debt-Servicing Accounting Must Be Source-Explicit

**User Story:** As a maintainer, I want SSC ACI self-pay accounting to remain
auditable, so FI yield and ACI servicing do not become entangled.

#### Acceptance Criteria

1. THE Self_Secured_Credit_System SHALL keep FI yield accounting distinct from
   SSC ACI self-pay accounting.
2. THE Self_Secured_Credit_System SHALL NOT require retroactive interpretation
   of one blended accrued-yield bucket to decide whether value is claimable or
   debt-paying.
3. THE implementation SHALL expose enough state to audit:
   - claimable FI yield
   - claimable ACI yield
   - ACI applied to SSC debt
   - outstanding SSC debt after servicing
4. THE implementation SHALL preserve claim behavior for non-SSC and non-ACI
   yield sources outside the SSC self-pay flow.

### Requirement 8: SSC Must Support Deterministic Servicing and Terminal Settlement

**User Story:** As a protocol architect, I want SSC to fail and unwind
deterministically, so the system does not depend on voluntary borrower action
when a line becomes unsafe.

#### Acceptance Criteria

1. THE Self_Secured_Credit_System SHALL support a service path that can settle
   maintenance, FI, ACI, and SSC debt state without requiring a traditional
   scheduled payment.
2. THE service path MAY be callable by the owner and MAY also be callable by
   anyone when the protocol needs a permissionless upkeep path.
3. WHEN an SSC position can no longer support its required lock after
   settlement, THE Self_Secured_Credit_System SHALL support deterministic
   self-settlement against the position's own locked principal.
4. Terminal self-settlement SHALL clear or reduce same-asset debt, release or
   consume the corresponding SSC lock, and restore coherent pool accounting.
5. The unhappy path SHALL NOT require external liquidators, price auctions, or
   offchain keepers with privileged rights.

### Requirement 9: View, Config, and Launch Surfaces Must Match the New Model

**User Story:** As a maintainer, I want the SSC public surface to describe the
actual greenfield architecture, so implementation and future reviews stay
aligned.

#### Acceptance Criteria

1. THE Self_Secured_Credit_System SHALL expose read functions for SSC line
   state, required lock, borrow capacity, claimable FI yield, claimable ACI
   yield, and current ACI routing mode.
2. THE Self_Secured_Credit_System SHALL expose deterministic previews for draw,
   repay, service, self-pay effect, and terminal self-settlement effect.
3. THE Self_Secured_Credit_System SHALL validate pool-level SSC config such as
   LTV, minimum draw amount, and any SSC-specific service thresholds.
4. Diamond launch and selector wiring SHALL reflect the clean SSC surface
   rather than the legacy monolithic lending shape.

### Requirement 10: Tests Must Prove Real SSC Behavior

**User Story:** As a maintainer, I want the SSC rebuild to ship with real-flow
coverage, so the implementation proves the intended economics instead of only
passing synthetic unit tests.

#### Acceptance Criteria

1. THE implementation SHALL include real-flow tests for deposit, draw, repay,
   withdraw, and transfer behavior through Position NFTs.
2. THE implementation SHALL include tests proving maintenance pressure affects
   SSC line health over time.
3. THE implementation SHALL include tests proving both ACI routing modes:
   - yield mode accrues claimable ACI
   - self-pay mode reduces debt prospectively
4. THE implementation SHALL include tests proving mode switches settle first and
   apply only to future ACI.
5. THE implementation SHALL include tests proving deterministic service and
   terminal self-settlement behavior.
6. THE implementation SHALL include invariant or regression coverage proving
   same-asset debt, required lock, and canonical encumbrance stay aligned.
