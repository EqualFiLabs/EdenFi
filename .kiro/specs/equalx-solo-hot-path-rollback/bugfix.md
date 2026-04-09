# Bugfix Requirements Document

## Introduction

This spec defines a targeted **EqualX Solo AMM** redesign for EqualFi that
restores a low-gas taker hot path without giving up live fee claimability.

It is a new canonical Track E spec, not a duplicate of
`equalx-findings-1-5-remediation`. That earlier spec fixed swap-time Solo AMM
accounting by making pool backing and ACI fully live on every swap. This new
track intentionally revisits that choice after gas benchmarking showed the Solo
hot path is too expensive for the product target.

Canonical track: **Track E — EqualX AMM Correctness**  
Phase: **Phase 3 — architectural / hot-path redesign**  
Primary sources:

- `.kiro/specs/equalx-findings-1-5-remediation/`
- `.kiro/specs/equalx-solo-amm-rebalance/`
- current swap-only gas benchmarks in `test/EqualXSoloAmmFacet.t.sol`

Dependencies:

- `.kiro/specs/equalfi-native-tracking-remediation/`
- `.kiro/specs/equalfi-aci-encumbrance-consistency/`
- `.kiro/specs/equalfi-fee-routing-accounting-cleanup/`

## Bug Analysis

### Current Behavior (Defect)

**Finding 1 — Solo swap hot path performs full ACI synchronization**

1.1 WHEN `swapEqualXSoloAmmExactIn` changes live reserves THEN
`_applyReserveDelta` mutates both `enc.encumberedCapital` and
`activeCreditPrincipalTotal` via `LibActiveCreditIndex.applyEncumbranceIncrease`
or `applyEncumbranceDecrease`

1.2 WHEN active-market reserve drift is applied to ACI on every swap THEN the
Solo hot path pays for settlement-sensitive substrate work that is not required
to keep fee claims live

1.3 WHEN the current Solo swap-only gas benchmark is measured THEN it lands far
above the product target of ~`200k`, with the current representative benchmark
roughly `443k`

**Finding 2 — Live fee claimability is coupled to the expensive part of swap-time accounting**

1.4 WHEN protocol fees are routed on Solo swaps THEN the current
implementation keeps both live fee backing and live ACI synchronization in the
same hot path, even though old EqualFi live yield claimability depended on fee
backing and fee-index accrual, not on per-swap ACI sync

**Finding 3 — Rebalance and close currently assume ACI always matches live reserve**

1.5 WHEN `executeEqualXSoloAmmRebalance` runs THEN ACI deltas are computed from
`previousReserve -> targetReserve`, which only makes sense if swap-time ACI has
already followed every live reserve movement

1.6 WHEN `_closeMarket` runs THEN it unlocks live encumbered capital and also
unwinds ACI by the full live reserve, which likewise assumes ACI stayed
perfectly synchronized during every active-market swap

### Expected Behavior (Correct)

**Finding 1 — Solo swap should keep live fee backing but defer ACI synchronization**

2.1 WHEN a Solo AMM swap executes THEN the system SHALL continue to route
protocol fees live through `LibFeeRouter.routeSamePool(...)`

2.2 WHEN a Solo AMM swap routes non-treasury protocol fees THEN the system
SHALL continue to recognize live fee backing (`trackedBalance`,
`nativeTrackedTotal`, fee-index backing, and yield reserve backing) so users
can still claim yield while the market is active

2.3 WHEN a Solo AMM swap changes reserves THEN the system SHALL continue to
update live `enc.encumberedCapital` so withdrawal blocking and live backing
availability remain correct

2.4 WHEN a Solo AMM swap changes reserves THEN the system SHALL NOT call
`LibActiveCreditIndex.applyEncumbranceIncrease(...)` or
`applyEncumbranceDecrease(...)` from the taker hot path

2.5 WHEN a Solo market is active between lifecycle boundaries THEN
`activeCreditPrincipalTotal` MAY intentionally lag live reserve and SHALL be
treated as a boundary-synced value, not a live-swap value

**Finding 2 — Rebalance and finalize should become the ACI synchronization boundaries**

2.6 WHEN `executeEqualXSoloAmmRebalance` runs THEN the system SHALL:

- adjust live encumbered capital from `previousReserve -> targetReserve`
- adjust ACI from the last synced baseline reserve -> `targetReserve`
- update the synced baseline to `targetReserve`

2.7 WHEN `_closeMarket` runs THEN the system SHALL:

- unlock live reserve backing using the current live reserve
- unwind ACI using the last synced baseline reserve, not the live reserve
- reconcile principal using `reserveForPrincipal` against the synced baseline

2.8 WHEN a Solo market is cancelled before start or finalized after expiry THEN
the system SHALL clear both live encumbrance and boundary-synced ACI state
cleanly without requiring swap-time ACI synchronization

**Finding 3 — The redesign should materially reduce Solo swap gas**

2.9 WHEN the Solo swap-only benchmark is rerun after the redesign THEN the
measured hot path SHALL be materially lower than the current `~443k` baseline
and the repo SHALL record the new benchmark versus the `~200k` product target

### Unchanged Behavior (Regression Prevention)

3.1 WHEN a Solo AMM swap executes THEN swap output math, fee split math,
slippage checks, stable/volatile invariant behavior, treasury routing, maker
fee accrual, and recipient payout SHALL remain unchanged

3.2 WHEN protocol fees are routed on a Solo AMM swap THEN live fee claims SHALL
remain possible during the active market without requiring finalize

3.3 WHEN a Solo market is active THEN the maker's live encumbered capital SHALL
continue to track live reserves so pool withdrawals remain blocked correctly

3.4 WHEN a Solo rebalance executes THEN the existing maker-only scheduling,
permissionless execution, timelock, cooldown, and reserve-bound semantics SHALL
remain unchanged

3.5 WHEN a Solo market finalizes THEN principal reconciliation SHALL continue to
attribute market PnL against the mutable baseline reserve, not against creation
reserves

3.6 WHEN Community AMM or Curve swap paths execute THEN their semantics SHALL
remain unchanged by this Solo-only redesign; later Community-specific gas work,
if any, is out of scope for this spec

## Non-Goals

This spec does not:

- remove live fee routing from Solo swaps
- change EqualX fee split policy
- change Solo swap math or pricing behavior
- redesign Community AMM or Curve accounting
- require `activeCreditPrincipalTotal` to equal live reserve during an active
  Solo market
- guarantee the final Solo gas number reaches `200k` in this spec alone
