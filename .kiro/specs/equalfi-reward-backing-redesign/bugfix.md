# Bugfix Requirements Document

## Introduction

Eight confirmed defects and architectural gaps in the EDEN by EqualFi reward system require remediation beyond the narrow Phase 1 accounting fixes already covered in `equalfi-fee-routing-accounting-cleanup`. This spec addresses reward claim integrity (fail-closed claims, FoT overpayment prevention), per-program backing isolation, operational lifecycle improvements (target-program cleanup, past-start semantics, manager rotation), and a minor ETH guard. Together these fixes harden EDEN reward-backing invariants, eliminate cross-program balance coupling, and improve lifecycle ergonomics.

Canonical Track: Track C. Fee Routing, Backing Isolation, and Exotic Token Policy
Phase: Phase 3. Architectural Redesign and Governance Hardening

Source reports:
- `assets/findings/EdenFi-eden-pashov-ai-audit-report-20260405-025500.md` (findings 3, 4, 6; leads: FoT claim, cross-program backing, rebasing, past-start, manager rotation)
- `assets/findings/EdenFi-libraries-phase2-pashov-ai-audit-report-20260406-163000.md` (reward engine double gross-up root cause — fixed in Phase 1)

Remediation plan:
- `assets/remediation/EqualFi-unified-remediation-plan.md` (Track C, Phase 3)
- `assets/remediation/EDEN-findings-3-4-5-6-remediation-plan.md`

Dependencies:
- Track A (Native Asset Tracking) should land first
- Track B (ACI/Encumbrance) should land first
- `equalfi-fee-routing-accounting-cleanup` (Phase 1 Track C) should land first — it fixes the reward engine double gross-up and truncation remainder that this spec builds on
- This spec assumes a clean-break rollout or new-program-only rollout for EDEN by EqualFi; in-place migration of live program backing is out of scope here and requires a separate migration spec

Non-goals:
- Reward engine double gross-up fix (Phase 1 — `equalfi-fee-routing-accounting-cleanup`)
- Reward index truncation remainder tracking (Phase 1 — `equalfi-fee-routing-accounting-cleanup`)
- Full rebasing token reconciliation implementation (design direction captured here, implementation deferred)
- In-place migration/bootstrap of `programBackingBalance` for already-live programs

## Bug Analysis

### Current Behavior (Defect)

**Finding 6 — Partial claim restores unbacked accrued rewards**

1.1 WHEN `claimRewardProgram` executes and `grossClaimAmount > availableGross` (insufficient contract balance) THEN the system caps the payout to `availableGross` and restores the shortfall to `accruedRewards`, creating an unbacked liability because the reserve backing for that restored amount was already consumed during accrual

1.2 WHEN a partial claim restores unbacked `accruedRewards` and a subsequent claim executes THEN the system allows the restored amount to be claimed against the diamond's shared token balance, effectively draining tokens that belong to other programs sharing the same reward token

**FoT claim overpayment — Fee-on-transfer claim delivers more than intended net**

1.3 WHEN `claimRewardProgram` executes with `outboundTransferBps > 0` and the actual token transfer fee is lower than the configured `outboundTransferBps` THEN the system sends `grossUpNetAmount(claimed)` tokens but the recipient receives more than `claimed` net, overpaying the user at the expense of program reserves

1.4 WHEN `claimRewardProgram` executes and `netReceived < claimed` THEN the system restores `claimed - netReceived` to `accruedRewards`, but this restored amount has no corresponding reserve backing, creating the same unbacked liability as finding 6

**Cross-program same-token backing isolation — Programs share a single live balance surface**

1.5 WHEN multiple EDEN reward programs use the same reward token THEN the system caps claims against the diamond's total token balance for that token rather than per-program backing, coupling programs through a shared live balance surface

1.6 WHEN one program's accounting desyncs (e.g., from partial claims, rounding, or external balance changes) THEN the system allows that program to consume tokens that belong to another program sharing the same reward token, because there is no per-program reserve isolation

**Finding 3 — `fundRewardProgram` missing `assertZeroMsgValue`**

1.7 WHEN `fundRewardProgram` is called with nonzero `msg.value` alongside an ERC20 funding call THEN the system accepts the accidental ETH into the diamond with no recovery path, because `fundRewardProgram` is `payable` but only handles ERC20 reward tokens

**Finding 4 — Unbounded target program array gas growth**

1.8 WHEN a reward program is closed or ended THEN the system does not remove the program from `targetProgramIds`, causing the array to grow monotonically and increasing gas cost for every EqualIndex mint/burn that triggers `beforeTargetBalanceChange` and `afterTargetBalanceChange`

1.9 WHEN many programs have been created and closed over time for the same target THEN the system iterates all historical programs (including dead ones) on every eligible-balance change, eventually approaching block gas limits for EqualIndex operations

**Past-start program semantics — Silent skip of retroactive accrual window**

1.10 WHEN `createRewardProgram` is called with `startTime` already in the past THEN the system initializes `lastRewardUpdate` to `block.timestamp`, silently skipping the elapsed historical window between `startTime` and `block.timestamp` and producing no rewards for that period

**Manager rotation — Fixed manager authority with no rotation path**

1.11 WHEN a reward program manager address is compromised or needs to be rotated THEN the system provides no mechanism to change the manager, requiring governance to work around the limitation or replace the entire program

### Expected Behavior (Correct)

**Finding 6 — Claims fail closed instead of partially succeeding**

