// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {DeployEqualFi} from "script/DeployEqualFi.s.sol";
import {OwnershipFacet} from "src/core/OwnershipFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {FlashLoanFacet} from "src/equallend/FlashLoanFacet.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";
import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
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
        assertTrue(loupe.facetAddress(FlashLoanFacet.flashLoan.selector) != address(0));
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
        assertTrue(loupe.facetAddress(OptionTokenAdminFacet.deployOptionToken.selector) != address(0));
        assertTrue(loupe.facetAddress(OptionTokenViewFacet.getOptionToken.selector) != address(0));
        assertTrue(loupe.facetAddress(OptionsFacet.createOptionSeries.selector) != address(0));
        assertTrue(loupe.facetAddress(OptionsViewFacet.getOptionSeriesProductiveCollateral.selector) != address(0));
        assertTrue(loupe.facetAddress(EdenRewardsFacet.createRewardProgram.selector) != address(0));

        assertEq(OptionTokenViewFacet(deployment.diamond).getOptionToken(), deployment.optionToken);
        assertTrue(deployment.optionToken != address(0));
        assertEq(OptionToken(deployment.optionToken).owner(), deployment.timelockController);
        assertEq(OptionToken(deployment.optionToken).manager(), deployment.diamond);

        assertEq(loupe.facetAddress(LEGACY_CREATE_BASKET_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_PRODUCT_MINT_SELECTOR), address(0));
        assertEq(loupe.facetAddress(LEGACY_PRODUCT_CREATE_SELECTOR), address(0));
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

        (LibEdenRewardsStorage.RewardProgramConfig memory config,) = EdenRewardsFacet(deployment.diamond).getRewardProgram(0);
        assertEq(uint8(config.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION));
        assertEq(config.target.targetId, 7);
        assertEq(config.rewardToken, address(rewardToken));
    }

    function _timelockCall(FixedDelayTimelockController controller, address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encodePacked("deploy-equalfi-test", data));
        controller.schedule(target, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        controller.execute(target, 0, data, bytes32(0), salt);
    }
}
