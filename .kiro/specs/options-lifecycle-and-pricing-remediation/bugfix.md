# Bugfix Requirements Document

## Introduction

Ten remediation items in the EqualFi Options lifecycle require coordinated fixes. The scope covers European tolerance bounding (finding 3), European reclaim/exercise window overlap (finding 4), strike normalization rounding bias (finding 5), reclaim collateral accounting mismatch (finding 6), silent decimals fallback in Options math (finding 7), deposit cap blocking option exercise (finding 8), option-token replacement orphaning live series (lead), userCount inflation via maintenance settlement (lead, depends on shared `equalfi-usercount-reconciliation` spec), creation-time guard for zero-normalized strike (lead), and WAD strike-price convention documentation (lead). Together these restore correct European lifecycle timing, protocol-safe rounding, residual collateral integrity, fail-closed decimals safety, unblocked exercise settlement, governance safety for token replacement, and parameterization guards.

Canonical Track: Track F. Options Lifecycle and Exerciseability
Phase: Phase 2. Product Lifecycle Fixes

Source report: `assets/findings/EdenFi-options-pashov-ai-audit-report-20260405-033500.md`
Remediation plan: `assets/remediation/Options-findings-3-8-remediation-plan.md`
Unified plan: `assets/remediation/EqualFi-unified-remediation-plan.md`

Depends on:
- Track A. Native Asset Tracking and Transfer Symmetry
- Track B. ACI / Encumbrance / Debt Tracker Consistency (shared `equalfi-usercount-reconciliation` for userCount inflation fix)
- Shared currency metadata safety from Track C

Downstream reports closed:
- `assets/findings/EdenFi-options-pashov-ai-audit-report-20260405-033500.md` (findings 3-8)
- `assets/findings/EdenFi-libraries-phase3-pashov-ai-audit-report-20260406-193000.md` (shared `LibCurrency.decimals` fallback propagation into Options)

Non-remediation (reviewed, no fix planned):
- Finding 1: Accepted as current product policy (permissionless reclaimed-claim burning)
- Finding 2: Accepted as current product policy (operator-directed exercise)
- No minimum expiry duration: Accepted as low-priority product hygiene

## Bug Analysis

### Current Behavior (Defect)

**Finding 3 — `setEuropeanTolerance` has no upper bound**

1.1 WHEN the admin calls `setEuropeanTolerance` with an excessively large `uint64` value THEN the system stores the value without validation, and subsequent European exercise-window checks compute `series.expiry + tolerance` which can overflow or produce unreasonable windows

1.2 WHEN `_validateExerciseWindow` computes `series.expiry + tolerance` with an oversized tolerance THEN the system can revert on overflow, permanently bricking ALL European option exercises across the protocol

**Finding 4 — European reclaim/exercise window overlap**

1.3 WHEN a European option series has nonzero tolerance and `block.timestamp` is in the range `(expiry, expiry + tolerance]` THEN the system allows both `reclaimOptions` (which checks `block.timestamp > series.expiry`) and exercise (which checks `block.timestamp <= expiry + tolerance`) to succeed simultaneously

1.4 WHEN the maker front-runs a holder's exercise by calling `reclaimOptions` during the overlap window THEN the system sets `series.remainingSize = 0` and unlocks collateral, causing the holder's exercise to revert and the maker to retain the intrinsic value

**Finding 5 — `_normalizeStrikeAmount` rounds down**

1.5 WHEN `_normalizeStrikeAmount` computes the strike payment for a call exercise using two sequential `Math.mulDiv` calls with default floor rounding THEN the system systematically underpays the maker by rounding the exerciser's obligation downward

1.6 WHEN `_normalizeStrikeAmount` computes put collateral locking using the same double-truncation structure THEN the system can under-collateralize put options by the cumulative floor-rounding error across both divisions

**Finding 6 — Reclaim collateral accounting mismatch**

1.7 WHEN `reclaimOptions` computes the collateral to unlock for remaining unexercised options THEN the system recomputes collateral from `remainingSize` via `_normalizeStrikeAmount` instead of using the stored `series.collateralLocked` residual, producing a rounded approximation that can differ from the actual locked amount

1.8 WHEN partial exercises have each truncated collateral decrements and the maker reclaims the remainder THEN the system can leave encumbrance dust permanently locked because the recomputed unlock amount does not match the stored residual

**Finding 7 — `LibCurrency.decimals` silent fallback to 18**

1.9 WHEN `_normalizeStrikeAmount` calls `LibCurrency.decimals(token)` for a token that reverts on `decimals()` THEN the system silently falls back to 18 decimals, producing wildly incorrect strike amounts and collateral calculations

