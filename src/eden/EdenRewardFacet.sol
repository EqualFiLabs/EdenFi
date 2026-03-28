// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenRewardStorage} from "../libraries/LibEdenRewardStorage.sol";
import {LibEdenRewards} from "../libraries/LibEdenRewards.sol";
import {LibEdenStEVEStorage} from "../libraries/LibEdenStEVEStorage.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import "../libraries/Errors.sol";

contract EdenRewardFacet is ReentrancyGuardModifiers {
    struct RewardView {
        address rewardToken;
        uint256 rewardRatePerSecond;
        uint256 lastRewardUpdate;
        uint256 globalRewardIndex;
        uint256 rewardReserve;
        uint256 eligibleSupply;
        bool enabled;
    }

    event RewardConfigUpdated(address indexed rewardToken, uint256 rewardRatePerSecond, bool enabled);
    event RewardsFunded(address indexed funder, uint256 amount);
    event RewardsClaimed(uint256 indexed tokenId, bytes32 indexed positionKey, address indexed to, uint256 amount);

    function configureRewards(address rewardToken, uint256 rewardRatePerSecond, bool enabled) external nonReentrant {
        LibAccess.enforceTimelockOrOwnerIfUnset();
        if (rewardToken == address(0)) revert InvalidUnderlying();

        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        LibEdenRewards.accrueGlobalRewards();

        address currentRewardToken = rewards.config.rewardToken;
        if (currentRewardToken != address(0) && currentRewardToken != rewardToken && rewards.config.rewardReserve > 0) {
            revert InvalidParameterRange("reward token locked with reserve");
        }

        rewards.config.rewardToken = rewardToken;
        rewards.config.rewardRatePerSecond = rewardRatePerSecond;
        rewards.config.enabled = enabled;
        if (rewards.config.lastRewardUpdate == 0) {
            rewards.config.lastRewardUpdate = block.timestamp;
        }

        emit RewardConfigUpdated(rewardToken, rewardRatePerSecond, enabled);
    }

    function fundRewards(uint256 amount, uint256 maxAmount) external payable nonReentrant returns (uint256 funded) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        address rewardToken = rewards.config.rewardToken;
        if (rewardToken == address(0)) revert InvalidParameterRange("reward token unset");
        if (amount == 0) revert InvalidParameterRange("amount=0");

        LibEdenRewards.accrueGlobalRewards();
        funded = LibCurrency.pullAtLeast(rewardToken, msg.sender, amount, maxAmount);
        rewards.config.rewardReserve += funded;

        emit RewardsFunded(msg.sender, funded);
    }

    function claimRewards(uint256 tokenId, address to) external nonReentrant returns (uint256 claimed) {
        LibPositionHelpers.requireOwnership(tokenId);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        claimed = LibEdenRewards.settlePositionRewards(positionKey);
        if (claimed == 0) revert InvalidParameterRange("nothing claimable");

        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        rewards.accruedRewards[positionKey] = 0;
        LibCurrency.transfer(rewards.config.rewardToken, to, claimed);

        emit RewardsClaimed(tokenId, positionKey, to, claimed);
    }

    function previewClaimRewards(uint256 tokenId) external view returns (uint256) {
        return LibEdenRewards.previewPositionRewards(LibPositionHelpers.positionKey(tokenId));
    }

    function claimableRewards(uint256 tokenId) external view returns (uint256) {
        return LibEdenRewards.previewPositionRewards(LibPositionHelpers.positionKey(tokenId));
    }

    function accruedRewardsOfPosition(uint256 tokenId) external view returns (uint256) {
        return LibEdenRewardStorage.s().accruedRewards[LibPositionHelpers.positionKey(tokenId)];
    }

    function rewardCheckpointOfPosition(uint256 tokenId) external view returns (uint256) {
        return LibEdenRewardStorage.s().positionRewardIndex[LibPositionHelpers.positionKey(tokenId)];
    }

    function getRewardConfig() external view returns (RewardView memory view_) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        view_.rewardToken = rewards.config.rewardToken;
        view_.rewardRatePerSecond = rewards.config.rewardRatePerSecond;
        view_.lastRewardUpdate = rewards.config.lastRewardUpdate;
        view_.globalRewardIndex = LibEdenRewards.previewGlobalRewardIndex();
        view_.rewardReserve = LibEdenRewards.previewRewardReserve();
        view_.eligibleSupply = LibEdenStEVEStorage.s().eligibleSupply;
        view_.enabled = rewards.config.enabled;
    }
}
