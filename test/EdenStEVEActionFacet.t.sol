// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenBasketPositionFacet} from "src/eden/EdenBasketPositionFacet.sol";
import {EdenStEVEActionFacet} from "src/eden/EdenStEVEActionFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {InsufficientPrincipal, InvalidParameterRange, NotNFTOwner} from "src/libraries/Errors.sol";
import {BasketToken} from "src/tokens/BasketToken.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenStEVEActionFacetTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
    }

    function test_CreateStEVE_WalletMintStaysNonEligible() public {
        eve.mint(bob, 20e18);
        uint256 emptyPositionId = _mintPosition(bob, 1);

        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        assertEq(EdenStEVEActionFacet(diamond).eligibleSupply(), 0);
        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(emptyPositionId), 0);
    }

    function test_DepositWithdrawStEVE_TracksEligibleSupply() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(bob, positionId, 10e18);

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(EdenStEVEActionFacet(diamond).eligibleSupply(), 10e18);
        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 10e18);
        assertEq(portfolio.rewards.eligiblePrincipal, 10e18);
        assertEq(portfolio.baskets.length, 1);
        assertEq(portfolio.baskets[0].units, 10e18);
        assertEq(ERC20(steveToken).balanceOf(bob), 0);

        vm.prank(bob);
        uint256 withdrawn = EdenStEVEActionFacet(diamond).withdrawStEVEFromPosition(positionId, 4e18, 4e18);

        assertEq(withdrawn, 4e18);
        assertEq(EdenStEVEActionFacet(diamond).eligibleSupply(), 6e18);
        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 6e18);
        assertEq(ERC20(steveToken).balanceOf(bob), 4e18);
    }

    function test_PositionMintAndBurnStEVE_TrackEligibleSupply() public {
        eve.mint(alice, 100e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 100e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100e18, 100e18);
        EdenBasketPositionFacet(diamond).mintBasketFromPosition(positionId, steveBasketId, 50e18);
        vm.stopPrank();

        assertEq(EdenStEVEActionFacet(diamond).eligibleSupply(), 50e18);
        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 50e18);

        vm.prank(alice);
        EdenBasketPositionFacet(diamond).burnBasketFromPosition(positionId, steveBasketId, 20e18);

        assertEq(EdenStEVEActionFacet(diamond).eligibleSupply(), 30e18);
        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 30e18);
    }

    function test_WithdrawStEVE_RevertsForNonOwner() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(bob, positionId, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, alice, positionId));
        EdenStEVEActionFacet(diamond).withdrawStEVEFromPosition(positionId, 4e18, 4e18);
    }

    function test_CreateStEVE_RevertsWhenAlreadyConfigured() public {
        EdenBasketBase.CreateBasketParams memory params = _stEveParams(address(eve));
        params.basketType = 0;
        bytes memory data = abi.encodeWithSelector(EdenStEVEActionFacet.createStEVE.selector, params);
        bytes32 salt = keccak256("invalid-steve-basket-type");

        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "stEVE already configured"));
        timelockController.execute(diamond, 0, data, bytes32(0), salt);
    }

    function test_DepositAndWithdrawStEVE_RevertForZeroAmountAndInsufficientPrincipal() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);

        vm.startPrank(bob);
        BasketToken(steveToken).approve(diamond, 10e18);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "amount=0"));
        EdenStEVEActionFacet(diamond).depositStEVEToPosition(positionId, 0, 0);
        vm.stopPrank();

        _depositWalletStEVEToPosition(bob, positionId, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 11e18, 10e18));
        EdenStEVEActionFacet(diamond).withdrawStEVEFromPosition(positionId, 11e18, 11e18);
    }
}
