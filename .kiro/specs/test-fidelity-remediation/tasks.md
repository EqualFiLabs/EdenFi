# Tasks

## Task 1: Establish Test Fidelity Tiers Before Refactors

- [x] 1. Classify every relevant suite as one of:
  - [x] 1.1 Storage / library smoke
  - [x] 1.2 Isolated harness unit tests
  - [x] 1.3 Real-flow module integration
  - [x] 1.4 Live-diamond launch integration
  - [x] 1.5 Stateful invariant / fuzz coverage
- [x] 2. Document which suites are intentionally synthetic and must not be treated as end-to-end confidence
- [x] 3. Document the rule that core value-moving flows must have at least one real-flow or live-diamond test path
- [x] 4. Confirm which existing synthetic suites are allowed to remain synthetic after remediation

## Task 2: Add Live-Diamond Coverage for the Options Module

- [x] 1. Add a live-diamond options integration suite on top of `test/utils/LaunchFixture.t.sol`
- [x] 2. Prove deployed launch state can:
  - [x] 2.1 Discover the canonical option token
  - [x] 2.2 Create option series
  - [x] 2.3 Exercise calls
  - [x] 2.4 Exercise puts
  - [x] 2.5 Reclaim expired series
  - [x] 2.6 Read productive-collateral views
- [x] 3. Ensure the live-diamond options suite uses real pool creation, real positions, and real deposits rather than direct principal seeding

## Task 3: Replace Synthetic Options Funding and Expand Lifecycle Coverage

- [x] 1. Refactor `test/OptionsFacet.t.sol` to stop using direct `setPool`, `joinPool`, and `seedPrincipal` setup where real flows are practical
- [x] 2. Replace options setup with:
  - [x] 2.1 Real pool initialization
  - [x] 2.2 Real `mintPosition`
  - [x] 2.3 Real `depositToPosition`
  - [x] 2.4 Real pool membership creation through those flows
- [x] 3. Add options edge-case coverage for creation failures:
  - [x] 3.1 Paused options
  - [x] 3.2 Zero `totalSize`
  - [x] 3.3 Zero `contractSize`
  - [x] 3.4 Zero `strikePrice`
  - [x] 3.5 Expiry in the past
  - [x] 3.6 Same underlying and strike pool
  - [x] 3.7 Same underlying and strike asset
  - [x] 3.8 Missing pool membership
- [x] 4. Add options edge-case coverage for exercise failures:
  - [x] 4.1 Zero amount
  - [x] 4.2 Zero recipient
  - [x] 4.3 Zero holder in `exerciseOptionsFor`
  - [x] 4.4 Insufficient token balance
  - [x] 4.5 Missing operator approval for `exerciseOptionsFor`
  - [x] 4.6 Exercise after reclaim
  - [x] 4.7 Exercise past American expiry
  - [x] 4.8 Exercise before and after European tolerance window
  - [x] 4.9 `maxPayment` slippage failure
  - [x] 4.10 `minReceived` slippage failure
- [x] 5. Add options coverage for:
  - [x] 5.1 `setOptionsPaused`
  - [x] 5.2 `setEuropeanTolerance`
  - [x] 5.3 `exerciseOptionsFor`
  - [x] 5.4 `burnReclaimedOptionsClaims`
  - [x] 5.5 Non-`1` `contractSize`
  - [x] 5.6 Mixed-decimal strike normalization
  - [x] 5.7 Fractional-style option amounts using `1e18` unit conventions

## Task 4: Strengthen the Options Invariant Suite

- [x] 1. Remove direct principal seeding from `test/OptionsInvariant.t.sol` where real deposits are practical
- [x] 2. Add invariant handler actions that:
  - [x] 2.1 Transfer claims from maker to holders
  - [x] 2.2 Exercise through approved operators
  - [x] 2.3 Mix call and put series in the same run
