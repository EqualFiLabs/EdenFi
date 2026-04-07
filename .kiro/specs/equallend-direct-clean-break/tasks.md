# Tasks

## Task 1: Establish the Clean Direct Storage and Type System
- [x] 1. Create or refactor the canonical EqualLend Direct storage layer
  - [x] 1.1 Define clean enums for fixed, rolling, and ratio-tranche offer kinds
  - [x] 1.2 Define fixed, rolling, and ratio-tranche offer structs around one shared accounting model
  - [x] 1.3 Define fixed and rolling agreement structs with explicit kind and terminal-state semantics
  - [x] 1.4 Define direct config and rolling config structs with bounded validation rules
  - [x] 1.5 Define reverse indexes for borrower-side and lender-side offers and agreements without asymmetric add/remove behavior
  - [x] 1.6 Add storage-isolation tests for the direct namespace

## Task 2: Lock in Shared Direct Accounting Invariants Before Product Rebuild
- [x] 2. Write or refactor shared helpers around canonical direct accounting
  - [x] 2.1 Centralize lender-capital departure from the lender pool
  - [x] 2.2 Centralize borrower borrowed-principal increases
  - [x] 2.3 Centralize same-asset debt and active-credit origination hooks
  - [x] 2.4 Centralize lender-side principal restoration on repayment and recovery
  - [x] 2.5 Centralize terminal-state cleanup for borrower locks, lender exposure, and debt ledgers
  - [x] 2.6 Ensure every direct lock/exposure mutation flows through the existing `LibEncumbrance` primitive rather than bespoke variant-specific methods
  - [x] 2.7 Add invariant tests proving fixed, rolling, and ratio paths all use the same ledger transitions

## Task 3: Rebuild Fixed Direct Offer Posting and Cancellation
- [x] 3. Rebuild the fixed direct offer facet on the clean model
  - [x] 3.1 Implement lender-posted fixed offers with `offerEscrowedCapital`
  - [x] 3.2 Implement borrower-posted fixed offers with `lockedCapital`
  - [x] 3.3 Re-validate pool alignment, solvency prerequisites, and available principal on posting
  - [x] 3.4 Implement manual cancellation for lender and borrower fixed offers
  - [x] 3.5 Implement transfer-safe cancellation or transfer blocking for open fixed offers
  - [x] 3.6 Add live-flow tests for post, cancel, and transfer semantics

## Task 4: Rebuild Fixed Direct Agreement Origination
- [x] 4. Rebuild fixed direct acceptance around the shared origination path
  - [x] 4.1 Implement acceptance of lender-posted fixed offers
  - [x] 4.2 Implement acceptance of borrower-posted fixed offers
  - [x] 4.3 Re-check live lender solvency, borrower solvency, and pool liquidity at acceptance time
  - [x] 4.4 Apply same-asset active-credit state only when borrow asset equals collateral asset
  - [x] 4.5 Route fixed-term fees through the clean lender / treasury / fee-index split
  - [x] 4.6 Add real-flow tests for lender-posted and borrower-posted fixed origination

## Task 5: Rebuild Fixed Direct Lifecycle
- [x] 5. Rebuild fixed-term repayment, exercise, call, and recovery
  - [x] 5.1 Implement borrower repayment with early-repay and grace-period gating
  - [x] 5.2 Implement borrower exercise with early-exercise and grace-period gating
  - [x] 5.3 Implement lender call where enabled
  - [x] 5.4 Implement post-grace recovery using the shared cleanup path
  - [x] 5.5 Ensure lender principal is restored to lender pool accounting before any owner withdrawal concerns
  - [x] 5.6 Add real-flow tests for repay, exercise, call, and recovery

## Task 6: Rebuild Rolling Offer Posting
- [x] 6. Rebuild rolling offer posting on top of the shared direct model
  - [x] 6.1 Implement lender-posted rolling offers with clean rolling-config validation
  - [x] 6.2 Implement borrower-posted rolling offers with clean rolling-config validation
  - [x] 6.3 Reuse the same lender escrow and borrower lock semantics as fixed direct
  - [x] 6.4 Implement rolling-offer cancellation and transfer-safe cleanup
  - [x] 6.5 Add live-flow tests for lender-posted and borrower-posted rolling offers

## Task 7: Rebuild Rolling Agreement Origination
- [x] 7. Rebuild rolling agreement acceptance so it matches fixed direct origination
  - [x] 7.1 Implement acceptance of lender-posted rolling offers
  - [x] 7.2 Implement acceptance of borrower-posted rolling offers
  - [x] 7.3 Re-check lender solvency, borrower solvency, and tracked liquidity before origination
  - [x] 7.4 Apply borrower borrowed principal and same-asset debt through the shared origination path
  - [x] 7.5 Initialize rolling cadence state: next due, arrears, payment count, outstanding principal, last accrual timestamp
  - [x] 7.6 Add tests proving rolling origination matches fixed direct debt and encumbrance behavior

## Task 8: Rebuild Rolling Payments and Full Closeout
- [x] 8. Rebuild scheduled rolling payments and full borrower closeout
  - [x] 8.1 Implement rolling payment accrual for arrears and current-period interest
  - [x] 8.2 Support optional amortization while rejecting principal reduction when amortization is disabled
  - [x] 8.3 Restore lender-side pool accounting on principal repayment instead of bypassing it
  - [x] 8.4 Update borrower debt, lender exposure, and same-asset debt only by the principal component
  - [x] 8.5 Implement full rolling repayment closeout
  - [x] 8.6 Add live-flow tests for recurring payments, amortization, and full rolling closeout

