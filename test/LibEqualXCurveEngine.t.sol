// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EqualXCurveFacetTest} from "test/EqualXCurveFacet.t.sol";
import {LibEqualXCurveEngine} from "src/libraries/LibEqualXCurveEngine.sol";

contract LibEqualXCurveEngineBugConditionTest is EqualXCurveFacetTest {
    function test_BugCondition_CurveSwap_ShouldRespectCanonicalMakerShare() public {
        uint256 canonicalMakerShareBps = 5000;
        harness.setFeeSplits(1000, canonicalMakerShareBps);

        vm.prank(alice);
        uint256 curveId = harness.createEqualXCurve(_defaultDescriptor());

        vm.warp(block.timestamp + 1 days);
        LibEqualXCurveEngine.CurveExecutionPreview memory preview = harness.previewEqualXCurveQuote(curveId, 10e18);

        vm.prank(bob);
        harness.executeEqualXCurveSwap(curveId, 10e18, preview.totalQuote, preview.amountOut, uint64(block.timestamp + 1 days), bob);

        uint256 expectedMakerFee = (preview.feeAmount * canonicalMakerShareBps) / 10_000;
        assertEq(harness.principalOf(2, alicePositionKey), 500e18 + 10e18 + expectedMakerFee);
    }

    function test_Integration_CurveSwap_ShouldAdoptUpdatedCanonicalMakerShareSource() public {
        vm.prank(alice);
        uint256 curveId = harness.createEqualXCurve(_defaultDescriptor());

        vm.warp(block.timestamp + 1 days);

        LibEqualXCurveEngine.CurveExecutionPreview memory firstPreview = harness.previewEqualXCurveQuote(curveId, 10e18);
        uint256 treasuryBalanceBeforeFirst = tokenB.balanceOf(treasury);
        uint256 yieldReserveBeforeFirst = harness.yieldReserveOf(2);
        uint256 makerPrincipalBeforeFirst = harness.principalOf(2, alicePositionKey);

        vm.prank(bob);
        harness.executeEqualXCurveSwap(
            curveId, 10e18, firstPreview.totalQuote, firstPreview.amountOut, uint64(block.timestamp + 1 days), bob
        );

        uint256 firstMakerFee = (firstPreview.feeAmount * 7000) / 10_000;
        uint256 firstProtocolFee = firstPreview.feeAmount - firstMakerFee;
        uint256 firstTreasuryFee = (firstProtocolFee * 1000) / 10_000;

        assertEq(harness.principalOf(2, alicePositionKey) - makerPrincipalBeforeFirst, 10e18 + firstMakerFee);
        assertEq(tokenB.balanceOf(treasury) - treasuryBalanceBeforeFirst, firstTreasuryFee);
        assertEq(harness.yieldReserveOf(2) - yieldReserveBeforeFirst, firstProtocolFee - firstTreasuryFee);

        harness.setFeeSplits(1000, 5000);

        LibEqualXCurveEngine.CurveExecutionPreview memory secondPreview = harness.previewEqualXCurveQuote(curveId, 10e18);
        uint256 treasuryBalanceBeforeSecond = tokenB.balanceOf(treasury);
        uint256 yieldReserveBeforeSecond = harness.yieldReserveOf(2);
        uint256 makerPrincipalBeforeSecond = harness.principalOf(2, alicePositionKey);

        vm.prank(bob);
        harness.executeEqualXCurveSwap(
            curveId, 10e18, secondPreview.totalQuote, secondPreview.amountOut, uint64(block.timestamp + 1 days), bob
        );

        uint256 secondMakerFee = (secondPreview.feeAmount * 5000) / 10_000;
        uint256 secondProtocolFee = secondPreview.feeAmount - secondMakerFee;
        uint256 secondTreasuryFee = (secondProtocolFee * 1000) / 10_000;

        assertEq(harness.principalOf(2, alicePositionKey) - makerPrincipalBeforeSecond, 10e18 + secondMakerFee);
        assertEq(tokenB.balanceOf(treasury) - treasuryBalanceBeforeSecond, secondTreasuryFee);
        assertEq(harness.yieldReserveOf(2) - yieldReserveBeforeSecond, secondProtocolFee - secondTreasuryFee);
        assertTrue(secondMakerFee != (secondPreview.feeAmount * 7000) / 10_000);
    }
}
