// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";
import {ILegacyEdenPositionFacet} from "test/utils/LegacyEdenPositionFacet.sol";

contract EdenLendingFuzzTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapEdenProduct();
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
        ILegacyEdenPositionFacet(diamond).mintBasketFromPosition(positionId, altBasketId, mintUnits);
        vm.stopPrank();

        EdenLendingFacet.BorrowPreview memory borrowPreview =
            EdenLendingFacet(diamond).previewBorrow(positionId, altBasketId, collateralUnits, duration);
        assertEq(borrowPreview.collateralUnits, collateralUnits);
        assertEq(borrowPreview.maturity, block.timestamp + duration);
        assertTrue(borrowPreview.invariantSatisfied);

        vm.prank(alice);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, altBasketId, collateralUnits, duration);

        EdenLendingFacet.RepayPreview memory repayPreview = EdenLendingFacet(diamond).previewRepay(positionId, loanId);
        assertEq(repayPreview.principals.length, borrowPreview.principals.length);
        assertEq(repayPreview.principals[0], borrowPreview.principals[0]);
        assertEq(repayPreview.unlockedCollateralUnits, collateralUnits);

        vm.startPrank(alice);
        alt.approve(diamond, repayPreview.principals[0]);
        EdenLendingFacet(diamond).repay(positionId, loanId);
        vm.stopPrank();

        assertEq(EdenLendingFacet(diamond).getLockedCollateralUnits(altBasketId), 0);
        assertTrue(!EdenLendingFacet(diamond).getLoanView(loanId).active);
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
        ILegacyEdenPositionFacet(diamond).mintBasketFromPosition(positionId, altBasketId, mintUnits);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, altBasketId, collateralUnits, duration);
        vm.stopPrank();

        EdenLendingFacet.ExtendPreview memory extendPreview =
            EdenLendingFacet(diamond).previewExtend(positionId, loanId, extraDuration);

        vm.prank(alice);
        EdenLendingFacet(diamond).extend(positionId, loanId, extraDuration);
        assertEq(EdenLendingFacet(diamond).getLoanView(loanId).maturity, extendPreview.newMaturity);

        vm.warp(uint256(extendPreview.newMaturity) + 1);
        EdenLendingFacet(diamond).recoverExpired(loanId);

        EdenLendingFacet.LoanView memory recovered = EdenLendingFacet(diamond).getLoanView(loanId);
        assertTrue(!recovered.active);
        assertEq(EdenLendingFacet(diamond).getLockedCollateralUnits(altBasketId), 0);
    }
}
