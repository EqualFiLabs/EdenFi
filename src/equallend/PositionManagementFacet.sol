// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {
    DepositBelowMinimum,
    DepositCapExceeded,
    InsufficientPrincipal,
    InvalidParameterRange,
    MaxUserCountExceeded,
    PoolNotInitialized
} from "../libraries/Errors.sol";

/// @title PositionManagementFacet
/// @notice Minimal Position NFT lifecycle and principal management for EDEN-facing substrate work.
contract PositionManagementFacet is ReentrancyGuardModifiers {
    event PositionMinted(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId);
    event DepositedToPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 amount,
        uint256 newPrincipal
    );
    event WithdrawnFromPosition(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 principalWithdrawn,
        uint256 remainingPrincipal
    );

    function mintPosition(uint256 pid) external payable nonReentrant returns (uint256 tokenId) {
        LibCurrency.assertZeroMsgValue();
        _pool(pid);

        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        tokenId = nft.mint(msg.sender, pid);

        emit PositionMinted(tokenId, msg.sender, pid);
    }

    function depositToPosition(
        uint256 tokenId,
        uint256 pid,
        uint256 amount,
        uint256 maxAmount
    ) external payable nonReentrant {
        _depositToPosition(tokenId, pid, amount, maxAmount, msg.sender);
    }

    function withdrawFromPosition(
        uint256 tokenId,
        uint256 pid,
        uint256 principalToWithdraw,
        uint256 minReceived
    ) external payable nonReentrant {
        _withdrawFromPosition(tokenId, pid, principalToWithdraw, minReceived, msg.sender);
    }

    function cleanupMembership(uint256 tokenId, uint256 pid) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        _requireOwnership(tokenId);
        _assertTokenPool(tokenId, pid);

        bytes32 positionKey = _getPositionKey(tokenId);
        LibPositionHelpers.ensurePoolMembership(positionKey, pid, true);
        (bool canClear, string memory reason) = LibPoolMembership.canClearMembership(positionKey, pid);
        LibPoolMembership._leavePool(positionKey, pid, canClear, reason);
    }

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

    function _depositToPosition(
        uint256 tokenId,
        uint256 pid,
        uint256 amount,
        uint256 maxAmount,
        address fundingAccount
    ) internal returns (uint256 received) {
        if (amount == 0) {
            revert InvalidParameterRange("amount=0");
        }

        _requireOwnership(tokenId);
        _assertTokenPool(tokenId, pid);

        Types.PoolData storage p = _pool(pid);
        LibCurrency.assertMsgValue(p.underlying, amount);

        bytes32 positionKey = _getPositionKey(tokenId);
        LibPositionHelpers.ensurePoolMembership(positionKey, pid, true);

        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);

        uint256 currentPrincipal = p.userPrincipal[positionKey];
        bool isNewUser = currentPrincipal == 0;
        _enforceMaxUsers(p, isNewUser);

        received = LibCurrency.pullAtLeast(p.underlying, fundingAccount, amount, maxAmount);
        if (received < p.poolConfig.minDepositAmount) {
            revert DepositBelowMinimum(received, p.poolConfig.minDepositAmount);
        }

        uint256 newPrincipal = currentPrincipal + received;
        _enforceDepositCap(p, newPrincipal);

        p.userPrincipal[positionKey] = newPrincipal;
        p.totalDeposits += received;
        p.trackedBalance += received;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
        if (isNewUser) {
            p.userCount += 1;
        }

        emit DepositedToPosition(tokenId, msg.sender, pid, received, newPrincipal);
    }

    function _withdrawFromPosition(
        uint256 tokenId,
        uint256 pid,
        uint256 principalToWithdraw,
        uint256 minReceived,
        address recipient
    ) internal returns (uint256 withdrawn) {
        LibCurrency.assertZeroMsgValue();
        if (principalToWithdraw == 0) {
            revert InvalidParameterRange("amount=0");
        }

        _requireOwnership(tokenId);
        _assertTokenPool(tokenId, pid);

        Types.PoolData storage p = _pool(pid);
        bytes32 positionKey = _getPositionKey(tokenId);
        LibPositionHelpers.ensurePoolMembership(positionKey, pid, true);

        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);

        uint256 currentPrincipal = p.userPrincipal[positionKey];
        uint256 totalEncumbered = p.userSameAssetDebt[positionKey];
        uint256 encumbrance = LibEncumbrance.total(positionKey, pid);
        if (encumbrance > totalEncumbered) {
            totalEncumbered = encumbrance;
        }

        if (totalEncumbered > currentPrincipal) {
            revert InsufficientPrincipal(totalEncumbered, currentPrincipal);
        }

        uint256 availablePrincipal = currentPrincipal - totalEncumbered;
        if (principalToWithdraw > availablePrincipal) {
            revert InsufficientPrincipal(principalToWithdraw, availablePrincipal);
        }

        uint256 newPrincipal = currentPrincipal - principalToWithdraw;
        p.userPrincipal[positionKey] = newPrincipal;
        p.totalDeposits -= principalToWithdraw;
        p.trackedBalance -= principalToWithdraw;
        if (newPrincipal == 0 && p.userCount > 0) {
            p.userCount -= 1;
        }
        if (LibCurrency.isNative(p.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= principalToWithdraw;
        }

        LibCurrency.transferWithMin(p.underlying, recipient, principalToWithdraw, minReceived);
        withdrawn = principalToWithdraw;

        emit WithdrawnFromPosition(tokenId, msg.sender, pid, principalToWithdraw, newPrincipal);
    }
}
