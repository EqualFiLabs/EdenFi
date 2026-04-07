# Tasks

## Task 1: Establish the Naming Boundary Before Implementation

- [x] 1. Reserve EDEN naming for the shared rewards engine
  - [x] 1.1 Audit existing `src/eden/*` modules for product-specific vs rewards-engine responsibilities
  - [x] 1.2 Classify product-specific modules that should move toward `stEVE` naming
  - [x] 1.3 Classify shared rewards-engine modules that should keep or gain `EDEN` naming
- [x] 1.4 Review and approve the explicit rename map in `.kiro/specs/eden-rewards-engine/rename-map.md`
- [x] 2. Update spec, comments, and implementation notes to reflect the final naming split
  - [x] 2.1 EqualFi = substrate
  - [x] 2.2 EqualIndex = generic basket / index layer
  - [x] 2.3 `stEVE` = product lane
  - [x] 2.4 EDEN = rewards engine

## Task 2: Build the EDEN Rewards Engine Storage and Program Registry

- [x] 1. Add greenfield rewards-engine storage
  - [x] 1.1 Add program id sequencing
  - [x] 1.2 Add program config and program state structs
  - [x] 1.3 Add per-program per-position reward checkpoint storage
  - [x] 1.4 Add per-program per-position accrued reward storage
- [x] 2. Add target typing
  - [x] 2.1 Define the target enum for `stEVE` and EqualIndex position rewards
  - [x] 2.2 Define the target-id convention
  - [x] 2.3 Add storage or indexing to discover programs by target

## Task 3: Implement Program Lifecycle

- [x] 1. Add reward-program creation
  - [x] 1.1 Create program with immutable target and reward token
  - [x] 1.2 Set rate, manager, and timing window
  - [x] 1.3 Prevent invalid target or timing configurations
- [x] 2. Add reward-program lifecycle controls
  - [x] 2.1 Enable / disable program accrual
  - [x] 2.2 Pause / resume program
  - [x] 2.3 End program accrual without invalidating existing claims
  - [x] 2.4 Add safe closure semantics for completed programs
- [x] 3. Add access control for governance and program managers

## Task 4: Implement Funding and Reserve-Bounded Accrual

- [x] 1. Add funding flows
  - [x] 1.1 Fund a program with its immutable reward token
  - [x] 1.2 Support repeated top-ups
  - [x] 1.3 Preserve fee-on-transfer-safe inbound accounting if needed
- [x] 2. Implement program-scoped global accrual
  - [x] 2.1 Accrue by elapsed time and reward rate
  - [x] 2.2 Bound accrual by reserve
  - [x] 2.3 Respect start / end windows
  - [x] 2.4 Keep accounting isolated per program

## Task 5: Implement Position Settlement and Claims

- [x] 1. Implement per-program position settlement
  - [x] 1.1 Settle global program state first
  - [x] 1.2 Compute pending rewards from the program index delta
  - [x] 1.3 Checkpoint the position for the program
- [x] 2. Implement claims
  - [x] 2.1 Claim rewards for a single program and position
  - [x] 2.2 Pay only in the originating program token
  - [x] 2.3 Zero accrued rewards before transfer
  - [x] 2.4 Consider an optional multi-program claim helper after the core path is correct

## Task 6: Integrate the stEVE Consumer Lane

- [x] 1. Refactor product-specific EDEN reward hooks toward `stEVE` ownership
  - [x] 1.1 Identify all `stEVE` position balance changes
  - [x] 1.2 Call rewards-engine settlement before eligible-balance changes
  - [x] 1.3 Update eligible supply after the owning lane mutates balance
- [x] 2. Define `stEVE` reward eligibility clearly
  - [x] 2.1 Only PNFT-held `stEVE` earns
  - [x] 2.2 Wallet-held `stEVE` does not earn
  - [x] 2.3 Reward claims remain controlled by the current position owner

## Task 7: Integrate the EqualIndex Consumer Lane

- [x] 1. Add EqualIndex reward hooks
  - [x] 1.1 Settle rewards before `mintFromPosition`
  - [x] 1.2 Settle rewards before `burnFromPosition`
  - [x] 1.3 Settle rewards on recovery / liquidation paths that reduce position-owned index principal
