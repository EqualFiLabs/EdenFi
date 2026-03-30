// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";

contract EdenRewardsStorageHarness {
    function createProgram(
        LibEdenRewardsStorage.RewardTargetType targetType,
        uint256 targetId,
        address rewardToken,
        address manager,
        uint256 rewardRatePerSecond,
        uint256 startTime,
        uint256 endTime,
        bool enabled,
        bool paused,
        bool closed
    ) external returns (uint256 programId) {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        programId = LibEdenRewardsStorage.allocateProgramId(store);

        LibEdenRewardsStorage.RewardTarget memory target =
            LibEdenRewardsStorage.RewardTarget({targetType: targetType, targetId: targetId});

        store.programs[programId].config = LibEdenRewardsStorage.RewardProgramConfig({
            target: target,
            rewardToken: rewardToken,
            manager: manager,
            outboundTransferBps: 0,
            rewardRatePerSecond: rewardRatePerSecond,
            startTime: startTime,
            endTime: endTime,
            enabled: enabled,
            paused: paused,
            closed: closed
        });

        LibEdenRewardsStorage.registerProgramTarget(store, programId, target);
    }

    function setProgramState(
        uint256 programId,
        uint256 fundedReserve,
        uint256 lastRewardUpdate,
        uint256 globalRewardIndex,
        uint256 eligibleSupply
    ) external {
        LibEdenRewardsStorage.s().programs[programId].state = LibEdenRewardsStorage.RewardProgramState({
            fundedReserve: fundedReserve,
            lastRewardUpdate: lastRewardUpdate,
            globalRewardIndex: globalRewardIndex,
            eligibleSupply: eligibleSupply
        });
    }

    function setPositionAccounting(uint256 programId, bytes32 positionKey, uint256 checkpoint, uint256 accrued)
        external
    {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        store.positionRewardIndex[programId][positionKey] = checkpoint;
        store.accruedRewards[programId][positionKey] = accrued;
    }

    function nextProgramId() external view returns (uint256) {
        return LibEdenRewardsStorage.s().nextProgramId;
    }

    function steveTargetId() external pure returns (uint256) {
        return LibEdenRewardsStorage.STEVE_TARGET_ID;
    }

    function targetKey(LibEdenRewardsStorage.RewardTargetType targetType, uint256 targetId)
        external
        pure
        returns (bytes32)
    {
        return LibEdenRewardsStorage.targetKey(targetType, targetId);
    }

    function getProgramConfig(uint256 programId)
        external
        view
        returns (LibEdenRewardsStorage.RewardProgramConfig memory)
    {
        return LibEdenRewardsStorage.s().programs[programId].config;
    }

    function getProgramState(uint256 programId)
        external
        view
        returns (LibEdenRewardsStorage.RewardProgramState memory)
    {
        return LibEdenRewardsStorage.s().programs[programId].state;
    }

    function getPositionRewardIndex(uint256 programId, bytes32 positionKey) external view returns (uint256) {
        return LibEdenRewardsStorage.s().positionRewardIndex[programId][positionKey];
    }

    function getAccruedRewards(uint256 programId, bytes32 positionKey) external view returns (uint256) {
        return LibEdenRewardsStorage.s().accruedRewards[programId][positionKey];
    }

    function getTargetProgramIds(LibEdenRewardsStorage.RewardTargetType targetType, uint256 targetId)
        external
        view
        returns (uint256[] memory programIds)
    {
        uint256[] storage storedIds = LibEdenRewardsStorage.programIdsForTarget(
            LibEdenRewardsStorage.s(), targetType, targetId
        );
        uint256 len = storedIds.length;
        programIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            programIds[i] = storedIds[i];
        }
    }
}

contract EdenRewardsStorageTest is Test {
    EdenRewardsStorageHarness internal harness;

    address internal rewardA = makeAddr("rewardA");
    address internal rewardB = makeAddr("rewardB");
    address internal manager = makeAddr("manager");

    function setUp() public {
        harness = new EdenRewardsStorageHarness();
    }

    function test_ProgramIdsIncrementAndConfigsPersist() public {
        uint256 steveProgramId = harness.createProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            harness.steveTargetId(),
            rewardA,
            manager,
            1e18,
            100,
            200,
            true,
            false,
            false
        );
        uint256 indexProgramId = harness.createProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            7,
            rewardB,
            manager,
            2e18,
            300,
            400,
            false,
            false,
            false
        );

        assertEq(steveProgramId, 0);
        assertEq(indexProgramId, 1);
        assertEq(harness.nextProgramId(), 2);

        LibEdenRewardsStorage.RewardProgramConfig memory steveConfig = harness.getProgramConfig(steveProgramId);
        assertEq(uint8(steveConfig.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION));
        assertEq(steveConfig.target.targetId, 0);
        assertEq(steveConfig.rewardToken, rewardA);
        assertEq(steveConfig.manager, manager);
        assertEq(steveConfig.rewardRatePerSecond, 1e18);
        assertEq(steveConfig.startTime, 100);
        assertEq(steveConfig.endTime, 200);
        assertTrue(steveConfig.enabled);
        assertFalse(steveConfig.paused);
        assertFalse(steveConfig.closed);

        harness.setProgramState(indexProgramId, 500e18, 1234, 9e27, 25e18);
        LibEdenRewardsStorage.RewardProgramState memory state = harness.getProgramState(indexProgramId);
        assertEq(state.fundedReserve, 500e18);
        assertEq(state.lastRewardUpdate, 1234);
        assertEq(state.globalRewardIndex, 9e27);
        assertEq(state.eligibleSupply, 25e18);
    }

    function test_TargetTypingAndDiscoveryByTarget() public {
        uint256 steveTargetId = harness.steveTargetId();

        uint256 first = harness.createProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, steveTargetId, rewardA, manager, 1, 0, 10, true, false, false
        );
        uint256 second = harness.createProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, steveTargetId, rewardB, manager, 2, 0, 20, true, false, false
        );
        uint256 third = harness.createProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 9, rewardA, manager, 3, 0, 30, true, false, false
        );

        uint256[] memory stevePrograms =
            harness.getTargetProgramIds(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, steveTargetId);
        assertEq(stevePrograms.length, 2);
        assertEq(stevePrograms[0], first);
        assertEq(stevePrograms[1], second);

        uint256[] memory indexPrograms =
            harness.getTargetProgramIds(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 9);
        assertEq(indexPrograms.length, 1);
        assertEq(indexPrograms[0], third);

        bytes32 steveKey = harness.targetKey(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, steveTargetId);
        bytes32 indexKey = harness.targetKey(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 9);
        assertTrue(steveKey != indexKey);
    }

    function test_PerProgramPositionAccountingIsIsolated() public {
        bytes32 alicePositionKey = keccak256("alice-position");

        uint256 first = harness.createProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            harness.steveTargetId(),
            rewardA,
            manager,
            1,
            0,
            10,
            true,
            false,
            false
        );
        uint256 second = harness.createProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 3, rewardB, manager, 1, 0, 10, true, false, false
        );

        harness.setPositionAccounting(first, alicePositionKey, 11e27, 17e18);
        harness.setPositionAccounting(second, alicePositionKey, 19e27, 23e18);

        assertEq(harness.getPositionRewardIndex(first, alicePositionKey), 11e27);
        assertEq(harness.getAccruedRewards(first, alicePositionKey), 17e18);
        assertEq(harness.getPositionRewardIndex(second, alicePositionKey), 19e27);
        assertEq(harness.getAccruedRewards(second, alicePositionKey), 23e18);
    }
}
