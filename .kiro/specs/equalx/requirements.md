# Requirements Document

## Introduction

This spec defines a greenfield **EqualX** architecture for EqualFi.

EqualX is the branded market layer that will replace the older Synthesis-era
auction and curve stack without preserving its ABI, API, storage layout, or
facet boundaries.

The intended EqualX surface includes three distinct but related modules:

1. **Solo AMM**: one maker position provisions two-sided liquidity into a
   time-bounded auction AMM.
2. **Community AMM**: multiple maker positions pool two-sided liquidity into a
   shared auction AMM with indexed fee distribution.
3. **Curve Liquidity**: maker positions publish time-bounded liquidity curves
   with explicit pricing profiles and commitment guards.

The goal is to preserve the valuable mechanics and invariants from the older
EqualFi derivative system while rebuilding them around the cleaner modern
EqualFi substrate:

- Position NFTs and `positionKey`
- pool membership
- canonical settled principal
- FI / ACI / maintenance settlement
- encumbrance
- native / ERC20 currency handling

Backwards compatibility is explicitly out of scope.

## Glossary

- **EqualFi Substrate**: The canonical base layer containing pools, positions,
  Position NFTs, `positionKey`, settlement indexes, encumbrance, governance,
  and currency primitives.
- **EqualX**: The branded market layer for auction-style and curve-style
  liquidity modules built on EqualFi.
- **Solo AMM**: A market where one maker position supplies both sides of the
  inventory and takers swap against that bounded liquidity.
- **Community AMM**: A market where multiple maker positions contribute
  inventory to the same pooled AMM and share fees by indexed ownership.
- **Curve Liquidity**: A time-bounded market where price is derived from a
  configured pricing profile rather than a reserve ratio.
- **Maker Position**: The Position NFT whose settled principal is locked or
  encumbered to back an EqualX market.
- **Taker**: The account swapping against EqualX liquidity.
- **Pricing Profile**: A rule or plugin that determines curve price as a
  function of time and parameters.
- **Commitment Guard**: A generation or commitment hash check that prevents
  takers from executing against stale curve assumptions.

## Requirements

### Requirement 1: EqualX Must Be a First-Class EqualFi Module

**User Story:** As a protocol architect, I want EqualX to be a branded but
architecturally clean market layer, so the old auction code can be ported
without dragging legacy naming or storage sprawl into the new EqualFi tree.

#### Acceptance Criteria

1. THE EqualX_System SHALL be a dedicated module family within EqualFi.
2. THE EqualX_System SHALL NOT preserve the older Synthesis facet or storage
   layout by default.
3. THE EqualX_System SHALL reuse current EqualFi substrate primitives wherever
   practical.
4. THE EqualX_System SHALL remain distinct from EDEN rewards, EqualIndex, and
   stEVE product code.

### Requirement 2: EqualX Must Separate Market Types Cleanly

**User Story:** As a maintainer, I want solo AMM, community AMM, and curve
liquidity to be distinct modules, so each state machine can evolve without
collapsing into one oversized derivative blob.

#### Acceptance Criteria

1. THE EqualX_System SHALL model Solo AMM as its own market type.
2. THE EqualX_System SHALL model Community AMM as its own market type.
3. THE EqualX_System SHALL model Curve Liquidity as its own market type.
4. THE system SHALL NOT treat curve liquidity as merely a flag on the AMM
   auction model.
5. Shared helpers MAY exist, but storage and state transitions SHALL remain
   market-type specific.

### Requirement 3: Markets Must Be Backed by Canonical Position-Owned Capital

**User Story:** As a protocol architect, I want EqualX markets to lock or
   encumber canonical settled principal from Position NFTs, so market backing
   remains consistent with EqualFi lending and maintenance rules.

#### Acceptance Criteria

1. Every EqualX maker market SHALL identify a backing maker Position NFT.
2. Every EqualX market SHALL derive maker identity through canonical
   `positionKey` ownership.
3. Capital used to back EqualX markets SHALL come from settled principal or
   other canonical substrate-owned balances.
