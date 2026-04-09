# Bugfix Requirements Document

## Introduction

Three root-cause defects in the shared EqualFi accounting libraries break ACI bucket placement, encumbrance yield settlement, and debt tracker consistency across the protocol substrate. Finding 1 (Libraries Phase 1, [90]): `_removeFromBase` and `_scheduleState` disagree on bucket placement when `offset >= BUCKET_COUNT` — `_scheduleState` places principal in a pending bucket, but `_removeFromBase` subtracts from `activeCreditMaturedTotal` instead, causing permanent inflation of the matured total when buckets roll and phantom principal that earns ACI yield diluting real participants. Finding 2 (Libraries Phase 1, [88]): `_increaseEncumbrance` and `_decreaseEncumbrance` overwrite `enc.indexSnapshot` to the current `activeCreditIndex` without first settling pending ACI yield accrued since the last snapshot, permanently destroying any unsettled yield on every encumbrance change — affecting every Community AMM join/leave and any Solo boundary-sync path that changes encumbrance. Finding 3 (Libraries Phase 2, [93]): `_decreaseBorrowedPrincipal` and `_decreaseSameAssetDebt` silently clamp five independent debt trackers to zero instead of reverting on over-subtraction, causing permanent desynchronization when multiple agreements share the same borrower/pool pair — `activeCreditPrincipalTotal` inflates, `userSameAssetDebt` understates, and per-positionId `sameAssetDebt` diverges.

These three library-level defects are the root cause of downstream accounting bugs in EqualX boundary-synced encumbrance flows, EqualScale (finding 1 — chargeOffLine never clears borrower debt state), EqualLend (debt-service tracker integrity), and EDEN (eligible supply and reward settlement semantics where `LibFeeIndex.settle` mutates balances). Fixing the shared accounting substrate first is the prerequisite for downstream product specs.

Canonical Track: Track B. ACI / Encumbrance / Debt Tracker Consistency
Phase: Phase 1. Shared Accounting Substrate

Source reports:
- `assets/findings/EdenFi-libraries-phase1-pashov-ai-audit-report-20260406-150000.md` (findings 3, 4)
- `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md` (finding 2)
Remediation plan: `assets/remediation/EqualFi-unified-remediation-plan.md` (Track B)

Downstream reports affected:
- `assets/findings/EdenFi-equalx-pashov-ai-audit-report-20260405-002000.md` (finding 2 — original Solo AMM swap-time ACI sync issue, later redesigned into boundary-synced Solo accounting)
- `assets/findings/EdenFi-equalscale-pashov-ai-audit-report-20260405-011500.md` (finding 1 — chargeOffLine never clears borrower debt state)
- `assets/findings/EdenFi-equallend-pashov-ai-audit-report-20260405-160000.md` (debt-service tracker integrity)
- EDEN eligible supply and reward settlement semantics where `LibFeeIndex.settle` mutates balances

## Bug Analysis

### Current Behavior (Defect)

**Finding 1 — ACI Bucket Asymmetry: `_removeFromBase` and `_scheduleState` disagree on bucket placement**

1.1 WHEN `_scheduleState` places principal into a pending bucket because `offset >= BUCKET_COUNT` (using the last bucket as overflow) and later `_removeFromBase` is called for the same state THEN the system subtracts from `activeCreditMaturedTotal` instead of from the pending bucket where the principal was actually placed, causing permanent inflation of the matured total

1.2 WHEN buckets roll forward via `_rollMatured` after the asymmetric placement from 1.1 THEN the pending bucket principal is added to `activeCreditMaturedTotal` a second time (once from the misplaced removal, once from the roll), creating phantom matured principal that earns ACI yield and dilutes real participants

1.3 WHEN the silent clamp-to-zero in `_removeFromBase` absorbs the accounting error (subtracting from `activeCreditMaturedTotal` when the principal is not actually there) THEN the system masks the drift instead of reverting, allowing `activeCreditMaturedTotal` to diverge permanently from the true sum of matured principals

**Finding 2 — ACI Encumbrance Changes Overwrite `indexSnapshot` Without Settling Pending Yield**

1.4 WHEN `_increaseEncumbrance` is called (e.g., during a Solo AMM rebalance / finalize boundary sync or a Community AMM join) THEN the system overwrites `enc.indexSnapshot` to the current `state.activeCreditIndex` without first settling any pending ACI yield accrued since the last snapshot, permanently destroying the unsettled yield equal to `principal * (currentIndex - oldSnapshot) / INDEX_SCALE`

1.5 WHEN `_decreaseEncumbrance` is called (e.g., during a Solo AMM finalize / cancel boundary sync or a Community AMM leave) and the encumbrance state is not fully zeroed THEN the system overwrites `enc.indexSnapshot` to the current `state.activeCreditIndex` without first settling pending ACI yield, permanently destroying the unsettled yield

1.6 WHEN multiple encumbrance changes occur across the life of a Solo AMM market across rebalance and close boundaries, or across repeated Community join/leave actions, THEN each snapshot overwrite compounds the yield loss because each change discards the yield accrued since the previous change

**Finding 3 — `_decreaseBorrowedPrincipal` / `_decreaseSameAssetDebt` Silent Clamp-to-Zero**

1.7 WHEN `_decreaseBorrowedPrincipal` is called with an `amount` exceeding the current `borrowedPrincipalByPool` value (e.g., when multiple agreements share the same borrower/pool pair and the first settlement over-clears the tracker) THEN the system silently clamps to zero instead of reverting, allowing subsequent settlements to skip the decrement entirely