## Task 9: Rebuild Rolling Exercise and Recovery
- [x] 9. Rebuild rolling unhappy-path and early-exit lifecycle
  - [x] 9.1 Implement borrower early exercise when enabled
  - [x] 9.2 Implement recovery after `nextDue + gracePeriodSeconds`
  - [x] 9.3 Split recovered value into lender share, protocol share, fee-index share, and borrower refund using one clean recovery path
  - [x] 9.4 Clear generic and rolling-specific indexes symmetrically on every rolling terminal state
  - [x] 9.5 Add live-flow tests for exercise, recovery timing, and recovery accounting

## Task 10: Rebuild Lender-Posted Ratio Tranches
- [x] 10. Rebuild lender-posted ratio-tranche offers as partial-fill wrappers around fixed direct
  - [x] 10.1 Implement posting with principal cap, principal remaining, and minimum fill validation
  - [x] 10.2 Escrow the full principal cap in `offerEscrowedCapital`
  - [x] 10.3 Implement partial fills that compute collateral required from the configured ratio
  - [x] 10.4 Route every fill through the shared fixed direct origination path
  - [x] 10.5 Implement cancellation that releases only unfilled principal capacity
  - [x] 10.6 Add live-flow tests for multi-fill, cancel, depletion, and same-asset variants

## Task 11: Rebuild Borrower-Posted Ratio Tranches
- [x] 11. Rebuild borrower-posted ratio-tranche offers as partial-fill wrappers around fixed direct
  - [x] 11.1 Implement posting with collateral cap, collateral remaining, and minimum fill validation
  - [x] 11.2 Lock the full collateral cap in `lockedCapital`
  - [x] 11.3 Implement partial fills that compute principal from the configured ratio
  - [x] 11.4 Route every fill through the shared fixed direct origination path
  - [x] 11.5 Implement cancellation that releases only unfilled collateral capacity
  - [x] 11.6 Add live-flow tests for multi-fill, cancel, depletion, and same-asset variants

## Task 12: Rebuild the View and Config Surface
- [x] 12. Rebuild direct view and config facets around clean storage and indexes
  - [x] 12.1 Implement fixed-offer, fixed-agreement, rolling-offer, rolling-agreement, and tranche-offer reads
  - [x] 12.2 Implement position-scoped borrower and lender lookups across all direct families
  - [x] 12.3 Implement rolling payment preview and rolling status reads
  - [x] 12.4 Implement tranche-status reads for remaining capacity, fills remaining, and depletion
  - [x] 12.5 Implement bounded owner-or-timelock config writes for direct and rolling config
  - [x] 12.6 Add round-trip tests for all direct view surfaces

## Task 13: Rebuild Transfer and Index Coherence Guarantees
- [x] 13. Harden transfer semantics and index cleanup across the whole direct surface
  - [x] 13.1 Ensure the Position NFT transfer path handles open direct offers consistently across fixed, rolling, and ratio products
  - [x] 13.2 Ensure active agreements survive PNFT transfer and follow the position owner
  - [x] 13.3 Remove stale ids from generic and product-specific indexes on every terminal state
  - [x] 13.4 Add tests proving generic borrower/lender agreement views remain coherent after rolling and ratio terminal transitions

## Task 14: Real-Flow Integration Coverage
- [x] 14. Create or rebuild live integration suites for the clean EqualLend Direct surface
  - [x] 14.1 Test lender-posted fixed offer from post to accept to repay
  - [x] 14.2 Test borrower-posted fixed offer from post to accept to recover
  - [x] 14.3 Test lender-posted rolling offer through multiple payments and closeout
  - [x] 14.4 Test borrower-posted rolling offer through recovery
  - [x] 14.5 Test lender-posted ratio-tranche multi-fill lifecycle
  - [x] 14.6 Test borrower-posted ratio-tranche multi-fill lifecycle
  - [x] 14.7 Test same-asset versions of fixed, rolling, lender-ratio, and borrower-ratio paths
  - [x] 14.8 Test PNFT transfer semantics for open offers and active agreements

## Task 15: Invariants and Regression Hardening
- [x] 15. Add fuzz and invariant coverage for the rebuilt direct system
  - [x] 15.1 Prove lender principal departure and return are symmetric across fixed and rolling paths
  - [x] 15.2 Prove borrower direct debt never exceeds the sum of active agreement principal
  - [x] 15.3 Prove same-asset debt origination and cleanup are symmetric across fixed, rolling, and ratio-tranche agreements
  - [x] 15.4 Prove offer and agreement indexes remain coherent through post, cancel, fill, repay, exercise, recover, and transfer
  - [x] 15.5 Prove direct encumbrance never exceeds available principal
  - [x] 15.6 Prove rolling payment actions cannot silently bypass lender pool restoration

## Task 16: Diamond Integration and Port Cutover
- [x] 16. Wire the clean EqualLend Direct rebuild into the EqualFi diamond
  - [x] 16.1 Register selector groups for fixed, rolling, tranche, lifecycle, and view facets
  - [x] 16.2 Add deployment and selector wiring tests
  - [x] 16.3 Confirm the launch bundle includes the full required direct surface, including rolling and ratio tranches
  - [x] 16.4 Confirm no legacy direct implementation path remains active beside the clean rebuild
