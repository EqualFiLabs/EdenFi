# EqualX Solo Hot-Path Rollback — Bugfix Design

## Overview

This design rolls **EqualX Solo AMM** back to a lower-gas accounting model
without restoring the old correctness bugs.

The key design choice is to separate two concerns that the current EqualFi Solo
implementation performs together on every swap:

- **live fee backing** so users can claim fee-derived yield during an active
  market
- **ACI synchronization** so `activeCreditPrincipalTotal` always matches live
  reserve

The redesign keeps the first behavior live and defers the second behavior to
explicit lifecycle boundaries.

## Glossary

- **Live Reserve**: `market.reserveA` / `market.reserveB`, the real pricing and
  payout state used by swaps.
- **Live Encumbrance**: `enc.encumberedCapital`, which continues to follow live
  reserve to preserve withdrawal blocking and maker backing availability.
- **Boundary-Synced ACI**: `activeCreditPrincipalTotal` after create,
  rebalance, or finalize, but not necessarily after every swap.
- **Synced Baseline**: `market.baselineReserveA` / `market.baselineReserveB`,
  the reserve amounts that last synchronized ACI and that anchor close-time
  principal reconciliation.
- **Live Fee Backing**: immediate `trackedBalance`, `nativeTrackedTotal`,
  fee-index, and reward-backing recognition from routed protocol fees.

## Why A New Spec Exists

The already-landed `equalx-findings-1-5-remediation` spec treated live swap
reserve changes and live ACI synchronization as one invariant. That was a
reasonable correctness-first fix, but the resulting Solo hot path is too
expensive for the product target.

This spec intentionally supersedes only that swap-time ACI decision. It does
not reopen the rest of the EqualX findings work.

## Root Cause

The current Solo hot path conflates:

1. value that really becomes claimable immediately because the tokens already
   sit in the same pool after the swap, and
2. substrate state that only needs to be exact at lifecycle boundaries.

Old `../EqualFi/` live yield claimability came from live fee routing and fee
index / yield reserve accrual, not from per-swap ACI reserve synchronization.
EqualFi preserved live claims but also made ACI exact on every swap, which is
the expensive part we now want to remove.

## Design Goals

1. Preserve live Solo yield claimability during active markets.
2. Preserve live encumbrance-based withdrawal blocking.
3. Remove per-swap ACI synchronization from the taker hot path.
4. Keep rebalance and finalize as the authoritative ACI synchronization
   boundaries.
5. Preserve current reserve pricing and close-time principal semantics.
6. Deliver a materially lower Solo swap gas benchmark than the current
   `~443k`.

## Non-Goals

This design does not:

- move Solo to a claim-after-finalize-only fee model
- remove live `trackedBalance` recognition for fee-routed backing
- change Community AMM or Curve accounting
- redesign EqualX fee policy or swap previews
- require ACI views to mirror live reserve on every block

## Product Semantics

### High-Level Model

Solo AMM will use three accounting layers:

1. **live reserve state**
   - used for swap pricing and payout
2. **live encumbrance state**
   - used for backing availability and withdrawal blocking
3. **boundary-synced ACI state**
   - used for active-credit weighting and synchronized only on create,
     rebalance, and finalize/cancel

This means an active market may intentionally have:

```text
live reserve != boundary-synced ACI reserve
```

That divergence is expected, temporary, and ends at the next lifecycle
boundary.

### Swap Semantics

On `swapEqualXSoloAmmExactIn(...)`:

- keep current token pull, quote math, fee split, treasury routing, maker fee
  accrual, and recipient payout
- keep live `trackedBalance` / `nativeTrackedTotal` recognition for the routed
  fee portion
- keep live `enc.encumberedCapital` updates from `previousReserve ->
  newReserve`
- do **not** call `LibActiveCreditIndex.applyEncumbranceIncrease/Decrease` from
  swap-time reserve changes

### Live Yield Claims

Users can still claim yield during an active Solo market because claimability
comes from live fee routing and fee backing, not from ACI reserve sync.

That means this redesign keeps:

- `LibFeeRouter.routeSamePool(...)`
- live `trackedBalance` increments for non-treasury routed fees
- live `nativeTrackedTotal` increments when applicable
- existing fee-index settlement behavior

### Rebalance Semantics

On `executeEqualXSoloAmmRebalance(...)`:

- live encumbrance moves from `previousReserve -> targetReserve`
- ACI moves from `baselineReserve -> targetReserve`
- `baselineReserve` is then updated to `targetReserve`

This preserves the existing maker-controlled rebalance feature while moving ACI
work off the swap path and onto the cold path.

### Finalize / Cancel Semantics

