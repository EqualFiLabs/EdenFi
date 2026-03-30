// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibEdenRewardStorage} from "./LibEdenRewardStorage.sol";
import {LibStEVEEligibilityStorage} from "./LibStEVEEligibilityStorage.sol";

library LibEdenRewards {
    function settlePositionRewards(bytes32 positionKey) internal returns (uint256 claimable) {
        accrueGlobalRewards();

        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        uint256 checkpoint = rewards.positionRewardIndex[positionKey];
        uint256 globalIndex = rewards.config.globalRewardIndex;
        uint256 eligiblePrincipal = LibStEVEEligibilityStorage.s().eligiblePrincipal[positionKey];

        if (globalIndex > checkpoint && eligiblePrincipal > 0) {
            rewards.accruedRewards[positionKey] += Math.mulDiv(
                eligiblePrincipal,
                globalIndex - checkpoint,
                LibEdenRewardStorage.REWARD_INDEX_SCALE
            );
        }

        rewards.positionRewardIndex[positionKey] = globalIndex;
        claimable = rewards.accruedRewards[positionKey];
    }

    function accrueGlobalRewards() internal {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        if (rewards.config.lastRewardUpdate == 0) {
            rewards.config.lastRewardUpdate = block.timestamp;
            return;
        }

        if (!rewards.config.enabled || rewards.config.rewardRatePerSecond == 0) {
            rewards.config.lastRewardUpdate = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - rewards.config.lastRewardUpdate;
        if (elapsed == 0) return;

        uint256 eligibleSupply = LibStEVEEligibilityStorage.s().eligibleSupply;
        if (eligibleSupply == 0 || rewards.config.rewardReserve == 0) {
            rewards.config.lastRewardUpdate = block.timestamp;
            return;
        }

        uint256 maxRewards = elapsed * rewards.config.rewardRatePerSecond;
        uint256 allocated = maxRewards > rewards.config.rewardReserve ? rewards.config.rewardReserve : maxRewards;
        if (allocated > 0) {
            rewards.config.rewardReserve -= allocated;
            rewards.config.globalRewardIndex += Math.mulDiv(
                allocated,
                LibEdenRewardStorage.REWARD_INDEX_SCALE,
                eligibleSupply
            );
        }

        rewards.config.lastRewardUpdate = block.timestamp;
    }

    function previewPositionRewards(bytes32 positionKey) internal view returns (uint256) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        uint256 globalIndex = previewGlobalRewardIndex();
        uint256 checkpoint = rewards.positionRewardIndex[positionKey];
        uint256 accrued = rewards.accruedRewards[positionKey];
        uint256 eligiblePrincipal = LibStEVEEligibilityStorage.s().eligiblePrincipal[positionKey];

        if (globalIndex > checkpoint && eligiblePrincipal > 0) {
            accrued += Math.mulDiv(
                eligiblePrincipal,
                globalIndex - checkpoint,
                LibEdenRewardStorage.REWARD_INDEX_SCALE
            );
        }

        return accrued;
    }

    function previewGlobalRewardIndex() internal view returns (uint256) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        if (
            rewards.config.lastRewardUpdate == 0 || !rewards.config.enabled || rewards.config.rewardRatePerSecond == 0
        ) {
            return rewards.config.globalRewardIndex;
        }

        uint256 elapsed = block.timestamp - rewards.config.lastRewardUpdate;
        if (elapsed == 0) return rewards.config.globalRewardIndex;

        uint256 eligibleSupply = LibStEVEEligibilityStorage.s().eligibleSupply;
        if (eligibleSupply == 0 || rewards.config.rewardReserve == 0) {
            return rewards.config.globalRewardIndex;
        }

        uint256 maxRewards = elapsed * rewards.config.rewardRatePerSecond;
        uint256 allocated = maxRewards > rewards.config.rewardReserve ? rewards.config.rewardReserve : maxRewards;
        return rewards.config.globalRewardIndex
            + Math.mulDiv(allocated, LibEdenRewardStorage.REWARD_INDEX_SCALE, eligibleSupply);
    }

    function previewRewardReserve() internal view returns (uint256) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        if (
            rewards.config.lastRewardUpdate == 0 || !rewards.config.enabled || rewards.config.rewardRatePerSecond == 0
        ) {
            return rewards.config.rewardReserve;
        }

        uint256 elapsed = block.timestamp - rewards.config.lastRewardUpdate;
        if (elapsed == 0) return rewards.config.rewardReserve;

        uint256 eligibleSupply = LibStEVEEligibilityStorage.s().eligibleSupply;
        if (eligibleSupply == 0 || rewards.config.rewardReserve == 0) {
            return rewards.config.rewardReserve;
        }

        uint256 maxRewards = elapsed * rewards.config.rewardRatePerSecond;
        return rewards.config.rewardReserve > maxRewards ? rewards.config.rewardReserve - maxRewards : 0;
    }
}
