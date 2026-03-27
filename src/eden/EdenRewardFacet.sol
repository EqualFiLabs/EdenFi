// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EdenStEVEFacet} from "./EdenStEVEFacet.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenRewardStorage} from "../libraries/LibEdenRewardStorage.sol";
import {LibEdenStEVEStorage} from "../libraries/LibEdenStEVEStorage.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import "../libraries/Errors.sol";

contract EdenRewardFacet is EdenStEVEFacet {
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
        _accrueGlobalRewards();

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

        _accrueGlobalRewards();
        funded = LibCurrency.pullAtLeast(rewardToken, msg.sender, amount, maxAmount);
        rewards.config.rewardReserve += funded;

        emit RewardsFunded(msg.sender, funded);
    }

    function claimRewards(uint256 tokenId, address to) external nonReentrant returns (uint256 claimed) {
        LibPositionHelpers.requireOwnership(tokenId);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        claimed = _settlePositionRewards(positionKey);
        if (claimed == 0) revert InvalidParameterRange("nothing claimable");

        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        rewards.accruedRewards[positionKey] = 0;
        LibCurrency.transfer(rewards.config.rewardToken, to, claimed);

        emit RewardsClaimed(tokenId, positionKey, to, claimed);
    }

    function previewClaimRewards(uint256 tokenId) external view returns (uint256) {
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        return _previewPositionRewards(positionKey);
    }

    function claimableRewards(uint256 tokenId) external view returns (uint256) {
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        return _previewPositionRewards(positionKey);
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
        view_.globalRewardIndex = _previewGlobalRewardIndex();
        view_.rewardReserve = _previewRewardReserve();
        view_.eligibleSupply = LibEdenStEVEStorage.s().eligibleSupply;
        view_.enabled = rewards.config.enabled;
    }

    function _beforeEligiblePrincipalChange(bytes32 positionKey) internal virtual override {
        _settlePositionRewards(positionKey);
    }

    function _settlePositionRewards(bytes32 positionKey) internal returns (uint256 claimable) {
        _accrueGlobalRewards();

        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        uint256 checkpoint = rewards.positionRewardIndex[positionKey];
        uint256 globalIndex = rewards.config.globalRewardIndex;
        uint256 eligiblePrincipal = LibEdenStEVEStorage.s().eligiblePrincipal[positionKey];

        if (globalIndex > checkpoint && eligiblePrincipal > 0) {
            rewards.accruedRewards[positionKey] +=
                Math.mulDiv(eligiblePrincipal, globalIndex - checkpoint, LibEdenRewardStorage.REWARD_INDEX_SCALE);
        }
        rewards.positionRewardIndex[positionKey] = globalIndex;
        return rewards.accruedRewards[positionKey];
    }

    function _accrueGlobalRewards() internal {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        uint256 lastUpdate = rewards.config.lastRewardUpdate;
        uint256 currentTime = block.timestamp;

        if (lastUpdate == 0) {
            rewards.config.lastRewardUpdate = currentTime;
            return;
        }
        if (currentTime <= lastUpdate) return;

        uint256 eligibleSupply = LibEdenStEVEStorage.s().eligibleSupply;
        if (!rewards.config.enabled || rewards.config.rewardRatePerSecond == 0 || eligibleSupply == 0) {
            rewards.config.lastRewardUpdate = currentTime;
            return;
        }

        uint256 elapsed = currentTime - lastUpdate;
        uint256 requestedRewards = elapsed * rewards.config.rewardRatePerSecond;
        uint256 allocatedRewards = requestedRewards > rewards.config.rewardReserve ? rewards.config.rewardReserve : requestedRewards;

        if (allocatedRewards > 0) {
            rewards.config.globalRewardIndex +=
                Math.mulDiv(allocatedRewards, LibEdenRewardStorage.REWARD_INDEX_SCALE, eligibleSupply);
            rewards.config.rewardReserve -= allocatedRewards;
        }

        rewards.config.lastRewardUpdate = currentTime;
    }

    function _previewPositionRewards(bytes32 positionKey) internal view returns (uint256) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        uint256 globalIndex = _previewGlobalRewardIndex();
        uint256 checkpoint = rewards.positionRewardIndex[positionKey];
        uint256 accrued = rewards.accruedRewards[positionKey];
        uint256 eligiblePrincipal = LibEdenStEVEStorage.s().eligiblePrincipal[positionKey];
        if (globalIndex <= checkpoint || eligiblePrincipal == 0) {
            return accrued;
        }
        return accrued + Math.mulDiv(eligiblePrincipal, globalIndex - checkpoint, LibEdenRewardStorage.REWARD_INDEX_SCALE);
    }

    function _previewGlobalRewardIndex() internal view returns (uint256) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        uint256 lastUpdate = rewards.config.lastRewardUpdate;
        uint256 currentTime = block.timestamp;
        uint256 globalIndex = rewards.config.globalRewardIndex;

        if (lastUpdate == 0 || currentTime <= lastUpdate) return globalIndex;

        uint256 eligibleSupply = LibEdenStEVEStorage.s().eligibleSupply;
        if (!rewards.config.enabled || rewards.config.rewardRatePerSecond == 0 || eligibleSupply == 0) {
            return globalIndex;
        }

        uint256 elapsed = currentTime - lastUpdate;
        uint256 requestedRewards = elapsed * rewards.config.rewardRatePerSecond;
        uint256 allocatedRewards = requestedRewards > rewards.config.rewardReserve ? rewards.config.rewardReserve : requestedRewards;
        if (allocatedRewards == 0) return globalIndex;

        return globalIndex + Math.mulDiv(allocatedRewards, LibEdenRewardStorage.REWARD_INDEX_SCALE, eligibleSupply);
    }

    function _previewRewardReserve() internal view returns (uint256) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        uint256 lastUpdate = rewards.config.lastRewardUpdate;
        uint256 currentTime = block.timestamp;

        if (
            lastUpdate == 0 || currentTime <= lastUpdate || !rewards.config.enabled || rewards.config.rewardRatePerSecond == 0
                || LibEdenStEVEStorage.s().eligibleSupply == 0
        ) {
            return rewards.config.rewardReserve;
        }

        uint256 elapsed = currentTime - lastUpdate;
        uint256 requestedRewards = elapsed * rewards.config.rewardRatePerSecond;
        if (requestedRewards >= rewards.config.rewardReserve) {
            return 0;
        }
        return rewards.config.rewardReserve - requestedRewards;
    }
}
