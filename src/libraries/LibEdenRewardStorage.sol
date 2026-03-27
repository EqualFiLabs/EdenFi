// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibEdenRewardStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.by.equalfi.reward.storage");
    uint256 internal constant REWARD_INDEX_SCALE = 1e27;

    struct RewardConfig {
        address rewardToken;
        uint256 rewardRatePerSecond;
        uint256 lastRewardUpdate;
        uint256 globalRewardIndex;
        uint256 rewardReserve;
        bool enabled;
    }

    struct RewardStorage {
        RewardConfig config;
        mapping(bytes32 => uint256) positionRewardIndex;
        mapping(bytes32 => uint256) accruedRewards;
    }

    function s() internal pure returns (RewardStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}
