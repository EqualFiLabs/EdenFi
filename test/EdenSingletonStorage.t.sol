// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EdenBasketDataFacet} from "src/eden/EdenBasketDataFacet.sol";
import {EdenBasketWalletFacet} from "src/eden/EdenBasketWalletFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenSingletonStorageTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
        eve.mint(alice, 50e18);
    }

    function test_SingletonProductStorage_BacksWalletAccounting() public {
        assertEq(EdenViewFacet(diamond).basketCount(), 1);

        uint256[] memory basketIds = EdenViewFacet(diamond).getBasketIds(0, 10);
        assertEq(basketIds.length, 1);
        assertEq(basketIds[0], steveBasketId);

        EdenViewFacet.BasketSummary memory beforeMint = EdenViewFacet(diamond).getBasketSummary(steveBasketId);
        assertEq(beforeMint.totalUnits, 0);
        assertEq(beforeMint.name, "stEVE");
        assertTrue(beforeMint.isStEVE);

        _mintWalletBasket(alice, steveBasketId, eve, 10e18);

        EdenViewFacet.BasketSummary memory afterMint = EdenViewFacet(diamond).getBasketSummary(steveBasketId);
        assertEq(afterMint.totalUnits, 10e18);
        assertEq(EdenBasketDataFacet(diamond).getBasketVaultBalance(steveBasketId, address(eve)), 10e18);
        assertEq(EdenBasketDataFacet(diamond).getBasketFeePot(steveBasketId, address(eve)), 0);

        vm.prank(alice);
        EdenBasketWalletFacet(diamond).burnBasket(steveBasketId, 10e18, alice);

        EdenViewFacet.BasketSummary memory afterBurn = EdenViewFacet(diamond).getBasketSummary(steveBasketId);
        assertEq(afterBurn.totalUnits, 0);
        assertEq(EdenBasketDataFacet(diamond).getBasketVaultBalance(steveBasketId, address(eve)), 0);
    }

    function test_RevertWhen_ConfiguringSecondEdenProduct() public {
        EdenBasketBase.CreateBasketParams memory params =
            _singleAssetParams("ALT Basket", "ALTB", address(alt), "ipfs://alt", 2, 0, 0);
        vm.expectRevert();
        EdenBasketWalletFacet(diamond).createBasket(params);
    }
}
