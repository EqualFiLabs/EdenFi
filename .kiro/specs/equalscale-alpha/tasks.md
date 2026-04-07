# Tasks

> Supersession note
>
> The implementation remains valid, but any task text below that previously
> referenced module namespaces for native Alpha reservations is superseded by
> the native encumbrance migration spec. First-party Alpha now uses canonical
> `encumberedCapital` and `lockedCapital`.

## Task 1: LibEqualScaleAlphaStorage — PNFT-Native Storage
- [x] 1. Create `src/libraries/LibEqualScaleAlphaStorage.sol`
  - [x] 1.1 Define `STORAGE_POSITION = keccak256("equalscale.alpha.storage")`
  - [x] 1.2 Define `CollateralMode`, `CreditLineStatus`, and `CommitmentStatus`
  - [x] 1.3 Define `BorrowerProfile` without duplicating canonical wallet identity state
  - [x] 1.4 Define `CreditLine` with proposal terms, live accounting fields, draw pacing, and delinquency state
  - [x] 1.5 Define `Commitment` keyed to lender positions with repayment, recovery, and loss accounting
  - [x] 1.6 Define `PaymentRecord`, `TreasuryTelemetryView`, and `RefinanceStatusView`
  - [x] 1.7 Define mappings for borrower profiles, lines, borrower line IDs, line commitments, and lender-position reverse lookups
  - [x] 1.8 Add tests proving storage-slot isolation from EDEN lending and the position-agent wallet storage (Property 1)

## Task 2: EqualScale Alpha Events and Errors
- [x] 2. Create `src/equalscale/IEqualScaleAlphaEvents.sol` and `src/equalscale/IEqualScaleAlphaErrors.sol`
  - [x] 2.1 Define events for borrower profile registration/update, proposal creation/update/cancel, commitment add/cancel/roll/exit, activation, draw, repay, refinancing, runoff, delinquency, charge-off, close, and freeze state
  - [x] 2.2 Define custom errors for borrower/lender position ownership, invalid proposal terms, invalid collateral mode, insufficient lender principal, invalid draw pacing, delinquency timing, and write-down state errors

## Task 3: EqualScaleAlphaFacet — Borrower Profile and Identity Reuse
- [x] 3. Create `src/equalscale/EqualScaleAlphaFacet.sol`
  - [x] 3.1 Implement `registerBorrowerProfile(positionId, treasuryWallet, bankrToken, metadataHash)` using existing position-agent reads to require completed ERC-8004 linkage
  - [x] 3.2 Implement borrower-owned profile updates for treasury wallet, Bankr token, and metadata hash
  - [x] 3.3 Add tests proving borrower profile registration reuses the already-ported wallet identity model instead of storing a second registry truth (Properties 2, 3)

## Task 4: Proposal Lifecycle With Optional Borrower Collateral
- [x] 4. Add proposal lifecycle functions to `EqualScaleAlphaFacet`
  - [x] 4.1 Implement `createLineProposal(...)` with settlement pool, target limit, minimum viable line, APR, minimum payment, max draw per period, cadence, grace period, facility term, refinance window, and collateral mode
  - [x] 4.2 Enforce collateral mode rules:
    - `CollateralMode.None` requires zero collateral fields
    - `CollateralMode.BorrowerPosted` requires non-zero collateral fields
  - [x] 4.3 Implement borrower-only update and cancel paths before active commitments make terms immutable
  - [x] 4.4 Add tests for invalid proposal terms, optional collateral validation, and pre-funding cancellation/update behavior (Properties 4, 24)

## Task 5: Lender Commitments via Settlement Encumbrance
- [x] 5. Add commitment flows to `EqualScaleAlphaFacet`
  - [x] 5.1 Implement `commitSolo(lineId, lenderPositionId)` requiring full requested target limit during the solo window
  - [x] 5.2 Implement `transitionToPooledOpen(lineId)` as a permissionless post-solo transition
  - [x] 5.3 Implement `commitPooled(lineId, lenderPositionId, amount)` for FCFS pooled commitments after solo expiry
  - [x] 5.4 Implement `cancelCommitment(lineId, lenderPositionId)` for unactivated pooled commitments
  - [x] 5.5 Reserve lender settlement-pool principal at commitment time through canonical `encumberedCapital`
  - [x] 5.6 Add tests proving commitments are keyed to lender positions and not wallet addresses (Properties 5, 6, 7)
  - [x] 5.7 Add tests proving lender Position NFT transfer moves commitment rights and obligations (Property 2)

