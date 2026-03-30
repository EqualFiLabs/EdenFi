// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {EdenBasketBase} from "./EdenBasketBase.sol";
import {EdenStEVELogic} from "./EdenStEVELogic.sol";
import {EdenPositionPoolHelpers} from "./EdenPositionPoolHelpers.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibEdenStEVEStorage} from "../libraries/LibEdenStEVEStorage.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibStEVERewards} from "../libraries/LibStEVERewards.sol";
import {StEVEToken} from "../tokens/StEVEToken.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

contract EdenStEVEActionFacet is EdenStEVELogic, EdenPositionPoolHelpers, ReentrancyGuardModifiers {
    event StEVEConfigured(uint256 indexed basketId, address indexed token);
    event StEVEDepositedToPosition(uint256 indexed tokenId, bytes32 indexed positionKey, uint256 amount);
    event StEVEWithdrawnFromPosition(uint256 indexed tokenId, bytes32 indexed positionKey, uint256 amount);

    function createStEVE(EdenBasketBase.CreateBasketParams calldata params)
        external
        nonReentrant
        returns (uint256 productId, address token)
    {
        LibAccess.enforceTimelockOrOwnerIfUnset();
        if (LibEdenStEVEStorage.s().configured) revert InvalidParameterRange("stEVE already configured");
        if (params.assets.length != 1) revert InvalidBundleDefinition();
        if (params.basketType != 1) revert InvalidParameterRange("stEVE basketType");
        _validateCreateParams(params);
        if (LibAppStorage.s().assetToPoolId[params.assets[0]] == 0) revert NoPoolForAsset(params.assets[0]);

        productId = LibEdenBasketStorage.PRODUCT_ID;
        token = address(new StEVEToken(params.name, params.symbol, address(this)));
        _configureStEVEProduct(params, token);

        LibEdenStEVEStorage.StEVEStorage storage store = LibEdenStEVEStorage.s();
        store.configured = true;

        emit StEVEConfigured(productId, token);
    }

    function depositStEVEToPosition(uint256 tokenId, uint256 amount, uint256 maxAmount)
        external
        payable
        nonReentrant
        returns (uint256 received)
    {
        LibEdenStEVEStorage.StEVEStorage storage store = LibEdenStEVEStorage.s();
        if (!store.configured) revert InvalidParameterRange("stEVE not configured");

        uint256 pid = LibEdenBasketStorage.s().product.poolId;
        if (amount == 0) revert InvalidParameterRange("amount=0");
        _requireOwnership(tokenId);
        Types.PoolData storage pool = _pool(pid);
        LibCurrency.assertMsgValue(pool.underlying, amount);

        bytes32 positionKey = _getPositionKey(tokenId);
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);

        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);
        uint256 eligibleBefore = LibStEVERewards.settleBeforeEligibleBalanceChange(positionKey);

        uint256 currentPrincipal = pool.userPrincipal[positionKey];
        bool isNewUser = currentPrincipal == 0;
        _enforceMaxUsers(pool, isNewUser);

        received = LibCurrency.pullAtLeast(pool.underlying, msg.sender, amount, maxAmount);
        if (received < pool.poolConfig.minDepositAmount) {
            revert DepositBelowMinimum(received, pool.poolConfig.minDepositAmount);
        }

        uint256 newPrincipal = currentPrincipal + received;
        _enforceDepositCap(pool, newPrincipal);

        pool.userPrincipal[positionKey] = newPrincipal;
        pool.totalDeposits += received;
        pool.trackedBalance += received;
        pool.userFeeIndex[positionKey] = pool.feeIndex;
        pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
        if (isNewUser) {
            pool.userCount += 1;
        }

        LibStEVERewards.syncEligibleBalanceChange(positionKey, eligibleBefore, eligibleBefore + received);

        emit StEVEDepositedToPosition(tokenId, positionKey, received);
    }

    function withdrawStEVEFromPosition(uint256 tokenId, uint256 amount, uint256 minReceived)
        external
        payable
        nonReentrant
        returns (uint256 withdrawn)
    {
        LibEdenStEVEStorage.StEVEStorage storage store = LibEdenStEVEStorage.s();
        if (!store.configured) revert InvalidParameterRange("stEVE not configured");

        bytes32 positionKey = _getPositionKey(tokenId);
        uint256 eligible = store.eligiblePrincipal[positionKey];
        if (amount > eligible) revert InsufficientPrincipal(amount, eligible);

        uint256 pid = LibEdenBasketStorage.s().product.poolId;
        _requireOwnership(tokenId);
        Types.PoolData storage pool = _pool(pid);
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);

        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);
        uint256 eligibleBefore = LibStEVERewards.settleBeforeEligibleBalanceChange(positionKey);

        if (LibEncumbrance.total(positionKey, pid) > eligible - amount) {
            revert InsufficientUnencumberedPrincipal(amount, eligible - amount);
        }

        if (amount > pool.trackedBalance) revert InsufficientPrincipal(amount, pool.trackedBalance);
        pool.userPrincipal[positionKey] -= amount;
        pool.totalDeposits -= amount;
        pool.trackedBalance -= amount;
        pool.userFeeIndex[positionKey] = pool.feeIndex;
        pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
        if (pool.userPrincipal[positionKey] == 0 && pool.userCount > 0) {
            pool.userCount -= 1;
        }
        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }

        LibStEVERewards.syncEligibleBalanceChange(positionKey, eligibleBefore, eligible - amount);
        withdrawn = LibCurrency.transferWithMin(pool.underlying, msg.sender, amount, minReceived);

        emit StEVEWithdrawnFromPosition(tokenId, positionKey, withdrawn);
    }

    function eligibleSupply() external view returns (uint256) {
        return LibEdenStEVEStorage.s().eligibleSupply;
    }

    function eligiblePrincipalOfPosition(uint256 tokenId) external view returns (uint256) {
        return LibEdenStEVEStorage.s().eligiblePrincipal[_getPositionKey(tokenId)];
    }
}
