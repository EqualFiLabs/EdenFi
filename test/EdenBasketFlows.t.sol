// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {EdenBasketPositionFacet} from "src/eden/EdenBasketPositionFacet.sol";
import {EdenStEVEActionFacet} from "src/eden/EdenStEVEActionFacet.sol";
import {EdenStEVEWalletFacet} from "src/eden/EdenStEVEWalletFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";
import {ILegacyEdenPositionFacet} from "test/utils/LegacyEdenPositionFacet.sol";
import {ILegacyEdenWalletFacet} from "test/utils/LegacyEdenWalletFacet.sol";

contract EdenBasketFlowsTest is EdenLaunchFixture {
    bytes4 internal constant CREATE_BASKET_SELECTOR =
        bytes4(keccak256("createBasket((string,string,string,address[],uint256[],uint16[],uint16[],uint16,uint8))"));
    bytes4 internal constant MINT_BASKET_SELECTOR = bytes4(keccak256("mintBasket(uint256,uint256,address,uint256[])"));
    bytes4 internal constant BURN_BASKET_SELECTOR = bytes4(keccak256("burnBasket(uint256,uint256,address)"));
    bytes4 internal constant MINT_BASKET_FROM_POSITION_SELECTOR =
        bytes4(keccak256("mintBasketFromPosition(uint256,uint256,uint256)"));
    bytes4 internal constant BURN_BASKET_FROM_POSITION_SELECTOR =
        bytes4(keccak256("burnBasketFromPosition(uint256,uint256,uint256)"));

    function test_ArbitraryEdenBasketCreation_IsImpossible() public {
        _bootstrapCorePools();

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(CREATE_BASKET_SELECTOR), address(0));

        bytes memory data = abi.encodeWithSelector(
            ILegacyEdenWalletFacet.createBasket.selector,
            _singleAssetParams("Forbidden Basket", "FBASK", address(eve), "ipfs://forbidden", 7, 1000, 1000)
        );
        bytes32 salt = keccak256("legacy-create-basket");

        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(bytes("Diamond: selector not found"));
        timelockController.execute(diamond, 0, data, bytes32(0), salt);
    }

    function test_ArbitraryEdenWalletMintBurn_IsImpossible() public {
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(MINT_BASKET_SELECTOR), address(0));
        assertEq(loupe.facetAddress(BURN_BASKET_SELECTOR), address(0));

        eve.mint(bob, 20e18);

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyEdenWalletFacet(diamond).mintBasket(steveBasketId, 10e18, bob, maxInputs);

        EdenStEVEWalletFacet(diamond).mintStEVE(10e18, bob, maxInputs);
        assertEq(ERC20(steveToken).balanceOf(bob), 10e18);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyEdenWalletFacet(diamond).burnBasket(steveBasketId, 10e18, bob);

        vm.stopPrank();

        assertEq(ERC20(steveToken).balanceOf(bob), 10e18);
        assertEq(EdenViewFacet(diamond).getProductVaultBalance(address(eve)), 10e18);
    }

    function test_ArbitraryEdenPositionMintBurn_IsImpossible() public {
        _bootstrapEdenProduct();
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(MINT_BASKET_FROM_POSITION_SELECTOR), address(0));
        assertEq(loupe.facetAddress(BURN_BASKET_FROM_POSITION_SELECTOR), address(0));

        alt.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 2);

        vm.startPrank(alice);
        alt.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 100e18, 100e18);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyEdenPositionFacet(diamond).mintBasketFromPosition(positionId, steveBasketId, 50e18);

        EdenBasketPositionFacet(diamond).mintStEVEFromPosition(positionId, 50e18);
        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 50e18);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyEdenPositionFacet(diamond).burnBasketFromPosition(positionId, steveBasketId, 50e18);
        vm.stopPrank();

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(positionId);
        assertTrue(portfolio.product.active);
        assertEq(portfolio.product.productId, steveBasketId);
        assertEq(portfolio.product.units, 50e18);
    }
}
