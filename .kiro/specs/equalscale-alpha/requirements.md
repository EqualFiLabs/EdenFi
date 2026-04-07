# Requirements Document

> Supersession note
>
> Native reservation semantics in this legacy EqualScale Alpha spec are
> superseded by
> `/home/hooftly/.openclaw/workspace/Projects/EdenFi/.kiro/specs/native-encumbrance-migration/`.
> EqualScale Alpha is a first-party EqualFi venue and now uses canonical
> `encumberedCapital` for lender commitments and canonical `lockedCapital` for
> borrower-posted collateral rather than per-line module namespaces.

## Introduction

EqualScale Alpha is a Position NFT-native agent credit agreement layer built on
the EqualFi substrate.

Borrowers request bounded revolving lines from a borrower Position NFT. Lenders
fund those lines from lender Position NFTs by encumbering settlement-pool
principal at commitment time. Borrower collateral is optional at the proposal
level. Alpha explicitly allows lender impairment if a borrower draws and fails
to repay.

EqualScale Alpha reuses the existing EqualFi substrate:

- Position NFT ownership and transfer semantics
- `positionKey`-based accounting
- canonical encumbrance buckets
- settlement discipline through existing index settlement patterns
- the ERC-6551 / ERC-6900 / ERC-8004 position-agent wallet stack

EqualScale Alpha does not assume protocol insurance, treasury backstops,
reputation scoring, or offchain revenue inference in Alpha.

## Glossary

- **Borrower_Position**: The Position NFT whose `positionKey` is the canonical
  borrower account for a line.
- **Lender_Position**: A Position NFT whose settlement-pool principal is
  committed to a line.
- **positionKey**: The canonical bytes32 identity derived from a Position NFT.
- **Borrower_Profile**: Borrower-specific metadata keyed by borrower
  `positionKey`. It does not replace the existing wallet identity rail.
- **Line_Proposal**: The borrower-authored commercial offer lenders may accept.
- **Credit_Line**: The live line state keyed to a borrower `positionKey`.
- **Commitment**: A lender position’s accepted exposure to a line. A commitment
  is backed by canonical `encumberedCapital` on settlement-pool principal.
- **Settlement_Pool**: The EqualFi pool from which line draws are funded and to
  which repayments return value.
- **Collateral_Mode**: Proposal-level collateral selection. Alpha supports
  `None` and `BorrowerPosted`.
- **Borrower_Posted_Collateral**: Optional borrower-position collateral
  locked at activation through canonical `lockedCapital`.
- **Solo_Window**: The initial 3-day period during which exactly one lender
  position may fully take the line.
- **Pooled_Window**: The period after solo expiry where multiple lender
  positions may commit first-come-first-serve.
- **Refinancing**: The end-of-term window in which existing lenders roll/exit,
  new lenders may enter, and the line is repriced by commitment behavior.
- **Runoff**: A state where new draws are disabled and the borrower must repay
  down to covered exposure.
- **Charged_Off**: A loss-aware terminal unhappy-path state after recoveries and
  write-down allocation are complete.
- **Treasury_Telemetry**: Trust-minimized public read-only borrower information
  such as treasury balance, payment current status, outstanding principal, and
  draw pacing.

## Requirements

### Requirement 1: Borrower Profile Uses Existing Position-Agent Identity

**User Story:** As a borrower, I want EqualScale Alpha to use my existing
Position NFT agent wallet registration, so that the credit system does not
create a second identity rail.

#### Acceptance Criteria

1. WHEN a caller registers a Borrower_Profile for a Position NFT, THE
   EqualScale_Alpha_System SHALL verify that the caller owns that Position NFT.
2. WHEN a caller registers a Borrower_Profile, THE EqualScale_Alpha_System SHALL
   require that the Position NFT already has a completed ERC-8004-linked agent
   registration through the position-agent wallet stack.
3. THE EqualScale_Alpha_System SHALL use live position-agent identity state
   rather than storing a second canonical `agentRegistry` / `agentId` truth in
   Alpha storage.
