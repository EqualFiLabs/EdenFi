# Implementation Plan: EDEN on EqualFi

## Overview

This implementation plan builds EDEN as a product layer on top of the EqualFi
substrate and EqualIndex accounting system.

The work is organized around five phases:

1. finish the minimum EqualFi substrate needed by EDEN
2. bring EqualIndex across as the canonical accounting layer
3. build EDEN basket and stEVE product surfaces on top
4. build position-owned EDEN lending and views
5. harden governance, deployment, and launch assembly

## Tasks

### Phase 1 — Finish EqualFi Substrate For EDEN

- [x] 1. Complete the minimum position-owned substrate
  - [x] 1.1 Port or finish `LibPositionHelpers`
    - Add canonical `positionKey` derivation
    - Add ownership validation helpers
    - Keep the helper layer trimmed to EDEN-relevant usage
    - _Requirements: 1.1–1.4, 3.1, 3.6_
  - [x] 1.2 Port or finish pool membership helpers
    - Support pool join / membership existence / safe cleanup
    - Keep the implementation generic and substrate-native
    - _Requirements: 1.1–1.4, 3.5_
  - [x] 1.3 Port or finish a trimmed `PositionManagementFacet`
    - Support `mintPosition`
    - Support deposit of pool principal to a position
    - Support withdrawal of pool principal from a position
    - Settle FI around principal changes
    - _Requirements: 2.1–2.4, 3.1–3.5_
  - [x] 1.4 Verify EDEN-needed substrate feeds into FI / ACI
    - Ensure the fee router and dual indexes are live for position-owned principal
    - Add only the minimum EDEN-needed hooks, not unrelated future module logic
    - _Requirements: 1.1–1.4, 3.4_
  - [x] 1.5 Write substrate tests
    - Position minting
    - Deposit / withdraw correctness
    - Pool membership behavior
    - FI settlement around principal changes
    - _Requirements: 3.1–3.6_

- [x] 2. Checkpoint — substrate ready for EDEN
  - Ensure all substrate tests pass
  - Verify no EDEN-specific accounting logic has leaked into generic substrate code

### Phase 2 — Bring EqualIndex Across As Canonical Accounting

- [ ] 3. Port the EqualIndex surface needed by EDEN
  - [x] 3.1 Bring over wallet-mode mint/burn flows
    - Preserve EOA mint and burn semantics
    - Preserve pool-backed fee routing
    - _Requirements: 1.2, 2.1–2.3_
  - [x] 3.2 Bring over position-mode mint/burn flows
    - Preserve position-owned principal accounting
    - Preserve FI settlement and pool membership behavior
    - _Requirements: 1.2, 2.2, 3.1–3.5_
  - [x] 3.3 Keep EqualIndex accounting canonical
    - Avoid introducing EDEN-specific forks into generic EqualIndex internals
    - _Requirements: 1.1–1.4_
  - [x] 3.4 Write EqualIndex port tests
    - Wallet-mode mint/burn
    - Position-mode mint/burn
    - Fee routing correctness
    - Principal settlement correctness
    - _Requirements: 1.1–1.4, 2.1–2.4_

- [x] 4. Checkpoint — EqualIndex native in EdenFi
  - Ensure EqualIndex behavior is preserved
  - Verify the port remains EDEN-agnostic at the accounting layer

### Phase 3 — Build EDEN Basket and stEVE Product Surfaces

- [ ] 5. Build EDEN basket primitives on top of EqualFi / EqualIndex
  - [x] 5.1 Define EDEN basket storage and metadata
    - Add basket configuration, metadata, and product-specific state
    - Keep pool/accounting state separate from basket metadata
    - _Requirements: 4.1–4.5_
  - [x] 5.2 Port basket token contracts
    - Port `BasketToken` semantics
    - Ensure compatibility with wallet mode and position mode
    - _Requirements: 2.1–2.4, 4.1–4.5_
  - [x] 5.3 Port basket creation and mint/burn flows
    - Create baskets
    - Support mint and burn behavior
    - Preserve FoT-safe inbound accounting
    - _Requirements: 4.1–4.5_
  - [x] 5.4 Decide and implement wallet-mode vs position-mode entry points
    - Support the minimum surface needed for both user modes
    - Keep the public interface consistent
    - _Requirements: 2.1–2.4, 4.5_
  - [x] 5.5 Write EDEN basket tests
    - Basket creation
    - Wallet mint/burn
    - Position-aware flows where applicable
    - FoT-safe accounting
    - _Requirements: 4.1–4.5_

