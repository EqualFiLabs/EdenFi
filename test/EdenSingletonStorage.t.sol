// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EdenStEVEWalletFacet} from "src/eden/EdenStEVEWalletFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";
import {ILegacyEdenWalletFacet} from "test/utils/LegacyEdenWalletFacet.sol";

contract EdenSingletonStorageTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
        eve.mint(alice, 50e18);
    }

    function test_SingletonProductStorage_BacksWalletAccounting() public {
        EdenViewFacet.ProductConfigView memory beforeMint = EdenViewFacet(diamond).getProductConfig();
        assertEq(beforeMint.productId, steveBasketId);
        assertEq(beforeMint.totalUnits, 0);
        assertEq(beforeMint.name, "stEVE");
        assertTrue(beforeMint.steveConfigured);

        _mintWalletBasket(alice, steveBasketId, eve, 10e18);

        EdenViewFacet.ProductConfigView memory afterMint = EdenViewFacet(diamond).getProductConfig();
        assertEq(afterMint.totalUnits, 10e18);
        assertEq(EdenViewFacet(diamond).getProductVaultBalance(address(eve)), 10e18);
        assertEq(EdenViewFacet(diamond).getProductFeePot(address(eve)), 0);

        vm.prank(alice);
        EdenStEVEWalletFacet(diamond).burnStEVE(10e18, alice);

        EdenViewFacet.ProductConfigView memory afterBurn = EdenViewFacet(diamond).getProductConfig();
        assertEq(afterBurn.totalUnits, 0);
        assertEq(EdenViewFacet(diamond).getProductVaultBalance(address(eve)), 0);
    }

    function test_RevertWhen_ConfiguringSecondEdenProduct() public {
        EdenBasketBase.CreateBasketParams memory params =
            _singleAssetParams("ALT Basket", "ALTB", address(alt), "ipfs://alt", 2, 0, 0);
        vm.expectRevert();
        ILegacyEdenWalletFacet(diamond).createBasket(params);
    }
}
