// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenBasketPositionFacet} from "src/eden/EdenBasketPositionFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {InsufficientPrincipal} from "src/libraries/Errors.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenLendingFacetTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
    }

    function test_PositionOwnedBorrowRepayAndViews() public {
        _bootstrapEdenProduct();
        alt.mint(alice, 200e18);

        uint256 positionId = _mintPosition(alice, 2);
        vm.startPrank(alice);
        alt.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 100e18, 100e18);
        EdenBasketPositionFacet(diamond).mintStEVEFromPosition(positionId, 50e18);
        vm.stopPrank();

        EdenLendingFacet.BorrowPreview memory borrowPreview =
            EdenLendingFacet(diamond).previewBorrow(positionId, 20e18, 7 days);
        assertEq(borrowPreview.availableCollateral, 50e18);
        assertEq(borrowPreview.productId, steveBasketId);
        assertEq(borrowPreview.principals[0], 20e18);
        assertTrue(borrowPreview.invariantSatisfied);

        vm.prank(alice);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, 20e18, 7 days);

        assertEq(EdenLendingFacet(diamond).loanCount(), 1);
        assertEq(EdenLendingFacet(diamond).borrowerLoanCount(positionId), 1);
        assertEq(EdenLendingFacet(diamond).getOutstandingPrincipal(address(alt)), 20e18);
        assertEq(EdenLendingFacet(diamond).getLockedCollateralUnits(), 20e18);

        EdenLendingFacet.LoanView memory liveLoan = EdenLendingFacet(diamond).getLoanView(loanId);
        assertEq(liveLoan.borrowerPositionKey, positionNft.getPositionKey(positionId));
        assertEq(liveLoan.productId, steveBasketId);
        assertTrue(liveLoan.active);
        assertTrue(!liveLoan.expired);
        assertEq(liveLoan.principals[0], 20e18);

        EdenLendingFacet.RepayPreview memory repayPreview = EdenLendingFacet(diamond).previewRepay(positionId, loanId);
        assertEq(repayPreview.principals[0], 20e18);
        assertEq(repayPreview.unlockedCollateralUnits, 20e18);

        vm.startPrank(alice);
        alt.approve(diamond, 20e18);
        EdenLendingFacet(diamond).repay(positionId, loanId);
        vm.stopPrank();

        assertEq(EdenLendingFacet(diamond).getLockedCollateralUnits(), 0);
        assertEq(EdenLendingFacet(diamond).getOutstandingPrincipal(address(alt)), 0);

        EdenLendingFacet.LoanView memory closedLoan = EdenLendingFacet(diamond).getLoanView(loanId);
        assertTrue(!closedLoan.active);

        uint256[] memory allLoanIds = EdenLendingFacet(diamond).getLoanIdsByBorrower(positionId);
        assertEq(allLoanIds.length, 1);
        uint256[] memory activeLoanIds = EdenLendingFacet(diamond).getActiveLoanIdsByBorrower(positionId);
        assertEq(activeLoanIds.length, 0);
    }

    function test_ExtendRecoveryAndPagination() public {
        _bootstrapEdenProduct();
        alt.mint(alice, 300e18);

        uint256 positionId = _mintPosition(alice, 2);
        vm.startPrank(alice);
        alt.approve(diamond, 300e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 120e18, 120e18);
        EdenBasketPositionFacet(diamond).mintStEVEFromPosition(positionId, 60e18);
        vm.stopPrank();

        vm.prank(alice);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, 20e18, 7 days);

        EdenLendingFacet.ExtendPreview memory extendPreview =
            EdenLendingFacet(diamond).previewExtend(positionId, loanId, 3 days);
        assertEq(extendPreview.newMaturity, block.timestamp + 10 days);

        vm.prank(alice);
        EdenLendingFacet(diamond).extend(positionId, loanId, 3 days);

        EdenLendingFacet.LoanView memory liveLoan = EdenLendingFacet(diamond).getLoanView(loanId);
        assertEq(liveLoan.maturity, block.timestamp + 10 days);

        vm.warp(block.timestamp + 10 days + 1);
        EdenLendingFacet.LoanView memory expiredLoan = EdenLendingFacet(diamond).getLoanView(loanId);
        assertTrue(expiredLoan.expired);

        EdenViewFacet.PositionPortfolio memory beforeRecovery = EdenViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(beforeRecovery.loans.length, 1);

        EdenLendingFacet(diamond).recoverExpired(loanId);

        EdenLendingFacet.LoanView memory recoveredLoan = EdenLendingFacet(diamond).getLoanView(loanId);
        assertTrue(!recoveredLoan.active);
        assertEq(EdenLendingFacet(diamond).getLockedCollateralUnits(), 0);

        uint256[] memory ids = EdenLendingFacet(diamond).getLoanIdsByBorrowerPaginated(positionId, 0, 10);
        assertEq(ids.length, 1);
        uint256[] memory activeIds = EdenLendingFacet(diamond).getActiveLoanIdsByBorrowerPaginated(positionId, 0, 10);
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
        EdenBasketPositionFacet(diamond).mintStEVEFromPosition(positionId, 50e18);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, 20e18, 7 days);
        fot.approve(diamond, 20e18);
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, 18e18, 20e18));
        EdenLendingFacet(diamond).repay(positionId, loanId);
        vm.stopPrank();
    }

    function test_LendingConfigAndBorrow_RevertForInvalidTiersAndDurations() public {
        _bootstrapEdenProduct();

        uint256[] memory badMins = new uint256[](2);
        badMins[0] = 2e18;
        badMins[1] = 1e18;
        uint256[] memory fees = new uint256[](2);
        fees[0] = 0;
        fees[1] = 0;
        bytes memory badTierData =
            abi.encodeWithSelector(EdenLendingFacet.configureBorrowFeeTiers.selector, badMins, fees);
        bytes32 salt = keccak256("invalid-borrow-fees");

        timelockController.schedule(diamond, 0, badTierData, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(EdenLendingFacet.InvalidTierConfiguration.selector);
        timelockController.execute(diamond, 0, badTierData, bytes32(0), salt);

        alt.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 2);
        vm.startPrank(alice);
        alt.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 100e18, 100e18);
        EdenBasketPositionFacet(diamond).mintStEVEFromPosition(positionId, 50e18);

        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.InvalidDuration.selector, 12 hours, 1 days, 14 days));
        EdenLendingFacet(diamond).borrow(positionId, 20e18, 12 hours);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.InvalidDuration.selector, 15 days, 1 days, 14 days));
        EdenLendingFacet(diamond).previewBorrow(positionId, 20e18, 15 days);
    }

    function test_LoanLifecycleNegatives_RevertForPositionMismatchClosedAndPrematureRecovery() public {
        _bootstrapEdenProduct();
        alt.mint(alice, 300e18);

        uint256 alicePositionId = _mintPosition(alice, 2);
        uint256 bobPositionId = _mintPosition(bob, 2);

        vm.startPrank(alice);
        alt.approve(diamond, 300e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 2, 120e18, 120e18);
        EdenBasketPositionFacet(diamond).mintStEVEFromPosition(alicePositionId, 60e18);
        uint256 loanId = EdenLendingFacet(diamond).borrow(alicePositionId, 20e18, 7 days);
        vm.stopPrank();

        bytes32 aliceKey = positionNft.getPositionKey(alicePositionId);
        bytes32 bobKey = positionNft.getPositionKey(bobPositionId);

        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.PositionMismatch.selector, aliceKey, bobKey));
        EdenLendingFacet(diamond).previewRepay(bobPositionId, loanId);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.PositionMismatch.selector, aliceKey, bobKey));
        EdenLendingFacet(diamond).repay(bobPositionId, loanId);

        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.LoanNotExpired.selector, loanId, uint40(block.timestamp + 7 days)));
        EdenLendingFacet(diamond).recoverExpired(loanId);

        vm.startPrank(alice);
        alt.approve(diamond, 20e18);
        EdenLendingFacet(diamond).repay(alicePositionId, loanId);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(EdenLendingFacet.LoanNotFound.selector, loanId));
        EdenLendingFacet(diamond).previewRepay(alicePositionId, loanId);
    }
}