4. THE EqualScale_Alpha_System SHALL store only borrower-specific metadata not
   already canonical elsewhere, including treasury wallet, Bankr token, and
   metadata hash.
5. IF a caller attempts to register a Borrower_Profile for a borrower position
   that already has an active profile, THEN THE EqualScale_Alpha_System SHALL
   revert with a descriptive error.
6. WHEN a Borrower_Profile is registered, THE EqualScale_Alpha_System SHALL emit
   a BorrowerProfileRegistered event containing the borrower position key,
   treasury wallet, Bankr token, and resolved agent ID.

### Requirement 2: Borrower Profile Updates

**User Story:** As a borrower, I want to update treasury-wallet and metadata
fields without breaking the canonical borrower identity model.

#### Acceptance Criteria

1. WHEN the owner of the borrower Position NFT updates the Borrower_Profile, THE
   EqualScale_Alpha_System SHALL update the stored treasury wallet, Bankr token,
   and/or metadata hash for that borrower `positionKey`.
2. IF a non-owner attempts to update a Borrower_Profile, THEN THE
   EqualScale_Alpha_System SHALL revert with an authorization error.
3. WHEN treasury wallet or Bankr token is updated, THE EqualScale_Alpha_System
   SHALL reject zero addresses.
4. WHEN a profile field is updated, THE EqualScale_Alpha_System SHALL emit a
   BorrowerProfileUpdated event.

### Requirement 3: Proposal Creation With Optional Borrower Collateral

**User Story:** As a borrower, I want to create a line proposal whose exact
commercial terms lenders can accept or reject, including optional borrower
collateral.

#### Acceptance Criteria

1. WHEN a borrower creates a Line_Proposal, THE EqualScale_Alpha_System SHALL
   require borrower Position NFT ownership and an active Borrower_Profile.
2. THE Line_Proposal SHALL include at minimum:
   - settlement pool ID
   - target limit
   - minimum viable line
   - APR in basis points
   - minimum payment per period
   - max draw per period
   - payment interval
   - grace period
   - facility term
   - refinance window
   - collateral mode
   - borrower collateral pool ID and collateral amount when collateral mode is
     `BorrowerPosted`
3. WHEN a proposal chooses `Collateral_Mode.None`, THE EqualScale_Alpha_System
   SHALL require borrower collateral pool ID and collateral amount to both be
   zero.
4. WHEN a proposal chooses `Collateral_Mode.BorrowerPosted`, THE
   EqualScale_Alpha_System SHALL require non-zero borrower collateral pool ID
   and collateral amount.
5. IF `minimumViableLine > targetLimit`, THEN THE EqualScale_Alpha_System SHALL
   revert with a descriptive error.
6. IF `maxDrawPerPeriod > targetLimit`, THEN THE EqualScale_Alpha_System SHALL
   revert with a descriptive error.
7. WHEN a proposal is created, THE EqualScale_Alpha_System SHALL place it into
   `SoloWindow` status and set `soloExclusiveUntil = block.timestamp + 3 days`.
8. WHEN a proposal is created, THE EqualScale_Alpha_System SHALL emit
   LineProposalCreated and CreditLineEnteredSoloWindow events.

### Requirement 4: Proposal Update or Cancellation Before Activation

**User Story:** As a borrower, I want to update or cancel a proposal before
lender commitments make the economic bargain live.

#### Acceptance Criteria

1. WHEN a proposal has no active lender commitments and has not activated, THE
   borrower Position NFT owner SHALL be able to update or cancel it.
2. IF active lender commitments exist for the proposal, THEN THE
   EqualScale_Alpha_System SHALL reject borrower-side term changes that would
   alter the lender bargain.
3. WHEN a proposal is canceled before activation, THE EqualScale_Alpha_System
   SHALL release any pre-activation state and emit a ProposalCancelled event.

### Requirement 5: Lender Commitments Are Position-Owned Encumbrances

