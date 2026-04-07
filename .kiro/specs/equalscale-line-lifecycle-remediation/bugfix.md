# Bugfix Requirements Document

## Introduction

Eleven remediation items in the EqualScale credit-line lifecycle require coordinated fixes. The scope covers charge-off borrower-debt cleanup (finding 1), payment checkpoint advancement guardrails (finding 5), charge-off interest-loss recognition (finding 6), runoff cure `minimumViableLine` enforcement (finding 7), native-asset draw reentrancy hardening (finding 4), `missedPayments` overflow hardening, freeze-to-refinancing lifecycle bypass, `allocateRecovery` value-stranding fix, borrower line view cleanup, treasury wallet lock during live lines, and pro-rata remainder fairness. Together these restore correct debt-state cleanup on charge-off, honest lender loss accounting, consistent state-machine transitions, safe allocation patterns, and lifecycle-policy integrity.

Canonical Track: Track D. Payment Lifecycle and Delinquency State Machines (EqualScale portion)
Phase: Phase 2. Product Lifecycle Fixes

Source report: `assets/findings/EdenFi-equalscale-pashov-ai-audit-report-20260405-011500.md`
Library report: `assets/findings/EdenFi-libraries-phase4-pashov-ai-audit-report-20260406-210000.md`
Remediation plan: `assets/remediation/EqualScale-findings-1-7-remediation-plan.md`
Unified plan: `assets/remediation/EqualFi-unified-remediation-plan.md`

Depends on:
- Track A. Native Asset Tracking and Transfer Symmetry
- Track B. ACI / Encumbrance / Debt Tracker Consistency
- Track H. Discovery, Storage Growth, and Registry Hygiene (for append-only line history overlap)

Downstream reports closed:
- EqualScale facet findings 1, 4, 5, 6, 7
- Libraries phase 4 duplicated EqualScale storage-growth and stale-history issues
- Agreed leads: `missedPayments` overflow, freeze integrity, `allocateRecovery` stranding, borrower line view, treasury wallet lock, pro-rata remainder

Non-remediation (reviewed, no fix planned):
- Finding 2: Confirmed behavior, accepted as current policy (permissionless full-commit activation)
- Finding 3: Disagree (cross-pool recovery accounting is correct — `trackedBalance` moves, `totalDeposits` does not)
- Finding 8: Fee-on-transfer settlement assets unsupported by policy

## Bug Analysis

### Current Behavior (Defect)

**Finding 1 — `chargeOffLine` never clears borrower debt state**

1.1 WHEN `chargeOffLine` is called and `finalizeClosedLine` zeroes `line.outstandingPrincipal` THEN the system does not call `reduceBorrowerDebt`, leaving `settlementPool.userSameAssetDebt`, `userActiveCreditStateDebt`, and `activeCreditPrincipalTotal` permanently inflated

1.2 WHEN a borrower has stale same-asset debt after charge-off closure THEN the system blocks later withdrawals and membership cleanup because phantom debt exceeds actual principal

**Finding 5 — Payment checkpoint advancement rolled forward too aggressively**

1.3 WHEN a borrower makes repeated minimum-size repayments in the same block and each satisfies the current minimum due THEN the system calls `advanceDueCheckpoint` multiple times, rolling `nextDueAt` forward by multiple periods in a single transaction

1.4 WHEN `advanceDueCheckpoint` increments `nextDueAt` by `paymentIntervalSecs` without capping at `termEndAt` THEN the system can push `nextDueAt` past the facility expiry, delaying delinquency enforcement

**Finding 6 — Charge-off silently drops accrued interest from lender loss accounting**

1.5 WHEN `chargeOffLine` accrues interest before allocating recovery and principal write-down THEN the system only tracks principal exposure outcomes and zeroes line interest state at finalization without lender-facing interest-loss attribution

1.6 WHEN a charged-off line has nonzero `accruedInterest` at charge-off time THEN the system understates total lender loss by silently discarding the interest component

**Finding 7 — Runoff cure can reactivate below `minimumViableLine`**

1.7 WHEN a line is in `Runoff` status and `outstandingPrincipal <= currentCommittedAmount` but `currentCommittedAmount < minimumViableLine` THEN the system calls `restartLineTerm` and returns the line to `Active` below the economic floor enforced elsewhere

