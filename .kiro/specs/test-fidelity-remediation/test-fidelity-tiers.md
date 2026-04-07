# Test Fidelity Tiers

This document classifies the current EqualFi Solidity test suites by confidence tier and records which suites are intentionally synthetic.

## Tier Definitions

### 1.1 Storage / library smoke

Small-surface tests that prove storage slots, math, events, errors, or isolated accounting helpers behave as expected. These suites may seed state directly and are not protocol end-to-end proofs.

### 1.2 Isolated harness unit tests

Harness-driven module tests that often install a subset of facets or write state directly to reach specific transitions. These suites are valuable for narrow branch coverage, but they are not sufficient proof of live user funding, eligibility, or collateral flows when those can be reached through real actions.

### 1.3 Real-flow module integration

Tests that exercise a real module lifecycle with user-like actions, deployed contracts, approvals, and transfers, but do not necessarily cover the full launch diamond wiring.

### 1.4 Live-diamond launch integration

Tests that use the launch deployment path or `LaunchFixture` and exercise behavior against the installed EqualFi diamond with live selectors, governance ownership, and real protocol surfaces.

### 1.5 Stateful invariant / fuzz coverage

Fuzz or invariant suites that check broader state-machine properties across many actions. These suites add breadth, but they do not replace the need for at least one real-flow or launch-level regression for each value-moving lifecycle.

## Current Suite Classification

### 1.1 Storage / Library Smoke

- `test/EdenRewardsStorage.t.sol`
- `test/EqualScaleAlphaInterfaces.t.sol`
- `test/EqualXStorage.t.sol`
- `test/LibEqualScaleAlphaStorage.t.sol`
- `test/LibEqualXMath.t.sol`
- `test/SubstratePort.t.sol`
- `test/PositionSubstrate.t.sol`
- `test/agent-wallet-core/AgentWalletCoreDependency.t.sol`
- `test/agent-wallet-core/LibPositionAgentStorage.t.sol`

### 1.2 Isolated Harness Unit Tests

- `test/EdenRewardsFacet.t.sol`
- `test/EqualIndexLendingFacet.t.sol`
- `test/EqualIndexPort.t.sol`
- `test/EqualScaleAlphaFacet.t.sol`
- `test/EqualXSoloAmmFacet.t.sol`
- `test/EqualXCommunityAmmFacet.t.sol`
- `test/EqualXCurveFacet.t.sol`
- `test/ManagedFeeRouting.t.sol`
- `test/OptionToken.t.sol`
- `test/OptionTokenModule.t.sol`
- `test/OptionsFacet.t.sol`
- `test/agent-wallet-core/PositionAgentFacet.t.sol`

### 1.3 Real-Flow Module Integration

- `test/EqualScaleAlpha.t.sol`
- `test/FixedDelayTimelockController.t.sol`
- `test/agent-wallet-core/PositionMSCAImpl.t.sol`

### 1.4 Live-Diamond Launch Integration

- `test/DeployEqualFi.t.sol`
- `test/DiamondCoreNegative.t.sol`
- `test/EqualIndexLaunch.t.sol`
- `test/FlashLoanFacet.t.sol`
- `test/ManagedPoolFacet.t.sol`
- `test/PoolAumFacet.t.sol`
- `test/PositionManagementFacet.t.sol`

### 1.5 Stateful Invariant / Fuzz Coverage

- `test/EqualIndexFuzz.t.sol`
- `test/EqualScaleAlphaFuzz.t.sol`
- `test/EqualXInvariant.t.sol`
- `test/OptionTokenInvariant.t.sol`
- `test/OptionsInvariant.t.sol`
- `test/PositionManagementFuzz.t.sol`

## Intentionally Synthetic Suites

The suites below intentionally use synthetic setup or direct state injection and must not be treated as end-to-end shipping confidence on their own.

### Permanent synthetic by design

- `test/SubstratePort.t.sol`
  Synthetic accounting smoke for substrate helpers.
- `test/PositionSubstrate.t.sol`
  Synthetic substrate smoke for balance and active-credit primitives.
- `test/EdenRewardsStorage.t.sol`
  Storage-focused rewards accounting checks.
- `test/EqualXStorage.t.sol`
  Storage layout and slot behavior checks.
- `test/LibEqualScaleAlphaStorage.t.sol`
  Storage and status-transition helper checks.
- `test/LibEqualXMath.t.sol`
  Math-only coverage.
- `test/EqualScaleAlphaInterfaces.t.sol`
  Event and custom-error surface smoke.
- `test/agent-wallet-core/AgentWalletCoreDependency.t.sol`
  Dependency and interface availability smoke.
- `test/agent-wallet-core/LibPositionAgentStorage.t.sol`
  Storage-layer smoke.
- `test/OptionToken.t.sol`
  Primitive ERC-1155 token behavior coverage.
- `test/OptionTokenModule.t.sol`
  Module wiring coverage for the canonical option token contract.
- `test/ManagedFeeRouting.t.sol`
  Synthetic subsystem coverage through the test-support facet until a first-class product flow routes through managed fee routing.

### Currently synthetic and targeted for remediation