2.1 WHEN `claimRewardProgram` executes and `grossClaimAmount > availableGross` (insufficient contract balance to fully honor the claim) THEN the system SHALL revert instead of partially paying and restoring an unbacked remainder

2.2 WHEN `claimRewardProgram` executes successfully THEN the system SHALL leave zero restored `accruedRewards` — a successful claim is fully honored or not executed at all

**FoT claim overpayment — Exact net delivery required**

2.3 WHEN `claimRewardProgram` executes with `outboundTransferBps > 0` and the post-transfer `netReceived != claimed` (either over-delivery or under-delivery) THEN the system SHALL revert, ensuring the configured gross-up produces exactly the intended net receipt

2.4 WHEN `claimRewardProgram` executes successfully THEN the system SHALL guarantee `netReceived == claimed`, preventing both overpayment and underpayment regardless of actual token transfer fee behavior

**Cross-program same-token backing isolation — Per-program reserve accounting**

2.5 WHEN a reward program is funded THEN the system SHALL track the funded amount in a per-program backing field (e.g., `programBackingBalance`) that is isolated from other programs using the same reward token

2.6 WHEN `claimRewardProgram` executes THEN the system SHALL check claim availability against the program's own per-program backing balance rather than the diamond's total token balance for that reward token

2.7 WHEN two EDEN programs share the same reward token THEN the system SHALL prevent one program's claims from consuming the other program's backing, maintaining strict per-program isolation

**Finding 3 — `fundRewardProgram` rejects accidental ETH**

2.8 WHEN `fundRewardProgram` is called with nonzero `msg.value` THEN the system SHALL revert via `LibCurrency.assertZeroMsgValue()`, preventing accidental ETH from being locked in the diamond

**Finding 4 — Dead programs removed from target arrays**

2.9 WHEN `closeRewardProgram` is called THEN the system SHALL remove the program from `targetProgramIds` using a swap-and-pop pattern, preventing closed programs from bloating live target-hook iteration

2.10 WHEN `beforeTargetBalanceChange` and `afterTargetBalanceChange` iterate `targetProgramIds` THEN the system SHALL only process live programs, keeping EqualIndex mint/burn gas cost bounded by the number of active programs

2.11 WHEN `closeRewardProgram` is called THEN the system SHALL require both `fundedReserve == 0` and `programBackingBalance == 0`, ensuring the program is fully drained before it becomes closed and is removed from live target iteration

**Past-start program semantics — Retroactive accrual support**

2.12 WHEN `createRewardProgram` is called with `startTime < block.timestamp` THEN the system SHALL initialize `lastRewardUpdate` to `startTime` instead of `block.timestamp`, enabling retroactive reward accrual from the configured start

2.13 WHEN `createRewardProgram` is called with `startTime >= block.timestamp` (future start) THEN the system SHALL CONTINUE TO initialize `lastRewardUpdate` to `block.timestamp` and wait until `startTime` to begin accrual

**Manager rotation — Rotatable manager authority**

2.14 WHEN the current manager or governance calls `setRewardProgramManager(programId, newManager)` THEN the system SHALL update the program's manager to `newManager` and emit a `RewardProgramManagerUpdated` event

2.15 WHEN an unauthorized caller attempts to rotate the manager THEN the system SHALL revert with `Unauthorized()`

### Unchanged Behavior (Regression Prevention)

**Reward program creation flow**

3.1 WHEN `createRewardProgram` is called with valid parameters and `startTime >= block.timestamp` THEN the system SHALL CONTINUE TO create the program, register the target, initialize state, and emit `RewardProgramCreated` identically to current behavior

3.2 WHEN `createRewardProgram` is called with `rewardToken == address(0)` or `manager == address(0)` THEN the system SHALL CONTINUE TO revert with the appropriate validation error

**Reward program funding flow**

3.3 WHEN `fundRewardProgram` is called with zero `msg.value` and valid ERC20 parameters THEN the system SHALL CONTINUE TO pull tokens, accrue, increment `fundedReserve`, and emit `RewardProgramFunded` identically

**Reward accrual and settlement flow**

3.4 WHEN `accrueRewardProgram` is called THEN the system SHALL CONTINUE TO compute eligible supply, preview accrual, store updated state, and emit `RewardProgramAccrued` identically

3.5 WHEN `settleRewardProgramPosition` is called THEN the system SHALL CONTINUE TO accrue, compute claimable rewards from index delta, and accumulate into `accruedRewards` identically

3.6 WHEN `claimRewardProgram` is called with sufficient program backing and correct FoT configuration THEN the system SHALL CONTINUE TO settle, transfer, and emit `RewardProgramClaimed` identically

**Reward program lifecycle flow**

3.7 WHEN `setRewardProgramEnabled`, `pauseRewardProgram`, `resumeRewardProgram`, or `endRewardProgram` is called by the manager or governance THEN the system SHALL CONTINUE TO accrue before mutation and update config identically

3.8 WHEN `closeRewardProgram` is called on a program with zero `fundedReserve` and zero `programBackingBalance` after `endTime` THEN the system SHALL CONTINUE TO mark the program closed and emit `RewardProgramClosed`

**Reward program view functions**

3.9 WHEN `previewRewardProgramPosition` or `previewRewardProgramsForPosition` is called THEN the system SHALL CONTINUE TO compute preview state, eligible balance, pending rewards, and claimable rewards identically

**Consumer hook flow**

3.10 WHEN `beforeTargetBalanceChange` and `afterTargetBalanceChange` are called for live programs THEN the system SHALL CONTINUE TO settle positions and update eligible supply identically for active programs
