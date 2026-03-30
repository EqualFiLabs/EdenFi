// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibEdenRewardsConsumer} from "./LibEdenRewardsConsumer.sol";
import {LibEdenRewardsStorage} from "./LibEdenRewardsStorage.sol";
import {LibFeeIndex} from "./LibFeeIndex.sol";

library LibEqualIndexRewards {
    function settleBeforeEligibleBalanceChange(uint256 indexId, uint256 indexPoolId, bytes32 positionKey)
        internal
        returns (uint256 eligibleBalance)
    {
        LibFeeIndex.settle(indexPoolId, positionKey);
        eligibleBalance = LibAppStorage.s().pools[indexPoolId].userPrincipal[positionKey];
        LibEdenRewardsConsumer.beforeTargetBalanceChange(_target(indexId), positionKey, eligibleBalance);
    }

    function syncEligibleBalanceChange(uint256 indexId, uint256 previousBalance, uint256 newBalance) internal {
        LibEdenRewardsConsumer.afterTargetBalanceChange(_target(indexId), previousBalance, newBalance);
    }

    function _target(uint256 indexId) private pure returns (LibEdenRewardsStorage.RewardTarget memory target) {
        target = LibEdenRewardsStorage.RewardTarget({
            targetType: LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            targetId: indexId
        });
    }
}
