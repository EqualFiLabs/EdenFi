// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {EdenBasketBase} from "./EdenBasketBase.sol";
import {EdenBasketFacet} from "./EdenBasketFacet.sol";
import {PositionManagementFacet} from "../equallend/PositionManagementFacet.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibEdenStEVEStorage} from "../libraries/LibEdenStEVEStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {StEVEToken} from "../tokens/StEVEToken.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

contract EdenStEVEFacet is EdenBasketFacet, PositionManagementFacet {
    event StEVEConfigured(uint256 indexed basketId, address indexed token);
    event StEVEDepositedToPosition(uint256 indexed tokenId, bytes32 indexed positionKey, uint256 amount);
    event StEVEWithdrawnFromPosition(uint256 indexed tokenId, bytes32 indexed positionKey, uint256 amount);

    function createStEVE(EdenBasketBase.CreateBasketParams calldata params)
        external
        nonReentrant
        returns (uint256 basketId, address token)
    {
        LibAccess.enforceTimelockOrOwnerIfUnset();
        if (LibEdenStEVEStorage.s().configured) revert InvalidParameterRange("stEVE already configured");
        if (params.assets.length != 1) revert InvalidBundleDefinition();
        if (params.basketType != 1) revert InvalidParameterRange("stEVE basketType");
        _validateCreateParams(params);
        if (LibAppStorage.s().assetToPoolId[params.assets[0]] == 0) revert NoPoolForAsset(params.assets[0]);

        basketId = LibEdenBasketStorage.s().basketCount;
        token = address(new StEVEToken(params.name, params.symbol, address(this), basketId));
        _createBasketInternal(params, basketId, token);

        LibEdenStEVEStorage.StEVEStorage storage store = LibEdenStEVEStorage.s();
        store.configured = true;
        store.basketId = basketId;

        emit StEVEConfigured(basketId, token);
    }

    function depositStEVEToPosition(uint256 tokenId, uint256 amount, uint256 maxAmount)
        external
        payable
        nonReentrant
        virtual
        returns (uint256 received)
    {
        LibEdenStEVEStorage.StEVEStorage storage store = LibEdenStEVEStorage.s();
        if (!store.configured) revert InvalidParameterRange("stEVE not configured");

        uint256 pid = LibEdenBasketStorage.s().baskets[store.basketId].poolId;
        if (amount == 0) revert InvalidParameterRange("amount=0");
        _requireOwnership(tokenId);
        Types.PoolData storage pool = _pool(pid);
        LibCurrency.assertMsgValue(pool.underlying, amount);

        bytes32 positionKey = _getPositionKey(tokenId);
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);

        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);
        _beforeEligiblePrincipalChange(positionKey);

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

        store.eligiblePrincipal[positionKey] += received;
        store.eligibleSupply += received;

        emit StEVEDepositedToPosition(tokenId, positionKey, received);
    }

    function withdrawStEVEFromPosition(uint256 tokenId, uint256 amount, uint256 minReceived)
        external
        payable
        nonReentrant
        virtual
        returns (uint256 withdrawn)
    {
        LibEdenStEVEStorage.StEVEStorage storage store = LibEdenStEVEStorage.s();
        if (!store.configured) revert InvalidParameterRange("stEVE not configured");

        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        uint256 eligible = store.eligiblePrincipal[positionKey];
        if (amount > eligible) revert InsufficientPrincipal(amount, eligible);

        uint256 pid = LibEdenBasketStorage.s().baskets[store.basketId].poolId;
        _requireOwnership(tokenId);
        Types.PoolData storage pool = _pool(pid);
        LibPoolMembership._ensurePoolMembership(positionKey, pid, true);

        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);
        _beforeEligiblePrincipalChange(positionKey);

        uint256 currentPrincipal = pool.userPrincipal[positionKey];
        uint256 totalEncumbered = pool.userSameAssetDebt[positionKey];
        uint256 encumbrance = LibEncumbrance.total(positionKey, pid);
        if (encumbrance > totalEncumbered) {
            totalEncumbered = encumbrance;
        }
        if (totalEncumbered > currentPrincipal) revert InsufficientPrincipal(totalEncumbered, currentPrincipal);

        uint256 availablePrincipal = currentPrincipal - totalEncumbered;
        if (amount > availablePrincipal) revert InsufficientPrincipal(amount, availablePrincipal);

        uint256 newPrincipal = currentPrincipal - amount;
        pool.userPrincipal[positionKey] = newPrincipal;
        pool.totalDeposits -= amount;
        pool.trackedBalance -= amount;
        if (newPrincipal == 0 && pool.userCount > 0) {
            pool.userCount -= 1;
        }
        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }

        LibCurrency.transferWithMin(pool.underlying, msg.sender, amount, minReceived);
        withdrawn = amount;

        store.eligiblePrincipal[positionKey] = eligible - withdrawn;
        store.eligibleSupply -= withdrawn;

        emit StEVEWithdrawnFromPosition(tokenId, positionKey, withdrawn);
    }

    function mintBasketFromPosition(uint256 positionId, uint256 basketId, uint256 units)
        public
        override
        basketExists(basketId)
        virtual
        returns (uint256 minted)
    {
        LibEdenStEVEStorage.StEVEStorage storage store = LibEdenStEVEStorage.s();
        if (store.configured && basketId == store.basketId) {
            bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
            _beforeEligiblePrincipalChange(positionKey);
            minted = super.mintBasketFromPosition(positionId, basketId, units);
            store.eligiblePrincipal[positionKey] += minted;
            store.eligibleSupply += minted;
            return minted;
        }

        minted = super.mintBasketFromPosition(positionId, basketId, units);
    }

    function burnBasketFromPosition(uint256 positionId, uint256 basketId, uint256 units)
        public
        override
        basketExists(basketId)
        virtual
        returns (uint256[] memory assetsOut)
    {
        LibEdenStEVEStorage.StEVEStorage storage store = LibEdenStEVEStorage.s();
        if (store.configured && basketId == store.basketId) {
            bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
            uint256 eligible = store.eligiblePrincipal[positionKey];
            if (units > eligible) revert InsufficientPrincipal(units, eligible);
            _beforeEligiblePrincipalChange(positionKey);
            store.eligiblePrincipal[positionKey] = eligible - units;
            store.eligibleSupply -= units;
        }

        assetsOut = super.burnBasketFromPosition(positionId, basketId, units);
    }

    function steveBasketId() external view returns (uint256) {
        if (!LibEdenStEVEStorage.s().configured) revert InvalidParameterRange("stEVE not configured");
        return LibEdenStEVEStorage.s().basketId;
    }

    function eligibleSupply() external view returns (uint256) {
        return LibEdenStEVEStorage.s().eligibleSupply;
    }

    function eligiblePrincipalOfPosition(uint256 tokenId) external view returns (uint256) {
        return LibEdenStEVEStorage.s().eligiblePrincipal[LibPositionHelpers.positionKey(tokenId)];
    }

    function _beforeEligiblePrincipalChange(bytes32 positionKey) internal virtual {}
}
