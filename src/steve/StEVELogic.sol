// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StEVEProductBase} from "./StEVEProductBase.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibStEVEStorage} from "../libraries/LibStEVEStorage.sol";
import {LibStEVEEligibilityStorage} from "../libraries/LibStEVEEligibilityStorage.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibModuleEncumbrance} from "../libraries/LibModuleEncumbrance.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

abstract contract StEVELogic is StEVEProductBase {
    event StEVEProductConfigured(address indexed token, address[] assets, uint256[] bundleAmounts);

    function _prepareStEVEWalletMint(
        LibStEVEStorage.ProductConfig storage product,
        uint256 units,
        uint256[] calldata maxInputAmounts,
        WalletMintState memory state
    ) internal {
        uint256 totalSupply = product.totalUnits;
        uint256 len = product.assets.length;
        for (uint256 i = 0; i < len; i++) {
            WalletMintLeg memory leg = _quoteStEVEWalletMintLeg(product, i, units, totalSupply);
            uint256 received = LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.totalRequired, maxInputAmounts[i]);
            _applyStEVEWalletMintLeg(i, leg, received, state);
        }
    }

    function _applyStEVEWalletMintLeg(
        uint256 i,
        WalletMintLeg memory leg,
        uint256 received,
        WalletMintState memory state
    ) internal {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        uint256 surplus = received - leg.totalRequired;
        store.accounting.vaultBalances[leg.asset] += leg.baseDeposit + surplus;
        if (leg.potBuyIn > 0) {
            store.accounting.feePots[leg.asset] += leg.potBuyIn;
        }
        _distributeStEVEFee(leg.asset, leg.fee);
        state.required[i] = leg.totalRequired;
        state.feeAmounts[i] = leg.fee;
    }

    function _quoteStEVEWalletMintLeg(
        LibStEVEStorage.ProductConfig storage product,
        uint256 i,
        uint256 units,
        uint256 totalSupply
    ) internal view returns (WalletMintLeg memory leg) {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        leg.asset = product.assets[i];
        if (totalSupply == 0) {
            leg.baseDeposit = Math.mulDiv(product.bundleAmounts[i], units, UNIT_SCALE);
        } else {
            uint256 economicBalance = store.accounting.vaultBalances[leg.asset];
            leg.baseDeposit = Math.mulDiv(economicBalance, units, totalSupply, Math.Rounding.Ceil);
            leg.potBuyIn = Math.mulDiv(store.accounting.feePots[leg.asset], units, totalSupply, Math.Rounding.Ceil);
        }
        leg.grossInput = leg.baseDeposit + leg.potBuyIn;
        leg.fee = Math.mulDiv(leg.grossInput, product.mintFeeBps[i], BPS_DENOMINATOR, Math.Rounding.Ceil);
        leg.totalRequired = leg.grossInput + leg.fee;
    }

    function _prepareStEVEWalletBurn(
        LibStEVEStorage.ProductConfig storage product,
        uint256 units,
        address to,
        WalletBurnState memory state
    ) internal {
        uint256 totalSupply = product.totalUnits;
        uint256 len = product.assets.length;
        for (uint256 i = 0; i < len; i++) {
            WalletBurnLeg memory leg = _quoteStEVEWalletBurnLeg(product, i, units, totalSupply);
            _applyStEVEWalletBurnLeg(i, leg, to, state);
        }
    }

    function _applyStEVEWalletBurnLeg(
        uint256 i,
        WalletBurnLeg memory leg,
        address to,
        WalletBurnState memory state
    ) internal {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        store.accounting.vaultBalances[leg.asset] -= leg.bundleOut;
        store.accounting.feePots[leg.asset] -= leg.potShare;
        _distributeStEVEFee(leg.asset, leg.fee);
        LibCurrency.transfer(leg.asset, to, leg.payout);
        state.assetsOut[i] = leg.payout;
        state.feeAmounts[i] = leg.fee;
    }

    function _quoteStEVEWalletBurnLeg(
        LibStEVEStorage.ProductConfig storage product,
        uint256 i,
        uint256 units,
        uint256 totalSupply
    ) internal view returns (WalletBurnLeg memory leg) {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        leg.asset = product.assets[i];
        leg.bundleOut = Math.mulDiv(product.bundleAmounts[i], units, UNIT_SCALE);
        uint256 vaultBalance = store.accounting.vaultBalances[leg.asset];
        if (vaultBalance < leg.bundleOut) revert InsufficientPoolLiquidity(leg.bundleOut, vaultBalance);
        leg.potShare = Math.mulDiv(store.accounting.feePots[leg.asset], units, totalSupply);
        uint256 gross = leg.bundleOut + leg.potShare;
        leg.fee = Math.mulDiv(gross, product.burnFeeBps[i], BPS_DENOMINATOR);
        leg.payout = gross - leg.fee;
    }

    function _prepareStEVEPositionMint(
        LibStEVEStorage.ProductConfig storage product,
        uint256 units,
        uint256 totalSupply,
        bytes32 positionKey,
        uint16 poolFeeShareBps,
        PositionMintState memory state
    ) internal {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 len = product.assets.length;
        for (uint256 i = 0; i < len; i++) {
            PositionMintLeg memory leg = _quoteStEVEPositionMintLeg(product, i, units, totalSupply, app);
            _applyStEVEPositionMintLeg(app, positionKey, i, leg, poolFeeShareBps, state);
        }
    }

    function _quoteStEVEPositionMintLeg(
        LibStEVEStorage.ProductConfig storage product,
        uint256 i,
        uint256 units,
        uint256 totalSupply,
        LibAppStorage.AppStorage storage app
    ) internal view returns (PositionMintLeg memory leg) {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        leg.asset = product.assets[i];
        leg.poolId = app.assetToPoolId[leg.asset];
        if (leg.poolId == 0) revert NoPoolForAsset(leg.asset);

        if (totalSupply == 0) {
            leg.baseDeposit = Math.mulDiv(product.bundleAmounts[i], units, UNIT_SCALE);
        } else {
            uint256 economicBalance = store.accounting.vaultBalances[leg.asset];
            leg.baseDeposit = Math.mulDiv(economicBalance, units, totalSupply, Math.Rounding.Ceil);
            leg.potBuyIn = Math.mulDiv(store.accounting.feePots[leg.asset], units, totalSupply, Math.Rounding.Ceil);
        }

        leg.grossInput = leg.baseDeposit + leg.potBuyIn;
        leg.fee = Math.mulDiv(leg.grossInput, product.mintFeeBps[i], BPS_DENOMINATOR, Math.Rounding.Ceil);
        leg.totalRequired = leg.grossInput + leg.fee;
    }

    function _applyStEVEPositionMintLeg(
        LibAppStorage.AppStorage storage app,
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

        LibModuleEncumbrance.encumber(positionKey, leg.poolId, _stEVEEncumbranceId(), leg.baseDeposit);
        LibStEVEStorage.s().accounting.vaultBalances[leg.asset] += leg.baseDeposit;

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
            LibStEVEStorage.s().accounting.feePots[leg.asset] += leg.potBuyIn;
        }

        if (leg.fee > 0) {
            uint256 poolShare = Math.mulDiv(leg.fee, poolFeeShareBps, BPS_DENOMINATOR);
            uint256 potFee = leg.fee - poolShare;
            if (potFee > 0) {
                if (pool.trackedBalance < potFee) revert InsufficientPoolLiquidity(potFee, pool.trackedBalance);
                pool.trackedBalance -= potFee;
                LibStEVEStorage.s().accounting.feePots[leg.asset] += potFee;
            }
            if (poolShare > 0) {
                LibFeeRouter.routeManagedShare(leg.poolId, poolShare, _stEVEFeeSource(), true, 0);
            }
        }
    }

    function _prepareStEVEPositionBurn(
        LibStEVEStorage.ProductConfig storage product,
        uint256 units,
        uint256 totalSupply,
        bytes32 positionKey,
        uint16 poolFeeShareBps,
        PositionBurnState memory state
    ) internal {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 len = product.assets.length;
        for (uint256 i = 0; i < len; i++) {
            PositionBurnLeg memory leg =
                _quoteStEVEPositionBurnLeg(product, i, units, totalSupply, poolFeeShareBps);
            _applyStEVEPositionBurnLeg(app, positionKey, i, leg, state);
        }
    }

    function _quoteStEVEPositionBurnLeg(
        LibStEVEStorage.ProductConfig storage product,
        uint256 i,
        uint256 units,
        uint256 totalSupply,
        uint16 poolFeeShareBps
    ) internal view returns (PositionBurnLeg memory leg) {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        leg.asset = product.assets[i];
        leg.bundleOut = Math.mulDiv(product.bundleAmounts[i], units, UNIT_SCALE);
        uint256 vaultBalance = store.accounting.vaultBalances[leg.asset];
        if (vaultBalance < leg.bundleOut) revert InsufficientPoolLiquidity(leg.bundleOut, vaultBalance);
        leg.potShare = Math.mulDiv(store.accounting.feePots[leg.asset], units, totalSupply);
        uint256 gross = leg.bundleOut + leg.potShare;
        leg.fee = Math.mulDiv(gross, product.burnFeeBps[i], BPS_DENOMINATOR);
        leg.payout = gross - leg.fee;
        leg.poolShare = Math.mulDiv(leg.fee, poolFeeShareBps, BPS_DENOMINATOR);
        leg.potFee = leg.fee - leg.poolShare;
    }

    function _applyStEVEPositionBurnLeg(
        LibAppStorage.AppStorage storage app,
        bytes32 positionKey,
        uint256 i,
        PositionBurnLeg memory leg,
        PositionBurnState memory state
    ) internal {
        uint256 poolId = app.assetToPoolId[leg.asset];
        if (poolId == 0) revert NoPoolForAsset(leg.asset);

        LibPoolMembership._ensurePoolMembership(positionKey, poolId, true);
        Types.PoolData storage pool = app.pools[poolId];
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();

        store.accounting.vaultBalances[leg.asset] -= leg.bundleOut;
        store.accounting.feePots[leg.asset] = store.accounting.feePots[leg.asset] - leg.potShare + leg.potFee;
        if (leg.poolShare > 0) {
            pool.trackedBalance += leg.poolShare;
            LibFeeRouter.routeManagedShare(poolId, leg.poolShare, _stEVEFeeSource(), true, 0);
        }

        state.assetsOut[i] = leg.payout;
        state.feeAmounts[i] = leg.fee;

        uint256 gross = leg.bundleOut + leg.potShare;
        if (gross == 0) return;

        uint256 navOut = Math.mulDiv(leg.payout, leg.bundleOut, gross);
        uint256 potOut = leg.payout - navOut;

        if (navOut > 0) {
            LibModuleEncumbrance.unencumber(positionKey, poolId, _stEVEEncumbranceId(), navOut);
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

    function _distributeStEVEFee(address asset, uint256 fee) internal {
        if (fee == 0) return;

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        uint256 poolId = app.assetToPoolId[asset];
        if (poolId == 0) revert NoPoolForAsset(asset);

        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        uint256 poolShare = Math.mulDiv(fee, _basketPoolFeeShareBps(), BPS_DENOMINATOR);
        uint256 potFee = fee - poolShare;
        if (potFee > 0) {
            store.accounting.feePots[asset] += potFee;
        }
        if (poolShare > 0) {
            app.pools[poolId].trackedBalance += poolShare;
            LibFeeRouter.routeManagedShare(poolId, poolShare, _stEVEFeeSource(), true, 0);
        }
    }

    function _requireStEVEConfigured() internal view {
        if (!LibStEVEEligibilityStorage.s().configured) revert InvalidParameterRange("stEVE not configured");
    }

    function _availablePrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 pid)
        internal
        view
        returns (uint256 available)
    {
        return LibPositionHelpers.availablePrincipal(pool, positionKey, pid);
    }

    function _stEVEFeeSource() internal pure returns (bytes32) {
        return keccak256("EDEN_STEVE_FEE");
    }

    function _stEVEEncumbranceId() internal pure returns (uint256) {
        return uint256(keccak256("EDEN_STEVE_ENCUMBRANCE"));
    }

    function _configureStEVEProduct(CreateBasketParams calldata params, address token) internal {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        if (store.productInitialized) revert InvalidParameterRange("product already configured");
        store.productInitialized = true;

        LibStEVEStorage.ProductConfig storage product = store.product;
        product.assets = params.assets;
        product.bundleAmounts = params.bundleAmounts;
        product.mintFeeBps = params.mintFeeBps;
        product.burnFeeBps = params.burnFeeBps;
        product.flashFeeBps = params.flashFeeBps;
        product.token = token;
        product.poolId = _createStEVEPool(token);

        store.productMetadata = LibStEVEStorage.ProductMetadata({
            name: params.name,
            symbol: params.symbol,
            uri: params.uri,
            creator: msg.sender,
            createdAt: uint64(block.timestamp),
            productType: params.basketType
        });

        emit StEVEProductConfigured(token, params.assets, params.bundleAmounts);
    }

    function _createStEVEPool(address underlying) internal returns (uint256 pid) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        if (!store.defaultPoolConfigSet) revert DefaultPoolConfigNotSet();
        if (underlying == address(0)) revert InvalidUnderlying();
        if (store.assetToPoolId[underlying] != 0) revert PoolAlreadyExists(store.assetToPoolId[underlying]);

        pid = _nextStEVEPoolId(store);
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

    function _nextStEVEPoolId(LibAppStorage.AppStorage storage store) internal view returns (uint256 pid) {
        pid = store.poolCount;
        if (pid == 0) pid = 1;
        while (store.pools[pid].initialized) {
            pid++;
        }
    }
}