**Finding 4 — Native-asset draw reentrancy hardening**

1.8 WHEN `draw` transfers native ETH to a borrower-controlled `treasuryWallet` via `.call{value}` THEN the system does not apply the diamond-wide `nonReentrant` guard, leaving the callback surface unnecessarily wide

**Lead — `missedPayments` overflow hardening**

1.9 WHEN `markDelinquent` increments `line.missedPayments` (a `uint8`) inside an `unchecked` block and the counter reaches 255 THEN the system wraps the counter back to zero, corrupting delinquency telemetry

**Lead — Freeze integrity across refinancing**

1.10 WHEN a governance-frozen line reaches term expiry and anyone calls `enterRefinancing` THEN the system allows `Frozen -> Refinancing` transition, bypassing the governance freeze

**Lead — `allocateRecovery` value-stranding fix**

1.11 WHEN `allocateRecovery` computes early shares against the original `totalExposed` and the final commitment receives the whole remaining recovery amount subject to a local cap THEN the system can leave real recovered value uncredited in skewed multi-lender commitment sets

**Lead — Borrower line view cleanup**

1.12 WHEN `getBorrowerLineIds` returns the raw append-only `borrowerLineIds` array THEN the system includes canceled and closed proposals, creating unnecessary integrator and frontend filtering burden

**Lead — Treasury wallet lock during live lines**

1.13 WHEN a borrower calls `updateBorrowerProfile` to change `treasuryWallet` while any EqualScale line is non-closed THEN the system allows the change, violating lender and operator expectations around underwritten payout routing

**Lead — Pro-rata remainder fairness**

1.14 WHEN `allocateRepayment`, `allocateRecovery`, `allocateWriteDown`, and `allocateDrawExposure` assign remainder dust to the final counted commitment THEN the system deterministically favors the same position across all allocation flows

### Expected Behavior (Correct)

**Finding 1 — Clear borrower debt on charge-off**

2.1 WHEN `chargeOffLine` is called and `line.outstandingPrincipal != 0` THEN the system SHALL call `reduceBorrowerDebt(settlementPool, line.settlementPoolId, borrowerPositionKey, line.outstandingPrincipal)` before `finalizeClosedLine` zeroes the line principal

2.2 WHEN charge-off closure completes THEN the system SHALL leave `userSameAssetDebt`, `userActiveCreditStateDebt`, and `activeCreditPrincipalTotal` reduced by the written-down principal amount

**Finding 5 — Limit checkpoint advancement to one period per due window**

2.3 WHEN `advanceDueCheckpoint` is called THEN the system SHALL cap `nextDueAt` at `termEndAt`, preventing the due checkpoint from overshooting the facility expiry

2.4 WHEN a borrower makes repeated repayments in the same block THEN the system SHALL advance `nextDueAt` by at most one period per due window, preventing multi-period rollforward from repeated same-block payments

**Finding 6 — Recognize accrued-interest loss on charge-off**

2.5 WHEN `chargeOffLine` runs on a line with nonzero `accruedInterest` THEN the system SHALL snapshot the accrued interest before finalization and record it as lender-side interest loss in commitment-level telemetry

2.6 WHEN a charged-off line has zero `accruedInterest` THEN the system SHALL preserve the current principal-only loss behavior

**Finding 7 — Enforce `minimumViableLine` floor on runoff cure**

2.7 WHEN `cureLineIfCovered` evaluates a `Runoff` line for restart and `currentCommittedAmount < minimumViableLine` THEN the system SHALL leave the line in `Runoff` status even if `outstandingPrincipal <= currentCommittedAmount`

2.8 WHEN `currentCommittedAmount >= minimumViableLine` THEN the system SHALL CONTINUE TO restart the line as intended

**Finding 4 — Add `nonReentrant` to draw**

2.9 WHEN `draw` is called on a native-asset settlement pool THEN the system SHALL apply the `nonReentrant` modifier, preventing reentrant calls through the borrower treasury callback

**Lead — Harden `missedPayments` tracking**

2.10 WHEN `markDelinquent` increments `missedPayments` THEN the system SHALL use checked arithmetic (remove `unchecked` block), preventing silent wraparound

**Lead — Block `Frozen -> Refinancing` bypass**

2.11 WHEN `enterRefinancing` is called on a `Frozen` line THEN the system SHALL revert, requiring governance to unfreeze before the line can progress to refinancing