4. EqualX SHALL use encumbrance or direct locking rules that compose with the
   EqualFi substrate rather than shadow ledgers where possible.
5. Any path that changes effective backing principal SHALL maintain EqualX
   invariants and prevent silent undercollateralization.
6. EqualX maker backing that is encumbered in-pool SHALL remain part of the
   canonical ACI / encumbrance model unless a market type explicitly defines an
   opt-out.

### Requirement 4: Solo AMM Must Support Time-Bounded Two-Sided Liquidity

**User Story:** As a maker, I want to post a bounded two-sided AMM backed by my
position, so takers can trade against my inventory during a defined time window.

#### Acceptance Criteria

1. Solo AMM markets SHALL bind exactly one maker position to one market.
2. A Solo AMM market SHALL define two backing pools or assets.
3. A Solo AMM market SHALL define start and end timestamps.
4. A Solo AMM market SHALL define fee terms and fee asset behavior.
5. A Solo AMM market SHALL support at least volatile invariant math in v1.
6. A Solo AMM market SHALL support stable invariant math when enabled and when
   token decimal constraints are satisfied.
7. A Solo AMM market SHALL support permissionless finalization or expiry
   cleanup.
8. A Solo AMM market SHALL keep the taker swap hot path low-gas by avoiding
   principal and deposit reconciliation on each swap.
9. A Solo AMM market SHALL continue to accrue treasury, active-credit, and
   fee-index effects on each swap even when principal reconciliation is
   deferred.

### Requirement 5: Community AMM Must Support Multi-Maker Fee Sharing

**User Story:** As a maker, I want to join a shared community AMM and receive my
pro rata fee share, so multiple PNFTs can pool liquidity without manual fee
   splitting.

#### Acceptance Criteria

1. Community AMM markets SHALL support multiple maker positions.
2. Community AMM markets SHALL track maker ownership through indexed shares.
3. Fee distribution SHALL be claimable or settleable per maker without looping
   all makers on every swap.
4. Community AMM makers SHALL be able to join before start under explicit ratio
   rules.
5. Community AMM makers SHALL be able to leave through a path that preserves
   fee and principal accounting.
6. Community AMM finalization SHALL not require privileged operator action.
7. A Community AMM market SHALL keep the taker swap hot path low-gas by
   avoiding full principal and share-backing reconciliation on each swap.
8. Community AMM SHALL still accrue treasury, active-credit, fee-index, and
   community maker-fee index effects on each swap.

### Requirement 6: Curve Liquidity Must Support Profile-Driven Pricing

**User Story:** As a maker, I want to publish time-bounded liquidity curves with
profile-driven pricing and update guards, so I can expose concentrated or
   shaped liquidity without an AMM reserve invariant.

#### Acceptance Criteria

1. Curve Liquidity SHALL support explicit pricing descriptors.
2. Curve Liquidity SHALL support at least one built-in pricing profile in v1.
3. Curve Liquidity SHALL support governance-approved custom profile plugins.
4. v1 SHALL ship with the default linear built-in profile only unless a later
   approved change explicitly adds more built-ins.
5. Curve execution SHALL validate generation or commitment state so takers
   cannot fill stale quotes after maker updates.
6. Curve Liquidity SHALL support cancellation, expiry, and partial fills.
7. Curve Liquidity SHALL track remaining executable volume explicitly.
8. Curve Liquidity base-side backing SHALL participate in the same canonical
   ACI / encumbrance model used by other EqualX maker backing unless an
   explicit exception is approved later.

### Requirement 7: Swap Math and Fee Policy Must Be Explicit

**User Story:** As a taker or auditor, I want EqualX swap math and fee routing
to be explicit, so quotes, execution, and accounting remain deterministic.

#### Acceptance Criteria

1. EqualX SHALL centralize reusable swap math helpers where appropriate.
2. EqualX SHALL make fee-asset semantics explicit, including `TokenIn` and
   `TokenOut` style behavior where supported.
3. EqualX SHALL apply maker fee allocation against the gross swap fee before
   routing the remaining protocol fee.
