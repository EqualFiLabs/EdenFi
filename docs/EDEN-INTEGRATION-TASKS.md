# EqualFi Substrate -> EDEN Integration Tasks

This checklist is intentionally scoped to one end goal:

- integrate **EDEN by EqualFi** onto the **EqualFi substrate**

It is not a plan to port all of EqualFi. The design should leave room for later
modules, but every task here should earn its place by moving us directly toward
an EDEN by EqualFi launch path.

## Phase 0 - Architecture Lock

- [ ] 0.1 Decide the EDEN operating model on the EqualFi substrate
  - Confirm EDEN will use position-owned accounting as the canonical model for leveraged and protocol-native flows
  - Confirm whether plain wallet-held basket tokens remain supported for simple users, or whether EDEN mints into positions only
  - Lock the rule for how stEVE rewards accrue when stEVE is held by a position

- [ ] 0.2 Define the EqualFi/EDEN boundary
  - EqualFi owns reusable primitives: pools, positions, encumbrance, fee routing, fee indexes, access, timelock
  - EDEN by EqualFi owns product logic: basket construction, stEVE, basket lending, basket metadata, EDEN-specific views
  - Write down which current `eden/repo/src` contracts are targets for replacement vs adaptation

- [ ] 0.3 Write the migration architecture note
  - Document how current EDEN address-owned state maps to future position-owned state
  - Decide whether launch happens from a fresh deployment or from a migration path
  - Explicitly note which old EDEN assumptions will be removed

## Phase 1 - Complete Position-Owned Pool Accounting In EqualFi

- [ ] 1.1 Port the minimal position helper layer
  - Bring over a trimmed `LibPositionHelpers`
  - Add the minimum ownership checks and `positionKey` helpers needed by EDEN
  - Avoid pulling in unrelated offerbook/direct-lending logic

- [ ] 1.2 Port the minimum pool membership layer
  - Add the smallest reusable membership primitive required by position-owned deposits and withdrawals
  - Support pool join, membership checks, and safe cleanup
  - Keep the implementation generic and EDEN-agnostic

- [ ] 1.3 Port a trimmed `PositionManagementFacet`
  - Support `mintPosition`
  - Support deposit to position principal
  - Support withdraw from position principal
  - Support fee-index settlement around deposit/withdraw
  - Exclude direct-lending, points, and unrelated module hooks for now

- [ ] 1.4 Complete ACI/FI substrate feeds needed by EDEN
  - Ensure `LibFeeRouter`, `LibFeeIndex`, and `LibActiveCreditIndex` are wired correctly for position-owned principal
  - Add only the debt/encumbrance hooks EDEN lending will require
  - Keep the fee-index design generic rather than EDEN-specific

- [ ] 1.5 Add EqualFi substrate tests for position-owned pool accounting
  - Position minting
  - Deposit/withdraw correctness
  - Membership behavior
  - FI settlement on principal
  - ACI behavior for encumbered principal

## Phase 2 - Port EDEN Basket Primitives Onto The EqualFi Substrate

- [ ] 2.1 Define EqualFi-native basket storage for EDEN
  - Port the EDEN basket/index storage model into the EqualFi substrate
  - Reconcile basket state with EqualFi pool/accounting primitives
  - Keep basket metadata and versioning separate from pool accounting concerns

- [ ] 2.2 Port basket token contracts
  - Bring over `BasketToken` and `StEVEToken` semantics as EqualFi-compatible contracts
  - Preserve transfer hooks needed for accounting updates
  - Ensure the token layer is compatible with positions and future module encumbrance

- [ ] 2.3 Port core basket creation and basket accounting
  - Port/create the EDEN-equivalent core facet on the EqualFi substrate
  - Create baskets
  - Mint and burn basket units
  - Preserve fee-pot logic and FoT-safe asset accounting
  - Rework the implementation to use EdenFi storage and helpers, not old EDEN assumptions

- [ ] 2.4 Decide and implement wallet-mode vs position-mode minting
  - If hybrid: support both `mint(...)` and `mintToPosition(...)`
  - If position-native: make positions the only stateful accounting owner and keep wallet holdings as output wrappers only
  - Keep the public surface minimal and consistent

- [ ] 2.5 Add tests for basket operations on the EqualFi substrate
  - Basket creation
  - Mint/burn accounting
  - Fee routing
  - Fee-pot behavior
  - Position-owned basket balances

## Phase 3 - Port stEVE And Reward Systems

- [ ] 3.1 Port stEVE reward configuration and TWAB logic
  - Rebuild stEVE rewards on EqualFi storage and token hooks
  - Preserve the current “unfunded epochs remain claimable” behavior
  - Keep the implementation compatible with position-held stEVE

- [ ] 3.2 Decide how stEVE rewards work for positions
  - Option A: rewards accrue to the position, claimable by current NFT owner
  - Option B: rewards accrue to wallet holders only, positions cannot hold reward-bearing stEVE
  - Lock one model and build views around it

- [ ] 3.3 Port indexed non-stEVE fee distribution for stEVE holders
  - Bring over the current EDEN indexed-fee logic in a way that sits cleanly on the EqualFi substrate
  - Ensure position-held stEVE is included correctly if positions are allowed to hold stEVE