1.8 WHEN `_decreaseSameAssetDebt` is called and any of the four independent trackers (`sameAssetDebtByAsset`, `userSameAssetDebt`, per-positionId `sameAssetDebt`, `activeCreditPrincipalTotal`) has already been over-cleared by a prior settlement THEN the system silently clamps each tracker to zero independently, causing permanent desynchronization between the five debt tracking dimensions

1.9 WHEN `activeCreditPrincipalTotal` is inflated due to silent clamp-to-zero on the debt-side ACI state THEN phantom borrower debt principal earns ACI yield that dilutes real encumbrance participants, and `userSameAssetDebt` understates the borrower's actual debt exposure

### Expected Behavior (Correct)

**Finding 1 — Symmetric bucket placement in `_removeFromBase`**

2.1 WHEN `_removeFromBase` is called for a state whose `offset >= BUCKET_COUNT` THEN the system SHALL remove principal from the same pending bucket that `_scheduleState` placed it in (the last bucket), not from `activeCreditMaturedTotal`, maintaining bucket placement symmetry

2.2 WHEN `_removeFromBase` encounters an over-subtraction from any bucket or from `activeCreditMaturedTotal` THEN the system SHALL revert instead of silently clamping to zero, surfacing accounting drift immediately rather than masking it

**Finding 2 — Settle pending yield before overwriting `indexSnapshot`**

2.3 WHEN `_increaseEncumbrance` is called THEN the system SHALL first settle any pending ACI yield for the encumbrance state (computing `principal * (currentIndex - oldSnapshot) / INDEX_SCALE` and crediting it to `userAccruedYield`) before overwriting `enc.indexSnapshot` and increasing principal

2.4 WHEN `_decreaseEncumbrance` is called and the encumbrance state is not fully zeroed THEN the system SHALL first settle any pending ACI yield for the encumbrance state before overwriting `enc.indexSnapshot` and decreasing principal

**Finding 3 — Revert on debt tracker over-subtraction**

2.5 WHEN `_decreaseBorrowedPrincipal` is called with `amount > current` THEN the system SHALL revert instead of silently clamping to zero, preventing permanent tracker desynchronization

2.6 WHEN `_decreaseSameAssetDebt` is called and any of the four independent trackers would underflow THEN the system SHALL revert instead of silently clamping each tracker to zero independently, preventing permanent desynchronization between the five debt tracking dimensions

### Unchanged Behavior (Regression Prevention)

**ACI bucket and maturity mechanics**

3.1 WHEN `_scheduleState` places principal into a pending bucket for states with `offset < BUCKET_COUNT` THEN the system SHALL CONTINUE TO place principal at the correct bucket index `(cursor + offset) % BUCKET_COUNT`

3.2 WHEN `_rollMatured` advances buckets and moves pending principal to `activeCreditMaturedTotal` THEN the system SHALL CONTINUE TO roll buckets correctly based on elapsed hours

3.3 WHEN `_removeFromBase` is called for a mature state (where `_isMature` returns true) THEN the system SHALL CONTINUE TO subtract from `activeCreditMaturedTotal` as before

3.4 WHEN `accrueWithSource` distributes ACI yield to the index THEN the system SHALL CONTINUE TO compute the index delta using `activeCreditMaturedTotal` as the base and distribute yield proportionally

**ACI encumbrance lifecycle**

3.5 WHEN `applyEncumbranceIncrease` is called with `amount == 0` THEN the system SHALL CONTINUE TO return early without modifying any state

3.6 WHEN `applyEncumbranceDecrease` is called and the decrease fully zeroes the encumbrance principal THEN the system SHALL CONTINUE TO call `resetIfZeroWithGate` to clear the state

3.7 WHEN `applyWeightedIncreaseWithGate` is called during encumbrance increase THEN the system SHALL CONTINUE TO apply weighted dilution, reschedule the state, and emit timing events

3.8 WHEN `applyPrincipalDecrease` is called during encumbrance decrease THEN the system SHALL CONTINUE TO remove from base and decrease principal correctly

**Debt tracker origination and settlement**

3.9 WHEN `_increaseBorrowedPrincipal` is called during loan origination THEN the system SHALL CONTINUE TO increment `borrowedPrincipalByPool` by the principal amount

3.10 WHEN `_increaseSameAssetDebt` is called during same-asset loan origination THEN the system SHALL CONTINUE TO increment all five debt trackers (`sameAssetDebtByAsset`, `userSameAssetDebt`, per-positionId `sameAssetDebt`, `activeCreditPrincipalTotal`, and the debt ACI state) correctly

3.11 WHEN `_decreaseBorrowedPrincipal` is called with `amount <= current` THEN the system SHALL CONTINUE TO decrement `borrowedPrincipalByPool` by the exact amount without reverting

3.12 WHEN `_decreaseSameAssetDebt` is called with `principalComponent` within bounds of all trackers THEN the system SHALL CONTINUE TO decrement all five trackers correctly, apply ACI principal decrease, and update the debt state index snapshot

3.13 WHEN `settlePrincipal` is called for a single-agreement borrower/pool pair THEN the system SHALL CONTINUE TO settle correctly because the trackers are in sync and no over-subtraction occurs

**Downstream product flows**

3.14 WHEN EqualX encumbrance flows mutate principal — especially Community AMM join/leave and Solo rebalance / finalize boundary sync — THEN the system SHALL CONTINUE TO settle pending yield correctly before overwriting `indexSnapshot`

3.15 WHEN EqualLend Direct loans are originated and settled THEN the system SHALL CONTINUE TO track debt correctly through `_increaseSameAssetDebt` / `_decreaseSameAssetDebt` for same-asset loans

3.16 WHEN EqualScale chargeOffLine clears borrower debt state THEN the system SHALL CONTINUE TO reduce debt trackers correctly (this is the downstream fix from EqualScale finding 1 that depends on the debt tracker revert-on-overflow fix landing here first)
