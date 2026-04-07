# Design Document

## Overview

This design extends **EqualX Solo AMM** with a bounded, timelocked, and
cooldown-gated rebalance mechanism.

The feature lets a maker intentionally move a live market's reserve ratio
without cancelling the market. The expected use case is to let the maker
off-price a market, attract arbitrageurs, and collect swap fees while keeping
reserve jumps visible and constrained.

The design intentionally preserves the existing EqualX Solo AMM hot path:

- taker swaps remain immediate and low-gas
- reserve-backed fee routing remains unchanged
- principal reconciliation remains deferred until close-time settlement

Rebalance actions are therefore treated as a separate cold-path lifecycle
operation rather than as part of the taker swap path.

## Design Goals

1. Preserve current Solo AMM swap-path gas and fee-routing behavior.
2. Allow maker-controlled repricing without cancelling the market.
3. Make rebalance intent visible ahead of execution.
4. Keep each rebalance mechanically bounded per reserve side.
5. Preserve canonical EqualFi backing, encumbrance, and ACI semantics.
6. Preserve correct close-time principal reconciliation after one or more
   rebalances.

## Non-Goals

This design does not:

- add automatic maker inventory management
- add oracle-based rebalancing guards
- re-check the 10% movement bound against live drift at execution time
- give takers a veto over a maker's scheduled rebalance
- change swap math, fee split policy, or market discovery semantics

## Product Semantics

### High-Level Model

Solo AMM rebalancing is a two-step lifecycle:

1. the maker schedules a rebalance with exact target reserves
2. anyone executes that rebalance after the market-specific ready time

The scheduled target reserves are public. The market remains active and
tradable during the waiting period. Swaps may move the live reserve ratio away
from the schedule snapshot during the timelock, but that drift does not cancel
or invalidate the scheduled rebalance.

This is intentional. The feature is maker-controlled. The public constraint is
that the maker's scheduled target reserves stayed within the 10% per-side bound
at schedule time.

### Timelock and Cooldown

The rebalance timelock is configured per market at creation and is immutable
afterward. This makes the timelock a visible, permanent property of the market
that takers and bots can factor into their risk model.

The protocol enforces a minimum timelock floor (default 1 minute in v1,
governance-configurable) to prevent same-block or near-instant rebalances that
would defeat the transparency purpose.

The cooldown between executed rebalances equals the market's configured
timelock. This keeps the pacing consistent: a market with a 1-minute timelock
can reprice once per minute; a market with a 15-minute timelock reprices once
per 15 minutes.

The next rebalance should become executable at:

```text
readyAt = max(block.timestamp + market.rebalanceTimelock, lastRebalanceExecutionAt + market.rebalanceTimelock)
```

A maker choosing a shorter timelock signals active management and competitive
pricing. A longer timelock signals passive management and more predictable
behavior. The market prices this in.

## API Surface

Representative external functions:

```solidity
function scheduleEqualXSoloAmmRebalance(
    uint256 marketId,
    uint256 targetReserveA,
    uint256 targetReserveB
) external;

function cancelEqualXSoloAmmRebalance(uint256 marketId) external;

function executeEqualXSoloAmmRebalance(uint256 marketId) external;
```

The `createEqualXSoloAmmMarket` function should accept an additional
`rebalanceTimelock` parameter (uint64, in seconds). The protocol should reject
values below the minimum timelock floor.

Representative events:

```solidity
event EqualXSoloAmmRebalanceScheduled(
    uint256 indexed marketId,
    bytes32 indexed makerPositionKey,
    uint256 snapshotReserveA,
    uint256 snapshotReserveB,
    uint256 targetReserveA,
    uint256 targetReserveB,
    uint64 executeAfter
);

event EqualXSoloAmmRebalanceCancelled(
    uint256 indexed marketId,
    bytes32 indexed makerPositionKey
);

event EqualXSoloAmmRebalanceExecuted(
    uint256 indexed marketId,
    bytes32 indexed makerPositionKey,
    uint256 previousReserveA,
    uint256 previousReserveB,
    uint256 newReserveA,
    uint256 newReserveB
);
```

Representative errors:

```solidity
error EqualXSoloAmm_RebalanceAlreadyPending(uint256 marketId);
error EqualXSoloAmm_NoPendingRebalance(uint256 marketId);
error EqualXSoloAmm_RebalanceNotReady(uint256 marketId, uint256 readyAt);
error EqualXSoloAmm_RebalanceZeroReserve();
error EqualXSoloAmm_RebalanceOutOfBounds(uint256 current, uint256 target);
```

## Storage Changes

### Market Storage

The current Solo AMM market stores immutable-looking `initialReserveA` and
`initialReserveB`, but rebalance support means the settlement baseline can no
longer stay creation-only.

The design should replace or conceptually rename those fields to a mutable
baseline:

```solidity
struct SoloAmmMarket {
    bytes32 makerPositionKey;
    uint256 makerPositionId;
    uint256 poolIdA;
    uint256 poolIdB;
    address tokenA;
    address tokenB;
    uint256 reserveA;
    uint256 reserveB;
    uint256 baselineReserveA;
    uint256 baselineReserveB;
    uint64 startTime;
    uint64 endTime;
    uint64 lastRebalanceExecutionAt;
    uint64 rebalanceTimelock;
    uint16 feeBps;
    FeeAsset feeAsset;
    InvariantMode invariantMode;
    ...
}
```

### Pending Rebalance Storage

Representative pending state:

```solidity
struct SoloAmmPendingRebalance {
    uint256 snapshotReserveA;
    uint256 snapshotReserveB;
    uint256 targetReserveA;
    uint256 targetReserveB;
    uint64 executeAfter;
    bool exists;
}
```

