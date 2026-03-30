// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibEdenRewardsStorage} from "./LibEdenRewardsStorage.sol";

library LibEdenRewardsEngine {
    function accrueProgram(uint256 programId)
        internal
        returns (LibEdenRewardsStorage.RewardProgramState memory state)
    {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        state = _previewAccrual(store.programs[programId].config, store.programs[programId].state, block.timestamp);
        store.programs[programId].state = state;
    }

    function previewProgramState(uint256 programId)
        internal
        view
        returns (LibEdenRewardsStorage.RewardProgramState memory state)
    {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        state = _previewAccrual(store.programs[programId].config, store.programs[programId].state, block.timestamp);
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
        uint256 maxRewards = elapsed * config.rewardRatePerSecond;
        uint256 allocated = maxRewards > state.fundedReserve ? state.fundedReserve : maxRewards;
        if (allocated > 0) {
            state.fundedReserve -= allocated;
            state.globalRewardIndex += Math.mulDiv(
                allocated, LibEdenRewardsStorage.REWARD_INDEX_SCALE, state.eligibleSupply
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
}
