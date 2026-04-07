# Testing Guardrails

This note describes the expected balance between EqualFi’s test layers and records the final fake-flow review standard for future work.

## Expected Balance

### Unit harness tests

Use harness tests for:

- narrow branch coverage
- storage and arithmetic validation
- explicit status-machine transitions that are awkward to reach through setup
- isolated module behavior where the harness is not pretending to be an end-to-end product proof

Harness tests are supplemental. They should not be the only confidence layer for any value-moving lifecycle.

### Live integration tests

Use live integration or launch-level tests for:

- user approvals
- deposits and pool funding
- collateral encumbrance changes
- withdrawals, repayments, reclaims, and reward claims
- governance or timelock controls on deployed module state

Every value-moving module should have at least one live-flow or launch-level regression in this layer.

### Invariant / fuzz suites

Use invariant and fuzz suites for:

- state-machine breadth
- accounting invariants across many call sequences
- randomized coverage of transfer, settlement, reclaim, and churn behavior

Invariant coverage widens confidence, but it does not replace the live layer.

## No Fake Funding Rule

Do not seed funding, eligibility, principal, collateral, or pool membership state directly when the protocol already exposes a real flow.

Prefer:

- real token minting to test users
- real approvals
- real `depositToPosition`
- real `mintFromPosition`
- real user claims, withdrawals, and repayments
- real timelock or governance calls for controlled admin actions

Direct state injection is only acceptable when one of the following is true:

- the suite is intentionally smoke-only or storage-only
- the branch is unreachable through honest setup and exists only to validate accounting drift or defensive failure handling
- a pure status-machine transition is being tested in isolation and a live counterpart already exists elsewhere

When direct state injection is necessary, keep it small, comment it in the test, and ensure a real-flow or launch-level regression exists for the surrounding value-moving behavior.

## Final Review Pass

A final repository pass was run against common fake-flow helpers and direct state mutation patterns.

The remaining synthetic patterns are intentional and justified:

- `test/SubstratePort.t.sol`
  Synthetic library and accounting smoke only.
- `test/PositionSubstrate.t.sol`
  Synthetic substrate smoke only.
- `test/ManagedFeeRouting.t.sol`
  Synthetic subsystem coverage until a first-class live product path owns the same routing behavior.
- `test/EqualScaleAlphaFacet.t.sol`
  Retains direct `setPoolTrackedBalance`, `setLineStatus`, and `setLineCurrentCommittedAmount` only for explicit liquidity-drift and status-machine edge coverage. Real lender and borrower funding now uses deposits.

Patterns reviewed and accepted as real-flow helpers, not fake setup:

- `_joinPool(...)` in the options suites
  This uses the real `joinPositionPool` surface and does not fabricate principal.

Anything beyond the exceptions above should be treated as a regression unless it comes with a strong written justification and a corresponding live regression elsewhere.
