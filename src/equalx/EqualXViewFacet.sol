// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibEqualXTypes} from "../libraries/LibEqualXTypes.sol";
import {LibEqualXDiscoveryStorage} from "../libraries/LibEqualXDiscoveryStorage.sol";
import {LibEqualXSoloAmmStorage} from "../libraries/LibEqualXSoloAmmStorage.sol";
import {LibEqualXCommunityAmmStorage} from "../libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCurveStorage} from "../libraries/LibEqualXCurveStorage.sol";

/// @notice View surface for EqualX market discovery and greenfield storage reads.
contract EqualXViewFacet {
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

    function getEqualXMarketsByPosition(bytes32 positionKey)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = LibEqualXDiscoveryStorage.marketsByPosition(LibEqualXDiscoveryStorage.s(), positionKey);
    }

    function getEqualXMarketsByPair(address tokenA, address tokenB)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = LibEqualXDiscoveryStorage.marketsByPair(LibEqualXDiscoveryStorage.s(), tokenA, tokenB);
    }

    function getEqualXActiveMarkets(LibEqualXTypes.MarketType marketType)
        external
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        pointers = LibEqualXDiscoveryStorage.activeMarketsByType(LibEqualXDiscoveryStorage.s(), marketType);
    }
}
