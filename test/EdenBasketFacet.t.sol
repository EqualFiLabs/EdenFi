// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenBasketFacet} from "src/eden/EdenBasketFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {InvalidArrayLength, InvalidUnits, IndexPaused, NoPoolForAsset} from "src/libraries/Errors.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenBasketFacetTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
    }

    function test_CreateBasket_WalletMintBurnAndMetadata() public {
        _bootstrapCorePools();

        (uint256 basketId, address basketTokenAddr) =
            _createBasket(_singleAssetParams("EDEN Basket", "EDEN", address(eve), "ipfs://eden", 7, 1000, 1000));

        eve.mint(bob, 20e18);
        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        EdenBasketFacet(diamond).mintBasket(basketId, 10e18, bob, maxInputs);
        vm.stopPrank();

        EdenViewFacet.BasketSummary memory basket = EdenViewFacet(diamond).getBasketSummary(basketId);
        assertGt(basket.poolId, 0);
        assertEq(basket.flashFeeBps, 50);
        assertEq(basket.name, "EDEN Basket");
        assertEq(basket.symbol, "EDEN");
        assertEq(basket.uri, "ipfs://eden");
        assertEq(basket.basketType, 7);
        assertEq(ERC20(basketTokenAddr).balanceOf(bob), 10e18);
        assertGt(eve.balanceOf(treasury), 0);
        assertGt(EdenBasketFacet(diamond).getBasketVaultBalance(basketId, address(eve)), 0);

        vm.prank(bob);
        EdenBasketFacet(diamond).burnBasket(basketId, 10e18, bob);

        basket = EdenViewFacet(diamond).getBasketSummary(basketId);
        assertEq(ERC20(basketTokenAddr).balanceOf(bob), 0);
        assertEq(basket.totalUnits, 0);
        assertGt(eve.balanceOf(bob), 0);
    }

    function test_PositionMode_MintBurnUpdatesPositionPortfolio() public {
        _bootstrapCorePools();

        alt.mint(alice, 250e18);
        uint256 positionId = _mintPosition(alice, 2);

        vm.startPrank(alice);
        alt.approve(diamond, 250e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 200e18, 200e18);
        vm.stopPrank();

        (uint256 basketId,) =
            _createBasket(_singleAssetParams("Position Basket", "PBASK", address(alt), "ipfs://pb", 0, 1000, 0));

        vm.prank(alice);
        EdenBasketFacet(diamond).mintBasketFromPosition(positionId, basketId, 50e18);

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(portfolio.baskets.length, 1);
        assertEq(portfolio.baskets[0].basketId, basketId);
        assertEq(portfolio.baskets[0].units, 50e18);
        assertEq(portfolio.baskets[0].availableUnits, 50e18);

        vm.prank(alice);
        EdenBasketFacet(diamond).burnBasketFromPosition(positionId, basketId, 20e18);

        portfolio = EdenViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(portfolio.baskets.length, 1);
        assertEq(portfolio.baskets[0].units, 30e18);
        assertEq(portfolio.baskets[0].availableUnits, 30e18);
    }

    function test_MintBasket_RevertsWhenFoTDeltaIsInsufficient() public {
        _bootstrapCorePoolsWithFoT();

        (uint256 basketId,) =
            _createBasket(_singleAssetParams("FoT Basket", "FBASK", address(fot), "ipfs://fot", 0, 0, 0));

        fot.mint(bob, 20e18);

        vm.startPrank(bob);
        fot.approve(diamond, 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, 9e18, 10e18));
        EdenBasketFacet(diamond).mintBasket(basketId, 10e18, bob, maxInputs);
        vm.stopPrank();
    }

    function test_CreateBasket_RevertsForMissingCanonicalPool() public {
        _bootstrapCorePools();
        address missingAsset = _addr("missing-asset");
        EdenBasketBase.CreateBasketParams memory params =
            _singleAssetParams("Missing Pool", "MISS", missingAsset, "ipfs://missing", 0, 0, 0);
        bytes memory data = abi.encodeWithSelector(EdenBasketFacet.createBasket.selector, params);
        bytes32 salt = keccak256("missing-basket-pool");

        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(NoPoolForAsset.selector, missingAsset));
        timelockController.execute(diamond, 0, data, bytes32(0), salt);
    }

    function test_MintBasket_RevertsForInvalidUnitsPausedBasketAndInputShape() public {
        _bootstrapCorePools();

        (uint256 basketId,) =
            _createBasket(_singleAssetParams("Guarded Basket", "GBASK", address(eve), "ipfs://guarded", 0, 1000, 0));

        eve.mint(bob, 100e18);

        vm.startPrank(bob);
        eve.approve(diamond, 100e18);

        uint256[] memory wrongLen = new uint256[](0);
        vm.expectRevert(InvalidArrayLength.selector);
        EdenBasketFacet(diamond).mintBasket(basketId, 10e18, bob, wrongLen);

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        vm.expectRevert(InvalidUnits.selector);
        EdenBasketFacet(diamond).mintBasket(basketId, 0, bob, maxInputs);

        maxInputs[0] = 10e18;
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InvalidMax.selector, 10e18, 11e18));
        EdenBasketFacet(diamond).mintBasket(basketId, 10e18, bob, maxInputs);
        vm.stopPrank();

        _setBasketPaused(basketId, true);

        vm.startPrank(bob);
        maxInputs[0] = 11e18;
        vm.expectRevert(abi.encodeWithSelector(IndexPaused.selector, basketId));
        EdenBasketFacet(diamond).mintBasket(basketId, 10e18, bob, maxInputs);
        vm.stopPrank();
    }
}