**User Story:** As a lender, I want my exposure to be owned by my Position NFT
and backed by canonical native encumbrance, so that the line integrates with
the rest of EqualFi.

#### Acceptance Criteria

1. WHEN a lender funds a line in either solo or pooled mode, THE
   EqualScale_Alpha_System SHALL require a lender Position NFT in the settlement
   pool.
2. WHEN a lender commits, THE EqualScale_Alpha_System SHALL encumber settlement
   principal on that lender position through canonical `encumberedCapital`.
3. THE EqualScale_Alpha_System SHALL key commitments by lender position ID and
   lender `positionKey`, not by wallet address alone.
4. DURING the Solo_Window, THE EqualScale_Alpha_System SHALL only allow one
   lender position to take the full requested target limit.
5. AFTER the Solo_Window expires, THE EqualScale_Alpha_System SHALL allow
   multiple lender positions to commit first-come-first-serve up to the
   remaining unfilled amount.
6. THE EqualScale_Alpha_System SHALL reject a commitment that exceeds the lender
   position’s available settlement-pool principal.
7. THE EqualScale_Alpha_System SHALL allow a lender to cancel an unactivated
   commitment during pooled funding, releasing the corresponding canonical
   reservation.
8. WHEN a commitment is added, canceled, rolled, or exited, THE
   EqualScale_Alpha_System SHALL emit commitment events containing the line ID,
   lender position ID, and amount affected.
9. Commitment rights and obligations SHALL follow lender Position NFT ownership
   if the lender Position NFT is transferred.

### Requirement 6: Activation Uses Committed Lender Capacity and Optional Borrower Collateral

**User Story:** As the system, I want a line to activate only when enough lender
positions have committed and optional borrower collateral can be locked.

#### Acceptance Criteria

1. WHEN commitments reach the requested `targetLimit`, THE EqualScale_Alpha_System
   SHALL allow the line to activate immediately.
2. WHEN commitments do not reach `targetLimit` but do reach
   `minimumViableLine`, THE borrower SHALL be able to accept a resized
   activation at the committed amount after the funding window.
3. WHEN a line activates, THE EqualScale_Alpha_System SHALL keep lender
   settlement reservations locked through canonical `encumberedCapital` for the
   line term.
4. WHEN the proposal uses `Collateral_Mode.BorrowerPosted`, THE
   EqualScale_Alpha_System SHALL lock the borrower’s stated collateral from the
   borrower position at activation through canonical `lockedCapital`.
5. WHEN the proposal uses `Collateral_Mode.None`, THE EqualScale_Alpha_System
   SHALL not require or attempt borrower collateral locking.
6. WHEN a line activates, THE EqualScale_Alpha_System SHALL initialize:
   - active limit
   - next payment due timestamp
   - term start and term end timestamps
   - refinance end timestamp
   - current draw-period window
7. WHEN a line activates, THE EqualScale_Alpha_System SHALL emit a
   CreditLineActivated event including the active limit and collateral mode.

### Requirement 7: Draws Respect Capacity and Proposal Draw Pacing

**User Story:** As a borrower, I want to draw against an active line only within
the limit and cadence lenders accepted.

#### Acceptance Criteria

1. WHEN the owner of the borrower Position NFT draws from an active line, THE
   EqualScale_Alpha_System SHALL require:
   - line status is Active
   - unused capacity remains under the active limit
   - current-period draws plus the requested draw do not exceed
     `maxDrawPerPeriod`
2. THE EqualScale_Alpha_System SHALL allocate each draw pro rata across active
   lender commitments for accounting purposes.
3. WHEN a draw is executed, THE EqualScale_Alpha_System SHALL increase
   outstanding principal and current-period draw usage.
4. WHEN a new draw period starts, THE EqualScale_Alpha_System SHALL reset the
   period draw counter.
5. THE EqualScale_Alpha_System SHALL reject draws while the line is Frozen,
   Refinancing, Runoff, Delinquent, ChargedOff, or Closed.
