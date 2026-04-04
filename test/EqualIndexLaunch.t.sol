// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {
    CanonicalPoolAlreadyInitialized,
    IndexPaused,
    InvalidArrayLength,
    InvalidBundleDefinition,
    InvalidParameterRange,
    InvalidUnits,
    NoPoolForAsset
} from "src/libraries/Errors.sol";

import {LaunchFixture, MockERC20Launch} from "test/utils/LaunchFixture.t.sol";

contract EqualIndexLaunchTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_WalletMode_MintBurn_RoutesFeesOnLiveDiamond() public {
        eve.mint(alice, 100e18);
        eve.mint(bob, 30e18);

        uint256 depositorPositionId = _mintPosition(alice, 1);
        vm.startPrank(alice);
        eve.approve(diamond, 100e18);
        PositionManagementFacet(diamond).depositToPosition(depositorPositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Wallet Index", "WIDX", address(eve), 1000, 1000));

        vm.startPrank(bob);
        eve.approve(diamond, 30e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        EqualIndexActionsFacetV3(diamond).burn(indexId, 10e18, bob);
        vm.stopPrank();

        assertEq(ERC20(indexToken).balanceOf(bob), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
        assertGt(PositionManagementFacet(diamond).previewPositionYield(depositorPositionId, 1), 0);
        assertGt(eve.balanceOf(treasury), 0);
    }

    function test_PositionMode_MintBurn_PreservesLivePositionAccounting() public {
        eve.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Position Index", "PIDX", address(eve), 1000, 1000));

        vm.prank(alice);
        uint256 minted = EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 50e18);
        assertEq(minted, 50e18);
        assertEq(ERC20(indexToken).balanceOf(diamond), 50e18);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(positionId, indexId, 50e18);

        assertEq(ERC20(indexToken).balanceOf(diamond), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
    }

    function test_EqualIndexWalletAndPositionFlows_RunWithoutSingletonProductBundle() public {
        eve.mint(alice, 200e18);
        eve.mint(bob, 30e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Equal EVE", "QEVE", address(eve), 1000, 1000));

        assertTrue(indexToken != address(0));

        vm.startPrank(bob);
        eve.approve(diamond, 30e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        EqualIndexActionsFacetV3(diamond).burn(indexId, 10e18, bob);
        vm.stopPrank();

        vm.prank(alice);
        uint256 minted = EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 50e18);
        assertEq(minted, 50e18);
        assertEq(ERC20(indexToken).balanceOf(diamond), 50e18);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(positionId, indexId, 50e18);

        assertEq(ERC20(indexToken).balanceOf(bob), 0);
        assertEq(ERC20(indexToken).balanceOf(diamond), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
    }

    function test_EqualIndexLending_BorrowAndRepay_WorksOnLiveDiamond() public {
        eve.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Lending Index", "LIDX", address(eve), 0, 0));
        uint256 indexPoolId = EqualIndexAdminFacetV3(diamond).getIndexPoolId(indexId);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 2e18);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(positionId, indexId, 1e18, 7 days);

        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(indexId, address(eve)), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 1e18);
        assertEq(testSupport.indexEncumberedOf(positionNft.getPositionKey(positionId), indexPoolId), 1e18);
        assertEq(testSupport.indexEncumberedForIndex(positionNft.getPositionKey(positionId), indexPoolId, indexId), 1e18);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, 1e18);

        vm.startPrank(alice);
        eve.approve(diamond, 1e18);
        EqualIndexLendingFacet(diamond).repayFromPosition(positionId, loanId);
        vm.stopPrank();

        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 0);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(indexId, address(eve)), 0);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
        assertEq(testSupport.indexEncumberedOf(positionNft.getPositionKey(positionId), indexPoolId), 0);
        assertEq(testSupport.indexEncumberedForIndex(positionNft.getPositionKey(positionId), indexPoolId, indexId), 0);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, 0);
    }

    function test_EqualIndexRewards_WalletHeldUnitsDoNotEarnButPositionHeldUnitsDo() public {
        eve.mint(alice, 40e18);
        eve.mint(bob, 20e18);

        uint256 bobEmptyPositionId = _mintPosition(bob, 1);
        uint256 alicePositionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 40e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 40e18, 40e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Reward Index", "RIDX", address(eve), 0, 0));

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 10e18, 0, 0, true);
        alt.mint(address(this), 200e18);
        _fundRewardProgram(address(this), programId, alt, 100e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 0);

        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "nothing claimable"));
        EdenRewardsFacet(diamond).claimRewardProgram(programId, bobEmptyPositionId, bob);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        (, state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 10e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);

        assertEq(claimed, 100e18);
        assertEq(alt.balanceOf(alice), 100e18);
        assertEq(ERC20(EqualIndexAdminFacetV3(diamond).getIndex(indexId).token).balanceOf(bob), 10e18);
    }

    function test_EqualIndexRewards_MintFromPositionSettlesBeforeBalanceIncrease() public {
        eve.mint(alice, 20e18);
        eve.mint(bob, 20e18);
        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Mint Reward Index", "MRI", address(eve), 0, 0));

        vm.prank(bob);
        EqualIndexPositionFacet(diamond).mintFromPosition(bobPositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 20e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);

        assertEq(aliceClaimed, 150e18);
        assertEq(bobClaimed, 450e18);
    }

    function test_EqualIndexRewards_BurnFromPositionSettlesBeforeBalanceDecrease() public {
        eve.mint(alice, 20e18);
        eve.mint(bob, 20e18);
        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Burn Reward Index", "BRI", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);
        vm.prank(bob);
        EqualIndexPositionFacet(diamond).mintFromPosition(bobPositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(alicePositionId, indexId, 5e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 15e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);

        assertEq(aliceClaimed, 250e18);
        assertEq(bobClaimed, 350e18);
    }

    function test_EqualIndexRewards_RecoverySettlesBeforePrincipalWriteDown() public {
        eve.mint(alice, 20e18);
        eve.mint(bob, 10e18);
        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, 10e18);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 10e18, 10e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Recover Reward Index", "RRI", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 2e18);
        vm.prank(bob);
        EqualIndexPositionFacet(diamond).mintFromPosition(bobPositionId, indexId, 1e18);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 0, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(alicePositionId, indexId, 1e18, 1 days);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        EqualIndexLendingFacet(diamond).recoverExpiredIndexLoan(loanId);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 2e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);

        assertEq(aliceClaimed, 350e18);
        assertEq(bobClaimed, 250e18);
    }

    function test_EqualIndexRewards_TargetScopedDiscoveryAndPreviewMatchClaims() public {
        eve.mint(alice, 40e18);
        uint256 alicePositionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 40e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 40e18, 40e18);
        vm.stopPrank();

        (uint256 targetIndexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Target Reward Index", "TRI", address(eve), 0, 0));
        (uint256 otherIndexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Other Reward Index", "ORI", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, targetIndexId, 10e18);

        uint256 targetProgramA =
            _createEqualIndexRewardProgram(targetIndexId, address(alt), address(this), 10e18, 0, 0, true);
        uint256 targetProgramB =
            _createEqualIndexRewardProgram(targetIndexId, address(eve), address(this), 20e18, 0, 0, true);
        uint256 otherProgram =
            _createEqualIndexRewardProgram(otherIndexId, address(alt), address(this), 30e18, 0, 0, true);

        alt.mint(address(this), 1_000e18);
        eve.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), targetProgramA, alt, 500e18);
        _fundRewardProgram(address(this), targetProgramB, eve, 500e18);
        _fundRewardProgram(address(this), otherProgram, alt, 500e18);

        vm.warp(block.timestamp + 10);

        uint256[] memory targetProgramIds = EdenRewardsFacet(diamond).getRewardProgramIdsByTarget(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, targetIndexId
        );
        assertEq(targetProgramIds.length, 2);
        assertEq(targetProgramIds[0], targetProgramA);
        assertEq(targetProgramIds[1], targetProgramB);

        uint256[] memory otherProgramIds = EdenRewardsFacet(diamond).getRewardProgramIdsByTarget(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, otherIndexId
        );
        assertEq(otherProgramIds.length, 1);
        assertEq(otherProgramIds[0], otherProgram);

        (EdenRewardsFacet.RewardProgramClaimPreview[] memory previews, uint256 totalClaimable) =
            EdenRewardsFacet(diamond).previewRewardProgramsForPosition(alicePositionId, targetProgramIds);

        assertEq(previews.length, 2);
        assertEq(previews[0].programId, targetProgramA);
        assertEq(previews[0].rewardToken, address(alt));
        assertEq(previews[0].claimableRewards, 100e18);
        assertEq(previews[1].programId, targetProgramB);
        assertEq(previews[1].rewardToken, address(eve));
        assertEq(previews[1].claimableRewards, 200e18);
        assertEq(totalClaimable, 300e18);

        vm.startPrank(alice);
        uint256 claimedA = EdenRewardsFacet(diamond).claimRewardProgram(targetProgramA, alicePositionId, alice);
        uint256 claimedB = EdenRewardsFacet(diamond).claimRewardProgram(targetProgramB, alicePositionId, alice);
        vm.stopPrank();

        assertEq(claimedA + claimedB, totalClaimable);
        assertEq(alt.balanceOf(alice), claimedA);
        assertEq(eve.balanceOf(alice), claimedB);
    }

    function test_CreateIndex_RevertsForInvalidDefinitionsAndMissingPoolsOnLiveDiamond() public {
        EqualIndexBaseV3.CreateIndexParams memory badLengths = _singleAssetIndexParams("Bad", "BAD", address(eve), 0, 0);
        badLengths.bundleAmounts = new uint256[](0);
        _scheduleCreateIndexExpectRevert(
            badLengths, keccak256("bad-length-index"), abi.encodeWithSelector(InvalidArrayLength.selector)
        );

        EqualIndexBaseV3.CreateIndexParams memory duplicateAssets =
            _singleAssetIndexParams("Dup", "DUP", address(eve), 0, 0);
        duplicateAssets.assets = new address[](2);
        duplicateAssets.assets[0] = address(eve);
        duplicateAssets.assets[1] = address(eve);
        duplicateAssets.bundleAmounts = new uint256[](2);
        duplicateAssets.bundleAmounts[0] = 1e18;
        duplicateAssets.bundleAmounts[1] = 1e18;
        duplicateAssets.mintFeeBps = new uint16[](2);
        duplicateAssets.burnFeeBps = new uint16[](2);
        _scheduleCreateIndexExpectRevert(
            duplicateAssets,
            keccak256("duplicate-assets-index"),
            abi.encodeWithSelector(InvalidBundleDefinition.selector)
        );

        MockERC20Launch missing = new MockERC20Launch("Missing", "MISS");
        EqualIndexBaseV3.CreateIndexParams memory missingPool =
            _singleAssetIndexParams("Missing", "MISS", address(missing), 0, 0);
        _scheduleCreateIndexExpectRevert(
            missingPool,
            keccak256("missing-pool-index"),
            abi.encodeWithSelector(NoPoolForAsset.selector, address(missing))
        );
    }

    function test_EqualIndex_RevertsForCanonicalDuplicatePausedIndexAndInvalidMintInputsOnLiveDiamond() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalPoolAlreadyInitialized.selector, address(eve), 1));
        PoolManagementFacet(diamond).initPool(address(eve));

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Guarded", "GRD", address(eve), 1000, 0));

        eve.mint(bob, 50e18);
        vm.startPrank(bob);
        eve.approve(diamond, 50e18);

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        vm.expectRevert(abi.encodeWithSelector(InvalidUnits.selector));
        EqualIndexActionsFacetV3(diamond).mint(indexId, 0, bob, maxInputs);

        maxInputs[0] = 10e18;
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InvalidMax.selector, 10e18, 11e18));
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();

        _timelockCall(diamond, abi.encodeWithSelector(EqualIndexAdminFacetV3.setPaused.selector, indexId, true));

        vm.startPrank(bob);
        maxInputs[0] = 11e18;
        vm.expectRevert(abi.encodeWithSelector(IndexPaused.selector, indexId));
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();
    }

    function _scheduleCreateIndexExpectRevert(
        EqualIndexBaseV3.CreateIndexParams memory params,
        bytes32 salt,
        bytes memory expectedRevert
    ) internal {
        bytes memory data = abi.encodeWithSelector(EqualIndexAdminFacetV3.createIndex.selector, params);
        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(expectedRevert);
        timelockController.execute(diamond, 0, data, bytes32(0), salt);
    }
}
