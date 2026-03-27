// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IndexToken} from "./IndexToken.sol";
import {EqualIndexBaseV3} from "./EqualIndexBaseV3.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

/// @notice Minimal admin + lifecycle management for EqualIndex V3.
contract EqualIndexAdminFacetV3 is EqualIndexBaseV3, ReentrancyGuardModifiers {
    event IndexCreated(
        uint256 indexed indexId,
        address token,
        address[] assets,
        uint256[] bundleAmounts,
        uint16 flashFeeBps
    );
    event IndexPauseUpdated(uint256 indexed indexId, bool paused);

    function createIndex(CreateIndexParams calldata p)
        external
        payable
        nonReentrant
        returns (uint256 indexId, address token)
    {
        if (p.assets.length == 0 || p.assets.length != p.bundleAmounts.length) revert InvalidArrayLength();
        if (p.mintFeeBps.length != p.assets.length || p.burnFeeBps.length != p.assets.length) {
            revert InvalidArrayLength();
        }
        _validateFeeCaps(p.mintFeeBps, p.burnFeeBps, p.flashFeeBps);

        for (uint256 i = 0; i < p.assets.length; i++) {
            if (p.bundleAmounts[i] == 0) revert InvalidBundleDefinition();
            for (uint256 j = i + 1; j < p.assets.length; j++) {
                if (p.assets[i] == p.assets[j]) revert InvalidBundleDefinition();
            }
            if (LibAppStorage.s().assetToPoolId[p.assets[i]] == 0) {
                revert NoPoolForAsset(p.assets[i]);
            }
        }

        bool isGov = LibAccess.isOwnerOrTimelock(msg.sender);
        if (isGov) {
            if (msg.value != 0) revert InsufficientIndexCreationFee(0, msg.value);
        } else {
            uint256 fee = LibAppStorage.indexCreationFee(LibAppStorage.s());
            if (fee == 0) revert InsufficientIndexCreationFee(1, 0);
            if (msg.value != fee) revert InsufficientIndexCreationFee(fee, msg.value);
            address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
            if (treasury == address(0)) revert TreasuryNotSet();
            (bool sent,) = treasury.call{value: fee}("");
            if (!sent) revert IndexCreationFeeTransferFailed();
        }

        if (s().poolFeeShareBps == 0) {
            s().poolFeeShareBps = 1000;
        }

        indexId = s().indexCount;
        s().indexCount = indexId + 1;

        token = address(new IndexToken(p.name, p.symbol, address(this), p.assets, p.bundleAmounts, p.flashFeeBps, indexId));

        Index storage idx = s().indexes[indexId];
        idx.assets = p.assets;
        idx.bundleAmounts = p.bundleAmounts;
        idx.mintFeeBps = p.mintFeeBps;
        idx.burnFeeBps = p.burnFeeBps;
        idx.flashFeeBps = p.flashFeeBps;
        idx.token = token;
        idx.paused = false;

        uint256 poolId = _createIndexTokenPool(token);
        s().indexToPoolId[indexId] = poolId;

        emit IndexCreated(indexId, token, p.assets, p.bundleAmounts, p.flashFeeBps);
    }

    function setPaused(uint256 indexId, bool paused) external onlyTimelock indexExists(indexId) {
        s().indexes[indexId].paused = paused;
        emit IndexPauseUpdated(indexId, paused);
    }

    function getIndex(uint256 indexId) external view indexExists(indexId) returns (IndexView memory index_) {
        Index storage idx = s().indexes[indexId];
        index_.assets = idx.assets;
        index_.bundleAmounts = idx.bundleAmounts;
        index_.mintFeeBps = idx.mintFeeBps;
        index_.burnFeeBps = idx.burnFeeBps;
        index_.flashFeeBps = idx.flashFeeBps;
        index_.totalUnits = idx.totalUnits;
        index_.token = idx.token;
        index_.paused = idx.paused;
    }

    function getVaultBalance(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getFeePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }

    function getIndexPoolId(uint256 indexId) external view returns (uint256) {
        return s().indexToPoolId[indexId];
    }

    function _createIndexTokenPool(address underlying) private returns (uint256 pid) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        if (!store.defaultPoolConfigSet) revert DefaultPoolConfigNotSet();
        if (underlying == address(0)) revert InvalidUnderlying();
        if (store.assetToPoolId[underlying] != 0) revert PoolAlreadyExists(store.assetToPoolId[underlying]);

        pid = _nextIndexPoolId(store);
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
            if (maintenanceRate == 0) {
                maintenanceRate = maxRate;
            }
        }
        p.poolConfig.maintenanceRateBps = maintenanceRate;

        delete p.poolConfig.fixedTermConfigs;
        uint256 termCount = defaults.fixedTermConfigs.length;
        for (uint256 i = 0; i < termCount; i++) {
            p.poolConfig.fixedTermConfigs.push(defaults.fixedTermConfigs[i]);
        }

        p.currentAumFeeBps = defaults.aumFeeMinBps;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);

        if (pid >= store.poolCount) {
            store.poolCount = pid + 1;
        }
    }

    function _nextIndexPoolId(LibAppStorage.AppStorage storage store) private view returns (uint256 pid) {
        pid = store.poolCount;
        if (pid == 0) {
            pid = 1;
        }
        while (store.pools[pid].initialized) {
            pid++;
        }
    }
}
