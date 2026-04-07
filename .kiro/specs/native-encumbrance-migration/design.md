# Design Document

## Overview

This design migrates first-party EqualFi venues away from module-style
encumbrance and onto the canonical encumbrance buckets already defined by
`LibEncumbrance`.

The goal is not to collapse all venue storage into one monolith. The goal is
to preserve a single canonical answer to the question:

```text
How much of this position's principal is currently unavailable?
```

That answer must come from the native encumbrance buckets:

- `lockedCapital`
- `encumberedCapital`
- `indexEncumbered`

Product-specific storage should answer a different question:

```text
Why is this principal unavailable?
```

That attribution belongs in venue-native storage for EqualScale Alpha and
EqualIndex lending.

## Design Goals

1. Preserve one canonical principal-availability system for first-party
   venues.
2. Keep venue-native storage where it adds clarity.
3. Remove first-party dependence on module IDs and module encumbrance
   namespaces.
4. Preserve correct settlement and unwind semantics.
5. Preserve current diamond facet launch structure where useful, without
   preserving module-style runtime semantics.

## Non-Goals

This design does not:

- force all native venues into one storage slot
- require EqualScale Alpha and EqualIndex lending to share one facet contract
- remove the `LibModuleEncumbrance` primitive from the codebase entirely
- define the third-party builder API for future modules
- preserve backwards compatibility for module-ID surfaces that only exist due
  to the old porting model

## Architectural Rule

### Native Venue Rule

For first-party EqualFi venues:

1. venue storage may be product-native
2. views may be venue-native
3. lifecycle logic may be split across multiple facets
4. principal reservation must use canonical encumbrance buckets

### Extension Rule

For future third-party or externally installed products:

1. module namespaces may be used
2. module IDs may be used
3. module-specific encumbrance attribution may remain appropriate

This migration therefore does not reject the existence of module encumbrance.
It reclassifies it as an extension abstraction rather than a first-party venue
default.

## Canonical Bucket Mapping

### EqualIndex Lending

EqualIndex lending collateral is native index collateral. It should use:

- `indexEncumbered`

It should not use:

- `moduleEncumbered`
- `LENDING_MODULE_ID`
- any public “module identity” API for native runtime behavior

### EqualScale Alpha

EqualScale Alpha has two distinct reservation shapes:

1. lender settlement-pool commitments
2. optional borrower-posted collateral

These should map to:

- lender settlement commitments -> `encumberedCapital`
- borrower-posted collateral -> `lockedCapital`

This makes the reservation semantics legible:

- commitments are capital reserved against future line exposure
- borrower collateral is explicitly locked against the line lifecycle

## EqualIndex Lending Migration

### Current Problem

EqualIndex lending is already deployed as a facet, but its internal model still
acts like a lending module:

- it defines a native `LENDING_MODULE_ID`
- it uses `LibModuleEncumbrance`
- it exposes `lendingModuleId()` publicly

That is not consistent with the desired greenfield native architecture.

### Target Model

EqualIndex lending should keep:

- dedicated loan storage
- lending configuration storage
- fee-tier storage
- native lending views

EqualIndex lending should change:

- collateral reservation from `moduleEncumbered` to `indexEncumbered`
- helper naming and tests away from “module”
- public API by removing `lendingModuleId()`

### Runtime Mapping

Borrow:

1. validate position ownership and index membership
2. validate available index principal
3. increase canonical `indexEncumbered`
4. apply any required ACI side effects
5. create the loan record in lending storage
6. disburse borrow assets

Repay / recover:

1. reduce outstanding principal state in lending storage
2. decrease canonical `indexEncumbered`
3. unwind any required ACI side effects
4. close or delete the loan record

### Storage Guidance

`LibEqualIndexLending` may remain as dedicated lending storage, but it should be
treated as product-native EqualIndex storage rather than “module storage.” A
rename is optional, but conceptually the library becomes native venue storage.

## EqualScale Alpha Migration

### Current Problem

EqualScale Alpha is also already deployed as facets, but its current design and
tests assume:

- per-line settlement commitment module IDs
- per-line borrower collateral module IDs
- `LibModuleEncumbrance` as the primary capital-reservation system

That is the wrong abstraction for a first-party native venue.

### Target Model

EqualScale Alpha should keep:

- borrower profile storage
- credit line storage
- commitment storage
- payment history
- native Alpha views and admin controls

EqualScale Alpha should change:

- lender commitment reservation to canonical `encumberedCapital`
- borrower collateral reservation to canonical `lockedCapital`
- removal of per-line module-ID-derived encumbrance logic

### Lender Commitment Semantics

A lender commitment is a reservation of settlement-pool principal owned by a
lender Position NFT.

That reservation should:

1. settle lender position state first where required
2. increase canonical `encumberedCapital`
3. apply matching ACI reservation effects if the venue needs them
4. store per-line attribution in Alpha commitment storage

Cancel / exit / close should reverse that symmetrically.

### Borrower Collateral Semantics

Borrower-posted collateral is line-scoped collateral intentionally locked for
the Alpha lifecycle.

That reservation should:

1. settle borrower position state first where required
2. increase canonical `lockedCapital`
3. store collateral attribution in Alpha line storage

Repayment closure or charge-off resolution should release that lock or consume
the collateral through explicit lifecycle logic.

### Attribution Without Module IDs

After migration, Alpha should answer:

- “How much is reserved?” through canonical encumbrance buckets
- “Which line caused it?” through `CreditLine` and `Commitment` storage

It should not require `settlementCommitmentModuleId(lineId)` or
`borrowerCollateralModuleId(lineId)` to explain active exposure.

## Product Attribution Model

### Principle

Encumbrance is not the attribution ledger.

The attribution ledger belongs to product-native storage:

- EqualIndex lending loan records explain why `indexEncumbered` exists
- EqualScale Alpha commitments explain why `encumberedCapital` exists
- EqualScale Alpha line collateral terms explain why `lockedCapital` exists

This is the same architectural pattern used by other native venues:

- canonical reservation lives in `LibEncumbrance`
- product meaning lives in product storage

## API and Facet Surface

### Facet Structure

The existing facet split may remain:

- `EqualScaleAlphaFacet`
- `EqualScaleAlphaAdminFacet`
- `EqualScaleAlphaViewFacet`
- `EqualIndexLendingFacet`

Making these native does not require collapsing them into fewer contracts. The
problem is the runtime model, not the selector grouping.

### Public API Changes

Representative EqualIndex lending cleanup:

- remove `lendingModuleId()`

Representative EqualScale Alpha cleanup:

- remove test-only or helper surfaces whose purpose is to expose per-line
  module IDs or module encumbrance

Public views should instead expose the product records that explain active
exposure.

## Testing Migration

### EqualIndex Lending

Tests should migrate from:

- module ID assertions
- module encumbrance assumptions

To:

- `indexEncumbered` assertions
- live borrow / repay / recover symmetry
- unchanged borrow basket and liquidity behavior

### EqualScale Alpha

Tests should migrate from:

- `settlementCommitmentModuleId`
- `borrowerCollateralModuleId`
- per-line module encumbrance assertions

To:

- lender-side `encumberedCapital` assertions
- borrower-side `lockedCapital` assertions
- line commitment storage assertions for per-line attribution
- unchanged lifecycle behavior across solo, pooled, refinance, runoff,
  delinquency, and charge-off paths

### Spec Migration

The existing EqualScale Alpha spec currently encodes module-style intent. This
migration should either:

1. update that spec in place, or
2. explicitly supersede its module-specific requirements

The key point is that future implementation work must no longer treat module
encumbrance as the target architecture for first-party Alpha behavior.

## Security Notes

1. Removing module IDs from native venues should not weaken attribution, as
   long as product storage remains the source of truth for per-line or per-loan
   state.
2. The migration must preserve settle-before-reserve-change discipline where
   required by ACI and fee-index behavior.
3. The migration should be done per venue with regression tests before
   refactoring shared primitives further.
4. `LibModuleEncumbrance` should remain available for future extension authors,
   but first-party native venues should stop depending on it.