## Task 6: Activation and Optional Borrower Collateral
- [x] 6. Add activation flows to `EqualScaleAlphaFacet`
  - [x] 6.1 Implement `activateLine(lineId)` for full-size activation when commitments reach target limit
  - [x] 6.2 Implement borrower-accepted resized activation when commitments are below target but above minimum viable line
  - [x] 6.3 Lock optional borrower collateral on activation only when `CollateralMode.BorrowerPosted` is selected through canonical `lockedCapital`
  - [x] 6.4 Initialize live line timestamps, active limit, and period accounting on activation
  - [x] 6.5 Add tests for unsecured and borrower-collateralized activation paths (Properties 8, 15, 24)

## Task 7: Draw Logic With Period Draw Caps
- [x] 7. Add draw execution to `EqualScaleAlphaFacet`
  - [x] 7.1 Implement `draw(lineId, amount)` gated by borrower Position NFT ownership, line status, available capacity, and `maxDrawPerPeriod`
  - [x] 7.2 Reset the current draw period when the payment interval rolls
  - [x] 7.3 Allocate draw exposure pro rata across active commitments
  - [x] 7.4 Add tests proving draw pacing, capacity enforcement, and status gating across Active / Frozen / Refinancing / Runoff / Delinquent / ChargedOff / Closed (Properties 9, 10)

## Task 8: Interest Accrual, Minimum Due, and Repayment
- [x] 8. Add repayment accounting to `EqualScaleAlphaFacet`
  - [x] 8.1 Implement interest accrual on outstanding principal using proposal APR and elapsed time
  - [x] 8.2 Compute `requiredMinimumDue = max(accruedInterestSinceLastDue, minimumPaymentPerPeriod)`
  - [x] 8.3 Implement `repay(lineId, amount)` applying payment to interest first and principal second
  - [x] 8.4 Restore line capacity only by the principal component
  - [x] 8.5 Distribute interest and principal repayment pro rata across lender commitments
  - [x] 8.6 Add tests for accrual math, minimum due enforcement, pro rata distribution, and borrower cure behavior (Properties 11, 12)

## Task 9: Refinance, Roll, Exit, Resize, and Runoff
- [x] 9. Add refinance lifecycle functions
  - [x] 9.1 Implement permissionless `enterRefinancing(lineId)` at term end
  - [x] 9.2 Implement `rollCommitment(lineId, lenderPositionId)` and `exitCommitment(lineId, lenderPositionId)` for existing lenders
  - [x] 9.3 Allow new pooled commitments during refinancing
  - [x] 9.4 Implement `resolveRefinancing(lineId)` with the three real outcomes: full renewal, resized renewal, or runoff
  - [x] 9.5 Implement borrower runoff cure by repaying down to covered exposure
  - [x] 9.6 Add tests for full renewal, resized renewal, runoff, and runoff cure (Properties 18, 19, 20)

## Task 10: Delinquency, Charge-Off, Recovery, and Write-Down
- [x] 10. Add unhappy-path lifecycle handling
  - [x] 10.1 Implement permissionless `markDelinquent(lineId)` after `nextDueAt + gracePeriodSecs` when the current minimum due is not satisfied
  - [x] 10.2 Implement permissionless `chargeOffLine(lineId)` after the global charge-off threshold elapses
  - [x] 10.3 Recover borrower collateral if and only if the line uses `CollateralMode.BorrowerPosted`
  - [x] 10.4 Apply recovered value pro rata across lender commitments
  - [x] 10.5 Write down residual unpaid principal pro rata across lender commitments and record per-commitment loss
  - [x] 10.6 Add tests for unsecured charge-off and secured charge-off separately (Properties 13, 14, 15)
  - [x] 10.7 Add tests proving Alpha does not assume any insurance module or treasury backstop (Property 25)

