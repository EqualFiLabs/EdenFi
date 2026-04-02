// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    PoolMembershipRequired,
    MembershipAlreadyExists,
    CannotClearMembership,
    WhitelistRequired
} from "./Errors.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {Types} from "./Types.sol";
import {LibEncumbrance} from "./LibEncumbrance.sol";

/// @title LibPoolMembership
/// @notice Minimal storage and helpers for managing position membership across pools.
library LibPoolMembership {
    bytes32 internal constant POOL_MEMBERSHIP_STORAGE_POSITION =
        keccak256("equal.lend.pool.membership.storage");

    struct PoolMembershipStorage {
        mapping(bytes32 => mapping(uint256 => bool)) joined;
    }

    function s() internal pure returns (PoolMembershipStorage storage ps) {
        bytes32 position = POOL_MEMBERSHIP_STORAGE_POSITION;
        assembly {
            ps.slot := position
        }
    }

    function _ensurePoolMembership(bytes32 positionKey, uint256 pid, bool allowAutoJoin)
        internal
        returns (bool alreadyMember)
    {
        PoolMembershipStorage storage store = s();
        alreadyMember = store.joined[positionKey][pid];
        if (alreadyMember) {
            return true;
        }

        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (p.isManagedPool && p.whitelistEnabled && !p.whitelist[positionKey]) {
            revert WhitelistRequired(positionKey, pid);
        }

        if (!allowAutoJoin) {
            revert PoolMembershipRequired(positionKey, pid);
        }

        store.joined[positionKey][pid] = true;
        return false;
    }

    function _joinPool(bytes32 positionKey, uint256 pid) internal {
        PoolMembershipStorage storage store = s();
        if (store.joined[positionKey][pid]) {
            revert MembershipAlreadyExists(positionKey, pid);
        }
        store.joined[positionKey][pid] = true;
    }

    function _leavePool(bytes32 positionKey, uint256 pid, bool canClear, string memory reason) internal {
        PoolMembershipStorage storage store = s();
        if (!store.joined[positionKey][pid]) {
            revert PoolMembershipRequired(positionKey, pid);
        }
        if (!canClear) {
            revert CannotClearMembership(positionKey, pid, reason);
        }
        delete store.joined[positionKey][pid];
    }

    function isMember(bytes32 positionKey, uint256 pid) internal view returns (bool) {
        return s().joined[positionKey][pid];
    }

    function canClearMembership(bytes32 positionKey, uint256 pid)
        internal
        view
        returns (bool canClear, string memory reason)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];

        if (p.userPrincipal[positionKey] > 0) {
            return (false, "principal>0");
        }
        if (p.userSameAssetDebt[positionKey] > 0) {
            return (false, "same-asset debt");
        }
        if (p.activeFixedLoanCount[positionKey] > 0) {
            return (false, "active fixed loans");
        }

        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        if (loan.active && loan.principalRemaining > 0) {
            return (false, "rolling loan active");
        }

        if (LibEncumbrance.total(positionKey, pid) > 0) {
            return (false, "encumbered");
        }

        return (true, "");
    }
}
