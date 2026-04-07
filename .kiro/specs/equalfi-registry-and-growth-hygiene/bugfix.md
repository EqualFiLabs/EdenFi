# Bugfix Requirements Document

## Introduction

Four storage-layer and registry-hygiene bugs across the EqualFi shared libraries require remediation. The bugs span EDEN reward program ID allocation (sentinel collision), Options exercise window initialization (zero tolerance default), EqualX discovery registry deduplication and active-registry hygiene, and EqualScale commitment tracking (append-only position IDs). Together they address first-program invisibility, unexercisable European options, duplicate discovery entries, active-registry cleanup discipline, and unbounded gas growth on commitment iteration.

Canonical Track: Track H. Discovery, Storage Growth, and Registry Hygiene
Phase: Phase 3. Architectural Redesign and Governance Hardening

Source report: `assets/findings/EdenFi-libraries-phase4-pashov-ai-audit-report-20260406-210000.md`
Unified plan: `assets/remediation/EqualFi-unified-remediation-plan.md`

Downstream reports closed:
- Libraries Phase 4, Finding 1 [85]: `allocateProgramId` zero-based ID sentinel collision
- Libraries Phase 4, Finding 2 [82]: `europeanToleranceSeconds` defaults to 0
- Libraries Phase 4, Lead: Discovery registry active-set hygiene
- Libraries Phase 4, Lead: Discovery registry unbounded growth
- EqualScale remediation plan: `lineCommitmentPositionIds` append-only growth

Dependencies:
- Phase 1 and Phase 2 specs should land first
- `equalfi-reward-backing-redesign` handles EDEN target-program cleanup separately
- `equalscale-line-lifecycle-remediation` handles borrower line view cleanup separately
- `options-lifecycle-and-pricing-remediation` handles European tolerance bounding separately — this spec handles the DEFAULT initialization

## Bug Analysis

### Current Behavior (Defect)

**Finding 1 — `allocateProgramId` zero-based ID sentinel collision**

1.1 WHEN the first EDEN reward program is created via `EdenRewardsFacet.createRewardProgram` THEN the system assigns program ID 0 because `allocateProgramId` uses return-then-increment (`programId = store.nextProgramId; store.nextProgramId = programId + 1`) starting from uninitialized storage (0)

1.2 WHEN any code checks whether a program ID exists by testing `programId == 0` as a "not found" sentinel THEN the system treats the first reward program as nonexistent because its ID collides with Solidity's default `uint256` value

**Finding 2 — `europeanToleranceSeconds` defaults to 0**

1.3 WHEN an EqualFi diamond is deployed without an explicit call to `setEuropeanTolerance` THEN the system stores `europeanToleranceSeconds = 0` because uninitialized `uint64` storage defaults to zero

1.4 WHEN a European option holder attempts to exercise an option before `setEuropeanTolerance` has been called THEN the system requires `block.timestamp` to exactly equal `series.expiry` (a single-second window), making the option effectively unexercisable

**Finding 3 — Discovery registry hygiene scope**

1.5 WHEN EqualX discovery is queried THEN `marketsByPosition` and `marketsByPair` intentionally behave as historical registries, while `activeMarketsByType` is the live set

1.6 WHEN remediation work treats historical arrays as if they were stale-active registries THEN the fix changes EqualFi discovery semantics rather than merely cleaning up growth bugs

**Finding 4 — Discovery registry unbounded growth and duplicate entries**

1.7 WHEN `registerMarket` is called for a market that has already been registered THEN the system pushes a duplicate `MarketPointer` into `marketsByPosition`, `marketsByPair`, and `activeMarketsByType` because there is no deduplication check

1.8 WHEN markets accumulate over time in discovery storage THEN duplicate registration and live-set churn increase storage growth and query noise even though historical position/pair registries are intentionally append-only

**Finding 5 — `lineCommitmentPositionIds` append-only growth**

1.9 WHEN a lender commitment is canceled, exited, written down, or closed on an EqualScale credit line THEN the system never removes the lender position ID from `lineCommitmentPositionIds[lineId]`, leaving the array to grow without bound

1.10 WHEN allocation helpers (`allocateRepayment`, `allocateRecovery`, `allocateWriteDown`, `closeAllCommitments`) iterate `lineCommitmentPositionIds` THEN the system scans all historical position IDs including those with non-active commitment status, increasing gas cost proportionally to total historical commitments rather than live commitments