- `test/OptionsFacet.t.sol`
- `test/OptionsInvariant.t.sol`
- `test/EqualIndexLendingFacet.t.sol`
- `test/EqualXSoloAmmFacet.t.sol`
- `test/EqualXCommunityAmmFacet.t.sol`
- `test/EqualXCurveFacet.t.sol`
- `test/EqualXInvariant.t.sol`
- `test/EdenRewardsFacet.t.sol`
- `test/EqualScaleAlphaFacet.t.sol`
- `test/EqualIndexPort.t.sol`
- `test/agent-wallet-core/PositionAgentFacet.t.sol`

These suites remain useful during remediation, but they should be treated as supplemental harness coverage rather than primary confidence for live funding, collateral, or eligibility flows.

## Core Confidence Rule

Every core value-moving lifecycle must have at least one `1.3 Real-flow module integration` or `1.4 Live-diamond launch integration` test path.

This rule applies in particular to:

- pool funding through real approvals and deposits
- borrow and repay lifecycles
- option series creation, exercise, reclaim, and claim burning
- EDEN reward eligibility changes and reward claiming
- EqualX creation, participation, cancellation, settlement, and collateral encumbrance changes
- EqualScale Alpha lender funding, borrower draw, repayment, delinquency, and loss handling
- any governance-controlled action that changes custody, entitlement, encumbrance, or user claim state

Synthetic harness coverage can remain as a companion layer for corner cases, arithmetic, or isolated state transitions, but it does not satisfy this rule by itself.

## Synthetic Suites Allowed To Remain Synthetic After Remediation

The following existing suites are allowed to remain synthetic after the remediation program is complete, because their purpose is narrow and they are not intended to be end-to-end product proofs:

- `test/SubstratePort.t.sol`
- `test/PositionSubstrate.t.sol`
- `test/EdenRewardsStorage.t.sol`
- `test/EqualScaleAlphaInterfaces.t.sol`
- `test/EqualXStorage.t.sol`
- `test/LibEqualScaleAlphaStorage.t.sol`
- `test/LibEqualXMath.t.sol`
- `test/agent-wallet-core/AgentWalletCoreDependency.t.sol`
- `test/agent-wallet-core/LibPositionAgentStorage.t.sol`
- `test/OptionToken.t.sol`
- `test/OptionTokenModule.t.sol`
- `test/ManagedFeeRouting.t.sol`

These suites should stay clearly labeled as smoke, primitive, storage, interface, or subsystem-only coverage, and each value-moving behavior they touch must also be represented elsewhere by at least one real-flow or live-diamond regression.

See also:

- `testing-guardrails.md` for the expected balance between harness, live, and invariant layers
- `module-live-coverage-audit.md` for the current value-moving module coverage matrix

## Substrate Smoke Coverage Map

`test/SubstratePort.t.sol` and `test/PositionSubstrate.t.sol` remain intentionally synthetic. They are allowed to stay as substrate smoke coverage because each value-moving behavior they touch now has a corresponding live-flow or launch-level regression elsewhere:

- Position NFT ownership transfer and position-carried rights:
  [EqualScaleAlpha.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/EqualScaleAlpha.t.sol#L390) proves borrower control and lender commitment rights move with live PNFT transfers.
- Canonical pool initialization and duplicate-canonical rejection:
  [EqualIndexLaunch.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/EqualIndexLaunch.t.sol#L452) covers the canonical-pool duplicate guard on the launched diamond.
- Real position deposit, withdraw, membership cleanup, and joined-pool behavior:
  [PositionManagementFacet.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/PositionManagementFacet.t.sol#L44) and [PositionManagementFacet.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/PositionManagementFacet.t.sol#L95) cover the live deposit, withdrawal, cleanup, and cross-pool PNFT flows.
- Position yield preview and successful claim on real protocol-generated yield:
  [PositionManagementFacet.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/PositionManagementFacet.t.sol#L71) proves yield is preserved across an additional live deposit and can still be claimed on the launched diamond.
- Fee-index-backed yield generation from real user actions:
  [EqualIndexLaunch.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/EqualIndexLaunch.t.sol#L57) proves real EqualIndex mint/burn activity creates claimable position yield.
- Index encumbrance under live collateral flows:
  [EqualIndexLaunch.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/EqualIndexLaunch.t.sol#L140) covers live EqualIndex collateral locking and release through borrow and repay.
- Live encumbrance under protocol flows:
  [EqualScaleAlpha.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/EqualScaleAlpha.t.sol#L191), [EqualScaleAlpha.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/EqualScaleAlpha.t.sol#L232), and [OptionsLaunch.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/OptionsLaunch.t.sol#L89) cover live encumbrance and release across EqualScale Alpha and options, with Alpha specifically exercising native `encumberedCapital` and `lockedCapital` flows.
- Active-credit-bearing collateral and productive-collateral accounting:
  [EqualScaleAlpha.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/EqualScaleAlpha.t.sol#L191) and [OptionsLaunch.t.sol](/home/hooftly/.openclaw/workspace/Projects/EdenFi/test/OptionsLaunch.t.sol#L134) cover live active-credit-backed collateral flows without synthetic state seeding.

The remaining smoke-only assertions in those two substrate suites are deliberately library-shaped: bucket splits, direct accounting checkpoints, and synthetic fallback branches that are more efficient to keep as narrow smoke coverage than to recreate through user-facing integration flows.
