# Bugfix Requirements Document

## Introduction

Two root-cause defects in `LibCurrency.sol` break native ETH accounting symmetry across the entire EqualFi protocol substrate. Finding 1: `transfer()` and `transferWithMin()` send native ETH out without decrementing `nativeTrackedTotal`, while `pull()` and `pullAtLeast()` auto-increment on receive. This asymmetry means every caller that sends native ETH must manually decrement — a fragile pattern used across 17+ call sites where any single omission permanently inflates `nativeTrackedTotal`, reduces `nativeAvailable()`, and eventually bricks all native pool operations. Finding 2: `assertMsgValue()` short-circuit evaluates `msg.value != 0 && msg.value != amount`, allowing `msg.value = 0` to pass for any native amount. When `pull()` is subsequently called with `msg.value = 0`, it claims untracked contract ETH (`address(this).balance - nativeTrackedTotal`) as a user deposit, enabling theft of orphaned ETH.

These two library-level defects are the root cause of downstream native accounting bugs in EqualLend (findings 1, 2), EqualIndex (finding 4), EqualScale (finding 3 — native component), and EqualX (curve native accounting). Fixing the shared currency layer first is the prerequisite for simplifying or eliminating downstream compensating patches.

Canonical Track: Track A. Native Asset Tracking and Transfer Symmetry
Phase: Phase 1. Shared Accounting Substrate

Source report: `assets/findings/EdenFi-libraries-phase3-pashov-ai-audit-report-20260406-193000.md` (findings 1, 2)
Remediation plan: `assets/remediation/EqualFi-unified-remediation-plan.md` (Track A)

Downstream reports affected:
- `assets/findings/EdenFi-equallend-pashov-ai-audit-report-20260405-160000.md` (findings 1, 2)
- `assets/findings/EdenFi-equalindex-pashov-ai-audit-report-20260405-020000.md` (finding 4)
- `assets/findings/EdenFi-equalscale-pashov-ai-audit-report-20260405-011500.md` (finding 3 — native ETH component)
- `assets/findings/EdenFi-equalx-pashov-ai-audit-report-20260405-002000.md` (curve native accounting lead)

## Bug Analysis

### Current Behavior (Defect)

**Finding 1 — `transfer` / `transferWithMin` never decrement `nativeTrackedTotal`**

1.1 WHEN `LibCurrency.transfer()` sends native ETH to a recipient THEN the system does not decrement `nativeTrackedTotal`, permanently inflating the tracked total relative to actual tracked obligations

1.2 WHEN `LibCurrency.transferWithMin()` sends native ETH to a recipient THEN the system does not decrement `nativeTrackedTotal`, permanently inflating the tracked total relative to actual tracked obligations

1.3 WHEN any of the 17+ downstream call sites invoke `transfer()` or `transferWithMin()` for native ETH without manually decrementing `nativeTrackedTotal` beforehand THEN `nativeTrackedTotal` drifts above actual tracked ETH, progressively reducing `nativeAvailable()` until it returns 0 and bricks all native pool operations that depend on untracked balance

1.4 WHEN `nativeTrackedTotal` is inflated due to missing decrements across multiple transfer calls THEN `nativeAvailable()` computes `address(this).balance - nativeTrackedTotal` as 0 (or underflows), causing `pull()` with `msg.value = 0` to revert with `InsufficientPoolLiquidity` and blocking legitimate native pool deposits that rely on untracked balance

**Finding 2 — `assertMsgValue` allows `msg.value = 0` for any native amount**

1.5 WHEN `assertMsgValue(address(0), amount)` is called with `msg.value = 0` and `amount > 0` THEN the system does not revert because the short-circuit evaluation `msg.value != 0 && msg.value != amount` evaluates to `false` when `msg.value = 0`, silently accepting a zero-value call for a non-zero native amount

1.6 WHEN `pull()` is called for native ETH with `msg.value = 0` after `assertMsgValue` has passed THEN the system claims untracked contract ETH balance (`address(this).balance - nativeTrackedTotal`) as the caller's deposit, crediting them for ETH they did not send

1.7 WHEN orphaned ETH exists in the contract (from selfdestruct, coinbase rewards, or dust from prior operations) and an attacker calls a deposit function with `msg.value = 0` THEN the attacker is credited with the orphaned ETH amount for free, stealing protocol-owned untracked balance

### Expected Behavior (Correct)

**Finding 1 — Symmetric native tracking in transfer functions**

2.1 WHEN `LibCurrency.transfer()` sends native ETH to a recipient THEN the system SHALL decrement `nativeTrackedTotal` by the transfer amount before executing the ETH send, maintaining the invariant that `nativeTrackedTotal` reflects only ETH currently tracked by pools

