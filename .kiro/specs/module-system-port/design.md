# Design Document

## Overview

This design ports the third-party module system from the legacy EqualFi
codebase into EdenFi. The module system provides permissionless registration,
AUM-gated encumbrance, delinquency escalation, and permanent deactivation for
external builders who want to create financial primitives on EqualFi liquidity.

The port preserves the existing architecture from `Projects/EqualFi/` with
minimal adaptation to EdenFi's current library and facet conventions.

## Design Goals

1. Preserve the economic discipline model: AUM fee → delinquency → death.
2. Keep module encumbrance cleanly separated from native first-party
   encumbrance types.
3. Integrate with EdenFi's existing ACI, fee index, and fee routing.
4. Maintain the gateway pattern: all module encumbrance flows through one
   facet that enforces AUM and liveness.
5. Ship with full test coverage ported from the legacy suite.

## Non-Goals

This design does not:

- change the module AUM fee model or delinquency escalation logic
- add module-specific fee routing beyond treasury (future work)
- add module governance or voting
- change how first-party products encumber capital
- add module discovery or marketplace features

## Architecture

### Storage Layer

**LibModuleRegistry** — isolated diamond storage for the module registry.

```solidity
struct Module {
    address owner;
    bytes32 metadataHash;
    bool paused;
    bool inactive;       // irreversible once set
    uint16 aumBps;
}

struct TupleAumState {
    uint64 lastAumEpoch;
    bool delinquent;
    uint64 delinquentSince;
    uint256 lastShortfall;
}

struct ModuleStorage {
    uint256 nextModuleId;
    uint256 moduleCreationFee;
    uint16 defaultModuleAumBps;
    uint16 minModuleAumBps;
    uint16 maxModuleAumBps;
    uint16 deactivationGraceEpochs;
    bool moduleAciPaused;
    mapping(uint256 => Module) modules;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => TupleAumState))) tupleAum;
}
```

Storage position: `keccak256("equallend.module.registry.storage")`

All module lifecycle events live on this library.

### AUM Engine

**LibModuleAum** — daily epoch-based AUM accrual per tuple.

Constants:
- `MODULE_AUM_EPOCH = 1 days`
- `BPS_DENOMINATOR = 10_000`
- `YEAR_DAYS = 365`

Accrual flow (`accrue(positionKey, poolId, moduleId)`):

1. Compute elapsed epochs since `lastAumEpoch`
2. If zero epochs, return early
3. Read encumbered amount for the tuple
4. Compute fee: `(encumbered × aumBps × epochs) / (365 × 10_000)`
5. Settle position fee index checkpoint (must happen before principal mutation)
6. Determine chargeable principal: `min(userPrincipal, encumbered)`
7. Charge: `min(feeDue, chargeablePrincipal)`
8. If charged > 0: reduce `userPrincipal`, reduce `totalDeposits`, route
   through treasury fee path
9. Compute shortfall: `feeDue - charged`
10. Update `lastAumEpoch`
11. If shortfall > 0: enter delinquency escalation
12. If no shortfall: clear delinquency state

### Delinquency Escalation

When shortfall > 0:

1. If not already delinquent: set `delinquent = true`,
   `delinquentSince = currentEpochStart`
2. Record `lastShortfall`
3. Emit `ModuleAumDelinquent`
4. If already delinquent AND elapsed delinquent epochs ≥
   `deactivationGraceEpochs`: set `module.inactive = true`, emit
   `ModulePermanentlyDeactivated`

When shortfall == 0:

1. Clear `delinquent`, `delinquentSince`, `lastShortfall`

The `inactive` flag is write-once. Once set, the module cannot be unpaused or
accept new encumbrance. Existing encumbrance can still be unwound.

### Fee Routing

AUM fees charged from principal are routed through
`LibFeeTreasury.accrueWithTreasuryFromPrincipal` (or EdenFi equivalent).

This path:
1. Reduces `userPrincipal` and `totalDeposits`
2. Transfers the treasury portion from `trackedBalance` to the treasury
   address

**Dependency check:** EdenFi may not have `LibFeeTreasury`. If not, the
charge path should use `LibFeeRouter` or a direct treasury transfer from
`trackedBalance`, matching the pattern used by `LibMaintenance._pay`.

Recommended approach: add a minimal `_chargeFromPrincipal` helper in
`LibModuleAum` that:
1. Reduces `userPrincipal` and `totalDeposits`
2. Transfers from `trackedBalance` to treasury via `LibCurrency.transfer`

This avoids introducing a new library dependency.

### Gateway Facet

