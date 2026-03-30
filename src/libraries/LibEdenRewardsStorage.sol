// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibEdenRewardsStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.eden.rewards.engine.storage");
    uint256 internal constant REWARD_INDEX_SCALE = 1e27;
    uint256 internal constant STEVE_TARGET_ID = 0;

    enum RewardTargetType {
        STEVE_POSITION,
        EQUAL_INDEX_POSITION
    }

    struct RewardTarget {
        RewardTargetType targetType;
        uint256 targetId;
    }

    struct RewardProgramConfig {
        RewardTarget target;
        address rewardToken;
        address manager;
        uint256 rewardRatePerSecond;
        uint256 startTime;
        uint256 endTime;
        bool enabled;
        bool closed;
    }

    struct RewardProgramState {
        uint256 fundedReserve;
        uint256 lastRewardUpdate;
        uint256 globalRewardIndex;
        uint256 eligibleSupply;
    }

    struct RewardProgram {
        RewardProgramConfig config;
        RewardProgramState state;
    }

    struct RewardsStorage {
        uint256 nextProgramId;
        mapping(uint256 => RewardProgram) programs;
        mapping(uint256 => mapping(bytes32 => uint256)) positionRewardIndex;
        mapping(uint256 => mapping(bytes32 => uint256)) accruedRewards;
        mapping(bytes32 => uint256[]) targetProgramIds;
    }

    function s() internal pure returns (RewardsStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function allocateProgramId(RewardsStorage storage store) internal returns (uint256 programId) {
        programId = store.nextProgramId;
        store.nextProgramId = programId + 1;
    }

    function registerProgramTarget(RewardsStorage storage store, uint256 programId, RewardTarget memory target)
        internal
    {
        store.targetProgramIds[targetKey(target)].push(programId);
    }

    function targetKey(RewardTarget memory target) internal pure returns (bytes32) {
        return targetKey(target.targetType, target.targetId);
    }

    function targetKey(RewardTargetType targetType, uint256 targetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint8(targetType), targetId));
    }

    function programIdsForTarget(RewardsStorage storage store, RewardTarget memory target)
        internal
        view
        returns (uint256[] storage programIds)
    {
        programIds = store.targetProgramIds[targetKey(target)];
    }

    function programIdsForTarget(RewardsStorage storage store, RewardTargetType targetType, uint256 targetId)
        internal
        view
        returns (uint256[] storage programIds)
    {
        programIds = store.targetProgramIds[targetKey(targetType, targetId)];
    }
}
