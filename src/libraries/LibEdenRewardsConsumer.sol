// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibEdenRewardsEngine} from "./LibEdenRewardsEngine.sol";
import {LibEdenRewardsStorage} from "./LibEdenRewardsStorage.sol";
import {LibStEVEEligibilityStorage} from "./LibStEVEEligibilityStorage.sol";
import {LibEqualIndexStorage} from "./LibEqualIndexStorage.sol";
import {InvalidParameterRange} from "./Errors.sol";

library LibEdenRewardsConsumer {
    function currentEligibleSupply(LibEdenRewardsStorage.RewardTarget memory target)
        internal
        view
        returns (uint256 eligibleSupply)
    {
        if (target.targetType == LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION) {
            return LibStEVEEligibilityStorage.s().eligibleSupply;
        }

        if (target.targetType == LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION) {
            uint256 poolId = LibEqualIndexStorage.poolIdForIndex(target.targetId);
            if (poolId == 0) {
                return 0;
            }
            return LibAppStorage.s().pools[poolId].totalDeposits;
        }

        revert InvalidParameterRange("targetType");
    }

    function beforeTargetBalanceChange(
        LibEdenRewardsStorage.RewardTarget memory target,
        bytes32 positionKey,
        uint256 eligibleBalance
    ) internal {
        _settleTargetPositionPrograms(target, positionKey, eligibleBalance);
    }

    function afterTargetBalanceChange(
        LibEdenRewardsStorage.RewardTarget memory target,
        uint256 previousBalance,
        uint256 newBalance
    ) internal {
        if (previousBalance == newBalance) {
            return;
        }

        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        uint256[] storage programIds = LibEdenRewardsStorage.programIdsForTarget(store, target);
        uint256 len = programIds.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 programId = programIds[i];
            LibEdenRewardsStorage.RewardProgramState memory state = LibEdenRewardsEngine.accrueProgram(programId);
            if (newBalance > previousBalance) {
                state.eligibleSupply += newBalance - previousBalance;
            } else {
                state.eligibleSupply -= previousBalance - newBalance;
            }
            store.programs[programId].state = state;
        }
    }

    function _settleTargetPositionPrograms(
        LibEdenRewardsStorage.RewardTarget memory target,
        bytes32 positionKey,
        uint256 eligibleBalance
    ) private {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        uint256[] storage programIds = LibEdenRewardsStorage.programIdsForTarget(store, target);
        uint256 len = programIds.length;
        for (uint256 i = 0; i < len; i++) {
            LibEdenRewardsEngine.settleProgramPosition(programIds[i], positionKey, eligibleBalance);
        }
    }
}
