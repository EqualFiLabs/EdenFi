// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../src/libraries/LibAppStorage.sol";
import {LibEqualXTypes} from "../src/libraries/LibEqualXTypes.sol";
import {LibEqualXSwapMath} from "../src/libraries/LibEqualXSwapMath.sol";
import {LibEqualXCommunityAmmStorage} from "../src/libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCommunityFeeIndex} from "../src/libraries/LibEqualXCommunityFeeIndex.sol";

contract LibEqualXMathHarness {
    function configureFeeRouter(address treasury, uint16 treasuryBps, uint16 activeCreditBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasury = treasury;
        store.treasuryShareBps = treasuryBps;
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = activeCreditBps;
        store.activeCreditShareConfigured = true;
    }

    function computeSwap(
        LibEqualXTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps
    ) external pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        return LibEqualXSwapMath.computeSwap(feeAsset, reserveIn, reserveOut, amountIn, feeBps);
    }

    function computeSwapByInvariant(
        LibEqualXTypes.InvariantMode invariantMode,
        LibEqualXTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps,
        uint8 decimalsIn,
        uint8 decimalsOut
    ) external pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        return
            LibEqualXSwapMath.computeSwapByInvariant(
                invariantMode, feeAsset, reserveIn, reserveOut, amountIn, feeBps, decimalsIn, decimalsOut
            );
    }

    function splitFeeWithRouter(
        uint256 feeAmount,
        uint16 makerBps
    )
        external
        view
        returns (uint256 makerFee, uint256 treasuryFee, uint256 activeCreditFee, uint256 feeIndexFee, uint256 protocolFee)
    {
        return LibEqualXSwapMath.previewProtocolSplit(feeAmount, makerBps);
    }

    function seedCommunityMarket(
        uint256 marketId,
        uint256 poolIdA,
        uint256 poolIdB,
        uint256 totalShares,
        bytes32 positionKey,
        uint256 share
    ) external {
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        store.markets[marketId].poolIdA = poolIdA;
        store.markets[marketId].poolIdB = poolIdB;
        store.markets[marketId].totalShares = totalShares;
        store.makers[marketId][positionKey].share = share;
    }

    function accrueTokenAFee(uint256 marketId, uint256 amount) external {
        LibEqualXCommunityFeeIndex.accrueTokenAFee(marketId, amount);
    }

    function accrueTokenBFee(uint256 marketId, uint256 amount) external {
        LibEqualXCommunityFeeIndex.accrueTokenBFee(marketId, amount);
    }

    function pendingFees(uint256 marketId, bytes32 positionKey) external view returns (uint256 feesA, uint256 feesB) {
        return LibEqualXCommunityFeeIndex.pendingFees(marketId, positionKey);
    }

    function settleMaker(uint256 marketId, bytes32 positionKey) external returns (uint256 feesA, uint256 feesB) {
        return LibEqualXCommunityFeeIndex.settleMaker(marketId, positionKey);
    }

    function marketState(uint256 marketId)
        external
        view
        returns (uint256 feeIndexA, uint256 feeIndexB, uint256 remainderA, uint256 remainderB)
    {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        return (market.feeIndexA, market.feeIndexB, market.feeIndexRemainderA, market.feeIndexRemainderB);
    }

    function accruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }
}

contract LibEqualXMathTest is Test {
    LibEqualXMathHarness internal harness;
    bytes32 internal constant MAKER_KEY = keccak256("maker");

    function setUp() public {
        harness = new LibEqualXMathHarness();
        harness.configureFeeRouter(address(0xBEEF), 1000, 7000);
    }

    function test_VolatileSwapMath_PreservesTokenInAndTokenOutSemantics() public view {
        (uint256 rawOutIn, uint256 feeIn, uint256 payoutIn) =
            harness.computeSwap(LibEqualXTypes.FeeAsset.TokenIn, 1000e18, 2000e18, 100e18, 300);
        assertEq(feeIn, 3e18);
        assertEq(rawOutIn, payoutIn);
        assertEq(payoutIn, 176845943482224247948);

        (uint256 rawOutOut, uint256 feeOut, uint256 payoutOut) =
            harness.computeSwap(LibEqualXTypes.FeeAsset.TokenOut, 1000e18, 2000e18, 100e18, 300);
        assertEq(rawOutOut, 181818181818181818181);
        assertEq(feeOut, 5454545454545454545);
        assertEq(payoutOut, rawOutOut - feeOut);
        assertLt(payoutOut, rawOutOut);
    }

    function test_StableSwapMath_ReturnsPositiveOutputAndFeeAwarePayout() public view {
        (uint256 rawOut, uint256 feeAmount, uint256 payout) = harness.computeSwapByInvariant(
            LibEqualXTypes.InvariantMode.Stable,
            LibEqualXTypes.FeeAsset.TokenOut,
            1_000_000e18,
            1_000_000e18,
            10_000e18,
            100,
            18,
            18
        );

        assertGt(rawOut, 0);
        assertEq(feeAmount, rawOut / 100);
        assertEq(payout, rawOut - feeAmount);
    }

    function test_SplitFeeWithRouter_PreservesMakerFirstProtocolRemainderRouting() public view {
        (uint256 makerFee, uint256 treasuryFee, uint256 activeFee, uint256 feeIndexFee, uint256 protocolFee) =
            harness.splitFeeWithRouter(10_000, 7_000);

        assertEq(makerFee, 7_000);
        assertEq(protocolFee, 3_000);
        assertEq(treasuryFee, 300);
        assertEq(activeFee, 2_100);
        assertEq(feeIndexFee, 600);
    }

    function test_CommunityFeeIndex_AccruesRemaindersAndSettlesToPoolYield() public {
        harness.seedCommunityMarket(1, 11, 22, 3, MAKER_KEY, 1);

        harness.accrueTokenAFee(1, 1);
        (uint256 feeIndexA,, uint256 remainderA,) = harness.marketState(1);
        assertEq(feeIndexA, 333333333333333333);
        assertEq(remainderA, 1);

        (uint256 pendingA, uint256 pendingB) = harness.pendingFees(1, MAKER_KEY);
        assertEq(pendingA, 0);
        assertEq(pendingB, 0);

        harness.accrueTokenAFee(1, 2);
        (feeIndexA,, remainderA,) = harness.marketState(1);
        assertEq(feeIndexA, 1000000000000000000);
        assertEq(remainderA, 0);

        (pendingA, pendingB) = harness.pendingFees(1, MAKER_KEY);
        assertEq(pendingA, 1);
        assertEq(pendingB, 0);

        (uint256 settledA, uint256 settledB) = harness.settleMaker(1, MAKER_KEY);
        assertEq(settledA, 1);
        assertEq(settledB, 0);
        assertEq(harness.accruedYield(11, MAKER_KEY), 1);
    }

    function test_CommunityFeeIndex_SettlesTokenBIndependently() public {
        harness.seedCommunityMarket(2, 101, 202, 10e18, MAKER_KEY, 2e18);
        harness.accrueTokenBFee(2, 5e18);

        (uint256 pendingA, uint256 pendingB) = harness.pendingFees(2, MAKER_KEY);
        assertEq(pendingA, 0);
        assertEq(pendingB, 1e18);

        harness.settleMaker(2, MAKER_KEY);
        assertEq(harness.accruedYield(202, MAKER_KEY), 1e18);
    }
}