- [ ] 6. Build stEVE as an EDEN product token
  - [x] 6.1 Port stEVE token semantics
    - Support wallet-held stEVE
    - Preserve EDEN product semantics
    - _Requirements: 5.1–5.5_
  - [x] 6.2 Implement stEVE deposit to Position NFT
    - Validate position ownership
    - Move stEVE into reward-eligible position-owned principal
    - _Requirements: 5.3, 6.1–6.5_
  - [x] 6.3 Implement stEVE withdraw from Position NFT
    - Validate position ownership
    - Respect encumbrance and product restrictions
    - _Requirements: 5.4, 6.1–6.5_
  - [x] 6.4 Write stEVE position-flow tests
    - Deposit correctness
    - Withdraw correctness
    - Reward-eligible supply updates
    - Wallet-held stEVE remains non-eligible
    - _Requirements: 5.1–5.5, 6.1–6.5_

- [ ] 7. Build the EDEN `EVE` reward facet
  - [x] 7.1 Add reward configuration and storage
    - Reward token
    - Reward rate
    - Global reward index
    - Eligible supply
    - Per-position checkpoints and accrued rewards
    - _Requirements: 6.1–6.5, 7.1–7.7_
  - [x] 7.2 Implement global reward index accrual
    - Update by elapsed time and eligible supply
    - Avoid TWAB epoch logic
    - _Requirements: 7.1–7.7_
  - [x] 7.3 Implement per-position reward settlement
    - Settle before principal changes
    - Settle on claim
    - Preserve accrued rewards on position transfer
    - _Requirements: 6.4–6.5, 7.3–7.7_
  - [x] 7.4 Implement funding and claim flows
    - Fund `EVE`
    - Preview rewards
    - Claim rewards from a position
    - Avoid silent reward burning under funding edge cases
    - _Requirements: 7.1–7.7_
  - [x] 7.5 Write reward facet tests
    - Only PNFT-held stEVE earns
    - Reward accrual proportional to principal * time
    - Settlement before principal changes
    - Claim correctness
    - Position transfer reward ownership
    - _Requirements: 6.1–6.5, 7.1–7.7_

- [x] 8. Checkpoint — EDEN product core ready
  - Ensure baskets, stEVE, and the reward facet all pass tests
  - Verify TWAB epoch logic is not being reintroduced into the new design

### Phase 4 — Build Position-Owned EDEN Lending and Views

- [x] 9. Build position-owned EDEN lending
  - [x] 9.1 Replace address-owned loan ownership with `positionKey`
    - Loans belong to positions
    - Borrowers are positions, not wallet addresses
    - _Requirements: 9.1–9.5_
  - [x] 9.2 Use encumbrance for collateral locks
    - Lock and unlock collateral through substrate primitives
    - Remove address-scan-based collateral tracking
    - _Requirements: 9.2, 9.5–9.6_
  - [x] 9.3 Port borrow / repay / extend / recovery flows
    - Keep EDEN lending product behavior
    - Rebase on position ownership and FoT-safe repayment logic
    - _Requirements: 9.1–9.6_
  - [x] 9.4 Port loan previews and durable views
    - Borrow preview
    - Repay preview
    - Extend preview
    - Loan history and lifecycle views
    - _Requirements: 9.4–9.6, 10.2–10.4_
  - [x] 9.5 Write lending tests
    - Position-owned borrow/repay correctness
    - Encumbrance correctness
    - Expiry/recovery behavior
    - View and preview correctness
    - _Requirements: 9.1–9.6_

- [x] 10. Build EDEN read and agent surfaces
  - [x] 10.1 Implement metadata and basket summary reads
    - Basket discovery
    - Basket metadata
    - Product config views
    - _Requirements: 10.1, 10.6_
  - [x] 10.2 Implement position-aware portfolio reads
    - User -> positions
    - Position -> baskets
    - Position -> reward state
    - _Requirements: 10.2–10.4_
  - [x] 10.3 Implement position-aware action-check surfaces
    - canMint
    - canBurn
    - canBorrow
    - canRepay
    - canExtend
    - canClaimRewards
    - _Requirements: 10.5–10.6_
  - [x] 10.4 Write read-surface tests
    - Metadata correctness
    - Portfolio completeness
    - Reward view correctness
    - Action-check correctness
    - _Requirements: 10.1–10.6_

- [x] 11. Checkpoint — EDEN functionality complete
  - Ensure lending and views pass end-to-end tests
  - Verify the product is fully position-aware where required

### Phase 5 — Governance, Deployment, and Launch Assembly

