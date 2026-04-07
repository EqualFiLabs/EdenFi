# Requirements Document

## Introduction

This spec defines a clean-break rewards architecture for EqualFi where:

- **EqualFi** remains the canonical substrate
- **EqualIndex** remains the canonical generic basket / index layer
- **stEVE** becomes the canonical product-specific lane currently carrying EDEN-branded product semantics
- **EDEN** becomes the canonical rewards engine and rewards-program layer

Nothing is live. Backwards compatibility is explicitly out of scope.

The goal is to avoid getting lost in naming or legacy shapes before implementation.
This spec therefore reserves:

- `stEVE` for product-specific token / product surfaces
- `EDEN` for the shared rewards engine

The EDEN rewards engine must support at least two consumer lanes:

1. `stEVE` PNFT-held principal
2. EqualIndex PNFT-held index principal for a specific `indexId`

The engine must not rely on mutable reward-token identity after liabilities are created.

## Glossary

- **EqualFi Substrate**: Shared base layer containing Position NFTs, `positionKey` accounting, pools, FI / ACI, encumbrance, governance, and other canonical primitives.
- **EqualIndex**: EqualFi’s canonical generic basket / index layer.
- **stEVE**: The canonical product-specific lane that replaces EDEN-as-product naming in code.
- **EDEN Rewards Engine**: The shared incentives layer that manages reward programs and reward liabilities.
- **Reward Program**: A funded campaign with a specific eligibility target, reward token, accrual schedule, and liability ledger.
- **Program Target**: The consumer lane a reward program points at, such as `stEVE` PNFT principal or EqualIndex PNFT-held principal for a specific `indexId`.
- **Position NFT / PNFT**: The ERC-721 account container used by EqualFi for position-owned balances.
- **positionKey**: The canonical `bytes32` identifier derived from a Position NFT.
- **Eligible Principal**: The settled PNFT-owned balance that participates in a specific reward program.
- **Reward Liability**: Rewards already accrued by positions, whether explicitly stored in per-position accrued balances or implicitly represented by reward-index deltas.
- **Program Epoch**: The bounded lifetime of a reward program with immutable reward-token identity.

## Requirements

### Requirement 1: EDEN Must Be the Shared Rewards Layer

**User Story:** As a protocol architect, I want EDEN to be the canonical rewards engine rather than a product-specific reward facet, so incentives can be reused across stEVE and EqualIndex without blurring product boundaries.

#### Acceptance Criteria

1. THE EDEN_Rewards_Engine SHALL be a shared protocol layer rather than a stEVE-only module.
2. THE EDEN_Rewards_Engine SHALL support at least `stEVE` and EqualIndex as first-class consumer lanes.
3. THE EDEN_Rewards_Engine SHALL NOT reintroduce EDEN as a generic basket / index layer.
4. THE EqualIndex_System SHALL remain the canonical generic basket / index lane.
5. Product-specific `stEVE` logic SHALL remain outside generic EDEN reward-program accounting wherever possible.

### Requirement 2: Naming Must Match the New Boundary

**User Story:** As a maintainer, I want names to map cleanly to architectural roles, so the codebase does not drift back into ambiguous EDEN-as-product and EDEN-as-rewards meanings.

#### Acceptance Criteria

1. Product-specific surfaces currently using EDEN naming SHALL be refactored toward `stEVE` naming.
2. Shared reward-program surfaces SHALL use `EDEN` or clearly rewards-engine-specific naming.
3. Public and internal naming SHALL avoid using `EDEN` to mean both the stEVE product lane and the rewards engine.
4. The resulting naming SHALL preserve the intended architecture: EqualFi substrate, EqualIndex generic layer, `stEVE` product lane, EDEN rewards engine.

### Requirement 3: Reward Programs Must Be Explicit and Targeted

**User Story:** As a project or governance actor, I want to create a reward program for a specific target, so rewards are attributable to one consumer lane and one eligibility base.

#### Acceptance Criteria

1. THE EDEN_Rewards_Engine SHALL support creation of explicit reward programs rather than one mutable global reward config.
2. Every reward program SHALL identify its target lane and target id.
3. THE system SHALL support a target for `stEVE` PNFT-held principal.
4. THE system SHALL support a target for EqualIndex PNFT-held principal scoped to a specific `indexId`.
5. THE reward-program model SHALL leave room for multiple programs over the same target without collapsing them into one liability bucket.

### Requirement 4: Reward Token Identity Must Be Bound to Liabilities

**User Story:** As a user, I want rewards earned under token A to remain claimable in token A, so governance cannot accidentally or intentionally swap liabilities into the wrong asset.

#### Acceptance Criteria

1. A reward program’s reward token SHALL be immutable once liabilities can begin accruing.
2. THE system SHALL NOT allow a mutable global reward token to serve already-created liabilities.
3. Reward liabilities SHALL remain attributable to the originating reward program.
4. Claims SHALL pay from the reward token associated with the originating reward program.
5. THE implementation SHALL prevent the M-01 class of bug where liabilities earned under one reward token become payable in another.

