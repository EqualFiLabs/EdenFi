# Rename Map

## Purpose

This document maps the current EDEN-branded codebase to the intended greenfield
naming boundary:

- **EqualFi** = substrate / protocol umbrella
- **EqualIndex** = generic basket / index layer
- **stEVE** = product lane
- **EDEN** = shared rewards engine

The point is not cosmetic cleanup. The point is to stop using `EDEN` to mean
both the product lane and the rewards engine.

Status:

- Accepted as the source-of-truth rename boundary for the rewards-engine refactor

## Naming Rules

1. Product-specific contracts, libraries, tests, and deploy helpers move toward `stEVE` naming.
2. Shared reward-program contracts and libraries keep or gain `EDEN` naming.
3. EqualIndex keeps its current naming.
4. Neutral shared substrate utilities should stay neutral and not be renamed just to match branding.

## Directory Target

### Contracts

- Shared rewards-engine contracts stay under `src/eden/`
- Product-specific contracts move from `src/eden/` to `src/steve/`

This yields the cleanest final code shape:

- `src/eden/` = EDEN rewards engine
- `src/steve/` = stEVE product lane
- `src/equalindex/` = EqualIndex

## Final Rename Map

### Rewards Engine Contracts

These should keep EDEN branding because they become the shared rewards engine.

| Current | Target | Why |
|---|---|---|
| `src/eden/EdenRewardFacet.sol` | `src/eden/EdenRewardsFacet.sol` | Shared EDEN rewards engine, not a stEVE-only reward facet |
| `src/libraries/LibEdenRewardStorage.sol` | `src/libraries/LibEdenRewardsStorage.sol` | Storage belongs to the EDEN rewards engine |
| `src/libraries/LibEdenRewards.sol` | `src/libraries/LibEdenRewardsEngine.sol` | Shared engine logic should read as engine-level logic, not product helper logic |

### stEVE Product Contracts

These are product-lane modules and should stop using EDEN branding.

| Current | Target | Why |
|---|---|---|
| `src/eden/EdenAdminFacet.sol` | `src/steve/StEVEAdminFacet.sol` | Admin surface is for the stEVE product lane |
| `src/eden/EdenBasketBase.sol` | `src/steve/StEVEProductBase.sol` | Base helpers are product-specific, not EDEN rewards-engine logic |
| `src/eden/EdenBasketPositionFacet.sol` | `src/steve/StEVEPositionFacet.sol` | Position mint / burn belongs to the stEVE product lane |
| `src/eden/EdenLendingFacet.sol` | `src/steve/StEVELendingFacet.sol` | Lending is against the stEVE product |
| `src/eden/EdenLendingLogic.sol` | `src/steve/StEVELendingLogic.sol` | Product-specific lending logic |
| `src/eden/EdenPositionPoolHelpers.sol` | `src/steve/StEVEPoolHelpers.sol` | Helper layer is tied to the stEVE product pool |
| `src/eden/EdenStEVEActionFacet.sol` | `src/steve/StEVEActionFacet.sol` | Already stEVE-specific in behavior; drop redundant EDEN prefix |
| `src/eden/EdenStEVELogic.sol` | `src/steve/StEVELogic.sol` | Already stEVE-specific in behavior; drop redundant EDEN prefix |
| `src/eden/EdenStEVEWalletFacet.sol` | `src/steve/StEVEWalletFacet.sol` | Wallet surface is stEVE-specific |
| `src/eden/EdenViewFacet.sol` | `src/steve/StEVEViewFacet.sol` | Views describe the stEVE product lane |
| `src/eden/IEdenLendingErrors.sol` | `src/steve/IStEVELendingErrors.sol` | Error interface is product-lane lending specific |

### stEVE Product Libraries

These remain under `src/libraries/` but should be renamed away from EDEN where
they are really product-lane state.

| Current | Target | Why |
|---|---|---|
| `src/libraries/LibEdenAdminStorage.sol` | `src/libraries/LibStEVEAdminStorage.sol` | Product admin storage |
| `src/libraries/LibEdenBasketStorage.sol` | `src/libraries/LibStEVEStorage.sol` | Canonical singleton product storage for stEVE |
| `src/libraries/LibEdenLendingStorage.sol` | `src/libraries/LibStEVELendingStorage.sol` | Product lending storage |
| `src/libraries/LibEdenStEVEStorage.sol` | `src/libraries/LibStEVEEligibilityStorage.sol` | Reward-eligibility state for PNFT-held stEVE |

### Deploy Script

The deploy surface should describe the protocol being deployed. We are
deploying EqualFi, not a "`By EqualFi`" branded artifact.

| Current | Target | Why |
|---|---|---|
| `script/DeployEdenByEqualFi.s.sol` | `script/DeployEqualFi.s.sol` | The deployment script assembles the EqualFi system; product branding should not be baked into the deploy entrypoint name |

## Test Rename Map

