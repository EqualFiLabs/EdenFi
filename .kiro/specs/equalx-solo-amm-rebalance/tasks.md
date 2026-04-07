# Tasks

## Task 1: Define the Solo AMM Rebalance State Model

- [x] 1. Add Solo AMM storage for pending rebalance state
  - [x] 1.1 Define a pending rebalance struct with snapshot reserves, target
        reserves, execute-after timestamp, and existence flag
  - [x] 1.2 Add last-executed rebalance timestamp tracking for each Solo AMM
        market
  - [x] 1.3 Add per-market `rebalanceTimelock` field (uint64, set at creation,
        immutable)
  - [x] 1.4 Add protocol-level `minRebalanceTimelock` to Solo AMM storage
        (governance-configurable, default 1 minute)
  - [x] 1.5 Replace or refactor creation-only reserve baseline fields into a
        mutable baseline used for close-time settlement
- [x] 2. Add storage-isolation coverage for any new Solo AMM storage layout

## Task 2: Add Rebalance Scheduling and Cancellation

- [x] 1. Implement maker-only rebalance scheduling for active Solo AMM markets
  - [x] 1.1 Require ownership of the maker Position NFT
  - [x] 1.2 Require the market to be active, started, and unexpired
  - [x] 1.3 Reject zero target reserves
  - [x] 1.4 Enforce the 10% per-side bound against the schedule snapshot
  - [x] 1.5 Compute `executeAfter` using the market's configured timelock and
        cooldown since the last executed rebalance
  - [x] 1.6 Store at most one pending rebalance per market
  - [x] 1.7 Emit a rebalance-scheduled event with snapshot and target reserves
- [x] 2. Implement maker-only cancellation of a pending rebalance
  - [x] 2.1 Delete the pending state cleanly
  - [x] 2.2 Emit a rebalance-cancelled event

## Task 3: Add Permissionless Rebalance Execution

- [x] 1. Implement permissionless rebalance execution after `executeAfter`
  - [x] 1.1 Require a pending rebalance to exist
  - [x] 1.2 Reject execution before the pending rebalance is ready
  - [x] 1.3 Execute the stored exact target reserves without re-checking live
        reserve drift against the 10% bound
- [x] 2. Apply reserve-delta backing changes safely
  - [x] 2.1 For reserve increases, settle position state and require
        sufficient available backing
  - [x] 2.2 For reserve increases, raise encumbered capital and active-credit
        backing by the reserve delta
  - [x] 2.3 For reserve decreases, release encumbered capital and
        active-credit backing by the reserve delta
  - [x] 2.4 Update live reserves and mutable settlement baselines to the
        executed targets
  - [x] 2.5 Record the last executed rebalance timestamp
  - [x] 2.6 Clear pending state and emit a rebalance-executed event

## Task 4: Preserve Correct Close-Time Settlement

- [x] 1. Refactor Solo AMM finalization to reconcile against the mutable
      baseline rather than the creation-time reserves
  - [x] 1.1 Unwind active-credit backing using the latest baseline values
  - [x] 1.2 Apply principal delta against the latest baseline values
  - [x] 1.3 Preserve existing fee-bucket realization semantics on finalization
- [x] 2. Confirm rebalance support does not force per-swap principal or deposit
      reconciliation

## Task 5: Add Rebalance Views and Selector Wiring

- [x] 1. Add a view for pending Solo AMM rebalance state
- [x] 2. Add any needed read of last rebalance execution timestamp or ready
      time
- [x] 3. Wire new selectors into the launch / diamond configuration
- [x] 4. Add deployment or selector regression coverage if the project uses it

## Task 6: Add Unit, Integration, and Invariant Coverage

- [x] 1. Add unit and live-flow tests for the rebalance lifecycle
  - [x] 1.1 Schedule succeeds for the maker and fails for non-owners
  - [x] 1.2 Schedule rejects targets outside the 10% bound
  - [x] 1.3 Cancel succeeds only for the maker
  - [x] 1.4 Execute is permissionless after the ready timestamp
  - [x] 1.5 Execute fails before the ready timestamp
  - [x] 1.6 Execute still succeeds after intervening swaps moved live reserves
  - [x] 1.7 Reserve increases fail when backing is insufficient
  - [x] 1.8 Reserve decreases release backing and allow subsequent withdrawal
        of newly freed capital
  - [x] 1.9 Preview and swap behavior reflect the new reserves immediately
  - [x] 1.10 Finalization after one rebalance settles principal correctly
  - [x] 1.11 Finalization after multiple rebalances settles principal correctly
  - [x] 1.12 Market creation rejects timelock below protocol minimum floor
  - [x] 1.13 Markets with different timelocks respect their own configured
        values
  - [x] 1.14 Cooldown equals the market's configured timelock
- [x] 2. Extend invariant or regression coverage
  - [x] 2.1 Live encumbered capital remains aligned with live market reserves
  - [x] 2.2 Active-credit backing changes only on create, rebalance, and close
  - [x] 2.3 Pending rebalance state is cleared on execution, cancellation, and
        market finalization
