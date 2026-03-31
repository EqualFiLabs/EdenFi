// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualXViewFacet} from "../src/equalx/EqualXViewFacet.sol";
import {LibEqualXTypes} from "../src/libraries/LibEqualXTypes.sol";
import {LibEqualXDiscoveryStorage} from "../src/libraries/LibEqualXDiscoveryStorage.sol";
import {LibEqualXSoloAmmStorage} from "../src/libraries/LibEqualXSoloAmmStorage.sol";
import {LibEqualXCommunityAmmStorage} from "../src/libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCurveStorage} from "../src/libraries/LibEqualXCurveStorage.sol";

contract EqualXStorageHarness is EqualXViewFacet {
    function createSolo(bytes32 positionKey, uint256 positionId, address tokenA, address tokenB)
        external
        returns (uint256 marketId)
    {
        LibEqualXSoloAmmStorage.SoloAmmStorage storage store = LibEqualXSoloAmmStorage.s();
        marketId = LibEqualXSoloAmmStorage.allocateMarketId(store);
        store.markets[marketId] = LibEqualXSoloAmmStorage.SoloAmmMarket({
            makerPositionKey: positionKey,
            makerPositionId: positionId,
            poolIdA: 11,
            poolIdB: 22,
            tokenA: tokenA,
            tokenB: tokenB,
            reserveA: 100e18,
            reserveB: 200e18,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            feeBps: 30,
            feeAsset: LibEqualXTypes.FeeAsset.TokenIn,
            invariantMode: LibEqualXTypes.InvariantMode.Volatile,
            active: true,
            finalized: false
        });
        LibEqualXDiscoveryStorage.registerMarket(
            LibEqualXDiscoveryStorage.s(), positionKey, tokenA, tokenB, LibEqualXTypes.MarketType.SOLO_AMM, marketId
        );
    }

    function createCommunity(bytes32 positionKey, uint256 positionId, address tokenA, address tokenB)
        external
        returns (uint256 marketId)
    {
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        marketId = LibEqualXCommunityAmmStorage.allocateMarketId(store);
        store.markets[marketId] = LibEqualXCommunityAmmStorage.CommunityAmmMarket({
            creatorPositionKey: positionKey,
            creatorPositionId: positionId,
            poolIdA: 33,
            poolIdB: 44,
            tokenA: tokenA,
            tokenB: tokenB,
            reserveA: 300e18,
            reserveB: 600e18,
            totalShares: 42e18,
            makerCount: 1,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 2 days),
            feeBps: 100,
            feeAsset: LibEqualXTypes.FeeAsset.TokenOut,
            invariantMode: LibEqualXTypes.InvariantMode.Stable,
            feeIndexA: 0,
            feeIndexB: 0,
            feeIndexRemainderA: 0,
            feeIndexRemainderB: 0,
            treasuryFeeAAccrued: 0,
            treasuryFeeBAccrued: 0,
            feeIndexFeeAAccrued: 0,
            feeIndexFeeBAccrued: 0,
            activeCreditFeeAAccrued: 0,
            activeCreditFeeBAccrued: 0,
            active: true,
            finalized: false
        });
        LibEqualXDiscoveryStorage.registerMarket(
            LibEqualXDiscoveryStorage.s(),
            positionKey,
            tokenA,
            tokenB,
            LibEqualXTypes.MarketType.COMMUNITY_AMM,
            marketId
        );
    }

    function createCurve(bytes32 positionKey, uint256 positionId, address tokenA, address tokenB)
        external
        returns (uint256 curveId)
    {
        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        curveId = LibEqualXCurveStorage.allocateCurveId(store);
        store.markets[curveId] = LibEqualXCurveStorage.CurveMarket({
            commitment: keccak256(abi.encode(positionKey, positionId, tokenA, tokenB)),
            remainingVolume: 500e18,
            endTime: uint64(block.timestamp + 3 days),
            generation: 1,
            active: true
        });
        store.curveData[curveId] = LibEqualXCurveStorage.CurveData({
            makerPositionKey: positionKey,
            makerPositionId: positionId,
            poolIdA: 55,
            poolIdB: 66
        });
        store.curvePricing[curveId] = LibEqualXCurveStorage.CurvePricing({
            startPrice: 1e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp + 1 hours),
            duration: 7 days
        });
        store.curveProfileData[curveId] = LibEqualXCurveStorage.CurveProfileData({profileId: 1, profileParams: bytes32(0)});
        store.curveImmutables[curveId] = LibEqualXCurveStorage.CurveImmutables({
            tokenA: tokenA,
            tokenB: tokenB,
            maxVolume: 500e18,
            salt: 7,
            feeRateBps: 50,
            priceIsQuotePerBase: true,
            feeAsset: LibEqualXTypes.FeeAsset.TokenIn
        });
        store.curveBaseIsA[curveId] = true;
        LibEqualXDiscoveryStorage.registerMarket(
            LibEqualXDiscoveryStorage.s(),
            positionKey,
            tokenA,
            tokenB,
            LibEqualXTypes.MarketType.CURVE_LIQUIDITY,
            curveId
        );
    }
}

