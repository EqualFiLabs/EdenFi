// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {Types} from "../libraries/Types.sol";
import {
    DepositCapExceeded,
    InvalidParameterRange,
    MaxUserCountExceeded,
    PoolNotInitialized
} from "../libraries/Errors.sol";

abstract contract StEVEPoolHelpers {
    function _pool(uint256 pid) internal view returns (Types.PoolData storage p) {
        p = LibPositionHelpers.pool(pid);
        if (!p.initialized) {
            revert PoolNotInitialized(pid);
        }
    }

    function _requireOwnership(uint256 tokenId) internal view {
        LibPositionHelpers.requireOwnership(tokenId);
    }

    function _getPositionKey(uint256 tokenId) internal view returns (bytes32) {
        return LibPositionHelpers.positionKey(tokenId);
    }

    function _assertTokenPool(uint256 tokenId, uint256 pid) internal view {
        if (LibPositionHelpers.derivePoolId(tokenId) != pid) {
            revert InvalidParameterRange("token pool mismatch");
        }
    }

    function _enforceDepositCap(Types.PoolData storage p, uint256 newPrincipal) internal view {
        if (!p.poolConfig.isCapped) {
            return;
        }
        uint256 cap = p.poolConfig.depositCap;
        if (cap > 0 && newPrincipal > cap) {
            revert DepositCapExceeded(newPrincipal, cap);
        }
    }

    function _enforceMaxUsers(Types.PoolData storage p, bool isNewUser) internal view {
        if (!isNewUser) {
            return;
        }
        uint256 maxUsers = p.poolConfig.maxUserCount;
        if (maxUsers > 0 && p.userCount >= maxUsers) {
            revert MaxUserCountExceeded(maxUsers);
        }
    }
}
