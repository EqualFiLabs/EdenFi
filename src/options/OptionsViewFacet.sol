// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";

/// @notice Read helpers for the EqualFi options lifecycle.
contract OptionsViewFacet {
    function getOptionSeries(uint256 seriesId) external view returns (LibOptionsStorage.OptionSeries memory series) {
        series = LibOptionsStorage.s().optionSeries[seriesId];
    }

    function getOptionSeriesIdsByPosition(uint256 positionId) external view returns (uint256[] memory seriesIds) {
        return _copySeriesIds(LibPositionHelpers.positionKey(positionId));
    }

    function getOptionSeriesIdsByPositionKey(bytes32 positionKey) external view returns (uint256[] memory seriesIds) {
        return _copySeriesIds(positionKey);
    }

    function previewExercisePayment(uint256 seriesId, uint256 amount) external view returns (uint256 payment) {
        LibOptionsStorage.OptionSeries storage series = LibOptionsStorage.s().optionSeries[seriesId];
        if (series.makerPositionKey == bytes32(0)) {
            return 0;
        }

        uint256 underlyingAmount = amount * series.contractSize;
        if (series.isCall) {
            payment = _previewStrikeAmount(
                underlyingAmount, series.strikePrice, series.underlyingAsset, series.strikeAsset
            );
        } else {
            payment = underlyingAmount;
        }
    }

    function isOptionsPaused() external view returns (bool paused) {
        paused = LibOptionsStorage.s().paused;
    }

    function europeanToleranceSeconds() external view returns (uint64 tolerance) {
        tolerance = LibOptionsStorage.s().europeanToleranceSeconds;
    }

    function _copySeriesIds(bytes32 positionKey) internal view returns (uint256[] memory seriesIds) {
        uint256[] storage storedIds = LibOptionsStorage.seriesIdsForPosition(LibOptionsStorage.s(), positionKey);
        uint256 len = storedIds.length;
        seriesIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            seriesIds[i] = storedIds[i];
        }
    }

    function _previewStrikeAmount(uint256 underlyingAmount, uint256 strikePrice, address underlying, address strike)
        internal
        view
        returns (uint256 strikeAmount)
    {
        uint256 underlyingScale = 10 ** uint256(LibCurrency.decimals(underlying));
        uint256 strikeScale = 10 ** uint256(LibCurrency.decimals(strike));
        uint256 normalizedUnderlying = Math.mulDiv(underlyingAmount, strikePrice, underlyingScale);
        strikeAmount = Math.mulDiv(normalizedUnderlying, strikeScale, 1e18);
    }
}