contract EqualXStorageTest is Test {
    EqualXStorageHarness internal harness;

    bytes32 internal constant POSITION_KEY_ONE = keccak256("position-one");
    bytes32 internal constant POSITION_KEY_TWO = keccak256("position-two");
    address internal constant TOKEN_A = address(0xA0);
    address internal constant TOKEN_B = address(0xB0);
    address internal constant TOKEN_C = address(0xC0);

    function setUp() public {
        harness = new EqualXStorageHarness();
    }

    function test_ModuleStorageMaintainsIndependentIdSequences() public {
        uint256 soloOne = harness.createSolo(POSITION_KEY_ONE, 1, TOKEN_A, TOKEN_B);
        uint256 soloTwo = harness.createSolo(POSITION_KEY_TWO, 2, TOKEN_B, TOKEN_C);
        uint256 communityOne = harness.createCommunity(POSITION_KEY_ONE, 3, TOKEN_A, TOKEN_B);
        uint256 curveOne = harness.createCurve(POSITION_KEY_ONE, 4, TOKEN_A, TOKEN_C);

        assertEq(soloOne, 1);
        assertEq(soloTwo, 2);
        assertEq(communityOne, 1);
        assertEq(curveOne, 1);
    }

    function test_DiscoveryIndexesStoreTypedPointersByPositionPairAndActiveStatus() public {
        uint256 soloId = harness.createSolo(POSITION_KEY_ONE, 1, TOKEN_A, TOKEN_B);
        uint256 communityId = harness.createCommunity(POSITION_KEY_ONE, 2, TOKEN_B, TOKEN_A);
        uint256 curveId = harness.createCurve(POSITION_KEY_TWO, 3, TOKEN_A, TOKEN_C);

        LibEqualXTypes.MarketPointer[] memory positionOne = harness.getEqualXMarketsByPosition(POSITION_KEY_ONE);
        assertEq(positionOne.length, 2);
        assertEq(uint8(positionOne[0].marketType), uint8(LibEqualXTypes.MarketType.SOLO_AMM));
        assertEq(positionOne[0].marketId, soloId);
        assertEq(uint8(positionOne[1].marketType), uint8(LibEqualXTypes.MarketType.COMMUNITY_AMM));
        assertEq(positionOne[1].marketId, communityId);

        LibEqualXTypes.MarketPointer[] memory pairAB = harness.getEqualXMarketsByPair(TOKEN_A, TOKEN_B);
        assertEq(pairAB.length, 2);
        assertEq(uint8(pairAB[0].marketType), uint8(LibEqualXTypes.MarketType.SOLO_AMM));
        assertEq(uint8(pairAB[1].marketType), uint8(LibEqualXTypes.MarketType.COMMUNITY_AMM));

        LibEqualXTypes.MarketPointer[] memory activeCurves =
            harness.getEqualXActiveMarkets(LibEqualXTypes.MarketType.CURVE_LIQUIDITY);
        assertEq(activeCurves.length, 1);
        assertEq(activeCurves[0].marketId, curveId);
    }

    function test_ViewFacetExposesStoredMarketShapes() public {
        uint256 soloId = harness.createSolo(POSITION_KEY_ONE, 10, TOKEN_A, TOKEN_B);
        uint256 communityId = harness.createCommunity(POSITION_KEY_ONE, 11, TOKEN_A, TOKEN_C);
        uint256 curveId = harness.createCurve(POSITION_KEY_TWO, 12, TOKEN_B, TOKEN_C);

        LibEqualXSoloAmmStorage.SoloAmmMarket memory solo = harness.getEqualXSoloAmmMarket(soloId);
        assertEq(solo.makerPositionId, 10);
        assertEq(solo.reserveA, 100e18);
        assertTrue(solo.active);

        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory community =
            harness.getEqualXCommunityAmmMarket(communityId);
        assertEq(community.creatorPositionId, 11);
        assertEq(community.totalShares, 42e18);
        assertEq(uint8(community.invariantMode), uint8(LibEqualXTypes.InvariantMode.Stable));

        (
            LibEqualXCurveStorage.CurveMarket memory curve,
            LibEqualXCurveStorage.CurveData memory data,
            LibEqualXCurveStorage.CurvePricing memory pricing,
            LibEqualXCurveStorage.CurveProfileData memory profileData,
            LibEqualXCurveStorage.CurveImmutables memory immutables,
            bool baseIsA
        ) = harness.getEqualXCurveMarket(curveId);

        assertEq(data.makerPositionId, 12);
        assertEq(curve.remainingVolume, 500e18);
        assertEq(pricing.startPrice, 1e18);
        assertEq(profileData.profileId, 1);
        assertEq(immutables.tokenA, TOKEN_B);
        assertTrue(baseIsA);
    }
}
