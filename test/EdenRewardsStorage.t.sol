// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";

contract EdenRewardsStorageHarness {
    function createProgram(
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

        LibEdenRewardsStorage.RewardTarget memory target = LibEdenRewardsStorage.RewardTarget({
            targetType: LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            targetId: targetId
        });

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

    function targetKey(uint256 targetId) external pure returns (bytes32) {
        return LibEdenRewardsStorage.targetKey(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, targetId);
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

    function getTargetProgramIds(uint256 targetId) external view returns (uint256[] memory programIds) {
        uint256[] storage storedIds = LibEdenRewardsStorage.programIdsForTarget(
            LibEdenRewardsStorage.s(),
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            targetId
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
        uint256 firstProgramId = harness.createProgram(7, rewardA, manager, 1e18, 100, 200, true, false, false);
        uint256 secondProgramId = harness.createProgram(9, rewardB, manager, 2e18, 300, 400, false, false, false);

        assertEq(firstProgramId, 0);
        assertEq(secondProgramId, 1);
        assertEq(harness.nextProgramId(), 2);

        LibEdenRewardsStorage.RewardProgramConfig memory firstConfig = harness.getProgramConfig(firstProgramId);
        assertEq(uint8(firstConfig.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION));
        assertEq(firstConfig.target.targetId, 7);
        assertEq(firstConfig.rewardToken, rewardA);
        assertEq(firstConfig.manager, manager);

        harness.setProgramState(secondProgramId, 500e18, 1234, 9e27, 25e18);
        LibEdenRewardsStorage.RewardProgramState memory state = harness.getProgramState(secondProgramId);
        assertEq(state.fundedReserve, 500e18);
        assertEq(state.lastRewardUpdate, 1234);
        assertEq(state.globalRewardIndex, 9e27);
        assertEq(state.eligibleSupply, 25e18);
    }

    function test_DiscoveryIsScopedByEqualIndexTargetId() public {
        uint256 first = harness.createProgram(9, rewardA, manager, 1, 0, 10, true, false, false);
        uint256 second = harness.createProgram(9, rewardB, manager, 2, 0, 20, true, false, false);
        uint256 third = harness.createProgram(15, rewardA, manager, 3, 0, 30, true, false, false);

        uint256[] memory programsForNine = harness.getTargetProgramIds(9);
        assertEq(programsForNine.length, 2);
        assertEq(programsForNine[0], first);
        assertEq(programsForNine[1], second);

        uint256[] memory programsForFifteen = harness.getTargetProgramIds(15);
        assertEq(programsForFifteen.length, 1);
        assertEq(programsForFifteen[0], third);

        assertTrue(harness.targetKey(9) != harness.targetKey(15));
    }

    function test_PerProgramPositionAccountingIsIsolated() public {
        bytes32 alicePositionKey = keccak256("alice-position");

        uint256 first = harness.createProgram(3, rewardA, manager, 1, 0, 10, true, false, false);
        uint256 second = harness.createProgram(4, rewardB, manager, 1, 0, 10, true, false, false);

        harness.setPositionAccounting(first, alicePositionKey, 11e27, 17e18);
        harness.setPositionAccounting(second, alicePositionKey, 19e27, 23e18);

        assertEq(harness.getPositionRewardIndex(first, alicePositionKey), 11e27);
        assertEq(harness.getAccruedRewards(first, alicePositionKey), 17e18);
        assertEq(harness.getPositionRewardIndex(second, alicePositionKey), 19e27);
        assertEq(harness.getAccruedRewards(second, alicePositionKey), 23e18);
    }
}
