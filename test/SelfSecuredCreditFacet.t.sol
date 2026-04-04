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
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_LiveLaunch_SelfSecuredCredit_InstallsLifecycleSelectors() external view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.drawSelfSecuredCredit.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.repaySelfSecuredCredit.selector) != address(0));
        assertTrue(loupe.facetAddress(SelfSecuredCreditFacet.closeSelfSecuredCredit.selector) != address(0));
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
