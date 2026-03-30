// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StEVELendingFacet} from "src/steve/StEVELendingFacet.sol";
import {StEVEPositionFacet} from "src/steve/StEVEPositionFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";

contract StEVELendingFuzzTest is StEVELaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapStEVEProduct();
    }

    function testFuzz_BorrowPreviewRepayParity(
        uint96 depositSeed,
        uint96 mintSeed,
        uint96 collateralSeed,
        uint32 durationSeed
    ) public {
        uint256 depositAmount = _boundUint(uint256(depositSeed), 50, 300) * 1e18;
        uint256 mintUnits = _boundUint(uint256(mintSeed), 20, depositAmount / 1e18) * 1e18;
        uint256 collateralUnits = _boundUint(uint256(collateralSeed), 1, mintUnits / 1e18) * 1e18;
        uint40 duration = uint40(_boundUint(uint256(durationSeed), 1 days, 14 days));

        alt.mint(alice, depositAmount);
        uint256 positionId = _mintPosition(alice, 2);

        vm.startPrank(alice);
        alt.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, depositAmount, depositAmount);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(positionId, mintUnits);
        vm.stopPrank();

        StEVELendingFacet.BorrowPreview memory borrowPreview =
            StEVELendingFacet(diamond).previewBorrow(positionId, collateralUnits, duration);
        assertEq(borrowPreview.collateralUnits, collateralUnits);
        assertEq(borrowPreview.maturity, block.timestamp + duration);
        assertTrue(borrowPreview.invariantSatisfied);

        vm.prank(alice);
        uint256 loanId = StEVELendingFacet(diamond).borrow(positionId, collateralUnits, duration);

        StEVELendingFacet.RepayPreview memory repayPreview = StEVELendingFacet(diamond).previewRepay(positionId, loanId);
        assertEq(repayPreview.principals.length, borrowPreview.principals.length);
        assertEq(repayPreview.principals[0], borrowPreview.principals[0]);
        assertEq(repayPreview.unlockedCollateralUnits, collateralUnits);

        vm.startPrank(alice);
        alt.approve(diamond, repayPreview.principals[0]);
        StEVELendingFacet(diamond).repay(positionId, loanId);
        vm.stopPrank();

        assertEq(StEVELendingFacet(diamond).getLockedCollateralUnits(), 0);
        assertTrue(!StEVELendingFacet(diamond).getLoanView(loanId).active);
    }

    function testFuzz_ExtendAndRecoverPreserveLoanLifecycle(
        uint96 depositSeed,
        uint96 mintSeed,
        uint96 collateralSeed,
        uint32 durationSeed,
        uint32 extraSeed
    ) public {
        uint256 depositAmount = _boundUint(uint256(depositSeed), 50, 300) * 1e18;
        uint256 mintUnits = _boundUint(uint256(mintSeed), 20, depositAmount / 1e18) * 1e18;
        uint256 collateralUnits = _boundUint(uint256(collateralSeed), 1, mintUnits / 1e18) * 1e18;
        uint256 durationDays = _boundUint(uint256(durationSeed), 1, 10);
        uint40 duration = uint40(durationDays * 1 days);
        uint256 maxExtraDays = 14 - durationDays;
        if (maxExtraDays == 0) {
            maxExtraDays = 1;
        }
        uint40 extraDuration = uint40(_boundUint(uint256(extraSeed), 1, maxExtraDays) * 1 days);

        alt.mint(alice, depositAmount);
        uint256 positionId = _mintPosition(alice, 2);

        vm.startPrank(alice);
        alt.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, depositAmount, depositAmount);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(positionId, mintUnits);
        uint256 loanId = StEVELendingFacet(diamond).borrow(positionId, collateralUnits, duration);
        vm.stopPrank();

        StEVELendingFacet.ExtendPreview memory extendPreview =
            StEVELendingFacet(diamond).previewExtend(positionId, loanId, extraDuration);

        vm.prank(alice);
        StEVELendingFacet(diamond).extend(positionId, loanId, extraDuration);
        assertEq(StEVELendingFacet(diamond).getLoanView(loanId).maturity, extendPreview.newMaturity);

        vm.warp(uint256(extendPreview.newMaturity) + 1);
        StEVELendingFacet(diamond).recoverExpired(loanId);

        StEVELendingFacet.LoanView memory recovered = StEVELendingFacet(diamond).getLoanView(loanId);
        assertTrue(!recovered.active);
        assertEq(StEVELendingFacet(diamond).getLockedCollateralUnits(), 0);
    }
}