- [x] 12. Rebuild EDEN governance and admin surfaces on EqualFi
  - [x] 12.1 Port EDEN admin/config reads and writes
    - Basket metadata setters
    - Product URI/versioning
    - Pause/config surfaces
    - _Requirements: 11.1–11.5_
  - [x] 12.2 Keep 7-day timelock governance canonical
    - Ensure EDEN product actions inherit EqualFi hardened governance
    - _Requirements: 11.1–11.4_
  - [x] 12.3 Port observability and admin events
    - Metadata events
    - Config events
    - Governance-friendly read surfaces
    - _Requirements: 10.1, 11.1–11.5_
  - [x] 12.4 Write governance tests
    - Timelock-only privileged actions
    - Event emissions
    - Config correctness
    - _Requirements: 11.1–11.5_

- [x] 13. Assemble the EDEN launch bundle
  - [x] 13.1 Create the EDEN deployment facet/module set
    - Include only substrate, EqualIndex, and EDEN product pieces needed for launch
    - _Requirements: 11.3–11.5_
  - [x] 13.2 Port bootstrap and deployment scripts
    - Deploy substrate
    - Deploy EDEN product assembly
    - Hand off governance to timelock
    - _Requirements: 11.1–11.5_
  - [x] 13.3 Add end-to-end EDEN integration tests
    - Wallet-mode flows
    - Position-mode flows
    - stEVE deposit and reward flow
    - Lending flow
    - Governance/admin behavior
    - _Requirements: 2.1–2.4, 4.1–4.5, 5.1–5.5, 6.1–6.5, 7.1–7.7, 9.1–9.6, 11.1–11.5_

- [x] 14. Checkpoint — EDEN launch-ready
  - Ensure all tests pass
  - Verify the launch bundle excludes unrelated future EqualFi modules
  - Verify EDEN rewards are index-based and only accrue to PNFT-held stEVE

### Phase 6 — Test Hardening and Protocol Assurance

- [x] 15. Replace harness-driven confidence with real-flow fixtures
  - [x] 15.1 Build canonical deployed fixtures for testing
    - Add reusable helpers that deploy the real diamond, install the launch facet set, and bootstrap protocol state through public/external entrypoints
    - Prefer the real deployment script path where practical
  - [x] 15.2 Remove storage-setter dependence from primary flow tests
    - Migrate basket, stEVE, reward, lending, view, and admin tests off direct `setOwner`, `setTimelock`, `setTreasury`, and overridden `setDefaultPoolConfig` shortcuts
    - Keep direct storage mutation only in narrowly scoped library/smoke fixtures where no real flow exists
  - [x] 15.3 Separate smoke/library tests from protocol-flow tests
    - Mark synthetic library tests as smoke coverage only
    - Ensure critical product assurances come from real user/admin/governance flows, not seeded storage

- [x] 16. Exhaustively cover unhappy paths and edge cases
  - [x] 16.1 Replace low-signal revert checks with exact expectations
    - Use `vm.expectRevert(<custom error selector>)` wherever the revert reason is part of the contract guarantee
    - Avoid low-level `call` + `!ok` except where selector matching is impossible
  - [x] 16.2 Add access-control and governance negative tests
    - Unauthorized owner/timelock calls
    - Timelock scheduling/execution failures
    - Ownership and diamond-cut rejection paths
  - [x] 16.3 Add basket and EqualIndex edge-case tests
    - Zero amounts
    - Invalid bundle definitions
    - Duplicate/canonical pool mismatches
    - Paused baskets/indexes
    - Fee cap and slippage failures
    - Fee-on-transfer underreceipt cases
  - [x] 16.4 Add stEVE and reward edge-case tests
    - Disabled rewards
    - Zero eligible supply
    - Underfunded reserve behavior
    - Reward funding with insufficient delta
    - Claims after transfers, partial claims, and repeated settlement
  - [x] 16.5 Add lending edge-case tests
    - Invalid durations
    - Invalid fee tiers
    - Position mismatch
    - Expired and already-closed loans
    - Recovery rejection paths
    - FoT repayment underreceipt
    - Preview failure-mode parity with execution paths

- [x] 17. Add broad fuzz coverage for all value-moving flows
  - [x] 17.1 Fuzz substrate position flows
    - Mint position
    - Deposit / withdraw
    - Membership cleanup
    - Position yield claim
  - [x] 17.2 Fuzz EqualIndex flows
    - Wallet-mode mint / burn
    - Position-mode mint / burn
    - Fee routing splits
    - Principal settlement around mint/burn boundaries
  - [x] 17.3 Fuzz EDEN basket flows
    - Wallet mint / burn
    - Position mint / burn
    - FoT-safe accounting
    - Fee routing and vault balance conservation
  - [x] 17.4 Fuzz stEVE flows
    - Wallet-held vs PNFT-held balances
    - Deposit / withdraw
    - Eligibility accounting across repeated transitions
  - [x] 17.5 Fuzz reward flows
    - Funding
    - Accrual over time
    - Settlement before principal changes
    - Claim correctness across multiple positions and transfers
  - [x] 17.6 Fuzz lending flows
    - Borrow / repay / extend / recover
    - Preview correctness
    - Encumbrance lock/unlock behavior
    - Borrow fee and collateral invariants

