# Live Coverage Audit

This note records which value-moving EqualFi modules have at least one real-flow or launch-level regression that exercises real approvals, real deposits, real withdrawals or claims where applicable, and real governance or timelock controls where applicable.

## Coverage Matrix

| Module | Real approvals | Real deposits | Real withdrawals / claims | Real governance / timelock | Primary suites |
| --- | --- | --- | --- | --- | --- |
| Pool + Position substrate | Yes | Yes | Yes | Yes, where applicable through launch-owned pool config and AUM controls | `test/PositionManagementFacet.t.sol`, `test/PoolAumFacet.t.sol`, `test/ManagedPoolFacet.t.sol` |
| Flash loans | Yes, receiver repays through approval / transfer paths | Yes, pool liquidity is funded by real deposits | Not a user claim module; exit path is full in-tx repayment | Not applicable | `test/FlashLoanFacet.t.sol` |
| EqualIndex actions + position mint/burn | Yes | Yes | Yes, through burn and downstream yield / reward claims | Yes, index creation runs through timelock | `test/EqualIndexLaunch.t.sol` |
| EqualIndex lending | Yes | Yes | Yes, through repay and expired-loan recovery | Yes, lending config runs through timelock | `test/EqualIndexLaunch.t.sol`, `test/EqualIndexLendingFacet.t.sol` |
| EDEN rewards | Yes, reward funding approvals and live claims | Yes, eligibility comes from real deposited positions | Yes, `claimRewardProgram` on live target state | Yes, create / enable / end / close are timelock or governance driven | `test/EdenRewardsFacet.t.sol`, `test/EqualIndexLaunch.t.sol` |
| Options + option token | Yes, exercise funding approvals | Yes, maker collateral is real deposited principal | Yes, through exercise delivery and expired-series reclaim | Yes, pause / tolerance config are timelock-controlled | `test/OptionsLaunch.t.sol`, `test/OptionsFacet.t.sol` |
| EqualScale Alpha | Yes | Yes | Yes, lender capital exits through live withdraw after close and borrower flows repay live debt | Yes, freeze / unfreeze / charge-off threshold are now launch-timelock tested | `test/EqualScaleAlpha.t.sol`, `test/EqualScaleAlphaLaunch.t.sol` |

## Re-check Priority Modules

The highest-risk live-vs-synthetic modules were re-checked first:

- Options:
  `test/OptionsLaunch.t.sol` proves canonical token discovery, live series creation, exercise, reclaim, and productive-collateral views on the launched diamond.
- EqualIndex lending:
  `test/EqualIndexLaunch.t.sol` and `test/EqualIndexLendingFacet.t.sol` prove live configure, borrow, repay, quote parity, and expired-loan recovery from real position-backed collateral.
- EDEN rewards:
  `test/EdenRewardsFacet.t.sol` and `test/EqualIndexLaunch.t.sol` prove reward lifecycle, live eligibility changes, claims, fee-on-transfer handling, and governance controls.
- EqualScale Alpha:
  `test/EqualScaleAlpha.t.sol` proves real borrower/lender funding flows, and `test/EqualScaleAlphaLaunch.t.sol` now proves launch-installed admin controls on the deployed timelock-owned diamond.

## Launch-Installed Selector Gap Review

The launch deployment installs the following value-moving families:

- `PoolManagementFacet`
- `PositionManagementFacet`
- `FlashLoanFacet`
- `EqualIndexAdminFacetV3`
- `EqualIndexActionsFacetV3`
- `EqualIndexPositionFacet`
- `EqualIndexLendingFacet`
- `EqualScaleAlphaFacet`
- `EqualScaleAlphaAdminFacet`
- `OptionTokenAdminFacet`
- `OptionTokenViewFacet`
- `OptionsFacet`
- `OptionsViewFacet`
- `EdenRewardsFacet`

After this pass, no remaining launch-installed value-moving selector family is known to be present without at least one behavior test on a real-flow or launch-level path.

The only gap identified during this audit was launch-level behavior coverage for `EqualScaleAlphaAdminFacet` on the deployed diamond. That gap is now covered by:

- `test/EqualScaleAlphaLaunch.t.sol::test_LiveLaunch_EqualScaleAlpha_SoloLifecycleSupportsTimelockFreezeAndUserExit`
- `test/EqualScaleAlphaLaunch.t.sol::test_LiveLaunch_EqualScaleAlpha_TimelockChargeOffThresholdControlsResolution`
