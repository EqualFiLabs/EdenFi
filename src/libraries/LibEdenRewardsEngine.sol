// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibEqualIndexStorage} from "./LibEqualIndexStorage.sol";
import {LibMaintenance} from "./LibMaintenance.sol";
import {LibEdenRewardsStorage} from "./LibEdenRewardsStorage.sol";
import {LibStEVEEligibilityStorage} from "./LibStEVEEligibilityStorage.sol";
import {LibStEVEStorage} from "./LibStEVEStorage.sol";
import {InvalidParameterRange} from "./Errors.sol";

library LibEdenRewardsEngine {
    function accrueProgram(uint256 programId)
        internal
        returns (LibEdenRewardsStorage.RewardProgramState memory state)
    {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        LibEdenRewardsStorage.RewardProgramConfig memory config = store.programs[programId].config;
        state = store.programs[programId].state;
        state.eligibleSupply = _currentEligibleSupply(config.target);
        state = _previewAccrual(config, state, block.timestamp);
        store.programs[programId].state = state;
    }

    function previewProgramState(uint256 programId)
        internal
        view
        returns (LibEdenRewardsStorage.RewardProgramState memory state)
    {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        LibEdenRewardsStorage.RewardProgramConfig memory config = store.programs[programId].config;
        state = store.programs[programId].state;
        state.eligibleSupply = _currentEligibleSupplyView(config.target);
        state = _previewAccrual(config, state, block.timestamp);
    }

    function settleProgramPosition(uint256 programId, bytes32 positionKey, uint256 eligibleBalance)
        internal
        returns (uint256 claimable)
    {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        LibEdenRewardsStorage.RewardProgramState memory state = accrueProgram(programId);

        uint256 checkpoint = store.positionRewardIndex[programId][positionKey];
        uint256 globalRewardIndex = state.globalRewardIndex;
        if (globalRewardIndex > checkpoint && eligibleBalance > 0) {
            store.accruedRewards[programId][positionKey] += Math.mulDiv(
                eligibleBalance, globalRewardIndex - checkpoint, LibEdenRewardsStorage.REWARD_INDEX_SCALE
            );
        }

        store.positionRewardIndex[programId][positionKey] = globalRewardIndex;
        claimable = store.accruedRewards[programId][positionKey];
    }

    function currentEligibleSupply(LibEdenRewardsStorage.RewardTarget memory target)
        internal
        view
        returns (uint256 eligibleSupply)
    {
        return _currentEligibleSupplyView(target);
    }

    function netFromGross(uint256 grossAmount, uint16 outboundTransferBps) internal pure returns (uint256 netAmount) {
        if (grossAmount == 0 || outboundTransferBps == 0) {
            return grossAmount;
        }

        uint256 feeAmount =
            Math.mulDiv(grossAmount, outboundTransferBps, LibEdenRewardsStorage.TRANSFER_FEE_BPS_SCALE);
        return grossAmount - feeAmount;
    }

    function grossUpNetAmount(uint256 netAmount, uint16 outboundTransferBps)
        internal
        pure
        returns (uint256 grossAmount)
    {
        if (netAmount == 0 || outboundTransferBps == 0) {
            return netAmount;
        }

        uint256 denominator = uint256(LibEdenRewardsStorage.TRANSFER_FEE_BPS_SCALE) - outboundTransferBps;
        grossAmount = Math.mulDiv(
            netAmount, LibEdenRewardsStorage.TRANSFER_FEE_BPS_SCALE, denominator, Math.Rounding.Ceil
        );

        while (grossAmount > 0 && netFromGross(grossAmount - 1, outboundTransferBps) >= netAmount) {
            unchecked {
                grossAmount -= 1;
            }
        }
    }

    function _previewAccrual(
        LibEdenRewardsStorage.RewardProgramConfig memory config,
        LibEdenRewardsStorage.RewardProgramState memory state,
        uint256 timestamp
    ) private pure returns (LibEdenRewardsStorage.RewardProgramState memory) {
        uint256 effectiveNow = _effectiveNow(config.endTime, timestamp);
        if (effectiveNow <= state.lastRewardUpdate) {
            return state;
        }

        if (config.closed || !config.enabled || config.paused || config.rewardRatePerSecond == 0) {
            state.lastRewardUpdate = effectiveNow;
            return state;
        }

        uint256 accrualStart = state.lastRewardUpdate;
        if (accrualStart < config.startTime) {
            accrualStart = config.startTime;
        }
        if (effectiveNow <= accrualStart) {
            state.lastRewardUpdate = effectiveNow;
            return state;
        }

        if (state.eligibleSupply == 0 || state.fundedReserve == 0) {
            state.lastRewardUpdate = effectiveNow;
            return state;
        }

        uint256 elapsed = effectiveNow - accrualStart;
        uint256 maxNetRewards = elapsed * config.rewardRatePerSecond;
        uint256 requiredGross = grossUpNetAmount(maxNetRewards, config.outboundTransferBps);
        uint256 allocatedGross = requiredGross > state.fundedReserve ? state.fundedReserve : requiredGross;
        uint256 allocatedNet = requiredGross > state.fundedReserve
            ? netFromGross(allocatedGross, config.outboundTransferBps)
            : maxNetRewards;
        if (allocatedNet > 0) {
            state.fundedReserve -= allocatedGross;
            state.globalRewardIndex += Math.mulDiv(
                allocatedNet, LibEdenRewardsStorage.REWARD_INDEX_SCALE, state.eligibleSupply
            );
        }

        state.lastRewardUpdate = effectiveNow;
        return state;
    }

    function _effectiveNow(uint256 endTime, uint256 timestamp) private pure returns (uint256 effectiveNow) {
        if (endTime != 0 && endTime < timestamp) {
            return endTime;
        }
        return timestamp;
    }

    function _currentEligibleSupply(LibEdenRewardsStorage.RewardTarget memory target)
        private
        returns (uint256 eligibleSupply)
    {
        uint256 poolId = _poolIdForTarget(target);
        if (poolId == 0) {
            return 0;
        }

        LibMaintenance.enforce(poolId);
        return LibAppStorage.s().pools[poolId].totalDeposits;
    }

    function _currentEligibleSupplyView(LibEdenRewardsStorage.RewardTarget memory target)
        private
        view
        returns (uint256 eligibleSupply)
    {
        uint256 poolId = _poolIdForTarget(target);
        if (poolId == 0) {
            return 0;
        }

        // Reward supply previews intentionally derive from authoritative pool state
        // plus any pending maintenance accrual so views match the live settle path.
        (eligibleSupply,) = LibMaintenance.previewState(poolId);
    }

    function _poolIdForTarget(LibEdenRewardsStorage.RewardTarget memory target) private view returns (uint256 poolId) {
        if (target.targetType == LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION) {
            if (!LibStEVEEligibilityStorage.s().configured) {
                return 0;
            }
            return LibStEVEStorage.s().product.poolId;
        }

        if (target.targetType == LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION) {
            return LibEqualIndexStorage.poolIdForIndex(target.targetId);
        }

        revert InvalidParameterRange("targetType");
    }
}
