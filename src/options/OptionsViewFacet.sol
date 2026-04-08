// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {Types} from "src/libraries/Types.sol";

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

    function getOptionSeriesProductiveCollateral(uint256 seriesId)
        external
        view
        returns (LibOptionsStorage.ProductiveCollateralView memory collateralView)
    {
        LibOptionsStorage.OptionSeries storage series = LibOptionsStorage.s().optionSeries[seriesId];
        if (series.makerPositionKey == bytes32(0)) {
            return collateralView;
        }

        return _buildProductiveCollateralView(seriesId, series);
    }

    function getOptionPositionProductiveCollateral(uint256 positionId)
        external
        view
        returns (LibOptionsStorage.ProductiveCollateralView[] memory collateralViews)
    {
        return _copyProductiveCollateralViews(LibPositionHelpers.positionKey(positionId));
    }

    function getOptionPositionProductiveCollateralByKey(bytes32 positionKey)
        external
        view
        returns (LibOptionsStorage.ProductiveCollateralView[] memory collateralViews)
    {
        return _copyProductiveCollateralViews(positionKey);
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

    function _copyProductiveCollateralViews(bytes32 positionKey)
        internal
        view
        returns (LibOptionsStorage.ProductiveCollateralView[] memory collateralViews)
    {
        uint256[] storage storedIds = LibOptionsStorage.seriesIdsForPosition(LibOptionsStorage.s(), positionKey);
        uint256 len = storedIds.length;
        collateralViews = new LibOptionsStorage.ProductiveCollateralView[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 seriesId = storedIds[i];
            collateralViews[i] = _buildProductiveCollateralView(seriesId, LibOptionsStorage.s().optionSeries[seriesId]);
        }
    }

    function _copySeriesIds(bytes32 positionKey) internal view returns (uint256[] memory seriesIds) {
        uint256[] storage storedIds = LibOptionsStorage.seriesIdsForPosition(LibOptionsStorage.s(), positionKey);
        uint256 len = storedIds.length;
        seriesIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            seriesIds[i] = storedIds[i];
        }
    }

    function _buildProductiveCollateralView(
        uint256 seriesId,
        LibOptionsStorage.OptionSeries storage series
    ) internal view returns (LibOptionsStorage.ProductiveCollateralView memory collateralView) {
        uint256 collateralPoolId = series.isCall ? series.underlyingPoolId : series.strikePoolId;
        address collateralAsset = series.isCall ? series.underlyingAsset : series.strikeAsset;
        bytes32 makerPositionKey = series.makerPositionKey;

        Types.PoolData storage pool = LibPositionHelpers.pool(collateralPoolId);
        uint256 settledPrincipal = LibFeeIndex.previewSettledPrincipal(collateralPoolId, makerPositionKey);
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(makerPositionKey, collateralPoolId);
        uint256 totalEncumbrance = enc.lockedCapital + enc.encumberedCapital + enc.offerEscrowedCapital
            + enc.indexEncumbered + enc.moduleEncumbered;
        uint256 availablePrincipal = settledPrincipal > totalEncumbrance ? settledPrincipal - totalEncumbrance : 0;
        uint256 accruedYield = LibAppStorage.s().pools[collateralPoolId].userAccruedYield[makerPositionKey];
        uint256 feeAccrued = LibAppStorage.s().pools[collateralPoolId].userClaimableFeeYield[makerPositionKey];
        uint256 pendingActiveCreditYield = LibActiveCreditIndex.pendingActiveCredit(collateralPoolId, makerPositionKey);
        uint256 feeYieldWithAccrued = LibFeeIndex.pendingYield(collateralPoolId, makerPositionKey);
        uint256 pendingFeeYield = feeYieldWithAccrued > feeAccrued ? feeYieldWithAccrued - feeAccrued : 0;
        collateralView.seriesId = seriesId;
        collateralView.makerPositionKey = makerPositionKey;
        collateralView.makerPositionId = series.makerPositionId;
        collateralView.collateralPoolId = collateralPoolId;
        collateralView.collateralAsset = collateralAsset;
        collateralView.remainingSize = series.remainingSize;
        collateralView.collateralLocked = series.collateralLocked;
        collateralView.settledPrincipal = settledPrincipal;
        collateralView.availablePrincipal = availablePrincipal;
        collateralView.totalEncumbrance = totalEncumbrance;
        collateralView.activeCreditEncumbrancePrincipal = pool.userActiveCreditStateEncumbrance[makerPositionKey].principal;
        collateralView.pendingActiveCreditYield = pendingActiveCreditYield;
        collateralView.pendingFeeYield = pendingFeeYield;
        collateralView.accruedYield = accruedYield;
        collateralView.claimableYield = accruedYield + pendingActiveCreditYield + pendingFeeYield;
        collateralView.isCall = series.isCall;
        collateralView.reclaimed = series.reclaimed;
    }

    function _previewStrikeAmount(uint256 underlyingAmount, uint256 strikePrice, address underlying, address strike)
        internal
        view
        returns (uint256 strikeAmount)
    {
        uint256 underlyingScale = 10 ** uint256(LibCurrency.decimalsOrRevert(underlying));
        uint256 strikeScale = 10 ** uint256(LibCurrency.decimalsOrRevert(strike));
        uint256 wadValue = Math.mulDiv(underlyingAmount, strikePrice, underlyingScale, Math.Rounding.Ceil);
        strikeAmount = Math.mulDiv(wadValue, strikeScale, 1e18, Math.Rounding.Ceil);
    }
}