- [x] 3. Add invariants covering:
  - [x] 3.1 Holder balances plus burned balances reconcile to issued claims
  - [x] 3.2 `remainingSize` and `collateralLocked` stay consistent for non-unit contract sizes
  - [x] 3.3 Reclaimed series cannot regain locked collateral
  - [x] 3.4 Productive-collateral views stay aligned after holder transfers and operator exercises

## Task 5: Convert EqualIndex Lending Tests to Real Funding Flows

- [x] 1. Refactor `test/EqualIndexLendingFacet.t.sol` away from direct `seedPool`, `setPoolPrincipal`, and manual `joinPool`
- [x] 2. Replace harness-only borrow context setup with:
  - [x] 2.1 Real pool initialization
  - [x] 2.2 Real borrower positions
  - [x] 2.3 Real deposits into each backing pool
  - [x] 2.4 Real index minting from positions before borrow
- [x] 3. Keep harness helper reads only where they do not bypass funding or eligibility logic
- [x] 4. Decide whether the entire suite should migrate to `LaunchFixture` or whether a smaller harness can still use real deposit flows safely

## Task 6: Expand EqualIndex Lending Edge-Case Coverage

- [x] 1. Add tests for `extendFromPosition`
- [x] 2. Add tests for duration bound failures:
  - [x] 2.1 Below minimum duration
  - [x] 2.2 Above maximum duration
- [x] 3. Add tests for borrow failures:
  - [x] 3.1 Borrow without minted index collateral units
  - [x] 3.2 Borrow above max LTV
  - [x] 3.3 Borrow when underlying vault liquidity is insufficient
  - [x] 3.4 Borrow with wrong or missing flat fee payment
- [x] 4. Add tests for repay behavior:
  - [x] 4.1 Partial repay if supported
  - `repayFromPosition` is exact-only today; there is no partial-repay entrypoint to test
  - [x] 4.2 Exact repay
  - [x] 4.3 Over-repay rejection or rounding behavior
- [x] 5. Add tests proving quote helpers match execution on live flows:
  - [x] 5.1 `maxBorrowable`
  - [x] 5.2 `quoteBorrowFee`
  - [x] 5.3 `quoteBorrowBasket`
- [x] 6. Add live tests for expired-loan recovery after real user-funded positions

## Task 7: Replace Synthetic Cross-Pool Principal in EqualX Unit Suites

- [x] 1. Refactor `test/EqualXSoloAmmFacet.t.sol` to remove `seedCrossPoolPrincipal`
- [x] 2. Refactor `test/EqualXCommunityAmmFacet.t.sol` to remove `seedCrossPoolPrincipal`
- [x] 3. Refactor `test/EqualXCurveFacet.t.sol` to remove `seedCrossPoolPrincipal`
- [x] 4. Replace those helpers with:
  - [x] 4.1 Real positions in every backing pool used by a maker
  - [x] 4.2 Real deposits into those pools
  - [x] 4.3 Real membership established through deposit flows
- [x] 5. Keep read-only helper methods that expose encumbrance or balances without mutating storage

## Task 8: Expand EqualX Edge-Case and Accounting Coverage

- [x] 1. Add EqualX tests for setup failures under real funding conditions:
  - [x] 1.1 Insufficient backing after maintenance
  - [x] 1.2 Backing blocked by pool caps
  - [x] 1.3 Backing blocked by max user count
  - [x] 1.4 Managed-pool / whitelist restrictions where relevant
- [x] 2. Add EqualX coverage for accounting boundaries:
  - [x] 2.1 Exact-boundary reserve usage
  - [x] 2.2 Full closeout after multiple swaps
  - [x] 2.3 Cancel / finalize after partial utilization
  - [x] 2.4 Yield and active-credit effects after real settlement
- [x] 3. Re-check native-asset curve flows under the same real-funding standards

## Task 9: Upgrade EqualX Invariant Seeding to Real Flows

- [x] 1. Refactor `test/EqualXInvariant.t.sol` so initial maker funding comes from real deposits instead of direct cross-pool principal writes
- [x] 2. Preserve the current invariant assertions while removing fake funding shortcuts
- [x] 3. Add invariant actions for:
  - [x] 3.1 Repeated real deposit setup where needed
  - [x] 3.2 Finalize / cancel / expiry churn under real backing
  - [x] 3.3 Community join / leave under real-funded makers

