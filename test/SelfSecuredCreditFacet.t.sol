// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {SelfSecuredCreditFacet} from "src/equallend/SelfSecuredCreditFacet.sol";
import {SelfSecuredCreditViewFacet} from "src/equallend/SelfSecuredCreditViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {
    InsufficientPoolLiquidity,
    InsufficientPrincipal,
    LoanBelowMinimum,
    NotNFTOwner,
    SolvencyViolation
} from "src/libraries/Errors.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {Types} from "src/libraries/Types.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract SelfSecuredCreditFacetTest is LaunchFixture {
    uint256 internal constant ROUTED_SSC_ACI_YIELD = 6_999_999_999_999_999_960;
    uint256 internal constant ROUTED_SSC_ACI_YIELD_AFTER_RETURN = 13_999_999_999_999_999_980;
    uint256 internal constant ROUTED_SSC_ACI_OVERFLOW_AFTER_CLOSE = 2 ether;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
        testSupport.setFoundationReceiver(treasury);
    }

    function test_LiveLaunch_SelfSecuredCredit_InstallsLifecycleSelectors() external view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.drawSelfSecuredCredit.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.repaySelfSecuredCredit.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.closeSelfSecuredCredit.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.previewSelfSecuredCreditMaintenance.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.getSelfSecuredCreditLineView.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.setSelfSecuredCreditAciMode.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.serviceSelfSecuredCredit.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.selfSettleSelfSecuredCredit.selector) != address(0));
    }

    function test_LiveFlow_SelfSecuredCredit_DepositDrawRepayCloseWithdrawAndCleanup() external {
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);

        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        uint256 drawReceived = SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        vm.stopPrank();

        assertEq(drawReceived, 60 ether);
        assertEq(eve.balanceOf(alice), 60 ether);
        assertEq(testSupport.principalOf(1, positionKey), 100 ether);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), 60 ether);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 75 ether);

        Types.SscLine memory lineAfterDraw = testSupport.sscLineOf(1, positionKey);
        assertEq(lineAfterDraw.outstandingDebt, 60 ether);
        assertEq(lineAfterDraw.requiredLockedCapital, 75 ether);
        assertTrue(lineAfterDraw.active);
        assertEq(PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance, 40 ether);

        (bool canClearWhileOpen, string memory reasonWhileOpen) = testSupport.canClearMembership(1, positionKey);
        assertTrue(!canClearWhileOpen);
        assertEq(reasonWhileOpen, "principal>0");

        vm.startPrank(alice);
        eve.approve(diamond, 60 ether);
        uint256 partialRepay = SelfSecuredCreditFacet(diamond).repaySelfSecuredCredit(positionId, 1, 20 ether, 20 ether);
        vm.stopPrank();

        assertEq(partialRepay, 20 ether);
        assertEq(eve.balanceOf(alice), 40 ether);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), 40 ether);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 50 ether);
        assertEq(PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance, 60 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 60 ether, 50 ether));
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, 1, 60 ether, 60 ether);

        vm.startPrank(alice);
        uint256 closedAmount = SelfSecuredCreditFacet(diamond).closeSelfSecuredCredit(positionId, 1, 40 ether);
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, 1, 100 ether, 100 ether);
        PositionManagementFacet(diamond).cleanupMembership(positionId, 1);
        vm.stopPrank();

        assertEq(closedAmount, 40 ether);
        assertEq(testSupport.principalOf(1, positionKey), 0);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), 0);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 0);
        assertEq(PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance, 0);
        assertEq(eve.balanceOf(alice), 100 ether);

        Types.SscLine memory lineAfterClose = testSupport.sscLineOf(1, positionKey);
        assertEq(lineAfterClose.outstandingDebt, 0);
        assertEq(lineAfterClose.requiredLockedCapital, 0);
        assertTrue(!lineAfterClose.active);
    }

    function test_Draw_RevertsBelowMinimumAboveTrackedLiquidityAndOverLtv() external {
        uint256 alicePositionId = _mintPosition(alice, 1);
        eve.mint(alice, 1_000 ether);

        vm.startPrank(alice);
        eve.approve(diamond, 1_000 ether);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 100 ether, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(LoanBelowMinimum.selector, 0.5 ether, 1 ether));
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(alicePositionId, 1, 0.5 ether, 0.5 ether);
        vm.expectRevert(abi.encodeWithSelector(SolvencyViolation.selector, 100 ether, 81 ether, 8_000));
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(alicePositionId, 1, 81 ether, 81 ether);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 900 ether, 900 ether);
        vm.stopPrank();

        // Synthetic branch coverage: SSC-only flows keep tracked liquidity above
        // the depositor-LTV max draw, so we use the test support facet to model
        // external tracked-liquidity consumption from other pool modules.
        testSupport.setPoolTrackedBalance(1, 500 ether);
        assertEq(PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance, 500 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolLiquidity.selector, 800 ether, 500 ether));
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(alicePositionId, 1, 800 ether, 800 ether);
    }

    function test_MaintenancePreview_ReducesSafeHeadroomOverTime() external {
        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        vm.stopPrank();

        Types.SscMaintenancePreview memory beforeWarp =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, 1);
        assertEq(beforeWarp.settledPrincipal, 100 ether);
        assertEq(beforeWarp.requiredLockedCapital, 75 ether);
        assertEq(beforeWarp.freeEquity, 25 ether);
        assertEq(beforeWarp.remainingBorrowRunway, 20 ether);
        assertTrue(!beforeWarp.unsafeAfterMaintenance);

        vm.warp(block.timestamp + 365 days);

        Types.SscMaintenancePreview memory afterWarp =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, 1);
        assertEq(afterWarp.settledPrincipal, 99 ether);
        assertEq(afterWarp.requiredLockedCapital, 75 ether);
        assertEq(afterWarp.freeEquity, 24 ether);
        assertEq(afterWarp.remainingBorrowRunway, 19.2 ether);
        assertTrue(!afterWarp.unsafeAfterMaintenance);
    }

    function test_Draw_SettlesMaintenanceBeforeDebtSensitiveChecks() external {
        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        Types.SscMaintenancePreview memory preview =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, 1);
        assertEq(preview.settledPrincipal, 99 ether);
        assertEq(preview.remainingBorrowRunway, 79.2 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SolvencyViolation.selector, 99 ether, 79.5 ether, 8_000));
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 79.5 ether, 79.5 ether);
    }

    function test_HighLtvSscPosition_CannotIgnoreMaintenanceIndefinitely() external {
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 80 ether, 80 ether);
        vm.stopPrank();

        Types.SscMaintenancePreview memory beforeWarp =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, 1);
        assertEq(beforeWarp.remainingBorrowRunway, 0);
        assertTrue(!beforeWarp.unsafeAfterMaintenance);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 100 ether);

        vm.warp(block.timestamp + 365 days);

        Types.SscMaintenancePreview memory afterWarp =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, 1);
        assertEq(afterWarp.settledPrincipal, 99 ether);
        assertEq(afterWarp.remainingBorrowRunway, 0);
        assertTrue(afterWarp.unsafeAfterMaintenance);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 100 ether, 99 ether));
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, 1, 1 ether, 1 ether);
    }

    function test_LiveFlow_SscLineView_SeparatesFiAndClaimableSscAci() external {
        testSupport.setFoundationReceiver(address(0));
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        eve.mint(diamond, 10 ether);

        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) =
            testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.claim.view"), false, 10 ether);
        assertEq(toTreasury, 1 ether);
        assertEq(toActiveCredit, 7 ether);
        assertEq(toFeeIndex, 2 ether);

        Types.SscLineView memory lineView = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(lineView.claimableFeeYield, 0.8 ether);
        assertEq(lineView.claimableAciYield, ROUTED_SSC_ACI_YIELD);
        assertEq(lineView.totalAciAppliedToDebt, 0);
        assertEq(lineView.freeEquity, 25 ether);
        assertEq(uint8(lineView.aciMode), uint8(Types.SscAciMode.Yield));
        assertTrue(lineView.active);

        assertEq(PositionManagementFacet(diamond).previewPositionYield(positionId, 1), 0.8 ether);
    }

    function test_LiveFlow_PositionClaim_RemainsFiOnlyWhenSscAciIsSeparated() external {
        testSupport.setFoundationReceiver(address(0));
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        eve.mint(diamond, 10 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.fi.claim"), false, 10 ether);

        uint256 claimable = PositionManagementFacet(diamond).previewPositionYield(positionId, 1);
        assertEq(claimable, 0.8 ether);

        vm.prank(alice);
        uint256 claimed = PositionManagementFacet(diamond).claimPositionYield(positionId, 1, alice, claimable);
        assertEq(claimed, 0.8 ether);
        assertEq(eve.balanceOf(alice), 60.8 ether);

        Types.SscLineView memory lineView = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(lineView.claimableFeeYield, 0);
        assertEq(lineView.claimableAciYield, ROUTED_SSC_ACI_YIELD);
        assertEq(PositionManagementFacet(diamond).previewPositionYield(positionId, 1), 0);
    }

    function test_LiveFlow_SscAciModeSwitch_IsOwnerControlledAndProspective() external {
        testSupport.setFoundationReceiver(address(0));
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, bob, positionId));
        SelfSecuredCreditFacet(diamond).setSelfSecuredCreditAciMode(positionId, 1, Types.SscAciMode.SelfPay);

        vm.warp(block.timestamp + 25 hours);
        eve.mint(diamond, 10 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.mode.before"), false, 10 ether);

        Types.SscLineView memory beforeSwitch = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(uint8(beforeSwitch.aciMode), uint8(Types.SscAciMode.Yield));
        assertEq(beforeSwitch.claimableAciYield, ROUTED_SSC_ACI_YIELD);

        vm.prank(alice);
        SelfSecuredCreditFacet(diamond).setSelfSecuredCreditAciMode(positionId, 1, Types.SscAciMode.SelfPay);

        Types.SscLineView memory selfPayView = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(uint8(selfPayView.aciMode), uint8(Types.SscAciMode.SelfPay));
        assertEq(selfPayView.claimableAciYield, ROUTED_SSC_ACI_YIELD);

        vm.prank(alice);
        SelfSecuredCreditFacet(diamond).setSelfSecuredCreditAciMode(positionId, 1, Types.SscAciMode.Yield);

        Types.SscLineView memory yieldView = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(uint8(yieldView.aciMode), uint8(Types.SscAciMode.Yield));
        assertEq(yieldView.claimableAciYield, ROUTED_SSC_ACI_YIELD);

        eve.mint(diamond, 20 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.mode.after"), false, 20 ether);

        Types.SscLineView memory afterReturn = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(uint8(afterReturn.aciMode), uint8(Types.SscAciMode.Yield));
        assertEq(afterReturn.claimableFeeYield, 1.6 ether);
        assertEq(afterReturn.claimableAciYield, ROUTED_SSC_ACI_YIELD_AFTER_RETURN);
    }

    function test_LiveFlow_SelfPayService_ReducesDebtAndRestoresFeeBase() external {
        testSupport.setFoundationReceiver(address(0));
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        SelfSecuredCreditFacet(diamond).setSelfSecuredCreditAciMode(positionId, 1, Types.SscAciMode.SelfPay);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        eve.mint(diamond, 10 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.selfpay.first"), false, 10 ether);

        Types.SscLineView memory beforeService = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(beforeService.outstandingDebt, 60 ether);
        assertEq(beforeService.freeEquity, 25 ether);
        assertEq(beforeService.claimableAciYield, 0);
        assertEq(beforeService.claimableFeeYield, 0.8 ether);

        vm.prank(alice);
        uint256 appliedToDebt = SelfSecuredCreditFacet(diamond).serviceSelfSecuredCredit(positionId, 1);
        assertEq(appliedToDebt, ROUTED_SSC_ACI_YIELD);

        Types.SscLineView memory afterService = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(afterService.totalAciAppliedToDebt, ROUTED_SSC_ACI_YIELD);
        assertEq(afterService.claimableAciYield, 0);
        assertEq(afterService.claimableFeeYield, 0.8 ether);
        assertTrue(afterService.outstandingDebt < beforeService.outstandingDebt);
        assertTrue(afterService.requiredLockedCapital < beforeService.requiredLockedCapital);
        assertGt(afterService.freeEquity, beforeService.freeEquity);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), afterService.outstandingDebt);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), afterService.requiredLockedCapital);
        assertEq(PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance, 40 ether + ROUTED_SSC_ACI_YIELD);

        uint256 feeYieldBeforeSecondRoute = afterService.claimableFeeYield;

        eve.mint(diamond, 20 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.selfpay.second"), false, 20 ether);

        Types.SscLineView memory afterSecondRoute =
            SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        uint256 incrementalFi = afterSecondRoute.claimableFeeYield - feeYieldBeforeSecondRoute;
        assertGt(incrementalFi, 0.8 ether);
    }

    function test_LiveFlow_SelfPayService_OverflowClosesDebtAndLeavesClaimableAci() external {
        testSupport.setFoundationReceiver(address(0));
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 5 ether, 5 ether);
        SelfSecuredCreditFacet(diamond).setSelfSecuredCreditAciMode(positionId, 1, Types.SscAciMode.SelfPay);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        eve.mint(diamond, 10 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.selfpay.overflow"), false, 10 ether);

        vm.prank(alice);
        uint256 appliedToDebt = SelfSecuredCreditFacet(diamond).serviceSelfSecuredCredit(positionId, 1);
        assertEq(appliedToDebt, 5 ether);

        Types.SscLineView memory afterOverflow = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(afterOverflow.outstandingDebt, 0);
        assertEq(afterOverflow.requiredLockedCapital, 0);
        assertEq(afterOverflow.totalAciAppliedToDebt, 5 ether);
        assertEq(afterOverflow.claimableAciYield, ROUTED_SSC_ACI_OVERFLOW_AFTER_CLOSE);
        assertEq(afterOverflow.freeEquity, 100 ether);
        assertTrue(!afterOverflow.active);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), 0);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 0);
        assertEq(PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance, 100 ether);
    }

    function test_LiveFlow_LockedCapital_BlocksUnsafeWithdrawalBoundary() external {
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, 1, 25 ether, 25 ether);
        vm.stopPrank();

        Types.SscLineView memory lineView = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, 1);
        assertEq(lineView.principal, 75 ether);
        assertEq(lineView.outstandingDebt, 60 ether);
        assertEq(lineView.requiredLockedCapital, 75 ether);
        assertEq(lineView.freeEquity, 0);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 75 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 1 ether, 0));
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, 1, 1 ether, 1 ether);
    }

    function test_LiveFlow_SscAciModeSwitch_DoesNotRetroactivelyReclassifyAccruedAci() external {
        testSupport.setFoundationReceiver(address(0));
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        uint256 positionId = _mintPosition(alice, 1);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        eve.mint(diamond, 10 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.reclassify.before"), false, 10 ether);

        Types.SscLineView memory beforeSwitch = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, 1);
        assertEq(beforeSwitch.claimableAciYield, ROUTED_SSC_ACI_YIELD);
        assertEq(beforeSwitch.totalAciAppliedToDebt, 0);

        vm.prank(alice);
        SelfSecuredCreditFacet(diamond).setSelfSecuredCreditAciMode(positionId, 1, Types.SscAciMode.SelfPay);

        eve.mint(diamond, 20 ether);
        testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.reclassify.after"), false, 20 ether);

        uint256 pendingSelfPay = SelfSecuredCreditViewFacet(diamond).pendingSscSelfPayEffect(positionId, 1);
        assertGt(pendingSelfPay, 0);

        vm.prank(alice);
        uint256 appliedToDebt = SelfSecuredCreditFacet(diamond).serviceSelfSecuredCredit(positionId, 1);
        assertEq(appliedToDebt, pendingSelfPay);

        Types.SscLineView memory afterService = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, 1);
        assertEq(afterService.claimableAciYield, ROUTED_SSC_ACI_YIELD);
        assertEq(afterService.totalAciAppliedToDebt, pendingSelfPay);
        assertEq(afterService.claimableFeeYield, 1.6 ether);
        assertEq(beforeSwitch.claimableAciYield, afterService.claimableAciYield);
    }

    function test_LiveFlow_SscAci_DoesNotDoubleCountDebtAndEncumbranceRewards() external {
        testSupport.setFoundationReceiver(address(0));
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        PositionManagementFacet(diamond).joinPositionPool(positionId, 2);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        OptionsFacet(diamond).createOptionSeries(
            LibOptionsStorage.CreateOptionSeriesParams({
                positionId: positionId,
                underlyingPoolId: 1,
                strikePoolId: 2,
                strikePrice: 2 ether,
                expiry: uint64(block.timestamp + 1 days),
                totalSize: 20 ether,
                contractSize: 1,
                isCall: true,
                isAmerican: true
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 25 hours);
        eve.mint(diamond, 10 ether);
        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) =
            testSupport.routeManagedShareExternal(1, 10 ether, keccak256("ssc.no.double.count"), false, 10 ether);
        assertEq(toTreasury, 1 ether);
        assertEq(toActiveCredit, 7 ether);
        assertEq(toFeeIndex, 2 ether);

        (uint256 debtPrincipal,,) = testSupport.debtActiveCreditStateOf(1, positionKey);
        (uint256 encumbrancePrincipal,,) = testSupport.encumbranceActiveCreditStateOf(1, positionKey);
        uint256 totalPendingActiveCredit = testSupport.pendingActiveCreditYieldOf(1, positionKey);
        uint256 sscDebtPending = testSupport.pendingSscDebtYieldOf(1, positionKey);
        uint256 nonSscPending = totalPendingActiveCredit - sscDebtPending;

        assertEq(debtPrincipal, 60 ether);
        assertEq(encumbrancePrincipal, 20 ether);
        assertEq(testSupport.poolActiveCreditPrincipalTotalOf(1), 80 ether);
        assertEq(totalPendingActiveCredit, toActiveCredit);

        Types.SscLineView memory lineView = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, 1);
        uint256 positionYield = PositionManagementFacet(diamond).previewPositionYield(positionId, 1);

        assertEq(lineView.claimableAciYield, sscDebtPending);
        assertEq(positionYield - lineView.claimableFeeYield, nonSscPending);
        assertEq(lineView.claimableAciYield + (positionYield - lineView.claimableFeeYield), totalPendingActiveCredit);
    }

    function test_LiveFlow_TerminalSettlement_PermissionlesslyHealsToSafeResidualLine() external {
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 80 ether, 80 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        Types.SscMaintenancePreview memory unsafePreview =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, 1);
        assertEq(unsafePreview.settledPrincipal, 99 ether);
        assertTrue(unsafePreview.unsafeAfterMaintenance);

        vm.prank(bob);
        Types.SscTerminalSettlementPreview memory settlement =
            SelfSecuredCreditFacet(diamond).selfSettleSelfSecuredCredit(positionId, 1);

        assertEq(settlement.principalBefore, 99 ether);
        assertEq(settlement.outstandingDebtBefore, 80 ether);
        assertEq(settlement.requiredLockedCapitalBefore, 100 ether);
        assertEq(settlement.principalConsumed, 4 ether);
        assertEq(settlement.debtRepaid, 4 ether);
        assertEq(settlement.principalAfter, 95 ether);
        assertEq(settlement.outstandingDebtAfter, 76 ether);
        assertEq(settlement.requiredLockedCapitalAfter, 95 ether);
        assertTrue(!settlement.lineClosed);

        Types.SscMaintenancePreview memory healedPreview =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, 1);
        assertEq(healedPreview.settledPrincipal, 95 ether);
        assertTrue(!healedPreview.unsafeAfterMaintenance);
        assertEq(testSupport.principalOf(1, positionKey), 95 ether);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), 76 ether);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 95 ether);
        assertEq(PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance, 19 ether);
    }

    function test_LiveFlow_TerminalSettlement_ClosesLineWhenNoSafeResidualRemains() external {
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 80 ether, 80 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + (25 * 365 days));

        Types.SscMaintenancePreview memory unsafePreview =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, 1);
        assertTrue(unsafePreview.unsafeAfterMaintenance);
        assertTrue(unsafePreview.settledPrincipal < 80 ether);

        vm.prank(bob);
        Types.SscTerminalSettlementPreview memory settlement =
            SelfSecuredCreditFacet(diamond).selfSettleSelfSecuredCredit(positionId, 1);

        assertEq(settlement.outstandingDebtBefore, 80 ether);
        assertEq(settlement.principalConsumed, settlement.principalBefore);
        assertEq(settlement.debtRepaid, 80 ether);
        assertEq(settlement.principalAfter, 0);
        assertEq(settlement.outstandingDebtAfter, 0);
        assertEq(settlement.requiredLockedCapitalAfter, 0);
        assertTrue(settlement.lineClosed);

        Types.SscLineView memory lineView = SelfSecuredCreditFacet(diamond).getSelfSecuredCreditLineView(positionId, 1);
        assertEq(lineView.principal, 0);
        assertEq(lineView.outstandingDebt, 0);
        assertEq(lineView.requiredLockedCapital, 0);
        assertTrue(!lineView.active);
        assertEq(testSupport.principalOf(1, positionKey), 0);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), 0);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 0);
        assertEq(PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance, 0);
    }

    function test_LiveFlow_SelfSecuredCredit_TransferPreservesActiveLineForNewOwner() external {
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 100 ether);
        vm.startPrank(alice);
        eve.approve(diamond, 100 ether);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100 ether, 100 ether);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, 1, 60 ether, 60 ether);
        positionNft.transferFrom(alice, bob, positionId);
        vm.stopPrank();

        assertEq(positionNft.ownerOf(positionId), bob);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), 60 ether);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 75 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, alice, positionId));
        SelfSecuredCreditFacet(diamond).repaySelfSecuredCredit(positionId, 1, 10 ether, 10 ether);

        eve.mint(bob, 60 ether);
        vm.startPrank(bob);
        eve.approve(diamond, 60 ether);
        uint256 repaid = SelfSecuredCreditFacet(diamond).closeSelfSecuredCredit(positionId, 1, 60 ether);
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, 1, 100 ether, 100 ether);
        vm.stopPrank();

        assertEq(repaid, 60 ether);
        assertEq(testSupport.sameAssetDebtOf(1, positionKey), 0);
        assertEq(testSupport.lockedCapitalOf(positionKey, 1), 0);
        assertEq(eve.balanceOf(bob), 100 ether);
    }
}
