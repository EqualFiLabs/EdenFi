// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibEdenRewardsConsumer} from "./LibEdenRewardsConsumer.sol";
import {LibEdenRewardsStorage} from "./LibEdenRewardsStorage.sol";
import {LibStEVEEligibilityStorage} from "./LibStEVEEligibilityStorage.sol";

library LibStEVERewards {
    function settleBeforeEligibleBalanceChange(bytes32 positionKey) internal returns (uint256 eligibleBalance) {
        eligibleBalance = LibStEVEEligibilityStorage.s().eligiblePrincipal[positionKey];
        LibEdenRewardsConsumer.beforeTargetBalanceChange(_target(), positionKey, eligibleBalance);
    }

    function syncEligibleBalanceChange(bytes32 positionKey, uint256 previousBalance, uint256 newBalance) internal {
        LibStEVEEligibilityStorage.EligibilityStorage storage store = LibStEVEEligibilityStorage.s();
        store.eligiblePrincipal[positionKey] = newBalance;
        if (newBalance > previousBalance) {
            store.eligibleSupply += newBalance - previousBalance;
        } else if (previousBalance > newBalance) {
            store.eligibleSupply -= previousBalance - newBalance;
        }

        LibEdenRewardsConsumer.afterTargetBalanceChange(_target(), previousBalance, newBalance);
    }

    function _target() private pure returns (LibEdenRewardsStorage.RewardTarget memory target) {
        target = LibEdenRewardsStorage.RewardTarget({
            targetType: LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            targetId: LibEdenRewardsStorage.STEVE_TARGET_ID
        });
    }
}
