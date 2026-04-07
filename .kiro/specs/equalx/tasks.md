# Tasks

## Task 1: Lock the EqualX Boundary Before Implementation

- [x] 1. Confirm EqualX is the branded market layer within EqualFi
- [x] 2. Confirm EqualX scope includes:
  - [x] 2.1 Solo AMM
  - [x] 2.2 Community AMM
  - [x] 2.3 Curve Liquidity
- [x] 3. Confirm EqualX excludes unrelated legacy derivative modules unless
      explicitly re-approved later
- [x] 4. Confirm curve liquidity is treated as a distinct module rather than an
      AMM mode flag

## Task 2: Define EqualX Storage and Naming

- [x] 1. Create greenfield EqualX storage libraries instead of reusing the old
      monolithic derivative storage
  - [x] 1.1 Add Solo AMM storage
  - [x] 1.2 Add Community AMM storage
  - [x] 1.3 Add Curve Liquidity storage
- [x] 2. Define a clear file and facet layout under `src/equalx/*`
- [x] 3. Add typed market identifiers and discovery indexes by position, pair,
      and active status where useful

## Task 3: Port Shared Math and Shared Primitives

- [x] 1. Port volatile and stable swap math into a greenfield EqualX math
      library
- [x] 2. Port fee-asset semantics for fee-on-input and fee-on-output behavior
- [x] 3. Port the community fee-index math into a greenfield EqualX fee-index
      library
- [x] 4. Re-validate old fee split logic against the current EqualFi substrate
      before reusing it
  - [x] 4.1 Preserve maker-first, protocol-remainder-second routing
  - [x] 4.2 Preserve treasury transfer on each swap
  - [x] 4.3 Preserve active-credit and fee-index accrual from the routed
        protocol remainder

## Task 4: Implement EqualX Solo AMM

- [x] 1. Add solo AMM market creation
  - [x] 1.1 Validate ownership, membership, pool pairing, and time windows
  - [x] 1.2 Lock or encumber maker backing capital
  - [x] 1.3 Support volatile invariant mode
  - [x] 1.4 Support stable invariant mode behind explicit validation
- [x] 2. Add taker swap execution
  - [x] 2.1 Match execution to quote math
  - [x] 2.2 Route fees explicitly
  - [x] 2.3 Prevent stale or invalid lifecycle execution
  - [x] 2.4 Use transient swap-cache style helpers in the hot path
  - [x] 2.5 Preserve low-gas reserve-accounting by avoiding principal and
        deposit reconciliation on each swap
  - [x] 2.6 Preserve treasury transfer, active-credit accrual, and fee-index
        accrual on each swap while principal reconciliation remains deferred
  - [x] 2.7 Preserve reserve-backed fee routing semantics equivalent to
        `routeSamePool(..., false, extraBacking)`
- [x] 3. Add expiry, cancel, and finalize flows
  - [x] 3.1 Keep cleanup permissionless where possible
  - [x] 3.2 Release or reconcile locked backing correctly
  - [x] 3.3 Reconcile maker principal and backing on close-time settlement
        rather than per-swap churn

## Task 5: Implement EqualX Community AMM

- [x] 1. Add community AMM market creation
  - [x] 1.1 Validate creator ownership, membership, and time windows
  - [x] 1.2 Seed the initial reserve and share state
- [x] 2. Add maker join flows
  - [x] 2.1 Enforce ratio rules
  - [x] 2.2 Snapshot fee indexes correctly before share changes
  - [x] 2.3 Update maker counts and total shares safely
- [x] 3. Add maker leave and claim flows
  - [x] 3.1 Settle indexed fees correctly
  - [x] 3.2 Reconcile reserve withdrawal against backing and contributions
- [x] 4. Add taker swap execution and permissionless finalize / expiry
  - [x] 4.1 Use transient swap-cache style helpers in the hot path
  - [x] 4.2 Preserve low-gas reserve-accounting by avoiding full principal and
        share-backing reconciliation on each swap
  - [x] 4.3 Preserve treasury transfer, active-credit accrual, fee-index
        accrual, and community fee-index accrual on each swap
  - [x] 4.4 Reconcile canonical maker backing on leave, claim, or finalization
        instead of during every taker execution
  - [x] 4.5 Preserve reserve-backed fee routing semantics equivalent to
        `routeSamePool(..., false, extraBacking)`

## Task 6: Implement EqualX Curve Liquidity

- [x] 1. Add curve creation
  - [x] 1.1 Validate descriptor shape, ownership, membership, and time bounds
  - [x] 1.2 Lock or encumber base-side collateral
  - [x] 1.3 Keep base-side backing inside the canonical ACI / encumbrance model
  - [x] 1.4 Store pricing and profile data cleanly
- [x] 2. Add curve updates and cancellations
  - [x] 2.1 Increment generation on meaningful updates
  - [x] 2.2 Recompute commitment hashes safely
  - [x] 2.3 Release backing on cancel or expiry as appropriate
- [x] 3. Add curve execution
  - [x] 3.1 Enforce generation and commitment guards
  - [x] 3.2 Keep quote and execution parity
  - [x] 3.3 Track remaining executable volume correctly
- [x] 4. Add built-in pricing profile support for v1

## Task 7: Add Profile Registry and Governance Controls

- [x] 1. Add governance-controlled pricing profile approval
- [x] 2. Add profile metadata reads
- [x] 3. Ensure unapproved profiles cannot be used in execution paths
- [x] 4. Decide which built-in profile ships in v1 beyond the default linear
      profile
  - [x] 4.1 v1 ships with the default linear built-in profile only

## Task 8: Integrate EqualX with the Current EqualFi Substrate

- [x] 1. Ensure all EqualX maker flows use canonical settled principal
- [x] 2. Ensure FI / ACI / maintenance settlement ordering is correct before
      backing changes
- [x] 3. Ensure EqualX encumbrance and lock semantics compose safely with
      lending and withdrawal flows
- [x] 4. Re-check native ETH behavior against current substrate helpers rather
      than old custom logic

## Task 9: Add EqualX Views and Agent Surfaces

- [x] 1. Add market metadata and state views for each EqualX module
- [x] 2. Add position-scoped discovery views
- [x] 3. Add pair-scoped and active-market discovery views
- [x] 4. Add execution-faithful preview and quote helpers
- [x] 5. Add maker participation and fee-pending views where relevant

## Task 10: Port the Valuable Invariants from the Older System

- [x] 1. Port Solo AMM invariants
  - [x] 1.1 Reserve and backing correctness
  - [x] 1.2 Finalize and expiry correctness
  - [x] 1.3 Quote / execution parity
- [x] 2. Port Community AMM invariants
  - [x] 2.1 Fee index remainder correctness
  - [x] 2.2 Maker share accounting correctness
  - [x] 2.3 Leave / claim / finalize correctness
- [x] 3. Port Curve Liquidity invariants
  - [x] 3.1 Generation and commitment mismatch protection
  - [x] 3.2 Remaining-volume correctness
  - [x] 3.3 Profile registry safety
- [x] 4. Prefer live-flow tests over setter-only harnesses wherever practical

## Task 11: Final Audit and Scope Review Before Shipping

- [x] 1. Review EqualX against the older Synthesis EqualFi feature surface and
      confirm what is intentionally not being ported
- [x] 2. Review EqualX against the current EqualFi substrate for integration
      risks
- [x] 3. Perform a dedicated security audit pass on solo AMM, community AMM,
      and curve liquidity after implementation
- [x] 4. Confirm branding, naming, and selector surfaces are coherent before
      broad frontend or agent integration
