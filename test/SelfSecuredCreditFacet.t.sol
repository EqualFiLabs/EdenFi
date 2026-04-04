// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {SelfSecuredCreditFacet} from "src/equallend/SelfSecuredCreditFacet.sol";
import {
    InsufficientPoolLiquidity,
    InsufficientPrincipal,
    LoanBelowMinimum,
    NotNFTOwner,
    SolvencyViolation
} from "src/libraries/Errors.sol";
import {Types} from "src/libraries/Types.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract SelfSecuredCreditFacetTest is LaunchFixture {
    uint256 internal constant ROUTED_SSC_ACI_YIELD = 6_999_999_999_999_999_960;

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
