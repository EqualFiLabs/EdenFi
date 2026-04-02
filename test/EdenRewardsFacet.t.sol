// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {InvalidParameterRange, InvalidUnderlying, Unauthorized} from "src/libraries/Errors.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract EdenRewardsFacetTest is LaunchFixture {
    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function test_CreateRewardProgram_PersistsEqualIndexTargetAndDiscovery() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 indexId = _createRewardIndex("Reward Index", "RIDX");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 startTime = block.timestamp + 8 days;
        uint256 endTime = startTime + 400;
        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 5e18, startTime, endTime, true);

        (
            LibEdenRewardsStorage.RewardProgramConfig memory config,
            LibEdenRewardsStorage.RewardProgramState memory state
        ) = EdenRewardsFacet(diamond).getRewardProgram(programId);

        assertEq(programId, 0);
        assertEq(uint8(config.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION));
        assertEq(config.target.targetId, indexId);
        assertEq(config.rewardToken, address(alt));
        assertEq(config.manager, manager);
        assertEq(state.eligibleSupply, 10e18);

        uint256[] memory programIds = EdenRewardsFacet(diamond).getRewardProgramIdsByTarget(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, indexId
        );
        assertEq(programIds.length, 1);
        assertEq(programIds[0], programId);
    }

    function test_CreateRewardProgram_RevertsForInvalidConfigAndUnauthorizedCaller() public {
        uint256 indexId = _createRewardIndex("Invalid Reward Index", "IRI");

        vm.prank(stranger);
        vm.expectRevert(bytes("LibAccess: not timelock"));
        EdenRewardsFacet(diamond).createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            indexId,
            address(alt),
            manager,
            1e18,
            0,
            10,
            true
        );

        vm.startPrank(address(timelockController));

        vm.expectRevert(InvalidUnderlying.selector);
        EdenRewardsFacet(diamond).createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            indexId,
            address(0),
            manager,
            1e18,
            0,
            10,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "manager"));
        EdenRewardsFacet(diamond).createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            indexId,
            address(alt),
            address(0),
            1e18,
            0,
            10,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "rewardRatePerSecond"));
        EdenRewardsFacet(diamond).createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            indexId,
            address(alt),
            manager,
            0,
            0,
            10,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "rewardWindow"));
        EdenRewardsFacet(diamond).createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            indexId,
            address(alt),
            manager,
            1e18,
            10,
            10,
            true
        );

        vm.stopPrank();
    }

    function test_ManagerAndGovernanceCanDriveLifecycle() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 indexId = _createRewardIndex("Lifecycle Reward Index", "LRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId =
            _createEqualIndexRewardProgram(indexId, address(alt), manager, 1e18, 0, block.timestamp + 8 days, true);

        vm.prank(manager);
        EdenRewardsFacet(diamond).setRewardProgramEnabled(programId, false);

        vm.prank(manager);
        EdenRewardsFacet(diamond).pauseRewardProgram(programId);

        vm.prank(manager);
        EdenRewardsFacet(diamond).resumeRewardProgram(programId);

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        EdenRewardsFacet(diamond).endRewardProgram(programId);

        vm.prank(address(timelockController));
        EdenRewardsFacet(diamond).endRewardProgram(programId);
        vm.warp(block.timestamp + 1);

        vm.prank(address(timelockController));
        EdenRewardsFacet(diamond).closeRewardProgram(programId);

        (LibEdenRewardsStorage.RewardProgramConfig memory config,) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertTrue(config.closed);
        assertTrue(!config.enabled);
        assertTrue(!config.paused);
    }

    function test_FundAccrueAndClaim_ForEqualIndexTarget() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 indexId = _createRewardIndex("Claim Reward Index", "CRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 10e18, 0, 0, true);

        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);

        EdenRewardsFacet.RewardProgramPositionView memory preview =
            EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.eligibleBalance, 10e18);
        assertEq(preview.claimableRewards, 100e18);

        vm.prank(alice);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);

        assertEq(claimed, 100e18);
        assertEq(alt.balanceOf(alice), 100e18);

        preview = EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.claimableRewards, 0);
    }

    function test_ClaimRewardProgram_GrossesUpFeeOnTransferRewards() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 indexId = _createRewardIndex("FoT Reward Index", "FRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(fot), manager, 10e18, 0, 0, true);

        vm.prank(manager);
        EdenRewardsFacet(diamond).setRewardProgramTransferFeeBps(programId, 1000);

        fot.mint(address(this), 1_000e18);
        vm.startPrank(address(this));
        fot.approve(diamond, 200e18);
        EdenRewardsFacet(diamond).fundRewardProgram(programId, 180e18, 200e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);

        assertEq(claimed, 100e18);
        assertEq(fot.balanceOf(alice), 100e18);
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

        uint256 indexId = _createRewardIndex("Wallet Reward Index", "WRI");

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
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 bobPositionId = _fundEvePosition(bob, 20e18);
        uint256 indexId = _createRewardIndex("Mint Reward Index", "MRI");

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
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 bobPositionId = _fundEvePosition(bob, 20e18);
        uint256 indexId = _createRewardIndex("Burn Reward Index", "BRI");

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
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 bobPositionId = _fundEvePosition(bob, 10e18);
        uint256 indexId = _createRewardIndex("Recover Reward Index", "RRI");

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

    function test_EqualIndexRewards_MultiplePositionsEnterAndLeaveProgram() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 bobPositionId = _fundEvePosition(bob, 20e18);
        uint256 indexId = _createRewardIndex("Multi Reward Index", "MRII");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        EqualIndexPositionFacet(diamond).mintFromPosition(bobPositionId, indexId, 10e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 20e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(alicePositionId, indexId, 10e18);

        (, state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 10e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);

        assertEq(aliceClaimed, 450e18);
        assertEq(bobClaimed, 450e18);
    }

    function test_EqualIndexRewards_PausedAndDisabledProgramsPreserveUnclaimedRewards() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 indexId = _createRewardIndex("Pause Reward Index", "PRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 10e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        vm.prank(manager);
        EdenRewardsFacet(diamond).pauseRewardProgram(programId);

        EdenRewardsFacet.RewardProgramPositionView memory preview =
            EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.claimableRewards, 100e18);

        vm.warp(block.timestamp + 10);
        preview = EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.claimableRewards, 100e18);

        vm.prank(manager);
        EdenRewardsFacet(diamond).resumeRewardProgram(programId);

        vm.warp(block.timestamp + 10);
        vm.prank(address(timelockController));
        EdenRewardsFacet(diamond).setRewardProgramEnabled(programId, false);

        preview = EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.claimableRewards, 200e18);

        vm.warp(block.timestamp + 10);
        preview = EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.claimableRewards, 200e18);

        vm.prank(alice);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        assertEq(claimed, 200e18);
    }

    function test_EqualIndexRewards_ClosedProgramStillAllowsOutstandingClaims() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 indexId = _createRewardIndex("Closed Reward Index", "CLRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 10e18, 0, 0, true);
        alt.mint(address(this), 100e18);
        _fundRewardProgram(address(this), programId, alt, 100e18);

        vm.warp(block.timestamp + 10);
        vm.prank(address(timelockController));
        EdenRewardsFacet(diamond).endRewardProgram(programId);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.fundedReserve, 0);

        vm.prank(address(timelockController));
        EdenRewardsFacet(diamond).closeRewardProgram(programId);

        (LibEdenRewardsStorage.RewardProgramConfig memory config,) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertTrue(config.closed);

        EdenRewardsFacet.RewardProgramPositionView memory preview =
            EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.claimableRewards, 100e18);

        vm.prank(alice);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        assertEq(claimed, 100e18);
        assertEq(alt.balanceOf(alice), 100e18);
    }

    function test_EqualIndexRewards_FeeOnTransferProgramHandlesLiveHookDrivenEligibility() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 bobPositionId = _fundEvePosition(bob, 20e18);
        uint256 indexId = _createRewardIndex("FoT Hook Reward Index", "FHRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(fot), manager, 27e18, 0, 0, true);

        vm.prank(manager);
        EdenRewardsFacet(diamond).setRewardProgramTransferFeeBps(programId, 1000);

        fot.mint(address(this), 2_000e18);
        vm.startPrank(address(this));
        fot.approve(diamond, 1_000e18);
        EdenRewardsFacet(diamond).fundRewardProgram(programId, 900e18, 1_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        EqualIndexPositionFacet(diamond).mintFromPosition(bobPositionId, indexId, 10e18);

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

        assertEq(aliceClaimed, 495e18);
        assertEq(bobClaimed, 315e18);
        assertEq(fot.balanceOf(alice), 495e18);
        assertEq(fot.balanceOf(bob), 315e18);
    }

    function test_EqualIndexRewards_ManagerAndGovernanceControls_ModulateLiveAccrual() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 indexId = _createRewardIndex("Governed Reward Index", "GRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 10e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        vm.prank(manager);
        EdenRewardsFacet(diamond).pauseRewardProgram(programId);

        EdenRewardsFacet.RewardProgramPositionView memory preview =
            EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.eligibleBalance, 10e18);
        assertEq(preview.claimableRewards, 100e18);

        vm.warp(block.timestamp + 10);
        vm.prank(address(timelockController));
        EdenRewardsFacet(diamond).setRewardProgramEnabled(programId, false);
        preview = EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.claimableRewards, 100e18);

        vm.prank(address(timelockController));
        EdenRewardsFacet(diamond).setRewardProgramEnabled(programId, true);

        vm.prank(manager);
        EdenRewardsFacet(diamond).resumeRewardProgram(programId);

        vm.warp(block.timestamp + 10);
        vm.prank(address(timelockController));
        EdenRewardsFacet(diamond).endRewardProgram(programId);

        preview = EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);
        assertEq(preview.claimableRewards, 200e18);

        vm.prank(alice);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        assertEq(claimed, 200e18);
    }

    function _fundEvePosition(address user, uint256 amount) internal returns (uint256 positionId) {
        eve.mint(user, amount);
        positionId = _mintPosition(user, 1);

        vm.startPrank(user);
        eve.approve(diamond, amount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, amount, amount);
        vm.stopPrank();
    }

    function _createRewardIndex(string memory name_, string memory symbol_) internal returns (uint256 indexId) {
        (indexId,) = _createIndexThroughTimelock(_singleAssetIndexParams(name_, symbol_, address(eve), 0, 0));
    }
}