### Requirement 5: Accrual Must Use Program-Scoped Index Accounting

**User Story:** As a user, I want rewards to accrue pro rata over time without epoch scanning, so claims and previews stay deterministic and efficient.

#### Acceptance Criteria

1. Each reward program SHALL maintain its own cumulative reward index.
2. Each reward program SHALL maintain per-position checkpoints and accrued rewards.
3. Accrual SHALL be computed lazily on interaction using elapsed time, program rate, eligible supply, and funded reserve.
4. Reward settlement SHALL occur before any change to a position’s eligible balance for a program.
5. The accounting model SHALL avoid TWAB-epoch scanning.

### Requirement 6: Eligibility Must Be Position-Owned and Settled

**User Story:** As a protocol architect, I want the reward base to follow canonical PNFT-owned accounting, so rewards compose with existing substrate behavior and do not depend on duplicate balance ledgers.

#### Acceptance Criteria

1. The v1 EDEN_Rewards_Engine SHALL treat PNFT-owned balances as the canonical eligible base.
2. Wallet-held `stEVE` SHALL NOT earn rewards in the shared engine by default.
3. Wallet-held EqualIndex tokens SHALL NOT earn rewards in the shared engine by default.
4. EqualIndex reward eligibility SHALL be based on PNFT-held index principal for the specified `indexId`.
5. Eligibility SHALL use settled position-owned accounting rather than an unrelated mirrored balance when a canonical substrate balance already exists.

### Requirement 7: Funding and Emissions Must Be Explicit

**User Story:** As a program manager, I want reward funding and reward emissions to be explicit, so liabilities do not silently exceed funded capacity.

#### Acceptance Criteria

1. Reward programs SHALL support explicit funding separate from fee routing.
2. Reward accrual SHALL be bounded by funded capacity.
3. A program SHALL expose its funded reserve and remaining capacity.
4. Claims SHALL draw from program-owned funded assets.
5. The system SHALL avoid silently burning accrued rewards due to underfunding or token swaps.
6. Outbound fee-on-transfer reward tokens SHALL be supported through net-receipt liability accounting.
7. Reward programs SHALL allow an explicit outbound transfer-fee configuration when gross-up is required to satisfy net liabilities.

### Requirement 8: Lifecycle and Governance Must Be Program-Scoped

**User Story:** As governance or a delegated program manager, I want predictable lifecycle controls, so I can launch, pause, fund, stop, and retire reward programs without corrupting liabilities.

#### Acceptance Criteria

1. The system SHALL support explicit program creation, funding, pausing, resuming, and closure semantics.
2. Lifecycle changes SHALL be scoped to a specific reward program.
3. A program SHALL be closable only through a path that preserves or settles outstanding liabilities.
4. Governance and/or an authorized manager SHALL control privileged reward-program actions.
5. Lifecycle semantics SHALL not require a mutable token swap on an already-accruing program.

### Requirement 9: Consumer Hooks Must Be Defined Up Front

**User Story:** As an implementer, I want clear hook points for stEVE and EqualIndex, so reward settlement is correct across mint, burn, deposit, withdrawal, and recovery flows.

#### Acceptance Criteria

1. The EDEN_Rewards_Engine SHALL define the balance-changing transitions that must settle rewards before eligibility changes.
2. The `stEVE` lane SHALL include its PNFT deposit / withdraw and other reward-relevant position transitions.
3. The EqualIndex lane SHALL include position mint / burn and any recovery path that changes PNFT-held index principal.
4. Claim flows SHALL settle reward state before payout.
5. The spec SHALL define how consumer modules notify the rewards engine about eligibility changes.

### Requirement 10: Views Must Expose Program and Position State Clearly

**User Story:** As a frontend or agent, I want to inspect reward programs and position claims deterministically, so I can present accurate claimable balances and program metadata.

#### Acceptance Criteria

1. The system SHALL expose reward-program metadata and configuration.
2. The system SHALL expose per-program reserve, rate, timing, and enabled status.
3. The system SHALL expose per-position claimable and accrued state on a per-program basis.
4. The system SHALL expose preview functions for claims and pending accruals.
5. The view surface SHALL make program identity and reward-token identity explicit.

### Requirement 11: Tests Must Enforce the Liability Model

**User Story:** As a maintainer, I want the reward engine’s safety properties enforced by tests, so future refactors do not reintroduce reward-liability drift.

#### Acceptance Criteria

1. Tests SHALL prove liabilities remain payable in the originating reward token.
2. Tests SHALL prove reward accrual is bounded by funded reserve.
3. Tests SHALL prove concurrent programs over one target do not corrupt each other’s accounting.
4. Tests SHALL prove only eligible PNFT-owned balances accrue rewards.
5. Tests SHALL prove balance-changing hooks settle rewards before eligibility changes.
6. Tests SHALL prove program pause / closure semantics preserve claims.