**Lead — Fix `allocateRecovery` value stranding**

2.12 WHEN `allocateRecovery` distributes recovered value across commitments THEN the system SHALL use a remaining-amount / remaining-exposure pattern, computing each step against the unreconciled remainder rather than the original total for every early lender

2.13 WHEN recovery allocation completes THEN the system SHALL have fully credited all recoverable value with no stranded remainder in skewed commitment sets

**Lead — Add filtered borrower line view**

2.14 WHEN an integrator calls the new filtered borrower-line view THEN the system SHALL return only line IDs whose status is not `Closed` and not a canceled proposal

2.15 WHEN an integrator calls the existing `getBorrowerLineIds` THEN the system SHALL CONTINUE TO return the full raw historical array

**Lead — Lock treasury wallet during live lines**

2.16 WHEN a borrower calls `updateBorrowerProfile` to change `treasuryWallet` and any EqualScale line for that borrower is not in `Closed` status THEN the system SHALL revert

2.17 WHEN all borrower EqualScale lines are `Closed` THEN the system SHALL allow the treasury wallet update

**Lead — Pro-rata remainder fairness**

2.18 WHEN allocation helpers distribute amounts across commitments THEN the system SHALL use a remaining-amount / remaining-exposure pattern that avoids always assigning remainder dust to the same final commitment

### Unchanged Behavior (Regression Prevention)

**Charge-off and close flow**

3.1 WHEN `chargeOffLine` runs on a delinquent line past the charge-off threshold THEN the system SHALL CONTINUE TO accrue interest, recover collateral, allocate recovery, write down principal, set `ChargedOff` status, and finalize the line correctly

3.2 WHEN `closeLine` is called on a line with zero outstanding principal THEN the system SHALL CONTINUE TO finalize the line, settle positions, release commitments, and unlock collateral correctly

**Repayment flow**

3.3 WHEN a borrower makes a valid repayment with correct parameters THEN the system SHALL CONTINUE TO accrue interest, allocate payment to interest then principal, reduce borrower debt, settle positions, advance checkpoint when minimum due is satisfied, and emit events correctly

3.4 WHEN a repayment reduces `outstandingPrincipal` to zero THEN the system SHALL CONTINUE TO allow `closeLine` to finalize the line

**Draw flow**

3.5 WHEN a borrower draws from an active line with valid parameters THEN the system SHALL CONTINUE TO check capacity, update principal, increase borrower debt, allocate draw exposure, transfer funds, and emit events correctly

3.6 WHEN a borrower draws ERC20 settlement assets THEN the system SHALL CONTINUE TO transfer without the reentrancy guard affecting the flow

**Delinquency and cure flow**

3.7 WHEN `markDelinquent` is called on an eligible line past the grace period with unsatisfied minimum due THEN the system SHALL CONTINUE TO set `Delinquent` status, record `delinquentSince`, increment `missedPayments`, and emit the event

3.8 WHEN a delinquent line receives a payment satisfying the minimum due THEN the system SHALL CONTINUE TO cure the line to `Active` or `Runoff` as appropriate

**Refinancing flow**

3.9 WHEN `enterRefinancing` is called on an `Active` line past term expiry THEN the system SHALL CONTINUE TO transition to `Refinancing` status

3.10 WHEN `rollCommitment`, `exitCommitment`, and `resolveRefinancing` are called during refinancing THEN the system SHALL CONTINUE TO process commitment changes and resolve the refinancing correctly

**Activation and commitment flow**

3.11 WHEN `activateLine`, `commitSolo`, `commitPooled`, and `cancelCommitment` are called with valid parameters THEN the system SHALL CONTINUE TO process activation and commitment changes correctly

**Collateral recovery**

3.12 WHEN `recoverBorrowerCollateral` moves backing from collateral pool to settlement pool THEN the system SHALL CONTINUE TO update `trackedBalance` without minting settlement-pool `totalDeposits`

**Borrower profile**

3.13 WHEN a borrower calls `updateBorrowerProfile` to change `bankrToken` or `metadataHash` THEN the system SHALL CONTINUE TO allow the update regardless of line status

**View functions**

3.14 WHEN `getBorrowerLineIds` is called THEN the system SHALL CONTINUE TO return the full raw historical array unchanged
