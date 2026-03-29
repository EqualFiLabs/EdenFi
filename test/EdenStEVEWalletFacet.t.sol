// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {EdenBasketDataFacet} from "src/eden/EdenBasketDataFacet.sol";
import {EdenStEVEActionFacet} from "src/eden/EdenStEVEActionFacet.sol";
import {EdenStEVEWalletFacet} from "src/eden/EdenStEVEWalletFacet.sol";
import {InvalidParameterRange} from "src/libraries/Errors.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenStEVEWalletFacetTest is EdenLaunchFixture {
    bytes4 internal constant CREATE_BASKET_SELECTOR =
        bytes4(keccak256("createBasket((string,string,string,address[],uint256[],uint16[],uint16[],uint16,uint8))"));
    bytes4 internal constant MINT_BASKET_SELECTOR = bytes4(keccak256("mintBasket(uint256,uint256,address,uint256[])"));
    bytes4 internal constant BURN_BASKET_SELECTOR = bytes4(keccak256("burnBasket(uint256,uint256,address)"));

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function test_LaunchCutsStEVEWalletSelectorsAndRemovesGenericWalletSelectors() public view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        assertTrue(loupe.facetAddress(EdenStEVEWalletFacet.mintStEVE.selector) != address(0));
        assertTrue(loupe.facetAddress(EdenStEVEWalletFacet.burnStEVE.selector) != address(0));
        assertEq(loupe.facetAddress(CREATE_BASKET_SELECTOR), address(0));
        assertEq(loupe.facetAddress(MINT_BASKET_SELECTOR), address(0));
        assertEq(loupe.facetAddress(BURN_BASKET_SELECTOR), address(0));
    }

    function test_WalletModeMintAndBurnUseExplicitStEVEFlows() public {
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));

        eve.mint(bob, 20e18);

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;
        EdenStEVEWalletFacet(diamond).mintStEVE(10e18, bob, maxInputs);

        assertEq(ERC20(steveToken).balanceOf(bob), 10e18);
        assertEq(EdenBasketDataFacet(diamond).getBasketVaultBalance(steveBasketId, address(eve)), 10e18);

        uint256[] memory assetsOut = EdenStEVEWalletFacet(diamond).burnStEVE(10e18, bob);
        vm.stopPrank();

        assertEq(assetsOut.length, 1);
        assertEq(assetsOut[0], 10e18);
        assertEq(ERC20(steveToken).balanceOf(bob), 0);
        assertEq(eve.balanceOf(bob), 20e18);
        assertEq(EdenBasketDataFacet(diamond).getBasketVaultBalance(steveBasketId, address(eve)), 0);
    }

    function test_RevertWhen_MintingStEVEBeforeProductConfigured() public {
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 1e18;

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "stEVE not configured"));
        EdenStEVEWalletFacet(diamond).mintStEVE(1e18, alice, maxInputs);
    }

    function test_WalletMintedStEVEStaysNonEligibleForRewards() public {
        (steveBasketId,) = _createStEVE(_stEveParams(address(eve)));

        eve.mint(bob, 10e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 emptyPositionId = _mintPosition(bob, 1);
        assertEq(EdenStEVEActionFacet(diamond).eligibleSupply(), 0);
        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(emptyPositionId), 0);
    }
}
