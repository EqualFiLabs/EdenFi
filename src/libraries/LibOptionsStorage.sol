// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @notice Storage anchor and typed records for EqualFi option-series lifecycle state.
library LibOptionsStorage {
    bytes32 internal constant OPTIONS_STORAGE_POSITION = keccak256("equalfi.options.storage");

    struct OptionSeries {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 underlyingPoolId;
        uint256 strikePoolId;
        address underlyingAsset;
        address strikeAsset;
        uint256 strikePrice;
        uint64 expiry;
        uint256 totalSize;
        uint256 remainingSize;
        uint256 contractSize;
        uint256 collateralLocked;
        bool isCall;
        bool isAmerican;
        bool reclaimed;
    }

    struct CreateOptionSeriesParams {
        uint256 positionId;
        uint256 underlyingPoolId;
        uint256 strikePoolId;
        uint256 strikePrice;
        uint64 expiry;
        uint256 totalSize;
        uint256 contractSize;
        bool isCall;
        bool isAmerican;
    }

    struct OptionsStorage {
        mapping(uint256 => OptionSeries) optionSeries;
        uint256 nextOptionSeriesId;
        bool paused;
        uint64 europeanToleranceSeconds;
        mapping(bytes32 => uint256[]) seriesIdsByPosition;
        mapping(bytes32 => mapping(uint256 => uint256)) seriesIndexPlusOneByPosition;
    }

    function s() internal pure returns (OptionsStorage storage store) {
        bytes32 position = OPTIONS_STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function addSeriesForPosition(OptionsStorage storage store, bytes32 positionKey, uint256 seriesId) internal {
        if (store.seriesIndexPlusOneByPosition[positionKey][seriesId] != 0) {
            return;
        }

        store.seriesIdsByPosition[positionKey].push(seriesId);
        store.seriesIndexPlusOneByPosition[positionKey][seriesId] = store.seriesIdsByPosition[positionKey].length;
    }

    function removeSeriesForPosition(OptionsStorage storage store, bytes32 positionKey, uint256 seriesId) internal {
        uint256 indexPlusOne = store.seriesIndexPlusOneByPosition[positionKey][seriesId];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = store.seriesIdsByPosition[positionKey].length - 1;
        if (index != lastIndex) {
            uint256 swappedId = store.seriesIdsByPosition[positionKey][lastIndex];
            store.seriesIdsByPosition[positionKey][index] = swappedId;
            store.seriesIndexPlusOneByPosition[positionKey][swappedId] = index + 1;
        }

        store.seriesIdsByPosition[positionKey].pop();
        delete store.seriesIndexPlusOneByPosition[positionKey][seriesId];
    }

    function seriesIdsForPosition(OptionsStorage storage store, bytes32 positionKey)
        internal
        view
        returns (uint256[] storage seriesIds)
    {
        return store.seriesIdsByPosition[positionKey];
    }
}
