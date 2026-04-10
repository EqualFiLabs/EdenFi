// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {DeployEqualFi} from "script/DeployEqualFi.s.sol";
import {OwnershipFacet} from "src/core/OwnershipFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {FlashLoanFacet} from "src/equallend/FlashLoanFacet.sol";
import {SelfSecuredCreditFacet} from "src/equallend/SelfSecuredCreditFacet.sol";
import {SelfSecuredCreditViewFacet} from "src/equallend/SelfSecuredCreditViewFacet.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {EqualXSoloAmmFacet} from "src/equalx/EqualXSoloAmmFacet.sol";
import {EqualXCommunityAmmLiquidityFacet} from "src/equalx/EqualXCommunityAmmLiquidityFacet.sol";
import {EqualXCommunityAmmSwapFacet} from "src/equalx/EqualXCommunityAmmSwapFacet.sol";
import {EqualXCurveCreationFacet} from "src/equalx/EqualXCurveCreationFacet.sol";
import {EqualXCurveExecutionFacet} from "src/equalx/EqualXCurveExecutionFacet.sol";
import {EqualXCurveManagementFacet} from "src/equalx/EqualXCurveManagementFacet.sol";
import {EqualXViewFacet} from "src/equalx/EqualXViewFacet.sol";
import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {Types} from "src/libraries/Types.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";
import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {
    MockEntryPointLaunch,
    MockERC6551RegistryLaunch,
    MockIdentityRegistryLaunch
} from "test/utils/PositionAgentBootstrapMocks.sol";

