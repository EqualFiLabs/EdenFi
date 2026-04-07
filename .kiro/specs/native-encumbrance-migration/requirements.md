# Requirements Document

## Introduction

This spec defines a migration of first-party EqualFi venues away from
module-style encumbrance and toward one canonical native encumbrance system.

The affected native venues are:

1. **EqualScale Alpha**
2. **EqualIndex Lending**

Both surfaces are already deployed as diamond facets, but parts of their
current internal accounting model still treat them like isolated modules.
That is not the intended greenfield architecture.

For first-party EqualFi venues:

- product state may remain product-native
- selectors may remain split across multiple facets where useful
- backing and reservation semantics must collapse into the canonical
  `LibEncumbrance` buckets

Module namespaces are reserved for future third-party builders and extension
surfaces, not for core EqualFi venues.

## Glossary

- **Native Venue**: A first-party EqualFi product surface that is part of the
  canonical protocol runtime.
- **Module Encumbrance**: Encumbrance tracked through per-module namespaces
  such as `moduleEncumbered` and `encumberedByModule`.
- **Canonical Encumbrance System**: The native encumbrance buckets already
  defined by `LibEncumbrance`, including `lockedCapital`,
  `encumberedCapital`, and `indexEncumbered`.
- **Product Attribution**: Product-specific records that explain why value is
  reserved, stored in venue-native storage rather than in encumbrance
  namespaces.

## Requirements

### Requirement 1: Native Venues Must Use Canonical Encumbrance Buckets

**User Story:** As a protocol architect, I want first-party venues to use one
canonical encumbrance system, so EqualFi does not fragment principal
availability rules across multiple accounting models.

#### Acceptance Criteria

1. First-party EqualFi venues SHALL use the canonical `LibEncumbrance`
   buckets for native principal reservation.
2. Native venues SHALL NOT rely on `moduleEncumbered` as their primary
   first-party principal reservation model.
3. Product-specific records MAY remain in venue-native storage, but they SHALL
   not replace canonical encumbrance totals.
4. Position withdrawal and availability rules SHALL continue to compose only
   against the canonical encumbrance totals exposed by the EqualFi substrate.

### Requirement 2: EqualIndex Lending Must Become Native Index Encumbrance

**User Story:** As a maintainer, I want EqualIndex lending collateral to be
tracked as native index encumbrance, so index-backed borrowing matches the
rest of EqualIndex and EqualFi semantics.

#### Acceptance Criteria

1. EqualIndex lending collateral SHALL be reserved through the canonical
   `indexEncumbered` path.
2. EqualIndex lending SHALL NOT rely on a lending module namespace or module
   ID for native collateral reservation.
3. EqualIndex lending MAY keep dedicated lending storage for loan records,
   lending configs, and fee tiers.
4. EqualIndex lending SHALL remove native runtime dependence on
   `LibModuleEncumbrance`.
5. EqualIndex lending SHALL remove public APIs that exist only to surface a
   native module identity.

### Requirement 3: EqualScale Alpha Must Become Native Encumbrance and Locking

**User Story:** As a maintainer, I want EqualScale Alpha commitments and
borrower collateral to use canonical native buckets, so Alpha behaves like a
first-party venue rather than a namespaced extension module.

#### Acceptance Criteria

1. EqualScale Alpha lender settlement-pool commitments SHALL reserve capital
   through canonical `encumberedCapital`.
2. EqualScale Alpha borrower-posted collateral SHALL reserve capital through
   canonical `lockedCapital`.
3. EqualScale Alpha SHALL NOT rely on per-line module IDs for first-party
   runtime encumbrance.
4. EqualScale Alpha MAY keep dedicated Alpha storage for borrower profiles,
   lines, commitments, payment history, and line status.
5. EqualScale Alpha SHALL remove native runtime dependence on
   `LibModuleEncumbrance`.

### Requirement 4: Product Attribution Must Move Into Product Storage

**User Story:** As a reviewer, I want product storage to explain why capital is
reserved, so native encumbrance totals stay canonical without losing venue
attribution.

#### Acceptance Criteria

1. EqualScale Alpha SHALL continue to track lender commitments and borrower
   collateral attribution in Alpha-native storage keyed by line and position.
2. EqualIndex lending SHALL continue to track loan attribution in lending
   storage keyed by loan ID and index ID.
3. Encumbrance namespaces SHALL NOT be the source of truth for per-line or
   per-loan attribution after migration.
4. Native view surfaces SHALL remain able to explain active product exposure
   without querying module-specific encumbrance namespaces.

### Requirement 5: Canonical Settlement Semantics Must Be Preserved

**User Story:** As a protocol developer, I want the migration to preserve live
availability, settlement, and unwind correctness, so the architecture gets
cleaner without introducing accounting regressions.

#### Acceptance Criteria

1. Any native reservation increase SHALL continue to settle relevant pool
   indexes before changing effective backing state where required.
2. Any native reservation decrease SHALL continue to unwind backing safely and
   symmetrically.
3. Active-credit and same-asset debt flows SHALL remain correct after the
   encumbrance migration.
4. The migration SHALL preserve or improve current withdrawal-safety behavior
   for affected positions.

### Requirement 6: Module Semantics Must Be Reserved for Third-Party Extensions

**User Story:** As a protocol architect, I want module namespaces reserved for
future extension builders, so core EqualFi venues do not consume the same
abstraction intended for third-party products.

#### Acceptance Criteria

1. The first-party EqualFi runtime SHALL treat module encumbrance as an
   extension mechanism rather than as the default design for native venues.
2. EqualScale Alpha and EqualIndex lending SHALL not depend on module-ID
   namespace isolation as a core invariant after migration.
3. Tests for native venues SHALL prefer canonical encumbrance assertions over
   module-ID namespace assertions.

### Requirement 7: Specs, Tests, and Launch Wiring Must Reflect the Native Model

**User Story:** As a maintainer, I want the written specs and regression tests
to match the intended architecture, so future work does not reintroduce the
same modeling mistake.

#### Acceptance Criteria

1. The EqualScale Alpha specs SHALL be updated or superseded so they no longer
   require module encumbrance for native venue behavior.
2. EqualIndex lending tests SHALL be updated to assert native index
   encumbrance rather than module encumbrance.
3. EqualScale Alpha tests SHALL be updated to assert canonical
   `encumberedCapital` and `lockedCapital` behavior rather than per-line module
   encumbrance.
4. Diamond launch wiring MAY continue to use multiple facets, but the runtime
   behavior SHALL reflect native venue accounting rather than module-style
   accounting.