### Rewards Engine Tests

| Current | Target |
|---|---|
| `test/EdenRewardFacet.t.sol` | `test/EdenRewardsFacet.t.sol` |
| `test/EdenRewardFuzz.t.sol` | `test/EdenRewardsFuzz.t.sol` |

### stEVE Product Tests

| Current | Target |
|---|---|
| `test/EdenAdminFacet.t.sol` | `test/StEVEAdminFacet.t.sol` |
| `test/EdenBasketFlows.t.sol` | `test/StEVEFlows.t.sol` |
| `test/EdenBasketFuzz.t.sol` | `test/StEVEFuzz.t.sol` |
| `test/EdenInvariant.t.sol` | `test/StEVEInvariant.t.sol` |
| `test/EdenLendingFacet.t.sol` | `test/StEVELendingFacet.t.sol` |
| `test/EdenLendingFuzz.t.sol` | `test/StEVELendingFuzz.t.sol` |
| `test/EdenSingletonStorage.t.sol` | `test/StEVESingletonStorage.t.sol` |
| `test/EdenStEVEActionFacet.t.sol` | `test/StEVEActionFacet.t.sol` |
| `test/EdenStEVEFuzz.t.sol` | `test/StEVEProductFuzz.t.sol` |
| `test/EdenStEVEWalletFacet.t.sol` | `test/StEVEWalletFacet.t.sol` |
| `test/EdenViewFacet.t.sol` | `test/StEVEViewFacet.t.sol` |
| `test/DeployEdenByEqualFi.t.sol` | `test/DeployEqualFi.t.sol` |

### Test Utilities

| Current | Target |
|---|---|
| `test/utils/EdenInvariantUtils.t.sol` | `test/utils/StEVEInvariantUtils.t.sol` |
| `test/utils/EdenLaunchFixture.t.sol` | `test/utils/StEVELaunchFixture.t.sol` |
| `test/utils/LegacyEdenPositionFacet.sol` | `test/utils/LegacyStEVEPositionFacet.sol` |
| `test/utils/LegacyEdenWalletFacet.sol` | `test/utils/LegacyStEVEWalletFacet.sol` |

## Spec Rename Map

The current spec directories capture history, so they do not all need to be
renamed immediately. The target naming should still be recorded.

| Current | Target | Recommendation |
|---|---|---|
| `.kiro/specs/eden-steve-only-clean-break/` | `.kiro/specs/steve-eden-rewards-clean-break/` | Defer until code rename starts to avoid churn |
| `.kiro/specs/eden-by-equalfi/` | `.kiro/specs/steve-by-equalfi/` | Defer; historical product spec |
| `.kiro/specs/eden-rewards-engine/` | keep | This is already aligned with the new boundary |

## Names Intentionally Kept

These names should stay as they are.

| Name | Reason |
|---|---|
| `src/equalindex/*` | EqualIndex remains the generic basket / index lane |
| `src/libraries/LibEqualIndexLending.sol` | Correctly scoped to EqualIndex |
| generic substrate libs such as `LibPositionHelpers`, `LibFeeIndex`, `LibEncumbrance` | Shared protocol primitives should stay neutral |

## Suggested Rename Order

1. Rename the rewards engine surface first
   - `EdenRewardFacet` → `EdenRewardsFacet`
   - `LibEdenRewardStorage` → `LibEdenRewardsStorage`
   - `LibEdenRewards` → `LibEdenRewardsEngine`
2. Move product contracts from `src/eden/` to `src/steve/`
3. Rename product libraries toward `LibStEVE*`
4. Rename deploy script and launch fixture
5. Rename tests and invariant helpers
6. Update old spec directory names only after code/import churn settles

## Notes and Open Choices

### `LibEdenStEVEStorage`

Recommended target: `LibStEVEEligibilityStorage`.

Why:

- its current job is not “all stEVE storage”
- it specifically tracks reward-eligibility state such as `eligibleSupply` and `eligiblePrincipal`

Alternative:

- `LibStEVEPositionStorage`

The recommended choice is `LibStEVEEligibilityStorage` because it reflects the
actual purpose more precisely.

### `EdenBasketBase`

Recommended target: `StEVEProductBase`.

Why:

- the code is no longer a generic basket base in the intended architecture
- it is the shared helper base for the singleton product lane

Alternative:

- `StEVEBase`

The recommended choice is `StEVEProductBase` because it makes the scope obvious.

### `EdenViewFacet`

Recommended target: `StEVEViewFacet`.

Why:

- its reads describe the product lane
- EDEN-named views should be reserved for rewards-engine reads in the future if needed

## Decision Summary

Final target naming should read like this:

- `src/eden/EdenRewardsFacet.sol`
- `src/eden/` only for shared EDEN rewards-engine code
- `src/steve/StEVE*.sol` for product-lane code
- `src/equalindex/*` for generic index code

That gives the codebase the same boundary the architecture is trying to enforce.