This can live in a dedicated mapping under `LibEqualXSoloAmmStorage` keyed by
`marketId`.

## Lifecycle Rules

### 1. Schedule

Scheduling a rebalance should:

1. require maker Position NFT ownership
2. require the market to exist, be active, be started, and be unexpired
3. reject zero target reserves
4. reject if a pending rebalance already exists
5. snapshot the current live reserves
6. require each target reserve to stay within `90%` to `110%` of its snapshot
7. compute `executeAfter` using the market's configured timelock and cooldown
8. store the pending rebalance
9. emit the schedule event

The 10% bound should be computed independently for each reserve side. A maker
may increase one reserve while decreasing the other, increase both, or decrease
both, as long as each side remains within the allowed range of its own
snapshot.

### 2. Cancel

Cancelling a rebalance should:

1. require maker Position NFT ownership
2. require a pending rebalance to exist
3. delete the pending rebalance
4. emit the cancellation event

### 3. Execute

Executing a rebalance should:

1. require the market to still exist, be active, be started, and be unexpired
2. require a pending rebalance to exist
3. require `block.timestamp >= executeAfter`
4. use the stored exact target reserves without re-checking against current
   live drift
5. settle and validate any required maker backing for reserve increases
6. release backing for reserve decreases
7. update the market reserve state to the scheduled targets
8. update the mutable settlement baseline to the executed targets
9. update `lastRebalanceExecutionAt`
10. clear the pending rebalance
11. emit the execution event

Execution should be permissionless. Once the maker has published a rebalance
plan and the delay has elapsed, anyone may land the state transition.

## Accounting Model

### Why the Existing Creation Baseline Is Not Enough

Current Solo AMM close-time settlement compares final reserves against the
market's creation-time reserve baseline. That works when only taker swaps move
reserves.

It does not work once a maker can manually add or remove backing mid-market.
Without a mutable settlement baseline, the close path would misinterpret maker
capital movements as trading PnL and incorrectly mint or burn principal during
finalization.

### Required Accounting Change

The Solo AMM implementation should treat `baselineReserveA` and
`baselineReserveB` as the maker-committed reserve baseline for:

1. active-credit backing tracked for the market
2. close-time principal reconciliation

The baseline is initialized at market creation and reset to the executed target
reserves on every successful rebalance execution.

### Reserve Increases

If a rebalance target increases a reserve side:

1. settle the maker position for that pool before checking availability
2. verify sufficient settled available principal exists
3. increase encumbered capital by the reserve delta
4. increase active-credit / backing state by the same delta
5. update the market reserve and baseline fields

### Reserve Decreases

If a rebalance target decreases a reserve side:

1. settle the maker position for that pool
2. decrease encumbered capital by the reserve delta
3. decrease active-credit / backing state by the same delta
4. update the market reserve and baseline fields

This operation should not touch tracked balance, total deposits, or principal
at execution time. Those remain deferred until market close, just like today.

### Finalization After Rebalances

At finalization:

1. the live reserves still represent the terminal trading state
2. maker fees and protocol fee buckets are still handled as today
3. principal delta should be measured against the latest mutable baseline
   rather than the creation-time reserves
4. active-credit / backing unwind should also use the latest mutable baseline

This preserves the intended economic meaning:

- maker-controlled rebalances move committed backing
- taker swaps after the most recent rebalance generate trading PnL
- close-time settlement realizes only that post-baseline trading result

## View Surface

The view facet should expose the pending rebalance state for a Solo AMM market.

Representative read shape:

```solidity
struct EqualXSoloAmmPendingRebalanceView {
    bool exists;
    uint256 snapshotReserveA;
    uint256 snapshotReserveB;
    uint256 targetReserveA;
    uint256 targetReserveB;
    uint64 executeAfter;
}
```

Representative read:

```solidity
function getEqualXSoloAmmPendingRebalance(uint256 marketId)
    external
    view
    returns (EqualXSoloAmmPendingRebalanceView memory pending);
```

This view is primarily for frontend, bot, and monitoring use.

## Testing Strategy

### Unit and Integration Coverage

The implementation should add tests for:

1. maker-only schedule and cancel permissions
2. permissionless execute after readiness
3. rejection of zero reserves
4. rejection of targets outside the 10% per-side schedule bound
5. scheduling during cooldown with delayed `executeAfter`
6. rejection of execute before `executeAfter`
7. success of execute even if live reserves drifted materially after schedule
8. backing insufficiency on reserve increases
9. reserve release and withdrawal freedom after reserve decreases
10. correct quote behavior immediately after execution
11. correct final principal settlement after one rebalance
12. correct final principal settlement after multiple rebalances

### Invariant Focus

Invariant or regression coverage should prove:

1. live market reserves still match live encumbered capital
2. rebalance execution changes active-credit / backing only by maker-directed
   reserve deltas, not by swap deltas
3. finalization after rebalances never double-counts maker capital movements
4. pending rebalance state cannot survive market finalization

## Security Notes

1. The 10% bound is a per-schedule constraint, not a total cumulative drift
   limit. Repeated rebalances can move the market further over time by design.
2. Because execution is permissionless, the execute path should avoid any
   dependence on `msg.sender` privileges beyond normal market validity checks.
3. The rebalance path must not bypass canonical ownership checks, pool
   membership assumptions, or settled-backing validation.
4. The implementation should avoid accidentally treating rebalance deltas as
   swap fees or swap output.
5. The per-market timelock is immutable after creation. This prevents a maker
   from attracting takers with a long timelock and then shortening it.
6. The protocol-enforced minimum timelock floor prevents same-block
   rebalances that would be invisible to takers.