## Task 11: Limited Timelock-Governed Admin Surface
- [x] 11. Create `src/equalscale/EqualScaleAlphaAdminFacet.sol`
  - [x] 11.1 Implement `freezeLine(lineId, reason)` and `unfreezeLine(lineId)` as timelock-governed controls
  - [x] 11.2 Implement `setChargeOffThreshold(thresholdSecs)` as a bounded timelock-governed config write
  - [ ] 11.3 Optionally implement proposal-creation pause if needed, but do not move normal lifecycle transitions behind admin authority
  - [x] 11.4 Add tests proving admin freeze is narrow and permissionless lifecycle transitions still work (Properties 10, 14)

## Task 12: EqualScale Alpha View Surface
- [x] 12. Create `src/equalscale/EqualScaleAlphaViewFacet.sol`
  - [x] 12.1 Implement borrower profile reads that merge in live position-agent identity state rather than duplicate it
  - [x] 12.2 Implement line reads, borrower line lookups, and lender-position commitment lookups
  - [x] 12.3 Implement `previewDraw`, `previewRepay`, and `currentMinimumDue`
  - [x] 12.4 Implement treasury telemetry with treasury balance, outstanding principal, accrued interest, next due amount, payment current, line status, and current-period draw usage
  - [x] 12.5 Implement view surfaces for aggregate and per-commitment write-downs
  - [x] 12.6 Add round-trip tests for all line, commitment, and telemetry views (Properties 22, 25)

## Task 13: Real-Flow Integration Tests
- [x] 13. Create `test/EqualScaleAlpha.t.sol`
  - [x] 13.1 Set up a real diamond fixture with Position NFT, settlement pool, borrower position, and lender positions
  - [x] 13.2 Test borrower profile registration using the existing ERC-8004 wallet registration path
  - [x] 13.3 Test unsecured solo-funded line from request to draw to repay to close
  - [x] 13.4 Test pooled line with multiple lender positions and pro rata accounting
  - [x] 13.5 Test borrower-collateralized line with optional collateral recovery
  - [x] 13.6 Test refinance outcomes: full renewal, resized renewal, runoff, runoff cure
  - [x] 13.7 Test delinquency, charge-off, and lender loss recognition
  - [x] 13.8 Test borrower and lender Position NFT transfer semantics on active lines and commitments (Properties 2, 23, 25)

## Task 14: Fuzz and Invariant Coverage
  - [x] 14. Create `test/EqualScaleAlphaFuzz.t.sol`
  - [x] 14.1 Fuzz borrower and lender ownership gating by Position NFT owner (Property 2)
  - [x] 14.2 Fuzz commitment encumbrance so committed amount never exceeds available lender principal (Properties 7, 15)
  - [x] 14.3 Fuzz draw capacity and period draw cap invariants (Properties 9, 10)
  - [x] 14.4 Fuzz interest accrual and repayment monotonicity (Properties 11, 12)
  - [x] 14.5 Fuzz pro rata repayment and write-down conservation across many lender positions (Properties 21, 25)
  - [x] 14.6 Fuzz optional collateral modes to prove unsecured and secured lines both behave correctly (Property 24)
  - [x] 14.7 Add invariant tests proving lender commitment rights track lender Position NFT ownership and borrower control tracks borrower Position NFT ownership (Property 2)
  - [x] 14.8 Add invariant tests proving EqualScale Alpha native reservations stay attributable without module namespaces (Property 16)

## Task 15: Diamond Deployment Integration
- [x] 15. Register EqualScale Alpha facets in the deploy path
  - [x] 15.1 Add selector groups for `EqualScaleAlphaFacet`, `EqualScaleAlphaAdminFacet`, and `EqualScaleAlphaViewFacet`
  - [x] 15.2 Install them in the live diamond deployment flow
  - [x] 15.3 Add deploy tests proving the Alpha selectors are wired into the live diamond and remain under EIP-170 size limits
