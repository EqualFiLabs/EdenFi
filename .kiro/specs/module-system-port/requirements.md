# Requirements Document

## Introduction

This spec defines the port of the third-party module system from the legacy
EqualFi codebase (`Projects/EqualFi/src/modules/`) into the EdenFi greenfield
substrate (`Projects/EdenFi/`).

The module system enables permissionless third-party builders to register
financial primitives on EqualFi, encumber user capital through a gateway, and
participate in ACI yield — while paying a per-module AUM fee that enforces
economic discipline through delinquency escalation and permanent deactivation.

First-party products (EqualLend, EqualScale, Options, Solo AMM) use native
encumbrance types and are not subject to module AUM. The module system is
exclusively for external builders.

## Glossary

- **Module**: A registered third-party financial primitive identified by a
  numeric `moduleId`.
- **Tuple**: The `(positionKey, poolId, moduleId)` triple that identifies a
  specific encumbrance relationship.
- **Module AUM**: A daily fee charged against module-encumbered capital,
  separate from the protocol-level maintenance fee.
- **Delinquency**: The state entered when a tuple cannot fully pay its AUM fee.
- **Deactivation**: Permanent, irreversible shutdown of a module after
  sustained delinquency past the grace period.
- **Gateway**: The facet through which all module encumbrance flows, enforcing
  AUM accrual and module liveness checks.

## Requirements

### Requirement 1: Module Registration

**User Story:** As a third-party builder, I want to register a module on
EqualFi so I can build a financial primitive that encumbers user capital.

#### Acceptance Criteria

1. Any address SHALL be able to register a module by paying the
   `moduleCreationFee` in native currency.
2. Governance (owner or timelock) SHALL be able to register modules without
   paying a fee.
3. Registration SHALL assign a sequential `moduleId`, store the caller as
   owner, record a `metadataHash`, and set the module's AUM rate to the
   current `defaultModuleAumBps`.
4. Registration SHALL revert when `moduleCreationFee` is zero and the caller
   is not governance (registration disabled).
5. Registration SHALL revert when `msg.value` does not match the required fee.
6. The creation fee SHALL be forwarded to the treasury address.

### Requirement 2: Module Lifecycle Controls

**User Story:** As a module owner, I want to pause and manage my module so I
can respond to issues without losing my registration.

#### Acceptance Criteria

1. The module owner SHALL be able to pause and unpause their module.
2. Governance SHALL also be able to pause and unpause any module.
3. Unpausing SHALL revert if the module has been permanently deactivated.
4. The module owner SHALL be able to transfer ownership to a new address.
5. Ownership transfer SHALL reject the zero address.

### Requirement 3: Module AUM Fee Accrual

**User Story:** As a protocol operator, I want modules to pay an ongoing AUM
fee on encumbered capital so the protocol earns from third-party usage and
unproductive modules are economically penalized.

#### Acceptance Criteria

1. Module AUM SHALL accrue daily per tuple `(positionKey, poolId, moduleId)`.
2. The fee for a tuple SHALL equal
   `(encumbered × aumBps × epochs) / (365 × 10_000)` where `epochs` is the
   number of full days since the last accrual.
3. The fee SHALL be charged from the position's principal in the relevant
   pool, capped at the encumbered amount.
4. Fee settlement SHALL settle the position's fee index checkpoint before
   mutating principal.
5. Charged amounts SHALL be routed through the treasury fee path.
6. Governance SHALL be able to set per-module AUM rates within configurable
   global bounds (`minModuleAumBps`, `maxModuleAumBps`).
7. Governance SHALL be able to set the default AUM rate for new modules.

### Requirement 4: Delinquency and Permanent Deactivation

**User Story:** As a protocol architect, I want modules that cannot pay their
AUM to be automatically and permanently shut down so unproductive modules
cannot indefinitely encumber user capital.

#### Acceptance Criteria

1. When a tuple's principal is insufficient to cover the full AUM fee, the
   system SHALL charge what is available and record the shortfall.