- [x] 2. Define EqualIndex reward eligibility clearly
  - [x] 2.1 Eligibility is scoped to a specific `indexId`
  - [x] 2.2 Only PNFT-held EqualIndex principal earns
  - [x] 2.3 Wallet-held EqualIndex balances do not earn in v1

## Task 8: Add Views and Agent Surfaces

- [x] 1. Add program metadata views
  - [x] 1.1 Get program config
  - [x] 1.2 Get program reserve and status
  - [x] 1.3 List programs by target
- [x] 2. Add position reward views
  - [x] 2.1 Preview claimable rewards for one program and position
  - [x] 2.2 Expose accrued + pending state
  - [x] 2.3 Add optional aggregate reads across program ids for a position

## Task 9: Rename Product-Specific EDEN Modules Toward stEVE

- [x] 1. Rename product-specific storage, actions, and views to `stEVE` naming where they are not part of the shared rewards engine
- [x] 2. Update imports, selectors, tests, deploy scripts, and comments to reflect the new names
- [x] 3. Ensure final code naming does not leave EDEN meaning both “product lane” and “rewards engine”

## Task 10: Add Tests and Invariants for the Reward Liability Model

- [x] 1. Add unit tests for program creation, funding, accrual, settlement, and claiming
- [x] 2. Add tests proving the M-01 class of bug is impossible
  - [x] 2.1 Liabilities earned under token A remain payable in token A
  - [x] 2.2 Program token identity does not drift after reserve changes
- [x] 3. Add tests proving reserve bounds accrual
- [x] 4. Add tests proving concurrent programs over one target remain isolated
- [x] 5. Add tests proving only eligible PNFT-held balances earn
- [x] 6. Add tests proving `stEVE` hooks settle before balance mutation
- [x] 7. Add tests proving EqualIndex hooks settle before balance mutation
- [x] 8. Add invariant coverage where practical for reserve, liabilities, and per-program isolation

## Task 11: Checkpoint the Architecture Before Broad Refactors

- [x] 1. Review this spec set against the existing `eden-steve-only-clean-break` spec
- [x] 2. Confirm the naming split is accepted before large file renames
- [x] 3. Confirm whether v1 should support one or multiple concurrent programs per target
- [x] 4. Confirm whether claim UX should stay strictly per-program or include aggregate claim helpers in the first implementation pass

## Task 12: Remove Legacy Rewards Code and Unify on the EDEN Program Engine

- [x] 1. Remove the legacy singleton rewards engine from the live surface
  - [x] 1.1 Remove `EdenRewardFacet` from the deploy script and selector surface
  - [x] 1.2 Delete legacy reward storage and helper libraries
  - [x] 1.3 Remove legacy tests, fixtures, and helper paths that still call `configureRewards`, `fundRewards`, or `claimRewards`
  - [x] 1.4 Confirm no live stEVE or EqualIndex hook still settles legacy reward state
- [x] 2. Make the new `EdenRewardsFacet` the only reward engine entrypoint
  - [x] 2.1 Ensure all reward funding, settlement, claiming, and views route through program-scoped APIs
  - [x] 2.2 Confirm no product-lane module reads or mutates legacy reward storage
  - [x] 2.3 Remove any remaining singleton-reward assumptions from deploy and view surfaces

## Task 13: Fix Lifecycle Checkpointing so Program Controls Cannot Burn Earned Emissions

- [x] 1. Accrue program state before lifecycle mutations
  - [x] 1.1 Accrue before `setRewardProgramEnabled`
  - [x] 1.2 Accrue before `pauseRewardProgram`
  - [x] 1.3 Accrue before `resumeRewardProgram`
  - [x] 1.4 Accrue before `endRewardProgram`
  - [x] 1.5 Accrue before `closeRewardProgram`
- [x] 2. Preserve claims through end / close flows
  - [x] 2.1 Ensure ending a program checkpoints final emissions under the pre-change config
  - [x] 2.2 Ensure closing a completed program does not invalidate later claims
  - [x] 2.3 Add tests for pause / disable / end with long idle periods before mutation

## Task 14: Rebuild Reward Eligibility Around Canonical Settled Principal

