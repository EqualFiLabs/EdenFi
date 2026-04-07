# Tasks

## Task 1: Port LibModuleRegistry

- [ ] 1. Create `src/libraries/LibModuleRegistry.sol` in EdenFi
  - [ ] 1.1 Define `Module` struct (owner, metadataHash, paused, inactive,
        aumBps)
  - [ ] 1.2 Define `TupleAumState` struct (lastAumEpoch, delinquent,
        delinquentSince, lastShortfall)
  - [ ] 1.3 Define `ModuleStorage` struct with all fields (nextModuleId,
        moduleCreationFee, defaultModuleAumBps, min/maxModuleAumBps,
        deactivationGraceEpochs, moduleAciPaused, modules mapping,
        tupleAum mapping)
  - [ ] 1.4 Add storage accessor `s()` with diamond storage position
  - [ ] 1.5 Add convenience accessors: `module(moduleId)`,
        `tupleAumState(positionKey, poolId, moduleId)`
  - [ ] 1.6 Add all event definitions (ModuleRegistered, ModuleOwnerUpdated,
        ModulePauseUpdated, ModuleAumAccrued, ModuleAumDelinquent,
        ModulePermanentlyDeactivated, ModuleAciPauseToggled)
  - [ ] 1.7 Add emit helper functions for each event

## Task 2: Port LibModuleAum

- [ ] 1. Create `src/libraries/LibModuleAum.sol` in EdenFi
  - [ ] 1.1 Define constants: MODULE_AUM_EPOCH, BPS_DENOMINATOR, YEAR_DAYS,
        MODULE_AUM_SOURCE
  - [ ] 1.2 Define `AccrualResult` struct
  - [ ] 1.3 Implement `currentEpochStart()`, `pendingEpochs()`,
        `delinquentEpochs()`, `effectiveAumBps()`
  - [ ] 1.4 Implement `accrue()` with full accrual logic: epoch computation,
        fee calculation, fee index settlement, principal charge, shortfall
        tracking
  - [ ] 1.5 Implement `_chargeFromPrincipal()` — reduce userPrincipal and
        totalDeposits, transfer treasury portion from trackedBalance
  - [ ] 1.6 Implement `_markDelinquency()` — delinquent flag, grace period
        check, permanent deactivation trigger
- [ ] 2. Verify fee routing compatibility
  - [ ] 2.1 Determine whether to use `LibFeeTreasury` (if it exists in
        EdenFi) or inline the treasury transfer in `_chargeFromPrincipal`
  - [ ] 2.2 Ensure trackedBalance and nativeTrackedTotal are correctly
        decremented on charge

## Task 3: Add Error Definitions

- [ ] 1. Add module-specific errors to `src/libraries/Errors.sol`
  - [ ] 1.1 ModuleNotFound, ModuleInactive, ModulePausedError
  - [ ] 1.2 ModuleRegistrationDisabled, ModuleIncorrectFee
  - [ ] 1.3 NotModuleOwner, InvalidModuleOwner
  - [ ] 1.4 ModuleAumOutOfBounds, TreasuryNotSet
  - [ ] 1.5 InsufficientUnencumberedPrincipal

## Task 4: Create Interfaces

- [ ] 1. Create `src/interfaces/IModuleRegistryFacet.sol`
- [ ] 2. Create `src/interfaces/IModuleGatewayFacet.sol`
- [ ] 3. Create `src/interfaces/IModuleViewFacet.sol`

## Task 5: Port ModuleRegistryFacet

- [ ] 1. Create `src/modules/ModuleRegistryFacet.sol` (or appropriate EdenFi
      path)
  - [ ] 1.1 Implement `registerModule(metadataHash)` with fee/governance
        branching
  - [ ] 1.2 Implement `setModuleOwner(moduleId, newOwner)`
  - [ ] 1.3 Implement `pauseModule(moduleId)` and `unpauseModule(moduleId)`
        with inactive guard
  - [ ] 1.4 Implement governance setters: setModuleCreationFee,
        setDefaultModuleAumBps, setModuleAumBps, setModuleAumBounds,
        setModuleDeactivationGraceEpochs, setModuleAciPaused
  - [ ] 1.5 Implement internal helpers: _nextModuleId, _requireModule,
        _enforceModuleOwner, _enforceModuleOwnerOrGovernance,
        _enforceAumBpsInBounds

