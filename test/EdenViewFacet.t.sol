// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EdenBasketFacet} from "src/eden/EdenBasketFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenViewFacetTest is EdenLaunchFixture {
    uint256 internal alicePositionId;
    uint256 internal aliceAltPositionId;
    uint256 internal bobPositionId;

    function setUp() public override {
        super.setUp();
        _bootstrapEdenProduct();

        eve.mint(alice, 200e18);
        alt.mint(alice, 200e18);
        eve.mint(address(this), 500e18);

        alicePositionId = _mintPosition(alice, 1);
        aliceAltPositionId = _mintPosition(alice, 2);
        bobPositionId = _mintPosition(bob, 1);

        _mintWalletBasket(alice, steveBasketId, eve, 20e18);
        _mintWalletBasket(alice, altBasketId, alt, 10e18);
        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);

        vm.startPrank(alice);
        alt.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(aliceAltPositionId, 2, 100e18, 100e18);
        EdenBasketFacet(diamond).mintBasketFromPosition(aliceAltPositionId, altBasketId, 40e18);
        vm.stopPrank();

        eve.approve(diamond, 500e18);
        EdenRewardFacet(diamond).fundRewards(500e18, 500e18);
        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        EdenLendingFacet(diamond).borrow(aliceAltPositionId, altBasketId, 15e18, 7 days);
    }

    function test_MetadataAndProductConfigReads() public view {
        assertEq(EdenViewFacet(diamond).basketCount(), 2);

        uint256[] memory basketIds = EdenViewFacet(diamond).getBasketIds(0, 10);
        assertEq(basketIds.length, 2);
        assertEq(basketIds[0], steveBasketId);
        assertEq(basketIds[1], altBasketId);

        EdenViewFacet.BasketSummary memory steveSummary = EdenViewFacet(diamond).getBasketSummary(steveBasketId);
        assertEq(steveSummary.name, "stEVE");
        assertTrue(steveSummary.isStEVE);

        EdenViewFacet.ProductConfigView memory config = EdenViewFacet(diamond).getProductConfig();
        assertEq(config.basketCount, 2);
        assertEq(config.steveBasketId, steveBasketId);
        assertEq(config.rewardToken, address(eve));
        assertTrue(config.rewardsEnabled);
    }

    function test_PositionAwarePortfolioReads() public view {
        uint256[] memory alicePositionIds = EdenViewFacet(diamond).getUserPositionIds(alice);
        assertEq(alicePositionIds.length, 2);
        assertEq(alicePositionIds[0], alicePositionId);
        assertEq(alicePositionIds[1], aliceAltPositionId);

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(alicePositionId);
        assertEq(portfolio.positionId, alicePositionId);
        assertEq(portfolio.owner, alice);
        assertEq(portfolio.baskets.length, 1);
        assertEq(portfolio.loans.length, 0);
        assertEq(portfolio.rewards.eligiblePrincipal, 10e18);
        assertGt(portfolio.rewards.claimableRewards, 0);

        EdenViewFacet.PositionPortfolio memory altPortfolio =
            EdenViewFacet(diamond).getPositionPortfolio(aliceAltPositionId);
        assertEq(altPortfolio.baskets.length, 1);
        assertEq(altPortfolio.loans.length, 1);

        EdenViewFacet.UserPortfolio memory userPortfolio = EdenViewFacet(diamond).getUserPortfolio(alice);
        assertEq(userPortfolio.positionIds.length, 2);
        assertEq(userPortfolio.positions.length, 2);
        assertEq(userPortfolio.positions[1].loans.length, 1);
    }

    function test_ActionChecksReflectState() public {
        EdenViewFacet.ActionCheck memory mintCheck = EdenViewFacet(diamond).canMint(altBasketId, 10e18);
        assertTrue(mintCheck.ok);

        _setBasketPaused(altBasketId, true);
        EdenViewFacet.ActionCheck memory pausedMint = EdenViewFacet(diamond).canMint(altBasketId, 10e18);
        assertTrue(!pausedMint.ok);
        assertEq(pausedMint.code, 2);
        _setBasketPaused(altBasketId, false);

        EdenViewFacet.ActionCheck memory burnCheck = EdenViewFacet(diamond).canBurn(alice, altBasketId, 100e18);
        assertTrue(!burnCheck.ok);
        assertEq(burnCheck.code, 4);

        EdenViewFacet.ActionCheck memory borrowCheck =
            EdenViewFacet(diamond).canBorrow(aliceAltPositionId, altBasketId, 50e18, 7 days);
        assertTrue(!borrowCheck.ok);
        assertEq(borrowCheck.code, 10);

        EdenViewFacet.ActionCheck memory repayCheck = EdenViewFacet(diamond).canRepay(bobPositionId, 0);
        assertTrue(!repayCheck.ok);
        assertEq(repayCheck.code, 5);

        vm.warp(block.timestamp + 8 days);
        EdenViewFacet.ActionCheck memory extendCheck = EdenViewFacet(diamond).canExtend(aliceAltPositionId, 0, 1 days);
        assertTrue(!extendCheck.ok);
        assertEq(extendCheck.code, 7);

        EdenViewFacet.ActionCheck memory claimCheck = EdenViewFacet(diamond).canClaimRewards(alicePositionId);
        assertTrue(claimCheck.ok);
        EdenViewFacet.ActionCheck memory emptyClaimCheck = EdenViewFacet(diamond).canClaimRewards(bobPositionId);
        assertTrue(!emptyClaimCheck.ok);
    }
}
