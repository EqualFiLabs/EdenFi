// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {LibEqualXTypes} from "../libraries/LibEqualXTypes.sol";
import {LibEqualXDiscoveryStorage} from "../libraries/LibEqualXDiscoveryStorage.sol";
import {LibEqualXSoloAmmStorage} from "../libraries/LibEqualXSoloAmmStorage.sol";
import {LibEqualXCommunityAmmStorage} from "../libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCommunityFeeIndex} from "../libraries/LibEqualXCommunityFeeIndex.sol";
import {LibEqualXCurveStorage} from "../libraries/LibEqualXCurveStorage.sol";
import {LibEqualXCurveEngine} from "../libraries/LibEqualXCurveEngine.sol";
import {LibEqualXSwapMath} from "../libraries/LibEqualXSwapMath.sol";

/// @notice View surface for EqualX market discovery and greenfield storage reads.
contract EqualXViewFacet {
    error EqualXView_InvalidMarket(LibEqualXTypes.MarketType marketType, uint256 marketId);
    error EqualXView_InvalidToken(address token);

    struct EqualXLinearMarketStatus {
        bool exists;
        bool active;
        bool finalized;
        bool started;
        bool expired;
        bool live;
        uint64 startTime;
        uint64 endTime;
    }

    struct EqualXCurveStatus {
        bool exists;
        bool active;
        bool started;
        bool expired;
        bool live;
        uint32 generation;
        bytes32 commitment;
        uint128 remainingVolume;
        uint64 startTime;
        uint64 endTime;
        uint16 profileId;
        bool baseIsA;
    }

    struct EqualXSwapQuote {
        uint256 rawOut;
        uint256 amountOut;
        uint256 feeAmount;
        uint256 makerFee;
        uint256 treasuryFee;
        uint256 activeCreditFee;
        uint256 feeIndexFee;
        address feeToken;
        uint256 feePoolId;
    }

    struct EqualXCommunityMakerView {
        LibEqualXCommunityAmmStorage.CommunityMakerPosition maker;
        uint256 pendingFeesA;
        uint256 pendingFeesB;
    }

    function getEqualXSoloAmmMarket(uint256 marketId)
        external
        view
        returns (LibEqualXSoloAmmStorage.SoloAmmMarket memory market)
    {
        market = LibEqualXSoloAmmStorage.s().markets[marketId];
    }

    function getEqualXCommunityAmmMarket(uint256 marketId)
        external
        view
        returns (LibEqualXCommunityAmmStorage.CommunityAmmMarket memory market)
    {
        market = LibEqualXCommunityAmmStorage.s().markets[marketId];
    }

    function getEqualXCurveMarket(
        uint256 curveId
    )
        external
        view
        returns (
            LibEqualXCurveStorage.CurveMarket memory market,
            LibEqualXCurveStorage.CurveData memory data,
            LibEqualXCurveStorage.CurvePricing memory pricing,
            LibEqualXCurveStorage.CurveProfileData memory profileData,
            LibEqualXCurveStorage.CurveImmutables memory immutables,
            bool baseIsA
        )
    {
        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        market = store.markets[curveId];
        data = store.curveData[curveId];
        pricing = store.curvePricing[curveId];
        profileData = store.curveProfileData[curveId];
        immutables = store.curveImmutables[curveId];
        baseIsA = store.curveBaseIsA[curveId];
    }

    function getEqualXCurveProfile(uint16 profileId)
        external
        view
        returns (LibEqualXCurveStorage.CurveProfileRegistryEntry memory entry, bool builtIn)
    {
        (entry, builtIn) = LibEqualXCurveEngine.getCurveProfile(profileId);
    }

    function isEqualXCurveProfileApproved(uint16 profileId) external view returns (bool approved) {
        approved = LibEqualXCurveEngine.isCurveProfileApproved(profileId);
    }

    function getEqualXBuiltInCurveProfiles() external pure returns (uint16[] memory profileIds) {
        profileIds = new uint16[](1);
        profileIds[0] = LibEqualXCurveEngine.builtInLinearProfileId();
    }

    function getEqualXSoloAmmStatus(uint256 marketId) external view returns (EqualXLinearMarketStatus memory status) {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        status = _buildLinearStatus(market.makerPositionId != 0, market.active, market.finalized, market.startTime, market.endTime);
    }

    function getEqualXCommunityAmmStatus(uint256 marketId)
        external
        view
        returns (EqualXLinearMarketStatus memory status)
    {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        status = _buildLinearStatus(
            market.creatorPositionId != 0, market.active, market.finalized, market.startTime, market.endTime
        );
    }

    function getEqualXCurveStatus(uint256 curveId) external view returns (EqualXCurveStatus memory status) {
        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        LibEqualXCurveStorage.CurveMarket storage market = store.markets[curveId];
        LibEqualXCurveStorage.CurveData storage data = store.curveData[curveId];
        LibEqualXCurveStorage.CurvePricing storage pricing = store.curvePricing[curveId];
        LibEqualXCurveStorage.CurveProfileData storage profile = store.curveProfileData[curveId];

        status.exists = data.makerPositionId != 0;
        status.active = market.active;
        status.started = block.timestamp >= pricing.startTime;
        status.expired = block.timestamp > market.endTime;
        status.live = status.active && status.started && !status.expired && market.remainingVolume > 0;
        status.generation = market.generation;
        status.commitment = market.commitment;
        status.remainingVolume = market.remainingVolume;
        status.startTime = pricing.startTime;
        status.endTime = market.endTime;
        status.profileId = profile.profileId;
        status.baseIsA = store.curveBaseIsA[curveId];
    }

    function getEqualXMarketsByPosition(bytes32 positionKey)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = LibEqualXDiscoveryStorage.marketsByPosition(LibEqualXDiscoveryStorage.s(), positionKey);
    }

    function getEqualXMarketsByPositionId(uint256 positionId)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = LibEqualXDiscoveryStorage.marketsByPosition(
            LibEqualXDiscoveryStorage.s(), LibPositionHelpers.positionKey(positionId)
        );
    }

    function getEqualXMarketsByPositionAndType(bytes32 positionKey, LibEqualXTypes.MarketType marketType)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = _filterByType(
            LibEqualXDiscoveryStorage.marketsByPosition(LibEqualXDiscoveryStorage.s(), positionKey), marketType
        );
    }

    function getEqualXMarketsByPositionIdAndType(uint256 positionId, LibEqualXTypes.MarketType marketType)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = _filterByType(
            LibEqualXDiscoveryStorage.marketsByPosition(
                LibEqualXDiscoveryStorage.s(), LibPositionHelpers.positionKey(positionId)
            ),
            marketType
        );
    }

    function getEqualXMarketsByPair(address tokenA, address tokenB)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = LibEqualXDiscoveryStorage.marketsByPair(LibEqualXDiscoveryStorage.s(), tokenA, tokenB);
    }

    function getEqualXMarketsByPairAndType(address tokenA, address tokenB, LibEqualXTypes.MarketType marketType)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = _filterByType(
            LibEqualXDiscoveryStorage.marketsByPair(LibEqualXDiscoveryStorage.s(), tokenA, tokenB), marketType
        );
    }

    function getEqualXActiveMarkets(LibEqualXTypes.MarketType marketType)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = LibEqualXDiscoveryStorage.activeMarketsByType(LibEqualXDiscoveryStorage.s(), marketType);
    }

    function getEqualXActiveMarketsByPosition(bytes32 positionKey)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = _filterActive(LibEqualXDiscoveryStorage.marketsByPosition(LibEqualXDiscoveryStorage.s(), positionKey));
    }

    function getEqualXActiveMarketsByPositionId(uint256 positionId)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = _filterActive(
            LibEqualXDiscoveryStorage.marketsByPosition(
                LibEqualXDiscoveryStorage.s(), LibPositionHelpers.positionKey(positionId)
            )
        );
    }

    function getEqualXActiveMarketsByPair(address tokenA, address tokenB)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = _filterActive(LibEqualXDiscoveryStorage.marketsByPair(LibEqualXDiscoveryStorage.s(), tokenA, tokenB));
    }

    function quoteEqualXSoloAmmExactIn(uint256 marketId, address tokenIn, uint256 amountIn)
        external
        view
        returns (EqualXSwapQuote memory preview)
    {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        if (market.makerPositionId == 0) revert EqualXView_InvalidMarket(LibEqualXTypes.MarketType.SOLO_AMM, marketId);

        bool inIsA = _soloTokenInIsA(market, tokenIn);
        uint256 reserveIn = inIsA ? market.reserveA : market.reserveB;
        uint256 reserveOut = inIsA ? market.reserveB : market.reserveA;
        uint8 decimalsIn = inIsA ? market.tokenADecimals : market.tokenBDecimals;
        uint8 decimalsOut = inIsA ? market.tokenBDecimals : market.tokenADecimals;

        (preview.rawOut, preview.feeAmount, preview.amountOut) = LibEqualXSwapMath.computeSwapByInvariant(
            market.invariantMode,
            market.feeAsset,
            reserveIn,
            reserveOut,
            amountIn,
            market.feeBps,
            decimalsIn,
            decimalsOut
        );

        if (preview.feeAmount > 0) {
            LibEqualXSwapMath.FeeSplit memory split = LibEqualXSwapMath.splitFeeWithRouter(preview.feeAmount, 7000);
            preview.makerFee = split.makerFee;
            preview.treasuryFee = split.treasuryFee;
            preview.activeCreditFee = split.activeCreditFee;
            preview.feeIndexFee = split.feeIndexFee;
        }

        if (market.feeAsset == LibEqualXTypes.FeeAsset.TokenIn) {
            preview.feeToken = tokenIn;
            preview.feePoolId = inIsA ? market.poolIdA : market.poolIdB;
        } else {
            preview.feeToken = inIsA ? market.tokenB : market.tokenA;
            preview.feePoolId = inIsA ? market.poolIdB : market.poolIdA;
        }
    }

    function quoteEqualXCommunityAmmExactIn(uint256 marketId, address tokenIn, uint256 amountIn)
        external
        view
        returns (EqualXSwapQuote memory preview)
    {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        if (market.creatorPositionId == 0) {
            revert EqualXView_InvalidMarket(LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId);
        }

        bool inIsA = _communityTokenInIsA(market, tokenIn);
        uint256 reserveIn = inIsA ? market.reserveA : market.reserveB;
        uint256 reserveOut = inIsA ? market.reserveB : market.reserveA;
        uint8 decimalsIn = inIsA ? market.tokenADecimals : market.tokenBDecimals;
        uint8 decimalsOut = inIsA ? market.tokenBDecimals : market.tokenADecimals;

        (preview.rawOut, preview.feeAmount, preview.amountOut) = LibEqualXSwapMath.computeSwapByInvariant(
            market.invariantMode,
            market.feeAsset,
            reserveIn,
            reserveOut,
            amountIn,
            market.feeBps,
            decimalsIn,
            decimalsOut
        );

        if (preview.feeAmount > 0) {
            LibEqualXSwapMath.FeeSplit memory split = LibEqualXSwapMath.splitFeeWithRouter(preview.feeAmount, 7000);
            preview.makerFee = split.makerFee;
            preview.treasuryFee = split.treasuryFee;
            preview.activeCreditFee = split.activeCreditFee;
            preview.feeIndexFee = split.feeIndexFee;
        }

        if (market.feeAsset == LibEqualXTypes.FeeAsset.TokenIn) {
            preview.feeToken = tokenIn;
            preview.feePoolId = inIsA ? market.poolIdA : market.poolIdB;
        } else {
            preview.feeToken = inIsA ? market.tokenB : market.tokenA;
            preview.feePoolId = inIsA ? market.poolIdB : market.poolIdA;
        }
    }

    function quoteEqualXCurveExactIn(uint256 curveId, uint256 amountIn)
        external
        view
        returns (LibEqualXCurveEngine.CurveExecutionPreview memory preview)
    {
        preview = LibEqualXCurveEngine.previewCurveQuote(curveId, amountIn);
    }

    function getEqualXSoloAmmMakerFeeBuckets(uint256 marketId)
        external
        view
        returns (
            uint256 makerFeeAAccrued,
            uint256 makerFeeBAccrued,
            uint256 treasuryFeeAAccrued,
            uint256 treasuryFeeBAccrued,
            uint256 feeIndexFeeAAccrued,
            uint256 feeIndexFeeBAccrued,
            uint256 activeCreditFeeAAccrued,
            uint256 activeCreditFeeBAccrued
        )
    {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        if (market.makerPositionId == 0) revert EqualXView_InvalidMarket(LibEqualXTypes.MarketType.SOLO_AMM, marketId);

        makerFeeAAccrued = market.makerFeeAAccrued;
        makerFeeBAccrued = market.makerFeeBAccrued;
        treasuryFeeAAccrued = market.treasuryFeeAAccrued;
        treasuryFeeBAccrued = market.treasuryFeeBAccrued;
        feeIndexFeeAAccrued = market.feeIndexFeeAAccrued;
        feeIndexFeeBAccrued = market.feeIndexFeeBAccrued;
        activeCreditFeeAAccrued = market.activeCreditFeeAAccrued;
        activeCreditFeeBAccrued = market.activeCreditFeeBAccrued;
    }

    function getEqualXCommunityMakerView(uint256 marketId, bytes32 positionKey)
        external
        view
        returns (EqualXCommunityMakerView memory makerView)
    {
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        if (market.creatorPositionId == 0) {
            revert EqualXView_InvalidMarket(LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId);
        }

        makerView.maker = store.makers[marketId][positionKey];
        (makerView.pendingFeesA, makerView.pendingFeesB) = LibEqualXCommunityFeeIndex.pendingFees(marketId, positionKey);
    }

    function getEqualXCommunityMakerViewById(uint256 marketId, uint256 positionId)
        external
        view
        returns (EqualXCommunityMakerView memory makerView)
    {
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        if (market.creatorPositionId == 0) {
            revert EqualXView_InvalidMarket(LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId);
        }

        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        makerView.maker = store.makers[marketId][positionKey];
        (makerView.pendingFeesA, makerView.pendingFeesB) = LibEqualXCommunityFeeIndex.pendingFees(marketId, positionKey);
    }

    function previewEqualXCommunityMakerFees(uint256 marketId, bytes32 positionKey)
        external
        view
        returns (uint256 feesA, uint256 feesB)
    {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        if (market.creatorPositionId == 0) {
            revert EqualXView_InvalidMarket(LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId);
        }
        (feesA, feesB) = LibEqualXCommunityFeeIndex.pendingFees(marketId, positionKey);
    }

    function _buildLinearStatus(bool exists, bool active, bool finalized, uint64 startTime, uint64 endTime)
        private
        view
        returns (EqualXLinearMarketStatus memory status)
    {
        status.exists = exists;
        status.active = active;
        status.finalized = finalized;
        status.started = block.timestamp >= startTime;
        status.expired = block.timestamp >= endTime;
        status.live = active && status.started && !status.expired;
        status.startTime = startTime;
        status.endTime = endTime;
    }

    function _filterByType(
        LibEqualXTypes.MarketPointer[] memory pointers,
        LibEqualXTypes.MarketType marketType
    ) private pure returns (LibEqualXTypes.MarketPointer[] memory filtered) {
        uint256 count;
        uint256 len = pointers.length;
        for (uint256 i; i < len; ++i) {
            if (pointers[i].marketType == marketType) {
                ++count;
            }
        }

        filtered = new LibEqualXTypes.MarketPointer[](count);
        uint256 out;
        for (uint256 i; i < len; ++i) {
            if (pointers[i].marketType == marketType) {
                filtered[out++] = pointers[i];
            }
        }
    }

    function _filterActive(LibEqualXTypes.MarketPointer[] memory pointers)
        private
        view
        returns (LibEqualXTypes.MarketPointer[] memory filtered)
    {
        uint256 count;
        uint256 len = pointers.length;
        for (uint256 i; i < len; ++i) {
            if (_pointerIsActive(pointers[i])) {
                ++count;
            }
        }

        filtered = new LibEqualXTypes.MarketPointer[](count);
        uint256 out;
        for (uint256 i; i < len; ++i) {
            if (_pointerIsActive(pointers[i])) {
                filtered[out++] = pointers[i];
            }
        }
    }

    function _pointerIsActive(LibEqualXTypes.MarketPointer memory pointer) private view returns (bool active) {
        if (pointer.marketType == LibEqualXTypes.MarketType.SOLO_AMM) {
            active = LibEqualXSoloAmmStorage.s().markets[pointer.marketId].active;
        } else if (pointer.marketType == LibEqualXTypes.MarketType.COMMUNITY_AMM) {
            active = LibEqualXCommunityAmmStorage.s().markets[pointer.marketId].active;
        } else {
            active = LibEqualXCurveStorage.s().markets[pointer.marketId].active;
        }
    }

    function _soloTokenInIsA(LibEqualXSoloAmmStorage.SoloAmmMarket storage market, address tokenIn)
        private
        view
        returns (bool inIsA)
    {
        if (tokenIn == market.tokenA) return true;
        if (tokenIn == market.tokenB) return false;
        revert EqualXView_InvalidToken(tokenIn);
    }

    function _communityTokenInIsA(LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market, address tokenIn)
        private
        view
        returns (bool inIsA)
    {
        if (tokenIn == market.tokenA) return true;
        if (tokenIn == market.tokenB) return false;
        revert EqualXView_InvalidToken(tokenIn);
    }
}