## Task 6: Port ModuleGatewayFacet

- [ ] 1. Create `src/modules/ModuleGatewayFacet.sol` (or appropriate EdenFi
      path)
  - [ ] 1.1 Implement `encumberPosition(positionId, poolId, moduleId, amount)`
        with full enforcement: module liveness check, AUM accrual,
        post-accrual inactive re-check, available principal check,
        encumbrance, ACI update
  - [ ] 1.2 Implement `unencumberPosition(positionId, poolId, moduleId,
        amount)` with AUM accrual, encumbrance release, ACI update (no
        pause/inactive gate)
  - [ ] 1.3 Implement `pokeModuleAum(positionId, poolId, moduleId)`
  - [ ] 1.4 Implement `_resolveOwnedPositionInPool` using EdenFi's
        `LibPositionHelpers`
  - [ ] 1.5 Use `LibPositionHelpers.settledAvailablePrincipal` for available
        principal check (adapt from legacy `LibSolvencyChecks`)

## Task 7: Port ModuleViewFacet

- [ ] 1. Create `src/modules/ModuleViewFacet.sol` (or appropriate EdenFi
      path)
  - [ ] 1.1 Implement `getModule(moduleId)`
  - [ ] 1.2 Implement `getModuleEncumbrance(positionId, poolId)`
  - [ ] 1.3 Implement `getModuleEncumbranceForModule(positionId, poolId,
        moduleId)`
  - [ ] 1.4 Implement `getModuleAumState(positionId, poolId, moduleId)` with
        computed fields (pendingEpochs, delinquentEpochs, graceSatisfied)
  - [ ] 1.5 Implement `getModuleAumConfig()`
  - [ ] 1.6 Implement `isModuleAciPaused()`

## Task 8: Diamond Wiring

- [ ] 1. Add module facet selectors to `DeployEqualFi.s.sol`
  - [ ] 1.1 ModuleRegistryFacet selectors
  - [ ] 1.2 ModuleGatewayFacet selectors
  - [ ] 1.3 ModuleViewFacet selectors
- [ ] 2. Add selector regression coverage if the project uses it

## Task 9: Port and Adapt Tests

- [ ] 1. Port `ModuleRegistryFacet.t.sol`
  - [ ] 1.1 Registration with fee, without fee (governance), disabled, wrong
        fee
  - [ ] 1.2 Ownership transfer, pause, unpause, unpause-when-inactive revert
  - [ ] 1.3 Governance setters: creation fee, default AUM, per-module AUM,
        bounds, grace epochs, ACI pause
- [ ] 2. Port `ModuleGatewayFacet.t.sol`
  - [ ] 2.1 Encumber succeeds for active module
  - [ ] 2.2 Encumber reverts for paused module
  - [ ] 2.3 Encumber reverts for inactive module
  - [ ] 2.4 Encumber reverts when AUM accrual triggers deactivation
  - [ ] 2.5 Unencumber succeeds even on inactive module
  - [ ] 2.6 AUM accrued before encumbrance change
  - [ ] 2.7 ACI updated on encumber/unencumber
  - [ ] 2.8 ACI not updated when moduleAciPaused
  - [ ] 2.9 pokeModuleAum triggers accrual
- [ ] 3. Port `ModuleViewFacet.t.sol`
  - [ ] 3.1 View correctness for module metadata
  - [ ] 3.2 View correctness for encumbrance amounts
  - [ ] 3.3 View correctness for AUM state and computed fields
- [ ] 4. Port `ModuleEncumbranceProperty.t.sol`
  - [ ] 4.1 Invariant: encumbered capital ≤ user principal
  - [ ] 4.2 Invariant: AUM charge ≤ min(encumbered, principal)
  - [ ] 4.3 Invariant: deactivated module rejects new encumbrance
  - [ ] 4.4 Invariant: deactivated module allows unencumber
- [ ] 5. Add AUM-specific tests
  - [ ] 5.1 Correct fee calculation for single epoch
  - [ ] 5.2 Correct fee calculation for multi-epoch catch-up
  - [ ] 5.3 Partial payment when principal < fee
  - [ ] 5.4 Delinquency set on shortfall, cleared on full payment
  - [ ] 5.5 Grace period countdown and permanent deactivation trigger
  - [ ] 5.6 Treasury receives charged amount
  - [ ] 5.7 Principal and totalDeposits correctly reduced