## Task 10: Convert EDEN Rewards Unit Tests to Real EqualIndex Flows

- [x] 1. Refactor `test/EdenRewardsFacet.t.sol` away from direct `setEqualIndexPool`, `setPoolDeposits`, and `setPoolPrincipal` setup for primary lifecycle tests
- [x] 2. Replace synthetic reward eligibility setup with:
  - [x] 2.1 Real index creation
  - [x] 2.2 Real position-held EqualIndex units
  - [x] 2.3 Real hook-driven eligibility changes
- [x] 3. Retain isolated synthetic tests only for narrow storage or arithmetic behaviors that cannot be reached economically through integration paths

## Task 11: Expand EDEN Rewards Lifecycle and Liability Coverage

- [x] 1. Add live tests for multiple eligible positions entering and leaving a program
- [x] 2. Add tests for paused and disabled programs with accrued but unclaimed rewards
- [x] 3. Add tests for program closure with outstanding claims still redeemable
- [x] 4. Add tests for fee-on-transfer reward tokens through the full live EqualIndex hook path
- [x] 5. Add tests for manager and governance lifecycle controls on live target state rather than synthetic supply only

## Task 12: Reduce Synthetic Pool and Credit-Line Mutation in EqualScale Alpha Tests

- [x] 1. Audit `test/EqualScaleAlphaFacet.t.sol` for direct pool and line mutations that can be replaced with real flows
- [x] 2. Replace `_seedSettlementPosition`-style funding with real deposits where practical
- [x] 3. Keep only the minimum direct state injection necessary for unreachable corner cases or pure state-machine transitions
- [x] 4. Cross-check every synthetic EqualScale Alpha case against whether the live integration suite in `test/EqualScaleAlpha.t.sol` should own that scenario instead

## Task 13: Expand Live EqualScale Alpha Integration Coverage

- [x] 1. Add live integration tests for:
  - [x] 1.1 Multi-lender pooled lines
  - [x] 1.2 Collateralized lines
  - [x] 1.3 Delinquency transitions
  - [x] 1.4 Charge-off flows
  - [x] 1.5 Refinance flows
- [x] 2. Ensure those tests use real funded positions and live module surfaces rather than synthetic pool writes

## Task 14: Preserve Synthetic Smoke Suites but De-Scope Their Authority

- [x] 1. Keep `test/SubstratePort.t.sol` as a synthetic library / accounting smoke suite
- [x] 2. Keep `test/PositionSubstrate.t.sol` as a synthetic substrate smoke suite
- [x] 3. Ensure every behavior covered only by those synthetic suites also has at least one real-flow regression elsewhere
- [x] 4. Add comments or test-doc notes clarifying that these suites are not end-to-end protocol proofs

## Task 15: Add Missing Live-Flow Regression Hooks Across the Protocol

- [x] 1. Review each value-moving module and confirm at least one suite exercises:
  - [x] 1.1 Real user approvals
  - [x] 1.2 Real deposits
  - [x] 1.3 Real withdrawals or claims
  - [x] 1.4 Real governance or timelock controls where applicable
- [x] 2. Add launch-level regressions where selectors are installed but not behavior-tested
- [x] 3. Re-check options, EqualIndex lending, EDEN rewards, and EqualScale Alpha first because they currently have the largest live-vs-synthetic gaps

## Task 16: Finalize Documentation and Guardrails for Future Test Work

- [x] 1. Add a short repo note describing the expected balance between:
  - [x] 1.1 Unit harness tests
  - [x] 1.2 Live integration tests
  - [x] 1.3 Invariant / fuzz suites
- [x] 2. Document that funding and eligibility state should not be seeded directly when a real flow exists
- [x] 3. Add a final review pass to confirm no new tests regress into fake-flow setup without strong justification
