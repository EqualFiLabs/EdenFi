# Tasks

## Task 1: Lock the Native Encumbrance Architecture

- [x] 1. Confirm first-party EqualFi venues use canonical encumbrance buckets
      rather than module encumbrance by default
- [x] 2. Confirm module namespaces are reserved for future third-party
      extension builders rather than native venues
- [x] 3. Confirm the target bucket mapping
  - [x] 3.1 EqualIndex lending collateral uses `indexEncumbered`
  - [x] 3.2 EqualScale Alpha lender commitments use `encumberedCapital`
  - [x] 3.3 EqualScale Alpha borrower collateral uses `lockedCapital`

## Task 2: Migrate EqualIndex Lending to Native Index Encumbrance

- [x] 1. Remove first-party module semantics from EqualIndex lending
  - [x] 1.1 Remove `LENDING_MODULE_ID`
  - [x] 1.2 Remove `lendingModuleId()` from the public API
  - [x] 1.3 Remove native runtime dependence on `LibModuleEncumbrance`
- [x] 2. Rewire collateral reservation through canonical index encumbrance
  - [x] 2.1 Use native `indexEncumbered` increase on borrow
  - [x] 2.2 Use native `indexEncumbered` decrease on repay
  - [x] 2.3 Use native `indexEncumbered` decrease on recovery
  - [x] 2.4 Preserve any required ACI side effects
- [x] 3. Keep product attribution in EqualIndex lending storage
  - [x] 3.1 Preserve loan records, configs, fee tiers, and outstanding
        principal accounting
  - [x] 3.2 Rename helpers or comments away from “module” where useful

## Task 3: Migrate EqualScale Alpha to Native Encumbrance and Locking

- [x] 1. Remove first-party module semantics from EqualScale Alpha
  - [x] 1.1 Remove line-scoped settlement commitment module-ID usage
  - [x] 1.2 Remove line-scoped borrower collateral module-ID usage
  - [x] 1.3 Remove native runtime dependence on `LibModuleEncumbrance`
- [x] 2. Rewire lender commitment reservation through canonical encumbrance
  - [x] 2.1 Settle lender position state before commitment changes where
        required
  - [x] 2.2 Use `encumberedCapital` increase on commit
  - [x] 2.3 Use `encumberedCapital` decrease on cancel, exit, refinance
        resolution, and terminal close
  - [x] 2.4 Preserve any required ACI side effects
- [x] 3. Rewire borrower-posted collateral through canonical locking
  - [x] 3.1 Settle borrower position state before collateral locking where
        required
  - [x] 3.2 Use `lockedCapital` increase at activation
  - [x] 3.3 Release or consume `lockedCapital` correctly on repayment close
        and unhappy-path resolution
- [x] 4. Keep line and commitment attribution in Alpha-native storage
  - [x] 4.1 Preserve borrower profile, line, commitment, and payment storage
  - [x] 4.2 Preserve per-line exposure attribution without module IDs

## Task 4: Update Specs and Views to Match the Native Model

- [x] 1. Update or supersede the existing EqualScale Alpha spec so it no
      longer requires module encumbrance for native behavior
- [x] 2. Update product comments and docs that describe first-party Alpha or
      EqualIndex lending as module-native
- [x] 3. Remove or replace views whose only purpose is to expose native module
      IDs or module encumbrance attribution
- [x] 4. Ensure product-native views still expose enough state to explain active
      exposure

## Task 5: Update Tests and Invariants

- [x] 1. Update EqualIndex lending tests
  - [x] 1.1 Assert native `indexEncumbered` behavior
  - [x] 1.2 Remove module-ID-specific assertions
  - [x] 1.3 Preserve live-flow borrow / repay / recover coverage
- [x] 2. Update EqualScale Alpha tests
  - [x] 2.1 Assert lender commitment effects through `encumberedCapital`
  - [x] 2.2 Assert borrower collateral effects through `lockedCapital`
  - [x] 2.3 Remove module-ID namespace assertions for native venue behavior
  - [x] 2.4 Preserve solo, pooled, refinance, runoff, delinquency, and
        charge-off flow coverage
- [x] 3. Update invariant coverage
  - [x] 3.1 Native venue reservations remain aligned with canonical
        encumbrance totals
  - [x] 3.2 Product storage remains sufficient to explain active exposure
  - [x] 3.3 Reservation increases and decreases remain symmetric through
        terminal states

## Task 6: Update Launch and Selector Wiring

- [x] 1. Remove any launch or selector expectations tied only to legacy
      module-ID APIs
- [x] 2. Keep the intended native facet surfaces in the diamond
- [x] 3. Add or update launch tests to confirm the migrated native surfaces are
      wired correctly
