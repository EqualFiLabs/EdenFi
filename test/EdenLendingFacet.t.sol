// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EdenBasketFacet} from "src/eden/EdenBasketFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";

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
        EdenBasketFacet(diamond).mintBasketFromPosition(positionId, altBasketId, 50e18);
        vm.stopPrank();

        EdenLendingFacet.BorrowPreview memory borrowPreview =
            EdenLendingFacet(diamond).previewBorrow(positionId, altBasketId, 20e18, 7 days);
        assertEq(borrowPreview.availableCollateral, 50e18);
        assertEq(borrowPreview.principals[0], 20e18);
        assertTrue(borrowPreview.invariantSatisfied);

        vm.prank(alice);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, altBasketId, 20e18, 7 days);

        assertEq(EdenLendingFacet(diamond).loanCount(), 1);
        assertEq(EdenLendingFacet(diamond).borrowerLoanCount(positionId), 1);
        assertEq(EdenLendingFacet(diamond).getOutstandingPrincipal(altBasketId, address(alt)), 20e18);
        assertEq(EdenLendingFacet(diamond).getLockedCollateralUnits(altBasketId), 20e18);

        EdenLendingFacet.LoanView memory liveLoan = EdenLendingFacet(diamond).getLoanView(loanId);
        assertEq(liveLoan.borrowerPositionKey, positionNft.getPositionKey(positionId));
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

        assertEq(EdenLendingFacet(diamond).getLockedCollateralUnits(altBasketId), 0);
        assertEq(EdenLendingFacet(diamond).getOutstandingPrincipal(altBasketId, address(alt)), 0);

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
        EdenBasketFacet(diamond).mintBasketFromPosition(positionId, altBasketId, 60e18);
        vm.stopPrank();

        vm.prank(alice);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, altBasketId, 20e18, 7 days);

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
        assertEq(EdenLendingFacet(diamond).getLockedCollateralUnits(altBasketId), 0);

        uint256[] memory ids = EdenLendingFacet(diamond).getLoanIdsByBorrowerPaginated(positionId, 0, 10);
        assertEq(ids.length, 1);
        uint256[] memory activeIds = EdenLendingFacet(diamond).getActiveLoanIdsByBorrowerPaginated(positionId, 0, 10);
        assertEq(activeIds.length, 0);
    }

    function test_RepayRevertsWhenFoTDeltaIsInsufficient() public {
        _bootstrapCorePoolsWithFoT();
        (uint256 basketId,) =
            _createBasket(_singleAssetParams("FoTBasket", "FBT", address(fot), "ipfs://fot", 0, 0, 0));
        _configureLending(basketId, 1 days, 14 days);

        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        _configureBorrowFeeTiers(basketId, mins, fees);

        fot.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 3);

        vm.startPrank(alice);
        fot.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 3, 100e18, 112e18);
        EdenBasketFacet(diamond).mintBasketFromPosition(positionId, basketId, 50e18);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, basketId, 20e18, 7 days);
        fot.approve(diamond, 20e18);
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, 18e18, 20e18));
        EdenLendingFacet(diamond).repay(positionId, loanId);
        vm.stopPrank();
    }
}