- [x] 1. Remove reward-only cached eligibility for `stEVE`
  - [x] 1.1 Stop treating `eligiblePrincipal` and `eligibleSupply` as the source of truth
  - [x] 1.2 Derive `stEVE` eligible balance from the settled product-pool principal
  - [x] 1.3 Derive program-level `stEVE` supply from the authoritative product-pool state
- [x] 2. Keep EqualIndex rewards aligned with canonical settled principal
  - [x] 2.1 Confirm position eligibility always uses settled EqualIndex pool principal
  - [x] 2.2 Confirm program-level EqualIndex supply is derived from authoritative pool state
  - [x] 2.3 Eliminate any path where rewards use stale pre-maintenance balances
- [x] 3. Refactor hooks around the new source of truth
  - [x] 3.1 Update stEVE hooks to settle before mutation using canonical settled principal
  - [x] 3.2 Update EqualIndex hooks to settle before mutation using canonical settled principal
  - [x] 3.3 Re-check lending recovery and liquidation paths after the source-of-truth change

## Task 15: Reconcile Reward Supply with Maintenance and Other Global Balance Changes

- [x] 1. Identify every path that changes effective eligible principal without an explicit mint / burn / deposit / withdraw call
  - [x] 1.1 Maintenance index settlement
  - [x] 1.2 Any fee-index-driven principal changes
  - [x] 1.3 Any recovery or write-down paths that bypass normal hooks
- [x] 2. Ensure program-level eligible supply stays synchronized when those paths execute
  - [x] 2.1 Prevent stEVE positions from earning on pre-maintenance balances
  - [x] 2.2 Prevent EqualIndex programs from consuming reserve against stale inflated supply
  - [x] 2.3 Decide whether supply is recomputed on demand or synchronized during each global-balance transition
- [x] 3. Add maintenance-sensitive regression coverage
  - [x] 3.1 stEVE rewards after maintenance
  - [x] 3.2 EqualIndex rewards after maintenance
  - [x] 3.3 Reserve / claimable / claimed accounting after maintenance

## Task 16: Tighten Reward Token Policy and Claim Semantics

- [x] 1. Support outbound fee-on-transfer reward tokens through net receipt semantics
  - [x] 1.1 Add explicit program-level outbound transfer-fee configuration for gross-up
  - [x] 1.2 Restore residual liability when actual net receipt is below the intended claim amount
- [x] 2. Preserve zero-before-transfer safety while preventing silent liability haircut
  - [x] 2.1 Add explicit tests for configured and unconfigured fee-on-transfer reward tokens on claim
  - [x] 2.2 Document the accepted reward-token policy in the rewards spec

## Task 17: Update Product Views and UX Surfaces to the Program-Native Model

- [x] 1. Remove remaining singleton reward assumptions from `stEVE` views
  - [x] 1.1 Replace singular reward-token / rate / reserve reads with program-native reads where appropriate
  - [x] 1.2 Add helper views for active reward programs on the `stEVE` lane if useful for UI
- [x] 2. Keep EqualIndex reward discovery program-native
  - [x] 2.1 Prefer target-scoped program discovery over singleton reward summaries
  - [x] 2.2 Ensure preview surfaces match claim behavior after the accounting refactor

## Task 18: Re-Audit and Re-Test the Final Rewards Architecture

- [x] 1. Add regression tests for each audit finding
  - [x] 1.1 Legacy reward selectors absent from the live diamond
  - [x] 1.2 Lifecycle controls cannot erase accrued-but-uncheckpointed emissions
  - [x] 1.3 `stEVE` rewards cannot exceed settled principal after maintenance
  - [x] 1.4 EqualIndex reserve cannot become stranded through stale eligible supply
  - [x] 1.5 Reward-token policy behaves exactly as documented on claim
- [x] 2. Re-run focused suites after the refactor
  - [x] 2.1 `test/EdenRewardsFacet.t.sol`
  - [x] 2.2 `test/StEVEActionFacet.t.sol`
  - [x] 2.3 `test/EqualIndexLaunch.t.sol`
  - [x] 2.4 deploy / selector-surface suites
- [x] 3. Perform a final audit pass on the post-remediation codebase before shipping
