// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EdenBasketDataFacet} from "src/eden/EdenBasketDataFacet.sol";
import {EdenBasketPositionFacet} from "src/eden/EdenBasketPositionFacet.sol";
import {EdenBasketWalletFacet} from "src/eden/EdenBasketWalletFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenBasketFuzzTest is EdenLaunchFixture {
    function testFuzz_EdenBasketWalletMintBurnConservesUserFacingState(uint96 unitsSeed) public {
        _bootstrapCorePools();

        uint256 units = _boundUint(uint256(unitsSeed), 1, 40) * 1e18;
        (uint256 basketId, address basketToken) =
            _createBasket(_singleAssetParams("EDEN Basket", "EDEN", address(eve), "ipfs://eden", 0, 1000, 1000));

        eve.mint(bob, units * 3);

        vm.startPrank(bob);
        eve.approve(diamond, units * 3);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = units * 2;
        EdenBasketWalletFacet(diamond).mintBasket(basketId, units, bob, maxInputs);
        assertEq(ERC20(basketToken).balanceOf(bob), units);
        EdenBasketWalletFacet(diamond).burnBasket(basketId, units, bob);
        vm.stopPrank();

        assertEq(ERC20(basketToken).balanceOf(bob), 0);
        assertEq(EdenViewFacet(diamond).getBasketSummary(basketId).totalUnits, 0);
        assertGt(EdenBasketDataFacet(diamond).getBasketFeePot(basketId, address(eve)), 0);
    }

    function testFuzz_EdenBasketPositionMintBurnRoundTrip(uint96 depositSeed, uint96 mintSeed) public {
        _bootstrapCorePools();

        uint256 depositAmount = _boundUint(uint256(depositSeed), 20, 200) * 1e18;
        uint256 maxMintWholeUnits = (depositAmount / 1e18) * 10 / 11;
        if (maxMintWholeUnits == 0) {
            maxMintWholeUnits = 1;
        }
        uint256 mintUnits = _boundUint(uint256(mintSeed), 1, maxMintWholeUnits) * 1e18;

        alt.mint(alice, depositAmount);
        uint256 positionId = _mintPosition(alice, 2);

        vm.startPrank(alice);
        alt.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, depositAmount, depositAmount);
        vm.stopPrank();

        (uint256 basketId,) =
            _createBasket(_singleAssetParams("Position Basket", "PBASK", address(alt), "ipfs://pb", 0, 1000, 1000));

        vm.prank(alice);
        EdenBasketPositionFacet(diamond).mintBasketFromPosition(positionId, basketId, mintUnits);

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(portfolio.baskets.length, 1);
        assertEq(portfolio.baskets[0].units, mintUnits);

        vm.prank(alice);
        EdenBasketPositionFacet(diamond).burnBasketFromPosition(positionId, basketId, mintUnits);

        portfolio = EdenViewFacet(diamond).getPositionPortfolio(positionId);
        if (portfolio.baskets.length > 0) {
            assertEq(portfolio.baskets[0].units, 0);
        }
    }

    function testFuzz_EdenBasketFoTMintRevertsOnUnderreceipt(uint96 unitsSeed) public {
        _bootstrapCorePoolsWithFoT();

        uint256 units = _boundUint(uint256(unitsSeed), 1, 20) * 1e18;
        (uint256 basketId,) =
            _createBasket(_singleAssetParams("FoT Basket", "FBASK", address(fot), "ipfs://fot", 0, 0, 0));

        fot.mint(bob, units * 2);

        vm.startPrank(bob);
        fot.approve(diamond, units * 2);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = units;
        vm.expectRevert(
            abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, (units * 9) / 10, units)
        );
        EdenBasketWalletFacet(diamond).mintBasket(basketId, units, bob, maxInputs);
        vm.stopPrank();
    }
}
