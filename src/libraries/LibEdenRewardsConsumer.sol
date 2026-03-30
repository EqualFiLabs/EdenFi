// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibEdenRewardsEngine} from "./LibEdenRewardsEngine.sol";
import {LibEdenRewardsStorage} from "./LibEdenRewardsStorage.sol";

library LibEdenRewardsConsumer {
    function currentEligibleSupply(LibEdenRewardsStorage.RewardTarget memory target)
        internal
        view
        returns (uint256 eligibleSupply)
    {
        return LibEdenRewardsEngine.currentEligibleSupply(target);
    }

    function beforeTargetBalanceChange(
        LibEdenRewardsStorage.RewardTarget memory target,
        bytes32 positionKey,
        uint256 eligibleBalance
    ) internal {
        _settleTargetPositionPrograms(target, positionKey, eligibleBalance);
    }

    function afterTargetBalanceChange(LibEdenRewardsStorage.RewardTarget memory target) internal {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        uint256[] storage programIds = LibEdenRewardsStorage.programIdsForTarget(store, target);
        uint256 len = programIds.length;
        uint256 eligibleSupply = currentEligibleSupply(target);
        for (uint256 i = 0; i < len; i++) {
            uint256 programId = programIds[i];
            store.programs[programId].state.eligibleSupply = eligibleSupply;
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