2.2 WHEN `LibCurrency.transferWithMin()` sends native ETH to a recipient THEN the system SHALL decrement `nativeTrackedTotal` by the transfer amount before executing the ETH send, maintaining the same symmetric tracking invariant

2.3 WHEN downstream call sites invoke `transfer()` or `transferWithMin()` for native ETH THEN the system SHALL NOT require callers to manually decrement `nativeTrackedTotal` because the library functions handle it internally, eliminating the fragile caller-responsibility pattern

**Finding 2 — Strict `msg.value` validation for native paths**

2.4 WHEN `assertMsgValue(address(0), amount)` is called with `msg.value = 0` and `amount > 0` THEN the system SHALL revert with `UnexpectedMsgValue`, preventing zero-value calls from passing validation for non-zero native amounts

2.5 WHEN `assertMsgValue(address(0), amount)` is called with `msg.value = amount` (including `msg.value = 0` when `amount = 0`) THEN the system SHALL pass validation, allowing legitimate exact-match calls

2.6 WHEN `pull()` is called for native ETH THEN the system SHALL only credit the caller for ETH actually sent via `msg.value`, never claiming untracked contract balance as a user deposit

### Unchanged Behavior (Regression Prevention)

**LibCurrency ERC-20 paths**

3.1 WHEN `transfer()` is called with an ERC-20 token (non-native) THEN the system SHALL CONTINUE TO execute `safeTransfer` without touching `nativeTrackedTotal`

3.2 WHEN `transferWithMin()` is called with an ERC-20 token (non-native) THEN the system SHALL CONTINUE TO execute `safeTransfer` with minimum-received validation without touching `nativeTrackedTotal`

3.3 WHEN `pull()` is called with an ERC-20 token THEN the system SHALL CONTINUE TO execute `safeTransferFrom` with balance-delta accounting without touching `nativeTrackedTotal`

3.4 WHEN `pullAtLeast()` is called with an ERC-20 token THEN the system SHALL CONTINUE TO execute `safeTransferFrom` with minimum-received validation without touching `nativeTrackedTotal`

**LibCurrency native receive paths**

3.5 WHEN `pull()` is called for native ETH with `msg.value > 0` and `msg.value == amount` THEN the system SHALL CONTINUE TO increment `nativeTrackedTotal` by `amount` and return `amount`

3.6 WHEN `pullAtLeast()` is called for native ETH with `msg.value == maxAmount` THEN the system SHALL CONTINUE TO increment `nativeTrackedTotal` by `maxAmount` and return `maxAmount`

**LibCurrency validation paths**

3.7 WHEN `assertMsgValue()` is called with an ERC-20 token and `msg.value = 0` THEN the system SHALL CONTINUE TO pass validation (ERC-20 calls should not send ETH)

3.8 WHEN `assertMsgValue()` is called with an ERC-20 token and `msg.value > 0` THEN the system SHALL CONTINUE TO revert with `UnexpectedMsgValue`

3.9 WHEN `assertZeroMsgValue()` is called with `msg.value > 0` THEN the system SHALL CONTINUE TO revert with `UnexpectedMsgValue`

**LibCurrency utility functions**

3.10 WHEN `balanceOfSelf()` is called for native ETH THEN the system SHALL CONTINUE TO return `address(this).balance`

3.11 WHEN `nativeAvailable()` is called THEN the system SHALL CONTINUE TO return `address(this).balance - nativeTrackedTotal` (clamped to 0), but the value will now be correct because `nativeTrackedTotal` is properly maintained

3.12 WHEN `decimals()` or `decimalsOrRevert()` is called THEN the system SHALL CONTINUE TO return 18 for native and query the token for ERC-20

**Downstream caller regression — manual decrements become redundant**

3.13 WHEN downstream callers (EqualLend, EqualIndex, EqualScale, EqualX, Options, LibFeeRouter, LibMaintenance, LibEqualLendDirectAccounting) currently manually decrement `nativeTrackedTotal` before calling `transfer()` or `transferWithMin()` THEN those manual decrements will cause double-decrement unless pruned — downstream call sites that manually decrement MUST be audited and pruned as part of this fix to prevent underflow

**Zero-amount edge cases**

3.14 WHEN `transfer()` is called with `amount = 0` for native ETH THEN the system SHALL CONTINUE TO return early without modifying `nativeTrackedTotal` or executing any ETH send

3.15 WHEN `pull()` is called with `amount = 0` for native ETH THEN the system SHALL CONTINUE TO return 0 without modifying `nativeTrackedTotal`
