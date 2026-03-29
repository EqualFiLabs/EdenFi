// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {BasketToken} from "../tokens/BasketToken.sol";
import {EdenBasketLogic} from "./EdenBasketLogic.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibEdenRewards} from "../libraries/LibEdenRewards.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibEdenStEVEStorage} from "../libraries/LibEdenStEVEStorage.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

contract EdenBasketPositionFacet is EdenBasketLogic, ReentrancyGuardModifiers {
    function mintStEVEFromPosition(uint256 positionId, uint256 units)
        external
        nonReentrant
        returns (uint256 minted)
    {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        uint256 basketId = _requireStEVEConfigured();

        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        if (basket.paused) revert IndexPaused(basketId);

        LibEdenRewards.settlePositionRewards(positionKey);

        PositionMintState memory state;
        state.required = new uint256[](basket.assets.length);
        state.feeAmounts = new uint256[](basket.assets.length);

        uint16 poolFeeShareBps = _basketPoolFeeShareBps();
        uint256 totalSupply = basket.totalUnits;
        _preparePositionMint(basketId, basket, units, totalSupply, positionKey, poolFeeShareBps, state);

        minted = units;
        basket.totalUnits += minted;
        BasketToken(basket.token).mintIndexUnits(address(this), minted);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        Types.PoolData storage basketPool = app.pools[basket.poolId];
        LibPoolMembership._ensurePoolMembership(positionKey, basket.poolId, true);
        LibFeeIndex.settle(basket.poolId, positionKey);

        uint256 currentPrincipal = basketPool.userPrincipal[positionKey];
        bool isNewUser = currentPrincipal == 0;
        if (isNewUser) {
            uint256 maxUsers = basketPool.poolConfig.maxUserCount;
            if (maxUsers > 0 && basketPool.userCount >= maxUsers) revert MaxUserCountExceeded(maxUsers);
        }

        uint256 newPrincipal = currentPrincipal + minted;
        if (basketPool.poolConfig.isCapped) {
            uint256 cap = basketPool.poolConfig.depositCap;
            if (cap > 0 && newPrincipal > cap) revert DepositCapExceeded(newPrincipal, cap);
        }

        basketPool.userPrincipal[positionKey] = newPrincipal;
        basketPool.totalDeposits += minted;
        basketPool.trackedBalance += minted;
        if (isNewUser && minted > 0) {
            basketPool.userCount += 1;
        }
        basketPool.userFeeIndex[positionKey] = basketPool.feeIndex;
        basketPool.userMaintenanceIndex[positionKey] = basketPool.maintenanceIndex;

        LibEdenStEVEStorage.StEVEStorage storage steve = LibEdenStEVEStorage.s();
        steve.eligiblePrincipal[positionKey] += minted;
        steve.eligibleSupply += minted;
    }

    function burnStEVEFromPosition(uint256 positionId, uint256 units)
        external
        nonReentrant
        returns (uint256[] memory assetsOut)
    {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        uint256 basketId = _requireStEVEConfigured();

        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        if (basket.paused) revert IndexPaused(basketId);
        if (units > basket.totalUnits) revert InvalidUnits();

        LibEdenStEVEStorage.StEVEStorage storage steve = LibEdenStEVEStorage.s();
        uint256 eligible = steve.eligiblePrincipal[positionKey];
        if (units > eligible) revert InsufficientPrincipal(units, eligible);
        LibEdenRewards.settlePositionRewards(positionKey);
        steve.eligiblePrincipal[positionKey] = eligible - units;
        steve.eligibleSupply -= units;

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        Types.PoolData storage basketPool = app.pools[basket.poolId];
        LibPoolMembership._ensurePoolMembership(positionKey, basket.poolId, true);
        LibFeeIndex.settle(basket.poolId, positionKey);
        uint256 positionBalance = basketPool.userPrincipal[positionKey];
        if (units > positionBalance) revert InsufficientIndexTokens(units, positionBalance);

        PositionBurnState memory state;
        state.assetsOut = new uint256[](basket.assets.length);
        state.feeAmounts = new uint256[](basket.assets.length);
        _preparePositionBurn(
            basketId, basket, units, basket.totalUnits, positionKey, _basketPoolFeeShareBps(), state
        );

        basket.totalUnits -= units;
        BasketToken(basket.token).burnIndexUnits(address(this), units);

        uint256 newPrincipal = positionBalance - units;
        basketPool.userPrincipal[positionKey] = newPrincipal;
        basketPool.totalDeposits -= units;
        if (basketPool.trackedBalance < units) revert InsufficientPrincipal(units, basketPool.trackedBalance);
        basketPool.trackedBalance -= units;
        if (positionBalance > 0 && newPrincipal == 0 && basketPool.userCount > 0) {
            basketPool.userCount -= 1;
        }
        basketPool.userFeeIndex[positionKey] = basketPool.feeIndex;
        basketPool.userMaintenanceIndex[positionKey] = basketPool.maintenanceIndex;
        assetsOut = state.assetsOut;
    }

    function _requireStEVEConfigured() internal view returns (uint256 basketId) {
        LibEdenStEVEStorage.StEVEStorage storage steve = LibEdenStEVEStorage.s();
        if (!steve.configured) revert InvalidParameterRange("stEVE not configured");
        return steve.basketId;
    }
}
