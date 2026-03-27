// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EdenBasketFacet} from "src/eden/EdenBasketFacet.sol";
import {EdenStEVEFacet} from "src/eden/EdenStEVEFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {NotNFTOwner} from "src/libraries/Errors.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenStEVEFacetTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
    }

    function test_CreateStEVE_WalletMintStaysNonEligible() public {
        eve.mint(bob, 20e18);

        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        assertEq(EdenStEVEFacet(diamond).eligibleSupply(), 0);
        assertEq(EdenStEVEFacet(diamond).eligiblePrincipalOfPosition(999), 0);
    }

    function test_DepositWithdrawStEVE_TracksEligibleSupply() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(bob, positionId, 10e18);

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(EdenStEVEFacet(diamond).eligibleSupply(), 10e18);
        assertEq(EdenStEVEFacet(diamond).eligiblePrincipalOfPosition(positionId), 10e18);
        assertEq(portfolio.rewards.eligiblePrincipal, 10e18);
        assertEq(portfolio.baskets.length, 1);
        assertEq(portfolio.baskets[0].units, 10e18);
        assertEq(ERC20(steveToken).balanceOf(bob), 0);

        vm.prank(bob);
        uint256 withdrawn = EdenStEVEFacet(diamond).withdrawStEVEFromPosition(positionId, 4e18, 4e18);

        assertEq(withdrawn, 4e18);
        assertEq(EdenStEVEFacet(diamond).eligibleSupply(), 6e18);
        assertEq(EdenStEVEFacet(diamond).eligiblePrincipalOfPosition(positionId), 6e18);
        assertEq(ERC20(steveToken).balanceOf(bob), 4e18);
    }

    function test_PositionMintAndBurnStEVE_TrackEligibleSupply() public {
        eve.mint(alice, 100e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 100e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100e18, 100e18);
        EdenBasketFacet(diamond).mintBasketFromPosition(positionId, steveBasketId, 50e18);
        vm.stopPrank();

        assertEq(EdenStEVEFacet(diamond).eligibleSupply(), 50e18);
        assertEq(EdenStEVEFacet(diamond).eligiblePrincipalOfPosition(positionId), 50e18);

        vm.prank(alice);
        EdenBasketFacet(diamond).burnBasketFromPosition(positionId, steveBasketId, 20e18);

        assertEq(EdenStEVEFacet(diamond).eligibleSupply(), 30e18);
        assertEq(EdenStEVEFacet(diamond).eligiblePrincipalOfPosition(positionId), 30e18);
    }

    function test_WithdrawStEVE_RevertsForNonOwner() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(bob, positionId, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, alice, positionId));
        EdenStEVEFacet(diamond).withdrawStEVEFromPosition(positionId, 4e18, 4e18);
    }
}
