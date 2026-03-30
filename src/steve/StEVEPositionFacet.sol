// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {BasketToken} from "../tokens/BasketToken.sol";
import {StEVELogic} from "./StEVELogic.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibStEVEStorage} from "../libraries/LibStEVEStorage.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibStEVERewards} from "../libraries/LibStEVERewards.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

contract StEVEPositionFacet is StEVELogic, ReentrancyGuardModifiers {
    function mintStEVEFromPosition(uint256 positionId, uint256 units)
        external
        nonReentrant
        returns (uint256 minted)
    {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        _requireStEVEConfigured();

        LibStEVEStorage.ProductConfig storage product = LibStEVEStorage.s().product;
        if (product.paused) revert IndexPaused(LibStEVEStorage.PRODUCT_ID);

        LibStEVERewards.settleBeforeEligibleBalanceChange(positionKey);

        PositionMintState memory state;
        state.required = new uint256[](product.assets.length);
        state.feeAmounts = new uint256[](product.assets.length);

        uint16 poolFeeShareBps = _basketPoolFeeShareBps();
        uint256 totalSupply = product.totalUnits;
        _prepareStEVEPositionMint(product, units, totalSupply, positionKey, poolFeeShareBps, state);

        minted = units;
        product.totalUnits += minted;
        BasketToken(product.token).mintIndexUnits(address(this), minted);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        Types.PoolData storage basketPool = app.pools[product.poolId];
        LibPoolMembership._ensurePoolMembership(positionKey, product.poolId, true);
        LibFeeIndex.settle(product.poolId, positionKey);

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

        LibStEVERewards.syncEligibleBalanceChange();
    }

    function burnStEVEFromPosition(uint256 positionId, uint256 units)
        external
        nonReentrant
        returns (uint256[] memory assetsOut)
    {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        _requireStEVEConfigured();

        LibStEVEStorage.ProductConfig storage product = LibStEVEStorage.s().product;
        if (product.paused) revert IndexPaused(LibStEVEStorage.PRODUCT_ID);
        if (units > product.totalUnits) revert InvalidUnits();

        uint256 eligibleBefore = LibStEVERewards.settleBeforeEligibleBalanceChange(positionKey);
        if (units > eligibleBefore) revert InsufficientPrincipal(units, eligibleBefore);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        Types.PoolData storage basketPool = app.pools[product.poolId];
        LibPoolMembership._ensurePoolMembership(positionKey, product.poolId, true);
        uint256 positionBalance = basketPool.userPrincipal[positionKey];
        if (units > positionBalance) revert InsufficientIndexTokens(units, positionBalance);

        PositionBurnState memory state;
        state.assetsOut = new uint256[](product.assets.length);
        state.feeAmounts = new uint256[](product.assets.length);
        _prepareStEVEPositionBurn(product, units, product.totalUnits, positionKey, _basketPoolFeeShareBps(), state);

        product.totalUnits -= units;
        BasketToken(product.token).burnIndexUnits(address(this), units);

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
        LibStEVERewards.syncEligibleBalanceChange();
        assetsOut = state.assetsOut;
    }

}
