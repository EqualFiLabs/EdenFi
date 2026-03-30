// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibEdenRewardsConsumer} from "./LibEdenRewardsConsumer.sol";
import {LibEdenRewardsStorage} from "./LibEdenRewardsStorage.sol";
import {LibFeeIndex} from "./LibFeeIndex.sol";
import {LibStEVEEligibilityStorage} from "./LibStEVEEligibilityStorage.sol";
import {LibStEVEStorage} from "./LibStEVEStorage.sol";

library LibStEVERewards {
    function settleBeforeEligibleBalanceChange(bytes32 positionKey) internal returns (uint256 eligibleBalance) {
        eligibleBalance = currentEligibleBalance(positionKey);
        LibEdenRewardsConsumer.beforeTargetBalanceChange(_target(), positionKey, eligibleBalance);
    }

    function syncEligibleBalanceChange() internal {
        LibEdenRewardsConsumer.afterTargetBalanceChange(_target());
    }

    function currentEligibleSupply() internal view returns (uint256 eligibleSupply) {
        uint256 poolId = _productPoolId();
        if (poolId == 0) {
            return 0;
        }

        return LibAppStorage.s().pools[poolId].totalDeposits;
    }

    function currentEligibleBalance(bytes32 positionKey) internal returns (uint256 eligibleBalance) {
        uint256 poolId = _productPoolId();
        if (poolId == 0) {
            return 0;
        }

        LibFeeIndex.settle(poolId, positionKey);
        return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
    }

    function previewEligibleBalance(bytes32 positionKey) internal view returns (uint256 eligibleBalance) {
        uint256 poolId = _productPoolId();
        if (poolId == 0) {
            return 0;
        }

        return LibFeeIndex.previewSettledPrincipal(poolId, positionKey);
    }

    function _target() private pure returns (LibEdenRewardsStorage.RewardTarget memory target) {
        target = LibEdenRewardsStorage.RewardTarget({
            targetType: LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            targetId: LibEdenRewardsStorage.STEVE_TARGET_ID
        });
    }

    function _productPoolId() private view returns (uint256 poolId) {
        if (!LibStEVEEligibilityStorage.s().configured) {
            return 0;
        }

        poolId = LibStEVEStorage.s().product.poolId;
    }
}
