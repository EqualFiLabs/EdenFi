// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {SelfSecuredCreditFacet} from "src/equallend/SelfSecuredCreditFacet.sol";
import {SelfSecuredCreditViewFacet} from "src/equallend/SelfSecuredCreditViewFacet.sol";
import {Types} from "src/libraries/Types.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract SelfSecuredCreditViewFacetTest is LaunchFixture {
    uint256 internal constant ROUTED_SSC_ACI_YIELD = 6_999_999_999_999_999_960;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
        testSupport.setFoundationReceiver(treasury);
    }

    function test_LiveLaunch_SelfSecuredCreditView_InstallsSelectors() external view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.getSscLine.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.previewSscDraw.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.previewSscRepay.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.previewSscService.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.previewSscTerminalSettlement.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.claimableSscFeeYield.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.claimableSscAciYield.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.sscAciMode.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.pendingSscSelfPayEffect.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditViewFacet.maxAdditionalSscDraw.selector) != address(0));
    }

    function test_LiveFlow_SscLineDrawAndRepayViews_RoundTrip() external {
        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        vm.stopPrank();

        Types.SscLineView memory lineBefore = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, 1);
        assertEq(lineBefore.principal, 100 ether);
        assertEq(lineBefore.outstandingDebt, 0);
        assertEq(lineBefore.requiredLockedCapital, 0);
        assertEq(lineBefore.freeEquity, 100 ether);
        assertEq(lineBefore.maxAdditionalDraw, 80 ether);
        assertEq(lineBefore.claimableFeeYield, 0);
        assertEq(lineBefore.claimableAciYield, 0);
        assertEq(lineBefore.pendingSelfPayAciToDebt, 0);
        assertEq(uint8(lineBefore.aciMode), uint8(Types.SscAciMode.Yield));
        assertTrue(!lineBefore.active);
        assertEq(SelfSecuredCreditViewFacet(diamond).maxAdditionalSscDraw(positionId, 1), 80 ether);

        Types.SscDrawPreview memory drawPreview =
            SelfSecuredCreditViewFacet(diamond).previewSscDraw(positionId, 1, 60 ether);
        assertEq(drawPreview.requestedAmount, 60 ether);
        assertEq(drawPreview.appliedDrawAmount, 60 ether);
        assertEq(drawPreview.settledPrincipal, 100 ether);
        assertEq(drawPreview.outstandingDebtBefore, 0);
        assertEq(drawPreview.outstandingDebtAfter, 60 ether);
        assertEq(drawPreview.requiredLockedCapitalBefore, 0);
        assertEq(drawPreview.requiredLockedCapitalAfter, 75 ether);
        assertEq(drawPreview.additionalLockRequired, 75 ether);
        assertEq(drawPreview.maxAdditionalDraw, 80 ether);
        assertEq(drawPreview.availableTrackedLiquidity, 100 ether);
        assertEq(drawPreview.freeEquityAfter, 25 ether);
        assertTrue(!drawPreview.requestExceedsMaxDraw);
        assertTrue(drawPreview.lineActiveAfter);

        vm.prank(alice);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);

        Types.SscLineView memory lineAfterDraw = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, 1);
        assertEq(lineAfterDraw.outstandingDebt, drawPreview.outstandingDebtAfter);
        assertEq(lineAfterDraw.requiredLockedCapital, drawPreview.requiredLockedCapitalAfter);
        assertEq(lineAfterDraw.freeEquity, drawPreview.freeEquityAfter);
        assertEq(lineAfterDraw.maxAdditionalDraw, 20 ether);
        assertTrue(lineAfterDraw.active);

        Types.SscRepayPreview memory repayPreview =
            SelfSecuredCreditViewFacet(diamond).previewSscRepay(positionId, 1, 20 ether);
        assertEq(repayPreview.requestedRepayAmount, 20 ether);
        assertEq(repayPreview.appliedRepayAmount, 20 ether);
        assertEq(repayPreview.outstandingDebtBefore, 60 ether);
        assertEq(repayPreview.outstandingDebtAfter, 40 ether);
        assertEq(repayPreview.requiredLockedCapitalBefore, 75 ether);
        assertEq(repayPreview.requiredLockedCapitalAfter, 50 ether);
        assertEq(repayPreview.lockReleased, 25 ether);
        assertEq(repayPreview.claimableAciYield, 0);
        assertTrue(!repayPreview.lineCloses);

        vm.startPrank(alice);
        eve.approve(diamond, 20 ether);
        SelfSecuredCreditFacet(diamond).repaySelfSecuredCredit(positionId, 1, 20 ether, 20 ether);
        vm.stopPrank();

        Types.SscLineView memory lineAfterRepay = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, 1);
        assertEq(lineAfterRepay.outstandingDebt, repayPreview.outstandingDebtAfter);
        assertEq(lineAfterRepay.requiredLockedCapital, repayPreview.requiredLockedCapitalAfter);
        assertEq(lineAfterRepay.freeEquity, 50 ether);
        assertEq(lineAfterRepay.maxAdditionalDraw, 40 ether);
    }

    function test_LiveFlow_SscServiceViews_ExposeModeClaimsAndPendingSelfPay() external {
        testSupport.setFoundationReceiver(address(0));
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        SelfSecuredCreditFacet(diamond).setSelfSecuredCreditAciMode(positionId, 1, Types.SscAciMode.SelfPay);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        eve.mint(diamond, 10 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.view.service"), false, 10 ether);

        assertEq(SelfSecuredCreditViewFacet(diamond).claimableSscFeeYield(positionId, 1), 0.8 ether);
        assertEq(SelfSecuredCreditViewFacet(diamond).claimableSscAciYield(positionId, 1), 0);
        assertEq(uint8(SelfSecuredCreditViewFacet(diamond).sscAciMode(positionId, 1)), uint8(Types.SscAciMode.SelfPay));
        assertEq(SelfSecuredCreditViewFacet(diamond).pendingSscSelfPayEffect(positionId, 1), ROUTED_SSC_ACI_YIELD);

        Types.SscServicePreview memory servicePreview =
            SelfSecuredCreditViewFacet(diamond).previewSscService(positionId, 1);
        assertEq(servicePreview.settledPrincipal, 100 ether);
        assertEq(servicePreview.outstandingDebtBefore, 60 ether);
        assertEq(servicePreview.outstandingDebtAfter, 60 ether - ROUTED_SSC_ACI_YIELD);
        assertEq(servicePreview.requiredLockedCapitalBefore, 75 ether);
        assertTrue(servicePreview.requiredLockedCapitalAfter < servicePreview.requiredLockedCapitalBefore);
        assertEq(servicePreview.claimableFeeYield, 0.8 ether);
        assertEq(servicePreview.claimableAciYield, 0);
        assertEq(servicePreview.aciAppliedToDebt, ROUTED_SSC_ACI_YIELD);
        assertEq(uint8(servicePreview.aciMode), uint8(Types.SscAciMode.SelfPay));
        assertTrue(!servicePreview.unsafeAfterService);

        vm.prank(alice);
        SelfSecuredCreditFacet(diamond).serviceSelfSecuredCredit(positionId, 1);

        Types.SscLineView memory lineAfterService = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, 1);
        assertEq(lineAfterService.outstandingDebt, servicePreview.outstandingDebtAfter);
        assertEq(lineAfterService.requiredLockedCapital, servicePreview.requiredLockedCapitalAfter);
        assertEq(lineAfterService.claimableFeeYield, servicePreview.claimableFeeYield);
        assertEq(lineAfterService.claimableAciYield, servicePreview.claimableAciYield);
        assertEq(lineAfterService.pendingSelfPayAciToDebt, 0);
        assertGt(lineAfterService.maxAdditionalDraw, 20 ether);
    }

    function test_LiveFlow_SscTerminalSettlementPreview_RoundTrip() external {
        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 80 ether, 80 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        Types.SscTerminalSettlementPreview memory preview =
            SelfSecuredCreditViewFacet(diamond).previewSscTerminalSettlement(positionId, 1);
        assertEq(preview.principalBefore, 99 ether);
        assertEq(preview.outstandingDebtBefore, 80 ether);
        assertEq(preview.requiredLockedCapitalBefore, 100 ether);
        assertEq(preview.principalConsumed, 4 ether);
        assertEq(preview.debtRepaid, 4 ether);
        assertEq(preview.principalAfter, 95 ether);
        assertEq(preview.outstandingDebtAfter, 76 ether);
        assertEq(preview.requiredLockedCapitalAfter, 95 ether);
        assertTrue(preview.settlementRequired);
        assertTrue(!preview.lineClosed);

        vm.prank(bob);
        Types.SscTerminalSettlementPreview memory actual =
            SelfSecuredCreditFacet(diamond).selfSettleSelfSecuredCredit(positionId, 1);

        assertEq(actual.principalBefore, preview.principalBefore);
        assertEq(actual.outstandingDebtBefore, preview.outstandingDebtBefore);
        assertEq(actual.requiredLockedCapitalBefore, preview.requiredLockedCapitalBefore);
        assertEq(actual.principalConsumed, preview.principalConsumed);
        assertEq(actual.debtRepaid, preview.debtRepaid);
        assertEq(actual.principalAfter, preview.principalAfter);
        assertEq(actual.outstandingDebtAfter, preview.outstandingDebtAfter);
        assertEq(actual.requiredLockedCapitalAfter, preview.requiredLockedCapitalAfter);
        assertTrue(actual.settlementRequired == preview.settlementRequired);
        assertTrue(actual.lineClosed == preview.lineClosed);
    }
}