1.10 WHEN `_previewStrikeAmount` in `OptionsViewFacet` uses the same silent-fallback `LibCurrency.decimals` THEN the system produces incorrect preview amounts that do not match what a fail-closed execution path would compute

**Finding 8 — Deposit cap blocks option exercise**

1.11 WHEN a holder exercises in-the-money options and `_increasePrincipal` credits the strike payment into the maker's pool position THEN the system enforces `depositCap` and `maxUserCount` checks, which can revert if the maker's pool has been reconfigured after series creation

1.12 WHEN the maker or pool admin adjusts pool caps after series creation THEN the system can permanently block exercise of already-issued options, stranding holder rights on mutable pool settings

**Lead — `setOptionToken` orphans active series**

1.13 WHEN the admin calls `setOptionToken` while live option series still exist with balances on the current ERC-1155 contract THEN the system replaces the canonical token address, and subsequent exercise/burn calls resolve the new token which has no balances for existing series

1.14 WHEN series balances are orphaned on the old token contract THEN the system makes those options permanently unexercisable with no migration path

**Lead — `userCount` inflation via maintenance settlement**

1.15 WHEN `LibFeeIndex.settle` zeros a user's `userPrincipal` through maintenance fee deduction without decrementing `pool.userCount` THEN the system leaves a stale count entry for that user

1.16 WHEN a subsequent exercise or principal credit path increments `userCount` again for the same logical user (whose principal was zeroed by maintenance) THEN the system double-counts the user, eventually blocking new pool entrants through `maxUserCount`

**Lead — `_normalizeStrikeAmount` truncation to zero**

1.17 WHEN `createOptionSeries` is called with parameter combinations where the normalized strike amount collapses to zero (low strike price, small contract size, decimal mismatch) THEN the system creates a series that is economically dead-on-arrival with collateral locked against an unexercisable option shape

**Lead — `strikePrice` WAD scale assumption**

1.18 WHEN an integrator creates a series with a `strikePrice` that is not WAD-scaled (1e18) THEN the system silently accepts the mis-scaled value and produces dramatically wrong pricing and collateral calculations with no validation or documentation guard

### Expected Behavior (Correct)

**Finding 3 — Bound European tolerance**

2.1 WHEN the admin calls `setEuropeanTolerance` with a value exceeding `MAX_EUROPEAN_TOLERANCE` (30 days) THEN the system SHALL revert, preventing unreasonable or overflow-prone tolerance values from entering storage

2.2 WHEN the admin calls `setEuropeanTolerance` with a value within the bound THEN the system SHALL store the value and European exercise-window validation SHALL work correctly within the bounded range

**Finding 4 — Eliminate European reclaim/exercise overlap**

2.3 WHEN a European option series has nonzero tolerance and `block.timestamp <= expiry + tolerance` THEN the system SHALL prevent `reclaimOptions` from succeeding, keeping the exercise window exclusively available to holders

2.4 WHEN `block.timestamp > expiry + tolerance` for a European series THEN the system SHALL allow `reclaimOptions` to proceed normally

2.5 WHEN an American option series has expired THEN the system SHALL CONTINUE TO allow reclaim immediately after expiry (American reclaim behavior unchanged)

**Finding 5 — Protocol-safe strike normalization**

2.6 WHEN `_normalizeStrikeAmount` computes the strike payment for exercise or collateral locking THEN the system SHALL use `Math.Rounding.Ceil` and collapse the two-step division into a single `Math.mulDiv` to minimize precision loss and round in the protocol-safe direction

2.7 WHEN `_previewStrikeAmount` in `OptionsViewFacet` computes preview amounts THEN the system SHALL use the same rounding and conversion logic as the execution path

**Finding 6 — Reclaim stored residual collateral**

2.8 WHEN `reclaimOptions` unlocks collateral for remaining unexercised options THEN the system SHALL use the stored `series.collateralLocked` value directly instead of recomputing from `remainingSize`

2.9 WHEN all options in a series have been exercised and the maker reclaims THEN the system SHALL unlock exactly the stored residual with no encumbrance dust left behind

**Finding 7 — Fail-closed decimals lookup**

2.10 WHEN `_normalizeStrikeAmount` queries token decimals THEN the system SHALL use `LibCurrency.decimalsOrRevert` instead of `LibCurrency.decimals`, reverting cleanly for tokens with unusable metadata

2.11 WHEN `_previewStrikeAmount` queries token decimals THEN the system SHALL use `LibCurrency.decimalsOrRevert` to keep preview and execution paths consistent