On `_closeMarket(...)`:

- unlock live reserve backing using `market.reserveA/B`
- settle ACI and unwind it using `baselineReserveA/B`
- compute `reserveForPrincipal` from live reserve net of protocol fees
- reconcile principal against `baselineReserveA/B`

This is the important split:

- **encumbrance unwind uses live reserve**
- **ACI unwind uses synced baseline**
- **principal reconciliation uses live reserve vs synced baseline**

## Storage Model

No new storage is required if `baselineReserveA/B` remains the canonical
boundary-synced reserve.

That field now has two linked meanings:

- the close-time principal baseline
- the last ACI-synced reserve

This is acceptable because rebalance execution should update both together.

## Required Code Changes

### 1. Remove swap-time ACI synchronization

File: `src/equalx/EqualXSoloAmmFacet.sol`

Function: `_applyReserveDelta`

Changes:

- keep the existing live `enc.encumberedCapital` increase / decrease logic
- remove the calls to:
  - `LibActiveCreditIndex.applyEncumbranceIncrease(...)`
  - `LibActiveCreditIndex.applyEncumbranceDecrease(...)`

### 2. Keep live fee routing untouched

File: `src/equalx/EqualXSoloAmmFacet.sol`

Function: `swapEqualXSoloAmmExactIn`

Changes:

- keep `LibFeeRouter.routeSamePool(...)`
- keep `_accrueProtocolFees(...)`
- keep live `feePool.trackedBalance += toActive + toFeeIndex`
- keep native tracked total increments for native fee pools

### 3. Change rebalance ACI synchronization to use the synced baseline

File: `src/equalx/EqualXSoloAmmFacet.sol`

Function: `_applyExecutedRebalanceDelta`

Changes:

- live encumbrance delta should continue to use `previousReserve ->
  targetReserve`
- ACI delta should use `baselineReserve -> targetReserve`
- `market.baselineReserveA/B = targetReserveA/B` after execution

Representative model:

```text
enc delta: live previous -> live target
aci delta: synced baseline -> live target
baseline := live target
```

### 4. Change close-time ACI unwind to use the synced baseline

File: `src/equalx/EqualXSoloAmmFacet.sol`

Function: `_closeMarket`

Changes:

- keep `_unlockReserveBacking(..., market.reserveA/B)`
- replace `applyEncumbranceDecrease(..., market.reserveA/B)` with baseline-based
  ACI unwind
- keep principal delta against `reserveForPrincipal` vs `baselineReserveA/B`

Representative model:

```text
unlock encumbrance: live reserve
unwind ACI: synced baseline reserve
apply principal delta: reserveForPrincipal vs synced baseline reserve
```

## Correctness Properties

Property 1: Solo swaps keep live fee claims but do not mutate ACI

For any active Solo swap that changes reserves and routes protocol fees, the
fixed code SHALL keep fee backing live while leaving
`activeCreditPrincipalTotal` unchanged by the swap itself.

Property 2: Live encumbrance remains aligned with live reserve

For any active Solo swap, the maker's `enc.encumberedCapital` SHALL continue to
track the live reserve delta exactly.

Property 3: Rebalance resynchronizes ACI at the boundary

For any executed Solo rebalance, the fixed code SHALL make ACI equal the new
target reserve by applying the delta from the last synced baseline, then update
that baseline.

Property 4: Finalize clears both live and boundary-synced state

For any finalized or cancelled Solo market, the fixed code SHALL fully unlock
live reserve backing, fully unwind the baseline-synced ACI amount, and
reconcile principal against the synced baseline.

Property 5: Gas direction improves materially

For the existing swap-only benchmark, the fixed Solo hot path SHALL measure
meaningfully below the current `~443k` baseline, with the remaining gap to the
`~200k` target documented.

## Testing Strategy

### Tests That Should Change

The prior EqualX bug-condition test that asserted swap-time ACI sync is no
longer the right expectation under this design. It should be replaced, not
preserved.

### New Bug-Condition / Redesign Tests

1. active Solo swap changes live reserve and encumbrance but does **not**
   change `activeCreditPrincipalTotal`
2. active Solo swap still allows live fee claim while the market remains open
3. rebalance syncs ACI from baseline to target even after intervening swaps
4. finalize/cancel clears live encumbrance and baseline-synced ACI correctly
5. gas benchmark records the new swap-only number against the old `~443k`
   baseline and the `~200k` target

### Preservation Tests

Preserve:

- Solo preview and swap output
- fee split and treasury routing
- live claimability while active
- withdrawal blocking from live encumbrance
- rebalance scheduling, bounds, timelock, and cooldown
- close-time principal reconciliation
- Community and Curve behavior

