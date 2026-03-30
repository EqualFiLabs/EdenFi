// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {InvalidParameterRange, InvalidUnderlying, Unauthorized} from "src/libraries/Errors.sol";

contract EdenRewardsFacetHarness is EdenRewardsFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setProgramReserve(uint256 programId, uint256 reserve) external {
        LibEdenRewardsStorage.s().programs[programId].state.fundedReserve = reserve;
    }
}

contract EdenRewardsFacetTest is Test {
    EdenRewardsFacetHarness internal facet;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal manager = makeAddr("manager");
    address internal rewardToken = makeAddr("rewardToken");
    address internal altRewardToken = makeAddr("altRewardToken");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        facet = new EdenRewardsFacetHarness();
        facet.setOwner(owner);
        facet.setTimelock(timelock);
    }

    function test_CreateRewardProgram_PersistsImmutableTargetAndToken() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, 0, rewardToken, manager, 5e18, 100, 500, true
        );

        (
            LibEdenRewardsStorage.RewardProgramConfig memory config,
            LibEdenRewardsStorage.RewardProgramState memory state
        ) = facet.getRewardProgram(programId);

        assertEq(programId, 0);
        assertEq(uint8(config.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION));
        assertEq(config.target.targetId, 0);
        assertEq(config.rewardToken, rewardToken);
        assertEq(config.manager, manager);
        assertEq(config.rewardRatePerSecond, 5e18);
        assertEq(config.startTime, 100);
        assertEq(config.endTime, 500);
        assertTrue(config.enabled);
        assertFalse(config.paused);
        assertFalse(config.closed);
        assertEq(state.fundedReserve, 0);

        uint256[] memory programIds =
            facet.getRewardProgramIdsByTarget(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, 0);
        assertEq(programIds.length, 1);
        assertEq(programIds[0], programId);
    }

    function test_CreateRewardProgram_RevertsForInvalidConfig() public {
        vm.startPrank(timelock);

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "steveTargetId"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, 1, rewardToken, manager, 1e18, 0, 10, true
        );

        vm.expectRevert(InvalidUnderlying.selector);
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7, address(0), manager, 1e18, 0, 10, true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "manager"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7, rewardToken, address(0), 1e18, 0, 10, true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "rewardRatePerSecond"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7, rewardToken, manager, 0, 0, 10, true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "rewardWindow"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7, rewardToken, manager, 1e18, 10, 10, true
        );
    }

    function test_CreateRewardProgram_RevertsForUnauthorizedCaller() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("LibAccess: not timelock"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 3, rewardToken, manager, 1e18, 0, 10, true
        );
    }

    function test_ManagerAndGovernanceCanDriveLifecycle() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 4, rewardToken, manager, 1e18, 0, 1000, true
        );

        vm.prank(manager);
        facet.setRewardProgramEnabled(programId, false);
        (LibEdenRewardsStorage.RewardProgramConfig memory config,) = facet.getRewardProgram(programId);
        assertFalse(config.enabled);

        vm.prank(manager);
        facet.pauseRewardProgram(programId);
        (config,) = facet.getRewardProgram(programId);
        assertTrue(config.paused);

        vm.prank(timelock);
        facet.resumeRewardProgram(programId);
        (config,) = facet.getRewardProgram(programId);
        assertFalse(config.paused);

        vm.warp(55);
        vm.prank(manager);
        facet.endRewardProgram(programId);
        (config,) = facet.getRewardProgram(programId);
        assertEq(config.endTime, 55);
        assertFalse(config.enabled);
        assertFalse(config.paused);
    }

    function test_LifecycleRevertsForUnauthorizedOrUnsafeClose() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 0, altRewardToken, manager, 1e18, 0, 100, true
        );

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        facet.setRewardProgramEnabled(programId, false);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "programNotPaused"));
        facet.resumeRewardProgram(programId);

        facet.setProgramReserve(programId, 10e18);
        vm.warp(101);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "programReserve"));
        facet.closeRewardProgram(programId);

        facet.setProgramReserve(programId, 0);
        vm.prank(manager);
        facet.closeRewardProgram(programId);

        (LibEdenRewardsStorage.RewardProgramConfig memory config,) = facet.getRewardProgram(programId);
        assertTrue(config.closed);
        assertFalse(config.enabled);
        assertFalse(config.paused);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "programClosed"));
        facet.pauseRewardProgram(programId);
    }
}