2. The tuple SHALL be marked delinquent with a `delinquentSince` timestamp.
3. If the shortfall is cured (full payment on a subsequent accrual), the
   delinquent flag SHALL be cleared.
4. If delinquency persists for more than `deactivationGraceEpochs` daily
   epochs, the module SHALL be permanently deactivated (`inactive = true`).
5. Permanent deactivation SHALL be irreversible — `unpauseModule` SHALL
   revert for inactive modules.
6. A `ModulePermanentlyDeactivated` event SHALL be emitted on deactivation.
7. Governance SHALL be able to configure `deactivationGraceEpochs`.

### Requirement 5: Encumbrance Gateway Enforcement

**User Story:** As a user, I want module encumbrance to be gated through a
single entry point that enforces AUM payment and module liveness so I cannot
encumber capital into a dead or delinquent module.

#### Acceptance Criteria

1. All module encumbrance SHALL flow through the gateway facet, not through
   direct `LibModuleEncumbrance` calls.
2. The gateway SHALL accrue pending AUM before processing any encumbrance
   change.
3. `encumberPosition` SHALL revert if the module is paused, inactive, or was
   deactivated during the pre-encumbrance AUM accrual.
4. `encumberPosition` SHALL verify sufficient available principal after AUM
   accrual.
5. `unencumberPosition` SHALL accrue AUM before releasing encumbrance.
6. `unencumberPosition` SHALL work even on inactive modules (users must be
   able to exit).
7. Encumbrance changes SHALL update ACI backing state unless module ACI is
   globally paused.
8. A public `pokeModuleAum` function SHALL allow anyone to trigger AUM
   accrual for any tuple.

### Requirement 6: Module ACI Integration

**User Story:** As a module user, I want my encumbered capital to earn ACI
yield so module participation is economically rewarded.

#### Acceptance Criteria

1. Module encumbrance increases SHALL call
   `LibActiveCreditIndex.applyEncumbranceIncrease` unless module ACI is
   paused.
2. Module encumbrance decreases SHALL call
   `LibActiveCreditIndex.applyEncumbranceDecrease`.
3. Governance SHALL be able to globally pause module ACI accrual via
   `setModuleAciPaused`.

### Requirement 7: View Surface

**User Story:** As an integrator, I want to read module state, encumbrance,
and AUM status so I can build UIs and monitoring around the module system.

#### Acceptance Criteria

1. The view facet SHALL expose module metadata (owner, metadataHash, paused,
   inactive, aumBps).
2. The view facet SHALL expose per-position total module encumbrance and
   per-module encumbrance.
3. The view facet SHALL expose tuple AUM state: lastAccruedEpoch,
   pendingEpochs, delinquent, delinquentSince, lastShortfall,
   delinquentEpochs, graceSatisfied.
4. The view facet SHALL expose global AUM config: defaultBps, minBps, maxBps,
   deactivationGraceEpochs, moduleAciPaused.

### Requirement 8: Testing

**User Story:** As a maintainer, I want comprehensive test coverage so the
module system is safe to ship.

#### Acceptance Criteria

1. Tests SHALL cover module registration (permissionless with fee, governance
   without fee, disabled registration, wrong fee amount).
2. Tests SHALL cover lifecycle controls (pause, unpause, unpause-when-inactive
   revert, ownership transfer).
3. Tests SHALL cover AUM accrual (correct fee calculation, principal
   reduction, treasury routing, multi-epoch catch-up).
4. Tests SHALL cover delinquency escalation (partial payment, delinquent flag,
   cure on subsequent payment, grace period expiry, permanent deactivation).
5. Tests SHALL cover gateway enforcement (encumber rejects on paused/inactive,
   AUM-triggered deactivation blocks encumber, unencumber works on inactive).
6. Tests SHALL cover ACI integration (encumbrance increases/decreases update
   active credit, module ACI pause respected).
7. Invariant tests SHALL verify encumbered capital aligns with module
   registry state and AUM never charges more than encumbered principal.
