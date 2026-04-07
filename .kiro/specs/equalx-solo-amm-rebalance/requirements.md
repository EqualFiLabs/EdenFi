# Requirements Document

## Introduction

This spec defines a bounded maker-controlled rebalance feature for **EqualX
Solo AMM** markets within EqualFi.

The feature allows a solo maker to intentionally move a live market's reserve
ratio without cancelling and recreating the market. The intended use case is
to let the maker off-price a pair, especially stable-oriented pairs, to invite
arbitrage and collect swap fees while keeping the market inside explicit,
auditable bounds.

This rebalance path must preserve the existing EqualX Solo AMM design goals:

- canonical position-backed capital
- low-gas taker swap execution
- explicit time-bounded lifecycle
- execution-faithful public state
- permissionless cleanup where practical

The rebalance path is intentionally maker-controlled, but it must be visible in
advance and mechanically bounded so takers, bots, and auditors can reason
about the upcoming reserve change.

## Glossary

- **Solo Rebalance**: A maker-controlled update that changes the live reserve
  targets of an active EqualX Solo AMM market.
- **Schedule Snapshot**: The market reserve state captured when a rebalance is
  scheduled and used to enforce the 10% movement bound.
- **Rebalance Timelock**: The minimum delay between scheduling a rebalance and
  when it becomes executable. Configured per market at creation, immutable
  after creation.
- **Rebalance Cooldown**: The minimum spacing between executed rebalances for a
  market. Equals the market's configured timelock.
- **Minimum Timelock Floor**: The protocol-enforced minimum timelock value.
  Prevents same-block or near-instant rebalances that would defeat
  transparency.
- **Rebalance Baseline**: The reserve baseline used for maker backing and
  close-time principal reconciliation after a rebalance executes.

## Requirements

### Requirement 1: Solo AMM Must Support Maker-Controlled Reserve Rebalancing

**User Story:** As a solo maker, I want to adjust a live market's reserve ratio
without cancelling it, so I can intentionally move price and stimulate
arbitrage-driven fee collection.

#### Acceptance Criteria

1. The EqualX Solo AMM module SHALL support a maker-controlled reserve
   rebalance path for active markets.
2. Only the owner of the maker Position NFT SHALL be able to schedule or
   cancel a rebalance for that market.
3. Rebalance execution SHALL be allowed without cancelling or finalizing the
   market.
4. Rebalance execution SHALL preserve the existing market identity, active
   status, fee configuration, and discovery indexes.

### Requirement 2: Rebalances Must Be Announced Before Execution

**User Story:** As a taker, bot, or auditor, I want reserve changes to be
announced before they execute, so I can observe and respond to the maker's
planned repricing.

#### Acceptance Criteria

1. Solo AMM rebalancing SHALL use a schedule-then-execute flow rather than a
   same-transaction reserve update.
2. A scheduled rebalance SHALL publish the target reserves and earliest
   execution time.
3. The rebalance timelock SHALL be configured per market at creation time.
4. The rebalance timelock SHALL be immutable after market creation.
5. The protocol SHALL enforce a minimum timelock floor (default 1 minute in
   v1) to prevent same-block or near-instant rebalances.
6. Governance SHALL be able to set the minimum timelock floor.
7. Rebalance execution SHALL be permissionless once the timelock has elapsed.
8. The maker SHALL be able to cancel a pending rebalance before execution.
9. The system SHALL support at most one pending rebalance per market at a
   time.

### Requirement 3: Rebalances Must Be Mechanically Bounded

**User Story:** As a protocol architect, I want each rebalance to stay within a
small explicit movement range, so maker-controlled repricing cannot jump
arbitrarily in one step.

#### Acceptance Criteria

1. Each reserve target in a scheduled rebalance SHALL remain within 90% to
   110% of that reserve's schedule snapshot amount.
2. The 10% bound SHALL be enforced against the schedule snapshot rather than
   against live reserves at execution time.
3. Rebalance execution SHALL NOT fail solely because the live reserve ratio or
   live reserve amounts drifted after scheduling.
4. A rebalance SHALL reject zero reserve targets.
5. A rebalance SHALL reject targets for expired, finalized, or inactive
   markets.

### Requirement 4: Rebalances Must Respect a Cooldown

**User Story:** As a taker or protocol operator, I want rebalances paced over
time, so makers cannot spam reserve updates too rapidly.

#### Acceptance Criteria

1. Solo AMM rebalances SHALL be subject to a cooldown between executions.
2. The rebalance cooldown SHALL equal the market's configured timelock.
3. The earliest execution time for a scheduled rebalance SHALL account for
   both the rebalance timelock and the cooldown since the last executed
   rebalance.
4. A maker SHALL be allowed to schedule a future rebalance during the cooldown
   period as long as execution cannot occur before the cooldown ends.

### Requirement 5: Rebalances Must Preserve Canonical Backing and Settlement

**User Story:** As a maintainer, I want manual reserve updates to compose with
EqualFi principal, encumbrance, and ACI accounting, so rebalance support does
not corrupt market settlement.

#### Acceptance Criteria

1. Reserve increases from a rebalance SHALL require sufficient settled
   available backing from the maker position at execution time.
2. Reserve decreases from a rebalance SHALL release backing capital safely at
   execution time.
3. Rebalances SHALL update canonical encumbrance and any related active-credit
   backing state consistently with the executed reserve delta.
4. Rebalances SHALL update the Solo AMM principal-settlement baseline so
   close-time principal reconciliation attributes only post-rebalance trading
   PnL to the market.
5. Rebalances SHALL NOT force per-swap principal reconciliation or tracked
   deposit churn.

### Requirement 6: Rebalances Must Be Observable Through Views, Events, and Tests

**User Story:** As an integrator or reviewer, I want rebalance state to be easy
to read and verify, so the feature is practical to consume and safe to change.

#### Acceptance Criteria

1. The system SHALL emit explicit events for rebalance scheduling,
   cancellation, and execution.
2. The EqualX view surface SHALL expose the pending rebalance state for a Solo
   AMM market.
3. Tests SHALL cover maker-only controls, 10% bounds, timelock behavior,
   cooldown behavior, execution by a non-maker, backing insufficiency on
   reserve increases, reserve release on decreases, and correct finalization
   after one or more rebalances.
4. Invariant or regression coverage SHALL confirm that rebalance support does
   not break reserve-to-encumbrance correctness or close-time principal
   settlement.
