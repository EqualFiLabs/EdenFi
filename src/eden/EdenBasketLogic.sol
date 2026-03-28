// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EdenBasketBase} from "./EdenBasketBase.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibModuleEncumbrance} from "../libraries/LibModuleEncumbrance.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

abstract contract EdenBasketLogic is EdenBasketBase {
    event BasketCreated(
        uint256 indexed basketId,
        address indexed token,
        address[] assets,
        uint256[] bundleAmounts
    );

    function _prepareWalletMint(
        uint256 basketId,
        LibEdenBasketStorage.BasketConfig storage basket,
        uint256 units,
        uint256[] calldata maxInputAmounts,
        WalletMintState memory state
    ) internal {
        uint256 totalSupply = basket.totalUnits;
        uint256 len = basket.assets.length;
        for (uint256 i = 0; i < len; i++) {
            WalletMintLeg memory leg = _quoteWalletMintLeg(basketId, basket, i, units, totalSupply);
            uint256 received = LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.totalRequired, maxInputAmounts[i]);
            _applyWalletMintLeg(basketId, i, leg, received, state);
        }
    }

    function _applyWalletMintLeg(
        uint256 basketId,
        uint256 i,
        WalletMintLeg memory leg,
        uint256 received,
        WalletMintState memory state
    ) internal {
        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();
        uint256 surplus = received - leg.totalRequired;
        store.vaultBalances[basketId][leg.asset] += leg.baseDeposit + surplus;
        if (leg.potBuyIn > 0) {
            store.feePots[basketId][leg.asset] += leg.potBuyIn;
        }
        _distributeWalletBasketFee(basketId, leg.asset, leg.fee);
        state.required[i] = leg.totalRequired;
        state.feeAmounts[i] = leg.fee;
    }

    function _quoteWalletMintLeg(
        uint256 basketId,
        LibEdenBasketStorage.BasketConfig storage basket,
        uint256 i,
        uint256 units,
        uint256 totalSupply
    ) internal view returns (WalletMintLeg memory leg) {
        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();
        leg.asset = basket.assets[i];
        if (totalSupply == 0) {
            leg.baseDeposit = Math.mulDiv(basket.bundleAmounts[i], units, UNIT_SCALE);
        } else {
            uint256 economicBalance = store.vaultBalances[basketId][leg.asset];
            leg.baseDeposit = Math.mulDiv(economicBalance, units, totalSupply, Math.Rounding.Ceil);
            leg.potBuyIn = Math.mulDiv(store.feePots[basketId][leg.asset], units, totalSupply, Math.Rounding.Ceil);
        }
        leg.grossInput = leg.baseDeposit + leg.potBuyIn;
        leg.fee = Math.mulDiv(leg.grossInput, basket.mintFeeBps[i], BPS_DENOMINATOR, Math.Rounding.Ceil);
        leg.totalRequired = leg.grossInput + leg.fee;
    }

    function _prepareWalletBurn(
        uint256 basketId,
        LibEdenBasketStorage.BasketConfig storage basket,
        uint256 units,
        address to,
        WalletBurnState memory state
    ) internal {
        uint256 totalSupply = basket.totalUnits;
        uint256 len = basket.assets.length;
        for (uint256 i = 0; i < len; i++) {
            WalletBurnLeg memory leg = _quoteWalletBurnLeg(basketId, basket, i, units, totalSupply);
            _applyWalletBurnLeg(basketId, i, leg, to, state);
        }
    }

    function _applyWalletBurnLeg(
        uint256 basketId,
        uint256 i,
        WalletBurnLeg memory leg,
        address to,
        WalletBurnState memory state
    ) internal {
        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();
        store.vaultBalances[basketId][leg.asset] -= leg.bundleOut;
        store.feePots[basketId][leg.asset] -= leg.potShare;
        _distributeWalletBasketFee(basketId, leg.asset, leg.fee);
        LibCurrency.transfer(leg.asset, to, leg.payout);
        state.assetsOut[i] = leg.payout;
        state.feeAmounts[i] = leg.fee;
    }

    function _quoteWalletBurnLeg(
        uint256 basketId,
        LibEdenBasketStorage.BasketConfig storage basket,
        uint256 i,
        uint256 units,
        uint256 totalSupply
    ) internal view returns (WalletBurnLeg memory leg) {
        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();
        leg.asset = basket.assets[i];
        leg.bundleOut = Math.mulDiv(basket.bundleAmounts[i], units, UNIT_SCALE);
        uint256 vaultBalance = store.vaultBalances[basketId][leg.asset];
        if (vaultBalance < leg.bundleOut) revert InsufficientPoolLiquidity(leg.bundleOut, vaultBalance);
        leg.potShare = Math.mulDiv(store.feePots[basketId][leg.asset], units, totalSupply);
        uint256 gross = leg.bundleOut + leg.potShare;
        leg.fee = Math.mulDiv(gross, basket.burnFeeBps[i], BPS_DENOMINATOR);
        leg.payout = gross - leg.fee;
    }

    function _preparePositionMint(
        uint256 basketId,
        LibEdenBasketStorage.BasketConfig storage basket,
        uint256 units,
        uint256 totalSupply,
        bytes32 positionKey,
        uint16 poolFeeShareBps,
        PositionMintState memory state
    ) internal {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 len = basket.assets.length;
        for (uint256 i = 0; i < len; i++) {
            PositionMintLeg memory leg = _quotePositionMintLeg(basketId, basket, i, units, totalSupply, app);
            _applyPositionMintLeg(app, basketId, positionKey, i, leg, poolFeeShareBps, state);
        }
    }

    function _quotePositionMintLeg(
        uint256 basketId,
        LibEdenBasketStorage.BasketConfig storage basket,
        uint256 i,
        uint256 units,
        uint256 totalSupply,
        LibAppStorage.AppStorage storage app
    ) internal view returns (PositionMintLeg memory leg) {
        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();
        leg.asset = basket.assets[i];
        leg.poolId = app.assetToPoolId[leg.asset];
        if (leg.poolId == 0) revert NoPoolForAsset(leg.asset);

        if (totalSupply == 0) {
            leg.baseDeposit = Math.mulDiv(basket.bundleAmounts[i], units, UNIT_SCALE);
        } else {
            uint256 economicBalance = store.vaultBalances[basketId][leg.asset];
            leg.baseDeposit = Math.mulDiv(economicBalance, units, totalSupply, Math.Rounding.Ceil);
            leg.potBuyIn = Math.mulDiv(store.feePots[basketId][leg.asset], units, totalSupply, Math.Rounding.Ceil);
        }

        leg.grossInput = leg.baseDeposit + leg.potBuyIn;
        leg.fee = Math.mulDiv(leg.grossInput, basket.mintFeeBps[i], BPS_DENOMINATOR, Math.Rounding.Ceil);
        leg.totalRequired = leg.grossInput + leg.fee;
    }

    function _applyPositionMintLeg(
        LibAppStorage.AppStorage storage app,
        uint256 basketId,
        bytes32 positionKey,
        uint256 i,
        PositionMintLeg memory leg,
        uint16 poolFeeShareBps,
        PositionMintState memory state
    ) internal {
        if (!LibPoolMembership.isMember(positionKey, leg.poolId)) {
            revert NotMemberOfRequiredPool(positionKey, leg.poolId);
        }

        Types.PoolData storage pool = app.pools[leg.poolId];
        uint256 available = _availablePrincipal(pool, positionKey, leg.poolId);
        if (available < leg.totalRequired) {
            revert InsufficientUnencumberedPrincipal(leg.totalRequired, available);
        }

        state.required[i] = leg.grossInput;
        state.feeAmounts[i] = leg.fee;

        LibModuleEncumbrance.encumber(positionKey, leg.poolId, _basketEncumbranceId(basketId), leg.baseDeposit);
        LibEdenBasketStorage.s().vaultBalances[basketId][leg.asset] += leg.baseDeposit;

        if (leg.potBuyIn > 0 || leg.fee > 0) {
            LibFeeIndex.settle(leg.poolId, positionKey);
            uint256 principal = pool.userPrincipal[positionKey];
            uint256 deduction = leg.potBuyIn + leg.fee;
            if (principal < deduction) revert InsufficientPrincipal(deduction, principal);
            pool.userPrincipal[positionKey] = principal - deduction;
            pool.totalDeposits -= deduction;
        }

        if (leg.potBuyIn > 0) {
            if (pool.trackedBalance < leg.potBuyIn) {
                revert InsufficientPoolLiquidity(leg.potBuyIn, pool.trackedBalance);
            }
            pool.trackedBalance -= leg.potBuyIn;
            LibEdenBasketStorage.s().feePots[basketId][leg.asset] += leg.potBuyIn;
        }

        if (leg.fee > 0) {
            uint256 poolShare = Math.mulDiv(leg.fee, poolFeeShareBps, BPS_DENOMINATOR);
            uint256 potFee = leg.fee - poolShare;
            if (potFee > 0) {
                if (pool.trackedBalance < potFee) revert InsufficientPoolLiquidity(potFee, pool.trackedBalance);
                pool.trackedBalance -= potFee;
                LibEdenBasketStorage.s().feePots[basketId][leg.asset] += potFee;
            }
            if (poolShare > 0) {
                LibFeeRouter.routeManagedShare(leg.poolId, poolShare, _basketFeeSource(basketId), true, 0);
            }
        }
    }

    function _preparePositionBurn(
        uint256 basketId,
        LibEdenBasketStorage.BasketConfig storage basket,
        uint256 units,
        uint256 totalSupply,
        bytes32 positionKey,
        uint16 poolFeeShareBps,
        PositionBurnState memory state
    ) internal {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 len = basket.assets.length;
        for (uint256 i = 0; i < len; i++) {
            PositionBurnLeg memory leg = _quotePositionBurnLeg(basketId, basket, i, units, totalSupply, poolFeeShareBps);
            _applyPositionBurnLeg(app, basketId, positionKey, i, leg, state);
        }
    }

    function _quotePositionBurnLeg(
        uint256 basketId,
        LibEdenBasketStorage.BasketConfig storage basket,
        uint256 i,
        uint256 units,
        uint256 totalSupply,
        uint16 poolFeeShareBps
    ) internal view returns (PositionBurnLeg memory leg) {
        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();
        leg.asset = basket.assets[i];
        leg.bundleOut = Math.mulDiv(basket.bundleAmounts[i], units, UNIT_SCALE);
        uint256 vaultBalance = store.vaultBalances[basketId][leg.asset];
        if (vaultBalance < leg.bundleOut) revert InsufficientPoolLiquidity(leg.bundleOut, vaultBalance);
        leg.potShare = Math.mulDiv(store.feePots[basketId][leg.asset], units, totalSupply);
        uint256 gross = leg.bundleOut + leg.potShare;
        leg.fee = Math.mulDiv(gross, basket.burnFeeBps[i], BPS_DENOMINATOR);
        leg.payout = gross - leg.fee;
        leg.poolShare = Math.mulDiv(leg.fee, poolFeeShareBps, BPS_DENOMINATOR);
        leg.potFee = leg.fee - leg.poolShare;
    }

    function _applyPositionBurnLeg(
        LibAppStorage.AppStorage storage app,
        uint256 basketId,
        bytes32 positionKey,
        uint256 i,
        PositionBurnLeg memory leg,
        PositionBurnState memory state
    ) internal {
        uint256 poolId = app.assetToPoolId[leg.asset];
        if (poolId == 0) revert NoPoolForAsset(leg.asset);

        LibPoolMembership._ensurePoolMembership(positionKey, poolId, true);
        Types.PoolData storage pool = app.pools[poolId];
        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();

        store.vaultBalances[basketId][leg.asset] -= leg.bundleOut;
        store.feePots[basketId][leg.asset] = store.feePots[basketId][leg.asset] - leg.potShare + leg.potFee;
        if (leg.poolShare > 0) {
            pool.trackedBalance += leg.poolShare;
            LibFeeRouter.routeManagedShare(poolId, leg.poolShare, _basketFeeSource(basketId), true, 0);
        }

        state.assetsOut[i] = leg.payout;
        state.feeAmounts[i] = leg.fee;

        uint256 gross = leg.bundleOut + leg.potShare;
        if (gross == 0) return;

        uint256 navOut = Math.mulDiv(leg.payout, leg.bundleOut, gross);
        uint256 potOut = leg.payout - navOut;

        if (navOut > 0) {
            LibModuleEncumbrance.unencumber(positionKey, poolId, _basketEncumbranceId(basketId), navOut);
        }
        if (potOut > 0) {
            LibFeeIndex.settle(poolId, positionKey);
            uint256 currentPrincipal = pool.userPrincipal[positionKey];
            bool isNewUser = currentPrincipal == 0;
            if (isNewUser) {
                uint256 maxUsers = pool.poolConfig.maxUserCount;
                if (maxUsers > 0 && pool.userCount >= maxUsers) revert MaxUserCountExceeded(maxUsers);
            }
            pool.userPrincipal[positionKey] = currentPrincipal + potOut;
            pool.totalDeposits += potOut;
            pool.trackedBalance += potOut;
            if (isNewUser) {
                pool.userCount += 1;
            }
            pool.userFeeIndex[positionKey] = pool.feeIndex;
            pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
        }
    }

    function _distributeWalletBasketFee(uint256 basketId, address asset, uint256 fee) internal {
        if (fee == 0) return;

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 poolId = app.assetToPoolId[asset];
        if (poolId == 0) revert NoPoolForAsset(asset);

        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();
        uint256 poolShare = Math.mulDiv(fee, _basketPoolFeeShareBps(), BPS_DENOMINATOR);
        uint256 potFee = fee - poolShare;
        if (potFee > 0) {
            store.feePots[basketId][asset] += potFee;
        }
        if (poolShare > 0) {
            app.pools[poolId].trackedBalance += poolShare;
            LibFeeRouter.routeManagedShare(poolId, poolShare, _basketFeeSource(basketId), true, 0);
        }
    }

    function _availablePrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 pid)
        internal
        view
        returns (uint256 available)
    {
        uint256 principal = pool.userPrincipal[positionKey];
        uint256 totalEncumbered = LibEncumbrance.total(positionKey, pid);
        if (totalEncumbered >= principal) return 0;
        return principal - totalEncumbered;
    }

    function _basketFeeSource(uint256 basketId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("EDEN_BASKET_FEE", basketId));
    }

    function _basketEncumbranceId(uint256 basketId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("EDEN_BASKET_ENCUMBRANCE", basketId)));
    }

    function _createBasketInternal(CreateBasketParams calldata params, uint256 basketId, address token) internal {
        LibEdenBasketStorage.EdenBasketStorage storage store = LibEdenBasketStorage.s();
        store.basketCount = basketId + 1;

        LibEdenBasketStorage.BasketConfig storage basket = store.baskets[basketId];
        basket.assets = params.assets;
        basket.bundleAmounts = params.bundleAmounts;
        basket.mintFeeBps = params.mintFeeBps;
        basket.burnFeeBps = params.burnFeeBps;
        basket.flashFeeBps = params.flashFeeBps;
        basket.token = token;
        basket.poolId = _createBasketTokenPool(token);

        store.basketMetadata[basketId] = LibEdenBasketStorage.BasketMetadata({
            name: params.name,
            symbol: params.symbol,
            uri: params.uri,
            creator: msg.sender,
            createdAt: uint64(block.timestamp),
            basketType: params.basketType
        });
        store.tokenToBasketIdPlusOne[token] = basketId + 1;

        emit BasketCreated(basketId, token, params.assets, params.bundleAmounts);
    }

    function _createBasketTokenPool(address underlying) internal returns (uint256 pid) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        if (!store.defaultPoolConfigSet) revert DefaultPoolConfigNotSet();
        if (underlying == address(0)) revert InvalidUnderlying();
        if (store.assetToPoolId[underlying] != 0) revert PoolAlreadyExists(store.assetToPoolId[underlying]);

        pid = _nextBasketPoolId(store);
        Types.PoolData storage p = store.pools[pid];
        if (p.initialized) revert PoolAlreadyExists(pid);

        p.underlying = underlying;
        p.initialized = true;
        store.assetToPoolId[underlying] = pid;

        Types.PoolConfig storage defaults = store.defaultPoolConfig;
        p.poolConfig.rollingApyBps = defaults.rollingApyBps;
        p.poolConfig.depositorLTVBps = defaults.depositorLTVBps;
        p.poolConfig.flashLoanFeeBps = defaults.flashLoanFeeBps;
        p.poolConfig.flashLoanAntiSplit = defaults.flashLoanAntiSplit;
        p.poolConfig.minDepositAmount = defaults.minDepositAmount;
        p.poolConfig.minLoanAmount = defaults.minLoanAmount;
        p.poolConfig.minTopupAmount = defaults.minTopupAmount;
        p.poolConfig.isCapped = defaults.isCapped;
        p.poolConfig.depositCap = defaults.depositCap;
        p.poolConfig.maxUserCount = defaults.maxUserCount;
        p.poolConfig.aumFeeMinBps = defaults.aumFeeMinBps;
        p.poolConfig.aumFeeMaxBps = defaults.aumFeeMaxBps;
        p.poolConfig.borrowFee = defaults.borrowFee;
        p.poolConfig.repayFee = defaults.repayFee;
        p.poolConfig.withdrawFee = defaults.withdrawFee;
        p.poolConfig.flashFee = defaults.flashFee;
        p.poolConfig.closeRollingFee = defaults.closeRollingFee;

        uint16 maxRate = store.maxMaintenanceRateBps == 0 ? 100 : store.maxMaintenanceRateBps;
        uint16 maintenanceRate = defaults.maintenanceRateBps;
        if (maintenanceRate == 0) {
            maintenanceRate = store.defaultMaintenanceRateBps;
            if (maintenanceRate == 0) maintenanceRate = maxRate;
        }
        p.poolConfig.maintenanceRateBps = maintenanceRate;

        delete p.poolConfig.fixedTermConfigs;
        for (uint256 i = 0; i < defaults.fixedTermConfigs.length; i++) {
            p.poolConfig.fixedTermConfigs.push(defaults.fixedTermConfigs[i]);
        }

        p.currentAumFeeBps = defaults.aumFeeMinBps;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);

        if (pid >= store.poolCount) {
            store.poolCount = pid + 1;
        }
    }

    function _nextBasketPoolId(LibAppStorage.AppStorage storage store) internal view returns (uint256 pid) {
        pid = store.poolCount;
        if (pid == 0) pid = 1;
        while (store.pools[pid].initialized) {
            pid++;
        }
    }
}