**Finding 8 — Bypass deposit cap for exercise settlement**

2.12 WHEN option exercise credits the strike payment into the maker's pool position THEN the system SHALL bypass `depositCap` and `maxUserCount` checks, treating exercise settlement as obligation fulfillment rather than a fresh deposit

2.13 WHEN ordinary voluntary deposits are made into the same pool THEN the system SHALL CONTINUE TO enforce `depositCap` and `maxUserCount` normally

**Lead — Block option-token replacement while live series exist**

2.14 WHEN the admin calls `setOptionToken` and live (non-terminal) option series still exist THEN the system SHALL revert, preventing orphaned balances

2.15 WHEN no live series exist (all series are reclaimed or the system is quiescent) THEN the system SHALL allow `setOptionToken` to proceed normally

**Lead — userCount reconciliation (Options-specific regression)**

2.16 WHEN maintenance settlement zeros a user's principal THEN the system SHALL decrement `userCount` appropriately (fix lands in shared `equalfi-usercount-reconciliation` spec)

2.17 WHEN subsequent exercise credits principal back to the same user THEN the system SHALL increment `userCount` only once, not double-count

**Lead — Creation-time zero-strike guard**

2.18 WHEN `createOptionSeries` is called and the normalized strike amount for the configured parameters would be zero THEN the system SHALL revert at creation time, preventing dead-on-arrival series

**Lead — WAD strike-price convention**

2.19 WHEN `createOptionSeries` is called THEN the system SHALL document via NatSpec that `strikePrice` is WAD-scaled (1e18) and tests SHALL reinforce the expected scaling convention

### Unchanged Behavior (Regression Prevention)

**Option series creation**

3.1 WHEN `createOptionSeries` is called with valid parameters (nonzero size, nonzero contract size, nonzero strike price, future expiry, valid pools, valid position) THEN the system SHALL CONTINUE TO validate inputs, settle positions, compute and lock collateral, write series state, add to position tracking, mint ERC-1155 tokens, and emit the creation event correctly

3.2 WHEN `createOptionSeries` is called with `isCall == true` THEN the system SHALL CONTINUE TO lock underlying notional as collateral

**Option exercise flow**

3.3 WHEN a holder exercises options with valid parameters within the exercise window THEN the system SHALL CONTINUE TO validate the window, burn tokens, settle positions, compute strike amount, unlock collateral, collect payment, credit maker principal, transfer collateral to recipient, and emit the exercise event correctly

3.4 WHEN a call option is exercised THEN the system SHALL CONTINUE TO collect strike payment from holder, credit it to maker's strike pool, and transfer underlying to recipient

3.5 WHEN a put option is exercised THEN the system SHALL CONTINUE TO collect underlying from holder, credit it to maker's underlying pool, and transfer strike collateral to recipient

**American option lifecycle**

3.6 WHEN an American option is exercised before expiry THEN the system SHALL CONTINUE TO allow exercise and validate the window correctly

3.7 WHEN an American option has expired THEN the system SHALL CONTINUE TO allow reclaim immediately after expiry

**European option exercise**

3.8 WHEN a European option is exercised within the tolerance-bounded window `[expiry - tolerance, expiry + tolerance]` THEN the system SHALL CONTINUE TO allow exercise

**Reclaim flow**

3.9 WHEN `reclaimOptions` is called for a fully exercised series (`remainingSize == 0`) THEN the system SHALL CONTINUE TO mark the series as reclaimed and remove it from position tracking without unlocking any collateral

3.10 WHEN `reclaimOptions` is called by a non-owner THEN the system SHALL CONTINUE TO revert with an ownership error

**Burn reclaimed claims**

3.11 WHEN `burnReclaimedOptionsClaims` is called for a reclaimed series THEN the system SHALL CONTINUE TO burn the specified amount of the holder's ERC-1155 tokens

**Admin functions**

3.12 WHEN `setOptionsPaused` is called by an authorized admin THEN the system SHALL CONTINUE TO toggle the paused state

3.13 WHEN `deployOptionToken` is called THEN the system SHALL CONTINUE TO deploy a new OptionToken and set it as canonical

**View functions**

3.14 WHEN `previewExercisePayment` is called for a valid series THEN the system SHALL CONTINUE TO return the correct preview amount (now using fail-closed decimals and consistent rounding)

3.15 WHEN `getOptionSeries`, `getOptionSeriesIdsByPosition`, or productive-collateral views are called THEN the system SHALL CONTINUE TO return correct state