- [x] 18. Build stateful invariant suites with handlers
  - [x] 18.1 Create invariant fixtures around the real deployed diamond
    - Use Foundry handler contracts with multiple actors
    - Avoid direct storage mutation inside handlers except for explicit ghost variables
  - [x] 18.2 Add substrate accounting invariants
    - `trackedBalance`
    - `totalDeposits`
    - `yieldReserve`
    - `nativeTrackedTotal`
    - Membership cleanliness after zero-principal states
  - [x] 18.3 Add position and encumbrance invariants
    - Encumbrance never exceeds available principal
    - Position key stability across transfers
    - Cleanup only succeeds for clean memberships
  - [x] 18.4 Add basket and EqualIndex invariants
    - Basket/index total units vs backing
    - Position-mode encumbrance conservation
    - Wallet and position accounting remain consistent after arbitrary sequences
  - [x] 18.5 Add reward invariants
    - Only PNFT-held stEVE earns
    - Global reward index monotonicity
    - Accrued + claimed rewards never exceed funded reserve
    - Position transfer preserves reward ownership without duplication
  - [x] 18.6 Add lending invariants
    - Loan lifecycle consistency
    - Outstanding principal accounting
    - Encumbered collateral conservation
    - Recovery and closure bookkeeping
  - [x] 18.7 Add governance/deployment invariants
    - Timelock remains the privileged controller after handoff
    - Fixed delay cannot be changed away from 7 days
    - Unauthorized actors cannot mutate protocol config

- [x] 19. Cover currently untested or under-tested subsystems
  - [x] 19.1 Add managed pool tests
    - `initManagedPool`
    - Manager-only mutable config
    - Whitelist add/remove/toggle behavior
    - Manager transfer and renunciation
  - [x] 19.2 Add managed fee-routing tests
    - `routeManagedShare`
    - System-share fallback to treasury
    - Base-pool routing correctness
    - Managed/system split accounting
  - [x] 19.3 Add direct `FixedDelayTimelockController` tests
    - Role restrictions
    - Schedule / execute / delay enforcement
    - `updateDelay` immutability behavior
  - [x] 19.4 Add core diamond negative tests
    - Loupe selector integrity
    - Ownership transfer edge cases
    - `DiamondInit` rejection paths
    - Unauthorized `diamondCut`
  - [x] 19.5 Add full branch coverage for read and agent surfaces
    - Every `ActionCheck` code
    - Unknown basket/index paths
    - Disabled rewards
    - Invalid duration / tier / balance branches
    - Portfolio and pagination boundary conditions

- [x] 20. Add admin and view surfaces for the existing pool-level AUM system
  - [x] 20.1 Port pool-level AUM admin writes
    - Add bounded `setAumFee`-style governance control for `currentAumFeeBps`
    - Keep enforcement within immutable per-pool min/max bounds
    - Do not port module registry or module-AUM controls in this phase
  - [x] 20.2 Port pool-level AUM and maintenance views
    - Expose current AUM fee, immutable AUM bounds, and maintenance state
    - Expose pool config and pool info views needed for governance and frontends
    - Keep the surface limited to the current pool-level AUM system already present in EdenFi
  - [x] 20.3 Add events for pool-level AUM admin changes
    - Emit explicit observability for AUM fee updates and any related config changes
    - Keep event scope limited to current pool-level AUM / maintenance configuration
  - [x] 20.4 Write pool-level AUM admin/view tests
    - Timelock-only AUM fee updates
    - Min/max bound enforcement
    - View correctness for current fee, bounds, and maintenance state
    - No module or module-AUM behavior introduced by this work

- [x] 21. Checkpoint — protocol assurance suite ready
  - Ensure primary flow tests use real protocol entrypoints rather than storage setters
  - Ensure all critical unhappy paths assert exact revert reasons where possible
  - Ensure fuzz suites and invariant suites are stable and deterministic
  - Ensure managed pools, timelock controller behavior, and diamond-core security paths are covered
  - Ensure launch confidence comes from real deployed-diamond tests, not synthetic seeded state alone
  - Ensure pool-level AUM admin and view surfaces are present without pulling in module or module-AUM scope