6. WHEN a draw is executed, THE EqualScale_Alpha_System SHALL emit a CreditDrawn
   event containing the line ID, draw amount, and resulting outstanding
   principal.

### Requirement 8: Interest Accrual and Minimum Payment Logic Are Proposal-Defined

**User Story:** As a lender, I want the protocol to enforce the pricing and
minimum payment floor I accepted in the proposal.

#### Acceptance Criteria

1. THE EqualScale_Alpha_System SHALL accrue interest on outstanding principal
   over elapsed time using the proposal APR.
2. THE EqualScale_Alpha_System SHALL compute the minimum due each payment period
   as at least the accrued interest since the previous due checkpoint, with the
   proposal’s `minimumPaymentPerPeriod` acting as an additional floor.
3. WHEN a repayment is made, THE EqualScale_Alpha_System SHALL apply payment to:
   - accrued interest first
   - principal second
4. WHEN a repayment includes principal reduction, THE EqualScale_Alpha_System
   SHALL restore available draw capacity only by the principal component.
5. THE EqualScale_Alpha_System SHALL cap repayment at the total outstanding
   obligation.
6. WHEN a repayment satisfies the current minimum due before the end of the
   grace window, THE EqualScale_Alpha_System SHALL advance the next due
   timestamp by exactly one payment interval.
7. WHEN a repayment is made, THE EqualScale_Alpha_System SHALL record a
   PaymentRecord and emit CreditPaymentMade.

### Requirement 9: Repayments and Recoveries Flow Pro Rata to Lenders

**User Story:** As a lender, I want repayments and recoveries to be allocated
pro rata across the lender positions that accepted the line.

#### Acceptance Criteria

1. WHEN principal or interest is repaid, THE EqualScale_Alpha_System SHALL
   allocate that value pro rata across active lender commitments.
2. WHEN borrower collateral is recovered, THE EqualScale_Alpha_System SHALL
   apply the recovered value pro rata across active lender commitments before
   any write-down is recognized.
3. THE EqualScale_Alpha_System SHALL maintain per-commitment accounting for:
   - committed amount
   - principal exposed
   - principal repaid
   - interest received
   - loss written down
4. Commitment claims and realized value SHALL remain attached to lender Position
   NFTs and follow lender Position NFT ownership.

### Requirement 10: Refinance, Roll, Exit, and Runoff

**User Story:** As a lender, I want my capital to be term-bound and repriced at
refinance rather than treated as permanently committed.

#### Acceptance Criteria

1. WHEN the line term ends, THE EqualScale_Alpha_System SHALL allow anyone to
   transition the line into `Refinancing`.
2. DURING `Refinancing`, existing lenders SHALL be able to:
   - roll existing commitments
   - partially or fully exit unneeded future commitment
   - leave the line uncovered
3. DURING `Refinancing`, new lender positions SHALL be able to commit under the
   same encumbrance model used during initial pooled funding.
4. WHEN refinance ends and covered commitment is at least the outstanding
   principal, THE EqualScale_Alpha_System SHALL allow the line to renew.
5. WHEN refinance ends and commitment is below the desired limit but still above
   the borrower-accepted resized limit, THE EqualScale_Alpha_System SHALL allow
   renewal at the smaller active limit.
6. WHEN refinance ends and commitment is below outstanding principal, THE
   EqualScale_Alpha_System SHALL transition the line to `Runoff`, disable new
   draws, and require the borrower to repay down to covered exposure.
7. WHEN the borrower cures a Runoff line by repaying outstanding principal down
   to covered exposure and a valid next term exists, THE EqualScale_Alpha_System
   SHALL allow the line to return to Active.

### Requirement 11: Delinquency and Charge-Off Are Permissionless

**User Story:** As a lender, I want core negative lifecycle transitions to be
permissionless, so the line cannot stay artificially healthy just because no
admin acted.

#### Acceptance Criteria

1. WHEN the current block timestamp exceeds `nextDueAt + gracePeriodSecs` and
   the current minimum due is not satisfied, THE EqualScale_Alpha_System SHALL
   allow anyone to mark the line `Delinquent`.