4. EqualX SHALL route the protocol-fee remainder through the canonical EqualFi
   fee router rather than duplicating treasury, active-credit, and fee-index
   split logic ad hoc.
5. EqualX SHALL make maker, treasury, active-credit, fee-index, and protocol
   fee routing explicit rather than implicit.
6. Treasury allocation produced by the routed protocol remainder SHALL be
   transferred on each swap, consistent with the intended `../EqualFi` runtime
   behavior.
7. Active-credit and fee-index accruals SHALL come from the routed
   protocol-fee remainder rather than from the gross swap fee.
8. Preview paths SHALL match execution semantics.
9. Stable-mode support SHALL validate decimal assumptions and fail safely when
   unsupported.
10. Solo AMM and Community AMM swap execution SHALL preserve the older
    low-gas runtime pattern from `../EqualFi` where:
    - reserve deltas are applied on each swap
    - treasury, active-credit, and fee-index effects are applied on each swap
    - principal reconciliation is deferred until market close or maker exit
11. EqualX SHALL use transient swap-cache style helpers in hot swap paths where
    they materially reduce repeated state reads or argument passing costs.
12. EqualX AMM hot paths SHALL preserve reserve-backed fee routing semantics
    equivalent to `routeSamePool(..., false, extraBacking)` where the routed
    protocol remainder is backed by live market reserves rather than by
    immediate tracked-principal churn.

### Requirement 8: Lifecycle Must Be Permissionless Where Practical

**User Story:** As a protocol architect, I want market cleanup and expiry to be
permissionless, so EqualX does not depend on an operator to transition stale
markets.

#### Acceptance Criteria

1. EqualX markets SHALL expose explicit active, expired, finalized, paused, or
   cancelled states as appropriate to their market type.
2. Expiry and finalization paths SHALL be callable by anyone when they are
   economically or operationally necessary.
3. Lifecycle transitions SHALL preserve backing and fee accounting.
4. Pausing or disabling creation SHALL not strand existing claims or locked
   inventory.
5. The design SHALL respect the onchain rule that nothing executes
   automatically.

### Requirement 9: Views Must Be Program-Native and Agent-Friendly

**User Story:** As a frontend or agent, I want accurate quote, market, and
position views, so EqualX can be safely integrated without reconstructing state
offchain from events alone.

#### Acceptance Criteria

1. EqualX SHALL expose market metadata and state per market type.
2. EqualX SHALL expose quote and preview functions that match execution.
3. EqualX SHALL expose maker-specific participation state where relevant.
4. EqualX SHALL expose discovery by position, pair, and other useful keys where
   appropriate.
5. View APIs SHALL make market identity and backing state explicit.

### Requirement 10: Native ETH and ERC20 Handling Must Follow Substrate Rules

**User Story:** As an integrator, I want EqualX currency handling to follow
current EqualFi substrate rules, so native ETH support does not fork into
special ad hoc logic.

#### Acceptance Criteria

1. EqualX SHALL use canonical EqualFi currency helpers for native ETH and ERC20
   handling.
2. Native ETH support SHALL be allowed only where the underlying pool and
   substrate rules already support it.
3. EqualX SHALL NOT introduce bespoke native-asset logic when the substrate
   already provides the necessary behavior.
4. Quote and execution semantics SHALL remain consistent between native and
   ERC20 assets.

### Requirement 11: Testing Must Preserve the Valuable Old Invariants

**User Story:** As a maintainer, I want the old Synthesis safety properties
ported as modern tests and invariants, so the greenfield rewrite preserves the
hard-won correctness of the earlier system.

#### Acceptance Criteria

1. EqualX SHALL port the meaningful solo AMM invariants from the older system.
2. EqualX SHALL port the meaningful community fee-index invariants from the
   older system.
3. EqualX SHALL port the meaningful curve generation and commitment invariants
   from the older system.
4. Ported invariants SHALL be rewritten against live EqualFi flows rather than
   setter-only harnesses wherever practical.
5. Tests SHALL cover maintenance, encumbrance, fee routing, and preview /
   execution parity.