### Expected Behavior (Correct)

**Finding 1 — One-based program ID allocation**

2.1 WHEN the first EDEN reward program is created THEN the system SHALL assign program ID 1 (not 0) by using increment-then-return in `allocateProgramId`, consistent with every other ID allocator in the codebase

2.2 WHEN `allocateProgramId` is called THEN the system SHALL increment `nextProgramId` before returning, so that ID 0 is never assigned and can safely serve as a "not found" sentinel

**Finding 2 — Safe default European tolerance**

2.3 WHEN the EqualFi diamond is initialized via `DiamondInit.init` THEN the system SHALL set `europeanToleranceSeconds` to a safe nonzero default (300 seconds / 5 minutes) so that European options are exercisable from deployment without requiring a separate admin configuration call

**Finding 3 — Preserve historical discovery semantics**

2.4 WHEN a market is closed or finalized THEN the system SHALL remove the market pointer only from live discovery sets such as `activeMarketsByType`, while preserving historical `marketsByPosition` and `marketsByPair` query semantics

**Finding 4 — Deduplicated discovery registration**

2.5 WHEN `registerMarket` is called for a market that already exists in a discovery array THEN the system SHALL skip the duplicate push, preventing duplicate `MarketPointer` entries

2.6 WHEN discovery arrays are queried THEN the system SHALL continue to distinguish historical registries (`marketsByPosition`, `marketsByPair`) from live registries (`activeMarketsByType`)

**Finding 5 — Bounded commitment position ID tracking**

2.7 WHEN a lender commitment transitions to a terminal status (Canceled, Exited, WrittenDown, Closed) THEN the system SHALL remove the lender position ID from `lineCommitmentPositionIds[lineId]` using swap-and-pop, keeping the array bounded to active commitments only

2.8 WHEN allocation helpers iterate `lineCommitmentPositionIds` THEN the system SHALL only encounter active commitment position IDs, bounding gas cost to the number of live commitments

### Unchanged Behavior (Regression Prevention)

**EDEN reward program lifecycle**

3.1 WHEN a reward program is created with a valid configuration THEN the system SHALL CONTINUE TO store the program config, register the target, and emit the creation event correctly

3.2 WHEN reward programs are funded, accrued, claimed, ended, or closed THEN the system SHALL CONTINUE TO use the assigned program ID for all lifecycle operations without behavioral change

3.3 WHEN `targetProgramIds` is queried for a target THEN the system SHALL CONTINUE TO return all registered program IDs for that target

**Options lifecycle**

3.4 WHEN `setEuropeanTolerance` is called by governance THEN the system SHALL CONTINUE TO update `europeanToleranceSeconds` to the governance-specified value, overriding the default

3.5 WHEN an American option is exercised THEN the system SHALL CONTINUE TO allow exercise at any time before expiry regardless of `europeanToleranceSeconds`

3.6 WHEN a European option is exercised within the tolerance window THEN the system SHALL CONTINUE TO validate the exercise window using `[expiry - tolerance, expiry + tolerance]`

**Discovery registry**

3.7 WHEN a new market is created and registered THEN the system SHALL CONTINUE TO add the market pointer to `marketsByPosition`, `marketsByPair`, and `activeMarketsByType`

3.8 WHEN `marketsByPosition` or `marketsByPair` is queried THEN the system SHALL CONTINUE TO return historical market pointers for the given key, while `activeMarketsByType` SHALL CONTINUE TO return only live market pointers

3.9 WHEN a market is active and has not been closed THEN the system SHALL CONTINUE TO appear in all three discovery arrays

**EqualScale commitment lifecycle**

3.10 WHEN a new lender commits to a credit line THEN the system SHALL CONTINUE TO add the lender position ID to `lineCommitmentPositionIds[lineId]` and record the commitment

3.11 WHEN allocation helpers iterate active commitments THEN the system SHALL CONTINUE TO correctly allocate repayment, recovery, write-down, and close amounts across all active commitments

3.12 WHEN `lineHasCommitmentPosition` is checked for a lender THEN the system SHALL return true only for lenders with an active commitment currently present in `lineCommitmentPositionIds`, allowing recommitment after a terminal transition
