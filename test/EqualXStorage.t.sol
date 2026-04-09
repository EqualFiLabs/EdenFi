// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EqualXViewFacet} from "../src/equalx/EqualXViewFacet.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "../src/libraries/LibEncumbrance.sol";
import {LibEqualXTypes} from "../src/libraries/LibEqualXTypes.sol";
import {LibEqualXDiscoveryStorage} from "../src/libraries/LibEqualXDiscoveryStorage.sol";
import {LibEqualXSoloAmmStorage} from "../src/libraries/LibEqualXSoloAmmStorage.sol";
import {LibEqualXCommunityAmmStorage} from "../src/libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCurveStorage} from "../src/libraries/LibEqualXCurveStorage.sol";
import {LibEqualXCurveEngine} from "../src/libraries/LibEqualXCurveEngine.sol";
import {LibPositionNFT} from "../src/libraries/LibPositionNFT.sol";

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
            baselineReserveA: 100e18,
            baselineReserveB: 200e18,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            lastRebalanceExecutionAt: 0,
            rebalanceTimelock: 15 minutes,
            feeBps: 30,
            feeAsset: LibEqualXTypes.FeeAsset.TokenIn,
            invariantMode: LibEqualXTypes.InvariantMode.Volatile,
            tokenADecimals: 18,
            tokenBDecimals: 18,
            makerFeeAAccrued: 0,
            makerFeeBAccrued: 0,
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
            LibEqualXDiscoveryStorage.s(), positionKey, tokenA, tokenB, LibEqualXTypes.MarketType.SOLO_AMM, marketId
        );
    }

    function setSoloPendingRebalance(
        uint256 marketId,
        uint256 snapshotReserveA,
        uint256 snapshotReserveB,
        uint256 targetReserveA,
        uint256 targetReserveB,
        uint64 executeAfter,
        bool exists
    ) external {
        LibEqualXSoloAmmStorage.s().pendingRebalances[marketId] = LibEqualXSoloAmmStorage.SoloAmmPendingRebalance({
            snapshotReserveA: snapshotReserveA,
            snapshotReserveB: snapshotReserveB,
            targetReserveA: targetReserveA,
            targetReserveB: targetReserveB,
            executeAfter: executeAfter,
            exists: exists
        });
    }

    function getSoloPendingRebalance(uint256 marketId)
        external
        view
        returns (LibEqualXSoloAmmStorage.SoloAmmPendingRebalance memory pending)
    {
        pending = LibEqualXSoloAmmStorage.s().pendingRebalances[marketId];
    }

    function getSoloMinRebalanceTimelock() external view returns (uint64) {
        return LibEqualXSoloAmmStorage.minRebalanceTimelock(LibEqualXSoloAmmStorage.s());
    }

    function soloStorageSlot() external pure returns (bytes32) {
        return LibEqualXSoloAmmStorage.STORAGE_POSITION;
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
            tokenADecimals: 18,
            tokenBDecimals: 18,
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

    function setCommunityMaker(
        uint256 marketId,
        bytes32 positionKey,
        uint256 share,
        uint256 snapshotA,
        uint256 snapshotB,
        uint256 initialContributionA,
        uint256 initialContributionB,
        bool isParticipant
    ) external {
        LibEqualXCommunityAmmStorage.s().makers[marketId][positionKey] = LibEqualXCommunityAmmStorage.CommunityMakerPosition({
            share: share,
            feeIndexSnapshotA: snapshotA,
            feeIndexSnapshotB: snapshotB,
            initialContributionA: initialContributionA,
            initialContributionB: initialContributionB,
            isParticipant: isParticipant
        });
        LibEqualXDiscoveryStorage.addPositionMarket(
            LibEqualXDiscoveryStorage.s(), positionKey, LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId
        );
    }

    function setCommunityFeeIndexes(uint256 marketId, uint256 feeIndexA, uint256 feeIndexB) external {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        market.feeIndexA = feeIndexA;
        market.feeIndexB = feeIndexB;
    }

    function setSoloState(uint256 marketId, bool active, bool finalized) external {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        market.active = active;
        market.finalized = finalized;
    }

    function closeSolo(uint256 marketId) external {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        market.active = false;
        market.finalized = true;
        LibEqualXDiscoveryStorage.removeActiveMarket(
            LibEqualXDiscoveryStorage.s(), LibEqualXTypes.MarketType.SOLO_AMM, marketId
        );
    }

    function registerSoloAgain(bytes32 positionKey, address tokenA, address tokenB, uint256 marketId) external {
        LibEqualXDiscoveryStorage.registerMarket(
            LibEqualXDiscoveryStorage.s(), positionKey, tokenA, tokenB, LibEqualXTypes.MarketType.SOLO_AMM, marketId
        );
    }

    function setSoloRebalanceTiming(uint256 marketId, uint64 lastRebalanceExecutionAt, uint64 rebalanceTimelock) external {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        market.lastRebalanceExecutionAt = lastRebalanceExecutionAt;
        market.rebalanceTimelock = rebalanceTimelock;
    }

    function setCommunityState(uint256 marketId, bool active, bool finalized) external {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        market.active = active;
        market.finalized = finalized;
    }

    function setCurveState(
        uint256 curveId,
        bool active,
        uint32 generation,
        bytes32 commitment,
        uint128 remainingVolume,
        uint64 endTime
    ) external {
        LibEqualXCurveStorage.CurveMarket storage market = LibEqualXCurveStorage.s().markets[curveId];
        market.active = active;
        market.generation = generation;
        market.commitment = commitment;
        market.remainingVolume = remainingVolume;
        market.endTime = endTime;
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

    function test_BugCondition_DiscoverySemantics_ShouldPreserveHistoricalPointersAfterSoloClose() public {
        uint256 soloId = harness.createSolo(POSITION_KEY_ONE, 1, TOKEN_A, TOKEN_B);

        harness.closeSolo(soloId);

        LibEqualXTypes.MarketPointer[] memory historicalByPosition = harness.getEqualXMarketsByPosition(POSITION_KEY_ONE);
        LibEqualXTypes.MarketPointer[] memory historicalByPair = harness.getEqualXMarketsByPair(TOKEN_A, TOKEN_B);
        LibEqualXTypes.MarketPointer[] memory activeSolo =
            harness.getEqualXActiveMarkets(LibEqualXTypes.MarketType.SOLO_AMM);

        assertEq(historicalByPosition.length, 1);
        assertEq(historicalByPosition[0].marketId, soloId);
        assertEq(historicalByPair.length, 1);
        assertEq(historicalByPair[0].marketId, soloId);
        assertEq(activeSolo.length, 0);
    }

    function test_BugCondition_DiscoveryDuplicate_ShouldNotDuplicateMarketPointers() public {
        uint256 soloId = harness.createSolo(POSITION_KEY_ONE, 1, TOKEN_A, TOKEN_B);

        harness.registerSoloAgain(POSITION_KEY_ONE, TOKEN_A, TOKEN_B, soloId);

        LibEqualXTypes.MarketPointer[] memory byPosition = harness.getEqualXMarketsByPosition(POSITION_KEY_ONE);
        LibEqualXTypes.MarketPointer[] memory byPair = harness.getEqualXMarketsByPair(TOKEN_A, TOKEN_B);
        LibEqualXTypes.MarketPointer[] memory activeSolo =
            harness.getEqualXActiveMarkets(LibEqualXTypes.MarketType.SOLO_AMM);

        assertEq(byPosition.length, 1, "position discovery should deduplicate market pointers");
        assertEq(byPair.length, 1, "pair discovery should deduplicate market pointers");
        assertEq(activeSolo.length, 1, "active discovery should deduplicate market pointers");
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
        assertEq(solo.baselineReserveA, 100e18);
        assertEq(solo.baselineReserveB, 200e18);
        assertEq(solo.rebalanceTimelock, 15 minutes);
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

    function test_ViewFacetAddsTypedDiscoveryStatusAndMakerPendingReads() public {
        uint256 soloId = harness.createSolo(POSITION_KEY_ONE, 10, TOKEN_A, TOKEN_B);
        uint256 communityId = harness.createCommunity(POSITION_KEY_ONE, 11, TOKEN_A, TOKEN_B);
        uint256 curveId = harness.createCurve(POSITION_KEY_ONE, 12, TOKEN_A, TOKEN_C);

        harness.setCommunityMaker(communityId, POSITION_KEY_TWO, 21e18, 1e18, 2e18, 50e18, 80e18, true);
        harness.setCommunityFeeIndexes(communityId, 4e18, 5e18);
        harness.setSoloState(soloId, false, true);
        harness.setCurveState(curveId, false, 2, keccak256("new-commitment"), 125e18, uint64(block.timestamp - 1));

        LibEqualXTypes.MarketPointer[] memory communityOnly =
            harness.getEqualXMarketsByPositionAndType(POSITION_KEY_ONE, LibEqualXTypes.MarketType.COMMUNITY_AMM);
        assertEq(communityOnly.length, 1);
        assertEq(communityOnly[0].marketId, communityId);

        LibEqualXTypes.MarketPointer[] memory pairSoloOnly =
            harness.getEqualXMarketsByPairAndType(TOKEN_A, TOKEN_B, LibEqualXTypes.MarketType.SOLO_AMM);
        assertEq(pairSoloOnly.length, 1);
        assertEq(pairSoloOnly[0].marketId, soloId);

        LibEqualXTypes.MarketPointer[] memory activeByPair = harness.getEqualXActiveMarketsByPair(TOKEN_A, TOKEN_B);
        assertEq(activeByPair.length, 1);
        assertEq(uint8(activeByPair[0].marketType), uint8(LibEqualXTypes.MarketType.COMMUNITY_AMM));

        EqualXViewFacet.EqualXLinearMarketStatus memory soloStatus = harness.getEqualXSoloAmmStatus(soloId);
        assertTrue(soloStatus.exists);
        assertFalse(soloStatus.active);
        assertTrue(soloStatus.finalized);
        assertFalse(soloStatus.live);

        EqualXViewFacet.EqualXLinearMarketStatus memory communityStatus = harness.getEqualXCommunityAmmStatus(communityId);
        assertTrue(communityStatus.exists);
        assertTrue(communityStatus.active);
        assertTrue(communityStatus.live);

        EqualXViewFacet.EqualXCurveStatus memory curveStatus = harness.getEqualXCurveStatus(curveId);
        assertTrue(curveStatus.exists);
        assertFalse(curveStatus.active);
        assertTrue(curveStatus.expired);
        assertEq(curveStatus.generation, 2);
        assertEq(curveStatus.remainingVolume, 125e18);

        EqualXViewFacet.EqualXCommunityMakerView memory makerView =
            harness.getEqualXCommunityMakerView(communityId, POSITION_KEY_TWO);
        assertEq(makerView.maker.share, 21e18);
        assertEq(makerView.pendingFeesA, 63e18);
        assertEq(makerView.pendingFeesB, 63e18);

        (uint256 feesA, uint256 feesB) = harness.previewEqualXCommunityMakerFees(communityId, POSITION_KEY_TWO);
        assertEq(feesA, 63e18);
        assertEq(feesB, 63e18);
    }

    function test_ViewFacetQuoteHelpersMatchStoredMarketMath() public {
        uint256 soloId = harness.createSolo(POSITION_KEY_ONE, 10, TOKEN_A, TOKEN_B);
        uint256 communityId = harness.createCommunity(POSITION_KEY_ONE, 11, TOKEN_A, TOKEN_B);
        uint256 curveId = harness.createCurve(POSITION_KEY_ONE, 12, TOKEN_A, TOKEN_C);

        EqualXViewFacet.EqualXSwapQuote memory soloQuote = harness.quoteEqualXSoloAmmExactIn(soloId, TOKEN_A, 10e18);
        assertEq(soloQuote.feePoolId, 11);
        assertEq(soloQuote.feeToken, TOKEN_A);
        assertGt(soloQuote.amountOut, 0);
        assertGt(soloQuote.feeAmount, 0);

        EqualXViewFacet.EqualXSwapQuote memory communityQuote =
            harness.quoteEqualXCommunityAmmExactIn(communityId, TOKEN_A, 10e18);
        assertEq(communityQuote.feePoolId, 44);
        assertEq(communityQuote.feeToken, TOKEN_B);
        assertGt(communityQuote.amountOut, 0);
        assertGt(communityQuote.feeAmount, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        LibEqualXCurveEngine.CurveExecutionPreview memory curveQuote = harness.quoteEqualXCurveExactIn(curveId, 10e18);
        assertEq(curveQuote.basePoolId, 55);
        assertEq(curveQuote.quotePoolId, 66);
        assertEq(curveQuote.baseToken, TOKEN_A);
        assertEq(curveQuote.quoteToken, TOKEN_C);
        assertGt(curveQuote.amountOut, 0);
    }

    function test_SoloAmmStorageTracksPendingRebalanceStateAndDefaultFloor() public {
        vm.warp(block.timestamp + 10 minutes);
        uint256 soloId = harness.createSolo(POSITION_KEY_ONE, 10, TOKEN_A, TOKEN_B);

        assertEq(harness.getSoloMinRebalanceTimelock(), 1 minutes);

        harness.setSoloRebalanceTiming(soloId, uint64(block.timestamp - 5 minutes), 30 minutes);
        harness.setSoloPendingRebalance(soloId, 100e18, 200e18, 105e18, 190e18, uint64(block.timestamp + 15 minutes), true);
        LibEqualXSoloAmmStorage.SoloAmmPendingRebalance memory pending = harness.getSoloPendingRebalance(soloId);
        EqualXViewFacet.EqualXSoloAmmPendingRebalanceView memory pendingView =
            harness.getEqualXSoloAmmPendingRebalance(soloId);

        assertEq(pending.snapshotReserveA, 100e18);
        assertEq(pending.snapshotReserveB, 200e18);
        assertEq(pending.targetReserveA, 105e18);
        assertEq(pending.targetReserveB, 190e18);
        assertEq(pending.executeAfter, uint64(block.timestamp + 15 minutes));
        assertTrue(pending.exists);
        assertTrue(pendingView.exists);
        assertEq(pendingView.snapshotReserveA, 100e18);
        assertEq(pendingView.snapshotReserveB, 200e18);
        assertEq(pendingView.targetReserveA, 105e18);
        assertEq(pendingView.targetReserveB, 190e18);
        assertEq(pendingView.executeAfter, uint64(block.timestamp + 15 minutes));
        assertEq(pendingView.lastRebalanceExecutionAt, uint64(block.timestamp - 5 minutes));
        assertEq(pendingView.rebalanceTimelock, 30 minutes);
    }

    function test_SoloAmmStorageSlotDoesNotCollideWithCoreStorages() public {
        bytes32 slot_ = harness.soloStorageSlot();

        assertTrue(slot_ != LibAppStorage.APP_STORAGE_POSITION, "collides with app storage");
        assertTrue(slot_ != LibDiamond.DIAMOND_STORAGE_POSITION, "collides with diamond storage");
        assertTrue(slot_ != LibEncumbrance.STORAGE_POSITION, "collides with encumbrance");
        assertTrue(slot_ != LibPositionNFT.POSITION_NFT_STORAGE_POSITION, "collides with position nft");
        assertTrue(slot_ != LibEqualXDiscoveryStorage.STORAGE_POSITION, "collides with equalx discovery");
        assertTrue(slot_ != LibEqualXCommunityAmmStorage.STORAGE_POSITION, "collides with community amm");
        assertTrue(slot_ != LibEqualXCurveStorage.STORAGE_POSITION, "collides with curve storage");
    }
}