**ModuleGatewayFacet** — single entry point for all module encumbrance.

`encumberPosition(positionId, poolId, moduleId, amount)`:
1. Require module exists, not paused, not inactive
2. Resolve position ownership and pool membership
3. `LibModuleAum.accrue(...)` — accrues pending AUM
4. Re-check `module.inactive` (accrual may have deactivated it)
5. Check available principal via `LibSolvencyChecks` or equivalent
6. `LibModuleEncumbrance.encumber(...)`
7. If `!moduleAciPaused`: `LibActiveCreditIndex.applyEncumbranceIncrease(...)`

`unencumberPosition(positionId, poolId, moduleId, amount)`:
1. Require module exists (no pause/inactive check — users must exit)
2. Resolve position ownership
3. `LibModuleAum.accrue(...)`
4. `LibModuleEncumbrance.unencumber(...)`
5. `LibActiveCreditIndex.applyEncumbranceDecrease(...)`

`pokeModuleAum(positionId, poolId, moduleId)`:
1. Require module exists
2. `LibModuleAum.accrue(...)`

### Registry Facet

**ModuleRegistryFacet** — registration and governance controls.

Registration:
- Governance callers: no fee required, `msg.value` must be 0
- Non-governance callers: `msg.value` must equal `moduleCreationFee`
  (reverts if fee is 0, meaning registration is disabled)
- Fee forwarded to treasury
- Module assigned sequential ID, owner = `msg.sender`, aumBps = default

Governance setters:
- `setModuleCreationFee(uint256)`
- `setDefaultModuleAumBps(uint16)` — bounded by min/max
- `setModuleAumBps(uint256 moduleId, uint16)` — bounded by min/max
- `setModuleAumBounds(uint16 min, uint16 max)`
- `setModuleDeactivationGraceEpochs(uint16)`
- `setModuleAciPaused(bool)`

Owner controls:
- `setModuleOwner(uint256 moduleId, address)`
- `pauseModule(uint256 moduleId)` — owner or governance
- `unpauseModule(uint256 moduleId)` — owner or governance, reverts if inactive

### View Facet

**ModuleViewFacet** — read-only surface.

- `getModule(moduleId)` → (owner, metadataHash, paused, inactive, aumBps)
- `getModuleEncumbrance(positionId, poolId)` → total module encumbered
- `getModuleEncumbranceForModule(positionId, poolId, moduleId)` → per-module
- `getModuleAumState(positionId, poolId, moduleId)` → full tuple AUM state
  including computed pending/delinquent epochs and grace satisfaction
- `getModuleAumConfig()` → global AUM parameters
- `isModuleAciPaused()` → bool

### Interfaces

Three interfaces matching the facets:

- `IModuleRegistryFacet`
- `IModuleGatewayFacet`
- `IModuleViewFacet`

### Error Definitions

Add to EdenFi's `Errors.sol`:

```solidity
error ModuleNotFound(uint256 moduleId);
error ModuleInactive(uint256 moduleId);
error ModulePausedError(uint256 moduleId);
error ModuleRegistrationDisabled();
error ModuleIncorrectFee(uint256 provided, uint256 required);
error NotModuleOwner(uint256 moduleId, address caller);
error InvalidModuleOwner(address owner);
error ModuleAumOutOfBounds(uint16 attempted, uint16 min, uint16 max);
error TreasuryNotSet();
error InsufficientUnencumberedPrincipal(uint256 requested, uint256 available);
```

### Solvency Check Dependency

The gateway uses `LibSolvencyChecks.calculateAvailablePrincipal` in the legacy
code. EdenFi uses `LibPositionHelpers.settledAvailablePrincipal` for the same
purpose. The gateway should use whichever is canonical in EdenFi — likely
`LibPositionHelpers.settledAvailablePrincipal(pool, positionKey, poolId)`.

## Security Notes

1. AUM accrual happens before every encumbrance mutation. This prevents a
   module from accumulating unbounded AUM debt.
2. The `inactive` flag is write-once and checked on both `encumberPosition`
   and `unpauseModule`. There is no path to resurrect a deactivated module.
3. `unencumberPosition` intentionally does not check pause/inactive state.
   Users must always be able to exit.
4. The gateway is the only authorized caller of `LibModuleEncumbrance` for
   module operations. First-party code should not call module encumbrance
   functions directly (they use native encumbrance types instead).
5. AUM fee calculation is capped at the encumbered amount to prevent charging
   more than the module controls.
6. Fee index settlement before principal mutation prevents stale checkpoint
   corruption.