- [ ] 3.4 Add tests for stEVE on the EqualFi substrate
  - TWAB correctness
  - claim flow
  - unfunded-epoch behavior
  - indexed-fee claims
  - position-held stEVE behavior

## Phase 4 - Port EDEN Lending As Position-Owned Lending

- [ ] 4.1 Replace address-owned basket loans with position-owned basket loans
  - Basket loans should belong to `positionKey`, not wallet address
  - Collateral locks should use EqualFi encumbrance primitives
  - Remove loan logic that depends on scanning borrower addresses

- [ ] 4.2 Implement EDEN lending hooks into ACI/FI
  - Debt and encumbrance changes should feed the EqualFi dual-index system cleanly
  - Same-asset debt treatment should be made explicit for EDEN baskets
  - Keep the implementation minimal for EDEN-only needs

- [ ] 4.3 Port borrow/repay/extend/recovery flows
  - Borrow from position
  - Repay from position
  - Extend from position
  - Recover expired collateral in a position-safe way
  - Preserve FoT-safe repayment accounting

- [ ] 4.4 Port loan views and previews
  - Loan history
  - Preview borrow/repay/extend
  - Position-owned portfolio views
  - Replace borrower-address views with position-aware views where appropriate

- [ ] 4.5 Add tests for position-owned EDEN lending
  - Borrow/repay correctness
  - Encumbrance behavior
  - ACI/FI interactions
  - Loan history
  - Recovery and expiry

## Phase 5 - Rebuild EDEN View And UX Surfaces On Top Of Positions

- [ ] 5.1 Rebuild metadata, portfolio, and agent views
  - Update EDEN views to read from positions and EqualFi ledgers
  - Preserve basket summaries, protocol summaries, and loan views
  - Rework user portfolio views so they reflect positions cleanly

- [ ] 5.2 Add position-aware portfolio aggregation
  - User -> positions
  - Position -> baskets
  - Position -> loans
  - Position -> rewards / indexed fees

- [ ] 5.3 Rebuild agent/action-check surfaces
  - `canMint`
  - `canBurn`
  - `canBorrow`
  - `canRepay`
  - `canExtend`
  - reward claim checks
  - make these position-aware where needed

- [ ] 5.4 Add tests for EDEN view parity
  - Preserve the useful EDEN read surface
  - Validate that position-owned state is reflected consistently

## Phase 6 - Governance, Admin, And Hardening

- [ ] 6.1 Rebuild EDEN admin/config surfaces on the EqualFi substrate
  - Basket metadata setters
  - protocol URI/version setters
  - pause/freeze/versioning/admin reads
  - keep timelock control as the canonical governance path

- [ ] 6.2 Integrate the real 7-day timelock model
  - Ensure EqualFi substrate governance matches the hardened EDEN direction
  - Avoid backsliding into owner-first shortcuts

- [ ] 6.3 Port event emissions and admin observability
  - Preserve the good event coverage already added in EDEN
  - Keep admin/config changes indexer-friendly

- [ ] 6.4 Add governance/security tests
  - timelock-only privileged actions
  - freeze behavior
  - event emissions
  - config surfaces

## Phase 7 - EDEN Product Assembly On EqualFi

- [ ] 7.1 Create the EDEN by EqualFi facet set
  - Assemble only the facets/modules required for EDEN
  - Keep optional future modules out of the deployed product set

- [ ] 7.2 Port or rewrite deployment scripts
  - EqualFi substrate deployment
  - EDEN by EqualFi product assembly
  - bootstrap / timelock ownership handoff
  - initial pool and basket setup

- [ ] 7.3 Establish integration parity against current EDEN behavior
  - Basket mint/burn
  - stEVE rewards
  - indexed fee distribution
  - lending
  - metadata and views

- [ ] 7.4 Add end-to-end EDEN integration tests on the EqualFi substrate
  - full happy paths
  - FoT token behavior
  - fee routing
  - position-owned flows
  - governance/admin behavior

## Phase 8 - Launch Readiness For EDEN

- [ ] 8.1 Run a focused security review on EqualFi substrate + EDEN product assembly
  - position transfer semantics
  - encumbrance invariants
  - fee routing correctness
  - stEVE reward behavior
  - governance hardening

- [ ] 8.2 Freeze/lock the EDEN launch architecture
  - Decide what is frozen at launch
  - Decide what remains upgradeable
  - Explicitly document the boundaries

- [ ] 8.3 Prepare launch docs
  - architecture overview
  - trust model
  - timelock/governance model
  - user-facing risks and semantics

## Recommended Immediate Build Order

If we want the highest-leverage next sequence, do this:

1. Port trimmed `PositionManagementFacet`
2. Add minimal pool membership helpers
3. Make position-owned principal live in the EqualFi substrate
4. Port EDEN baskets onto the EqualFi substrate
5. Port EDEN lending onto `positionKey`
6. Port stEVE and indexed-fee flows
7. Rebuild EDEN views and deployment assembly

## Definition Of Done

We are done with this plan when:

- EDEN by EqualFi runs on EqualFi substrate primitives instead of the old standalone EDEN architecture
- basket lending is position-owned
- stEVE rewards and indexed fees work on the new substrate
- governance is timelock-controlled
- the deployed EDEN product excludes unrelated EqualFi modules
- the substrate still leaves room for future modules without forcing rewrites