2. WHILE a line is `Delinquent`, THE EqualScale_Alpha_System SHALL reject new
   draws.
3. WHEN a delinquent borrower fully cures the missed due amount, THE
   EqualScale_Alpha_System SHALL allow the line to return to Active if no other
   blocking state applies.
4. WHEN a line remains delinquent beyond the configured charge-off threshold,
   THE EqualScale_Alpha_System SHALL allow anyone to charge off the line.
5. A charged-off line SHALL:
   - recover optional borrower collateral if present
   - apply all recoverable value pro rata to lenders
   - recognize any remaining unpaid principal as lender loss
   - transition to `ChargedOff` and then terminal closure
6. The EqualScale_Alpha_System SHALL emit explicit events for entering
   Delinquent, Runoff, ChargedOff, and Closed-with-loss outcomes.

### Requirement 12: Alpha Explicitly Allows Lender Losses

**User Story:** As a lender, I want Alpha to be honest about lender loss
possibility rather than silently assuming protocol backstops.

#### Acceptance Criteria

1. THE EqualScale_Alpha_System SHALL treat unrecovered principal after repayment
   and optional collateral recovery as a pro rata lender write-down.
2. THE EqualScale_Alpha_System SHALL not assume an insurance module, reserve, or
   protocol treasury backstop in Alpha.
3. View surfaces SHALL expose whether a line ended with loss and how much loss
   was recognized in aggregate and per commitment.

### Requirement 13: Limited Admin Controls Only

**User Story:** As a protocol operator, I want narrowly scoped policy controls
without making normal lifecycle progress dependent on admin action.

#### Acceptance Criteria

1. THE EqualScale_Alpha_System SHALL allow timelock-governed admin functions to
   freeze or unfreeze a line.
2. WHILE a line is Frozen, draws SHALL be disabled but repayments SHALL remain
   allowed.
3. Core progress functions such as entering pooled mode, entering refinancing,
   marking delinquent, and charging off SHALL remain permissionless.
4. THE EqualScale_Alpha_System MAY expose admin setters for global thresholds
   such as charge-off delay, but SHALL not require admin action for ordinary
   term rollover failure handling.

### Requirement 14: Read Surfaces and Treasury Telemetry

**User Story:** As a borrower, lender, or integrator, I want to query the full
state of a line and its commitments.

#### Acceptance Criteria

1. THE EqualScale_Alpha_System SHALL expose views for:
   - Borrower_Profile by borrower position
   - line state by line ID
   - line IDs by borrower position
   - active and historical commitments by line ID
   - commitments by lender position
   - previewDraw
   - previewRepay
   - isLineDrawEligible
   - currentMinimumDue
   - refinance status
2. THE EqualScale_Alpha_System SHALL expose treasury telemetry containing at
   least:
   - treasury wallet balance
   - outstanding principal
   - accrued interest
   - next due amount
   - payment current flag
   - current-period draw usage versus `maxDrawPerPeriod`
   - line status
3. THE EqualScale_Alpha_System SHALL clearly distinguish observational telemetry
   from guaranteed repayment capacity.

### Requirement 15: Storage Isolation and Native Encumbrance Discipline

**User Story:** As a protocol developer, I want EqualScale Alpha state and
native reservation accounting to remain isolated from EDEN lending and other
product storage.

#### Acceptance Criteria

1. THE EqualScale_Alpha_System SHALL store all EqualScale Alpha state in a
   unique diamond storage slot derived from `keccak256("equalscale.alpha.storage")`.
2. THE EqualScale_Alpha_System SHALL reserve lender commitments through
   canonical `encumberedCapital` and borrower-posted collateral through
   canonical `lockedCapital`.
3. THE EqualScale_Alpha_System SHALL key borrower state by borrower
   `positionKey` and lender commitment state by lender `positionKey`.
4. Tests SHALL prove storage-slot isolation and that product-native storage is
   sufficient to explain active exposure without module-ID namespace isolation.
