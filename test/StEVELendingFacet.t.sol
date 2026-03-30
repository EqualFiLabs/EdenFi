// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StEVELendingFacet} from "src/steve/StEVELendingFacet.sol";
import {StEVEPositionFacet} from "src/steve/StEVEPositionFacet.sol";
import {StEVEViewFacet} from "src/steve/StEVEViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {InsufficientPrincipal} from "src/libraries/Errors.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";

contract StEVELendingFacetTest is StEVELaunchFixture {
    function setUp() public override {
        super.setUp();
    }

    function test_PositionOwnedBorrowRepayAndViews() public {
        _bootstrapStEVEProduct();
        alt.mint(alice, 200e18);

        uint256 positionId = _mintPosition(alice, 2);
        vm.startPrank(alice);
        alt.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 100e18, 100e18);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(positionId, 50e18);
        vm.stopPrank();

        StEVELendingFacet.BorrowPreview memory borrowPreview =
            StEVELendingFacet(diamond).previewBorrow(positionId, 20e18, 7 days);
        assertEq(borrowPreview.availableCollateral, 50e18);
        assertEq(borrowPreview.productId, steveBasketId);
        assertEq(borrowPreview.principals[0], 20e18);
        assertTrue(borrowPreview.invariantSatisfied);

        vm.prank(alice);
        uint256 loanId = StEVELendingFacet(diamond).borrow(positionId, 20e18, 7 days);

        assertEq(StEVELendingFacet(diamond).loanCount(), 1);
        assertEq(StEVELendingFacet(diamond).borrowerLoanCount(positionId), 1);
        assertEq(StEVELendingFacet(diamond).getOutstandingPrincipal(address(alt)), 20e18);
        assertEq(StEVELendingFacet(diamond).getLockedCollateralUnits(), 20e18);

        StEVELendingFacet.LoanView memory liveLoan = StEVELendingFacet(diamond).getLoanView(loanId);
        assertEq(liveLoan.borrowerPositionKey, positionNft.getPositionKey(positionId));
        assertEq(liveLoan.productId, steveBasketId);
        assertTrue(liveLoan.active);
        assertTrue(!liveLoan.expired);
        assertEq(liveLoan.principals[0], 20e18);

        StEVELendingFacet.RepayPreview memory repayPreview = StEVELendingFacet(diamond).previewRepay(positionId, loanId);
        assertEq(repayPreview.principals[0], 20e18);
        assertEq(repayPreview.unlockedCollateralUnits, 20e18);

        vm.startPrank(alice);
        alt.approve(diamond, 20e18);
        StEVELendingFacet(diamond).repay(positionId, loanId);
        vm.stopPrank();

        assertEq(StEVELendingFacet(diamond).getLockedCollateralUnits(), 0);
        assertEq(StEVELendingFacet(diamond).getOutstandingPrincipal(address(alt)), 0);

        StEVELendingFacet.LoanView memory closedLoan = StEVELendingFacet(diamond).getLoanView(loanId);
        assertTrue(!closedLoan.active);

        uint256[] memory allLoanIds = StEVELendingFacet(diamond).getLoanIdsByBorrower(positionId);
        assertEq(allLoanIds.length, 1);
        uint256[] memory activeLoanIds = StEVELendingFacet(diamond).getActiveLoanIdsByBorrower(positionId);
        assertEq(activeLoanIds.length, 0);
    }

    function test_ExtendRecoveryAndPagination() public {
        _bootstrapStEVEProduct();
        alt.mint(alice, 300e18);

        uint256 positionId = _mintPosition(alice, 2);
        vm.startPrank(alice);
        alt.approve(diamond, 300e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 120e18, 120e18);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(positionId, 60e18);
        vm.stopPrank();

        vm.prank(alice);
        uint256 loanId = StEVELendingFacet(diamond).borrow(positionId, 20e18, 7 days);

        StEVELendingFacet.ExtendPreview memory extendPreview =
            StEVELendingFacet(diamond).previewExtend(positionId, loanId, 3 days);
        assertEq(extendPreview.newMaturity, block.timestamp + 10 days);

        vm.prank(alice);
        StEVELendingFacet(diamond).extend(positionId, loanId, 3 days);

        StEVELendingFacet.LoanView memory liveLoan = StEVELendingFacet(diamond).getLoanView(loanId);
        assertEq(liveLoan.maturity, block.timestamp + 10 days);

        vm.warp(block.timestamp + 10 days + 1);
        StEVELendingFacet.LoanView memory expiredLoan = StEVELendingFacet(diamond).getLoanView(loanId);
        assertTrue(expiredLoan.expired);

        StEVEViewFacet.PositionPortfolio memory beforeRecovery = StEVEViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(beforeRecovery.loans.length, 1);

        StEVELendingFacet(diamond).recoverExpired(loanId);

        StEVELendingFacet.LoanView memory recoveredLoan = StEVELendingFacet(diamond).getLoanView(loanId);
        assertTrue(!recoveredLoan.active);
        assertEq(StEVELendingFacet(diamond).getLockedCollateralUnits(), 0);

        uint256[] memory ids = StEVELendingFacet(diamond).getLoanIdsByBorrowerPaginated(positionId, 0, 10);
        assertEq(ids.length, 1);
        uint256[] memory activeIds = StEVELendingFacet(diamond).getActiveLoanIdsByBorrowerPaginated(positionId, 0, 10);
        assertEq(activeIds.length, 0);
    }

    function test_RepayRevertsWhenFoTDeltaIsInsufficient() public {
        _bootstrapCorePoolsWithFoT();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(fot)));
        _configureLending(1 days, 14 days);

        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        _configureBorrowFeeTiers(mins, fees);

        fot.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 3);

        vm.startPrank(alice);
        fot.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 3, 100e18, 112e18);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(positionId, 50e18);
        uint256 loanId = StEVELendingFacet(diamond).borrow(positionId, 20e18, 7 days);
        fot.approve(diamond, 20e18);
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, 18e18, 20e18));
        StEVELendingFacet(diamond).repay(positionId, loanId);
        vm.stopPrank();
    }

    function test_LendingConfigAndBorrow_RevertForInvalidTiersAndDurations() public {
        _bootstrapStEVEProduct();

        uint256[] memory badMins = new uint256[](2);
        badMins[0] = 2e18;
        badMins[1] = 1e18;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 0;
        fees[1] = 0;
        bytes memory badTierData =
            abi.encodeWithSelector(StEVELendingFacet.configureBorrowFeeTiers.selector, badMins, fees);
        bytes32 salt = keccak256("invalid-borrow-fees");

        timelockController.schedule(diamond, 0, badTierData, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(StEVELendingFacet.InvalidTierConfiguration.selector);
        timelockController.execute(diamond, 0, badTierData, bytes32(0), salt);

        alt.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 2);
        vm.startPrank(alice);
        alt.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 100e18, 100e18);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(positionId, 50e18);

        vm.expectRevert(abi.encodeWithSelector(StEVELendingFacet.InvalidDuration.selector, 12 hours, 1 days, 14 days));
        StEVELendingFacet(diamond).borrow(positionId, 20e18, 12 hours);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(StEVELendingFacet.InvalidDuration.selector, 15 days, 1 days, 14 days));
        StEVELendingFacet(diamond).previewBorrow(positionId, 20e18, 15 days);
    }

    function test_LoanLifecycleNegatives_RevertForPositionMismatchClosedAndPrematureRecovery() public {
        _bootstrapStEVEProduct();
        alt.mint(alice, 300e18);

        uint256 alicePositionId = _mintPosition(alice, 2);
        uint256 bobPositionId = _mintPosition(bob, 2);

        vm.startPrank(alice);
        alt.approve(diamond, 300e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 2, 120e18, 120e18);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(alicePositionId, 60e18);
        uint256 loanId = StEVELendingFacet(diamond).borrow(alicePositionId, 20e18, 7 days);
        vm.stopPrank();

        bytes32 aliceKey = positionNft.getPositionKey(alicePositionId);
        bytes32 bobKey = positionNft.getPositionKey(bobPositionId);

        vm.expectRevert(abi.encodeWithSelector(StEVELendingFacet.PositionMismatch.selector, aliceKey, bobKey));
        StEVELendingFacet(diamond).previewRepay(bobPositionId, loanId);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StEVELendingFacet.PositionMismatch.selector, aliceKey, bobKey));
        StEVELendingFacet(diamond).repay(bobPositionId, loanId);

        vm.expectRevert(abi.encodeWithSelector(StEVELendingFacet.LoanNotExpired.selector, loanId, uint40(block.timestamp + 7 days)));
        StEVELendingFacet(diamond).recoverExpired(loanId);

        vm.startPrank(alice);
        alt.approve(diamond, 20e18);
        StEVELendingFacet(diamond).repay(alicePositionId, loanId);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(StEVELendingFacet.LoanNotFound.selector, loanId));
        StEVELendingFacet(diamond).previewRepay(alicePositionId, loanId);
    }
}