contract MockERC20Deploy is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployEqualFiTest is Test, DeployEqualFi {
    bytes4 internal constant LEGACY_CREATE_BASKET_SELECTOR = 0x58e4bfcc;
    bytes4 internal constant LEGACY_PRODUCT_MINT_SELECTOR = 0x7fdd64b4;
    bytes4 internal constant LEGACY_PRODUCT_CREATE_SELECTOR = 0x7f45d621;
    bytes4 internal constant LEGACY_EQUAL_INDEX_LENDING_MODULE_SELECTOR = bytes4(keccak256("lendingModuleId()"));
    bytes4 internal constant LEGACY_ALPHA_SETTLEMENT_MODULE_SELECTOR =
        bytes4(keccak256("settlementCommitmentModuleId(uint256)"));
    bytes4 internal constant LEGACY_ALPHA_COLLATERAL_MODULE_SELECTOR =
        bytes4(keccak256("borrowerCollateralModuleId(uint256)"));
    bytes4 internal constant LEGACY_SSC_OPEN_ROLLING_SELECTOR =
        bytes4(keccak256("openRollingFromPosition(uint256,uint256,uint256,uint256)"));
    bytes4 internal constant LEGACY_SSC_PAYMENT_SELECTOR =
        bytes4(keccak256("makePaymentFromPosition(uint256,uint256,uint256,uint256)"));
    bytes4 internal constant LEGACY_SSC_EXPAND_ROLLING_SELECTOR =
        bytes4(keccak256("expandRollingFromPosition(uint256,uint256,uint256,uint256)"));
    bytes4 internal constant LEGACY_SSC_CLOSE_ROLLING_SELECTOR =
        bytes4(keccak256("closeRollingCreditFromPosition(uint256,uint256,uint256)"));
    bytes4 internal constant LEGACY_SSC_OPEN_FIXED_SELECTOR =
        bytes4(keccak256("openFixedFromPosition(uint256,uint256,uint256,uint256,uint256)"));
    bytes4 internal constant LEGACY_SSC_REPAY_FIXED_SELECTOR =
        bytes4(keccak256("repayFixedFromPosition(uint256,uint256,uint256,uint256,uint256)"));

    address internal treasury = makeAddr("treasury");

    MockERC20Deploy internal rewardToken;
    MockEntryPointLaunch internal entryPoint;
    MockERC6551RegistryLaunch internal erc6551Registry;
    MockIdentityRegistryLaunch internal identityRegistry;

    function setUp() public {
        rewardToken = new MockERC20Deploy("Reward", "RWD");
        entryPoint = new MockEntryPointLaunch();
        erc6551Registry = new MockERC6551RegistryLaunch();
        identityRegistry = new MockIdentityRegistryLaunch();
    }

    function test_DeployBase_WiresDiamondCoreAndPositionNft() public {
        BaseDeployment memory deployment = deployBase(address(this), treasury);

        assertEq(OwnershipFacet(deployment.diamond).owner(), address(this));

        PositionNFT nft = PositionNFT(deployment.positionNFT);
        assertEq(nft.minter(), deployment.diamond);
        assertEq(nft.diamond(), deployment.diamond);
    }

    function test_DeployLaunch_InstallsExpectedFacetSurfaceWithoutLegacyProductBundle() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);
        assertEq(loupe.facetAddresses().length, TOTAL_FACET_COUNT);
        assertEq(OwnershipFacet(deployment.diamond).owner(), deployment.timelockController);

        assertTrue(loupe.facetAddress(PositionManagementFacet.mintPosition.selector) != address(0));
        assertTrue(loupe.facetAddress(PositionManagementFacet.joinPositionPool.selector) != address(0));
        assertTrue(loupe.facetAddress(FlashLoanFacet.flashLoan.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.drawSelfSecuredCredit.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.getSscLine.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualIndexAdminFacetV3.createIndex.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualIndexActionsFacetV3.mint.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualIndexPositionFacet.mintFromPosition.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualIndexLendingFacet.borrowFromPosition.selector) != address(0));
        assertTrue(loupe.facetAddress(PositionAgentConfigFacet.setERC6551Registry.selector) != address(0));
        assertTrue(loupe.facetAddress(PositionAgentTBAFacet.deployTBA.selector) != address(0));
        assertTrue(loupe.facetAddress(PositionAgentViewFacet.getTBAInterfaceSupport.selector) != address(0));
        assertTrue(loupe.facetAddress(PositionAgentRegistryFacet.recordAgentRegistration.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualScaleAlphaFacet.registerBorrowerProfile.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualScaleAlphaAdminFacet.freezeLine.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualScaleAlphaViewFacet.getBorrowerProfile.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualXSoloAmmFacet.createEqualXSoloAmmMarket.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualXCommunityAmmLiquidityFacet.createEqualXCommunityAmmMarket.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualXCommunityAmmSwapFacet.previewEqualXCommunityAmmSwapExactIn.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualXCurveCreationFacet.createEqualXCurve.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualXCurveExecutionFacet.previewEqualXCurveQuote.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualXCurveManagementFacet.updateEqualXCurve.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualXViewFacet.getEqualXSoloAmmPendingRebalance.selector) != address(0));
        assertTrue(loupe.facetAddress(OptionTokenAdminFacet.deployOptionToken.selector) != address(0));
        assertTrue(loupe.facetAddress(OptionTokenViewFacet.getOptionToken.selector) != address(0));
        assertTrue(loupe.facetAddress(OptionsFacet.createOptionSeries.selector) != address(0));
        assertTrue(loupe.facetAddress(OptionsViewFacet.getOptionSeriesProductiveCollateral.selector) != address(0));
        assertTrue(loupe.facetAddress(EdenRewardsFacet.createRewardProgram.selector) != address(0));

        _assertNativeFacetSurfaceInstalled(loupe);
        _assertEqualXFacetSurfaceInstalled(loupe);
        _assertDirectFacetSurfaceInstalled(loupe);

        assertEq(OptionTokenViewFacet(deployment.diamond).getOptionToken(), deployment.optionToken);
        assertTrue(deployment.optionToken != address(0));
        assertEq(OptionToken(deployment.optionToken).owner(), deployment.timelockController);
        assertEq(OptionToken(deployment.optionToken).manager(), deployment.diamond);

        assertEq(loupe.facetAddress(LEGACY_CREATE_BASKET_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_PRODUCT_MINT_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_PRODUCT_CREATE_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_EQUAL_INDEX_LENDING_MODULE_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_ALPHA_SETTLEMENT_MODULE_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_ALPHA_COLLATERAL_MODULE_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_SSC_OPEN_ROLLING_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_SSC_PAYMENT_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_SSC_EXPAND_ROLLING_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_SSC_CLOSE_ROLLING_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_SSC_OPEN_FIXED_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_SSC_REPAY_FIXED_SELECTOR), address(0));
    }

    function test_DeployLocalLaunch_BootstrapsCorePoolsAndSeedAssetsForLocalTesting() public {
        LocalLaunchDeployment memory deployment = deployLocalLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );

        assertEq(OwnershipFacet(deployment.launch.diamond).owner(), deployment.launch.timelockController);
        assertEq(ERC20(deployment.eveToken).balanceOf(address(this)), LOCAL_TEST_MINT_AMOUNT);
        assertEq(ERC20(deployment.altToken).balanceOf(address(this)), LOCAL_TEST_MINT_AMOUNT);
        assertEq(ERC20(deployment.fotToken).balanceOf(address(this)), LOCAL_TEST_MINT_AMOUNT);

        PoolManagementFacet.PoolInfoView memory eveInfo =
            PoolManagementFacet(deployment.launch.diamond).getPoolInfoView(deployment.evePoolId);
        PoolManagementFacet.PoolInfoView memory altInfo =
            PoolManagementFacet(deployment.launch.diamond).getPoolInfoView(deployment.altPoolId);
        PoolManagementFacet.PoolInfoView memory fotInfo =
            PoolManagementFacet(deployment.launch.diamond).getPoolInfoView(deployment.fotPoolId);
        PoolManagementFacet.PoolInfoView memory nativeInfo =
            PoolManagementFacet(deployment.launch.diamond).getPoolInfoView(deployment.nativePoolId);

        assertTrue(eveInfo.initialized);
        assertTrue(altInfo.initialized);
        assertTrue(fotInfo.initialized);
        assertTrue(nativeInfo.initialized);
        assertEq(eveInfo.underlying, deployment.eveToken);
        assertEq(altInfo.underlying, deployment.altToken);
        assertEq(fotInfo.underlying, deployment.fotToken);
        assertEq(nativeInfo.underlying, address(0));

        PoolManagementFacet.PoolConfigView memory eveConfig =
            PoolManagementFacet(deployment.launch.diamond).getPoolConfigView(deployment.evePoolId);
        assertEq(eveConfig.minDepositAmount, 1e18);
        assertEq(eveConfig.minLoanAmount, 1e18);
        assertEq(eveConfig.fixedTermConfigs.length, 1);
        assertEq(eveConfig.fixedTermConfigs[0].durationSecs, 7 days);
        assertEq(eveConfig.fixedTermConfigs[0].apyBps, 500);
    }

    function test_DeployLaunch_InitializesTimelockGovernanceForEdenRewards() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );

        vm.expectRevert(bytes("LibAccess: not timelock"));
        EdenRewardsFacet(deployment.diamond).createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            7,
            address(rewardToken),
            address(this),
            1e18,
            0,
            10,
            true
        );

        _timelockCall(
            FixedDelayTimelockController(payable(deployment.timelockController)),
            deployment.diamond,
            abi.encodeWithSelector(
                EdenRewardsFacet.createRewardProgram.selector,
                LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
                7,
                address(rewardToken),
                address(this),
                1e18,
                0,
                10,
                true
            )
        );

        uint256[] memory programIds = EdenRewardsFacet(deployment.diamond).getRewardProgramIdsByTarget(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7
        );
        assertEq(programIds.length, 1);

        (LibEdenRewardsStorage.RewardProgramConfig memory config,) =
            EdenRewardsFacet(deployment.diamond).getRewardProgram(programIds[0]);
        assertEq(uint8(config.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION));
        assertEq(config.target.targetId, 7);
        assertEq(config.rewardToken, address(rewardToken));
    }

    function _assertDirectFacetSurfaceInstalled(IDiamondLoupe loupe) internal view {
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectFixedOffer());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectFixedAgreement());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectLifecycle());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectRollingOffer());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectRollingAgreement());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectRollingPayment());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectRollingLifecycle());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectConfig());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualLendDirectView());
    }

    function _assertNativeFacetSurfaceInstalled(IDiamondLoupe loupe) internal view {
        _assertFacetSelectorsInstalled(loupe, _selectorsSelfSecuredCredit());
        _assertFacetSelectorsInstalled(loupe, _selectorsSelfSecuredCreditView());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualIndexLending());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualScaleAlpha());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualScaleAlphaAdmin());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualScaleAlphaView());

        address sscLifecycleFacet = loupe.facetAddress(SelfSecuredCreditFacet.drawSelfSecuredCredit.selector);
        address sscViewFacet = loupe.facetAddress(SelfSecuredCreditViewFacet.getSscLine.selector);
        assertTrue(sscLifecycleFacet != address(0));
        assertTrue(sscViewFacet != address(0));
        assertTrue(sscLifecycleFacet != sscViewFacet);
    }

    function _assertEqualXFacetSurfaceInstalled(IDiamondLoupe loupe) internal view {
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualXSoloAmm());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualXCommunityAmmLiquidity());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualXCommunityAmmSwap());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualXCurveCreation());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualXCurveExecution());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualXCurveManagement());
        _assertFacetSelectorsInstalled(loupe, _selectorsEqualXView());
    }

    function _assertFacetSelectorsInstalled(IDiamondLoupe loupe, bytes4[] memory expectedSelectors) internal view {
        address facet = loupe.facetAddress(expectedSelectors[0]);
        assertTrue(facet != address(0));

        bytes4[] memory installedSelectors = loupe.facetFunctionSelectors(facet);
        assertEq(installedSelectors.length, expectedSelectors.length);

        for (uint256 i; i < expectedSelectors.length; ++i) {
            assertEq(loupe.facetAddress(expectedSelectors[i]), facet);
            assertTrue(_containsSelector(installedSelectors, expectedSelectors[i]));
        }
    }

    function _containsSelector(bytes4[] memory selectors, bytes4 needle) internal pure returns (bool found) {
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == needle) {
                return true;
            }
        }
        return false;
    }

    function _timelockCall(FixedDelayTimelockController controller, address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encodePacked("deploy-equalfi-test", data));
        controller.schedule(target, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        controller.execute(target, 0, data, bytes32(0), salt);
    }
}
