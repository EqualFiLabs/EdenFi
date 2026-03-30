// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StEVEWalletFacet} from "src/steve/StEVEWalletFacet.sol";
import {StEVEViewFacet} from "src/steve/StEVEViewFacet.sol";
import {StEVEProductBase} from "src/steve/StEVEProductBase.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";
import {ILegacyStEVEWalletFacet} from "test/utils/LegacyStEVEWalletFacet.sol";

contract StEVESingletonStorageTest is StEVELaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
        eve.mint(alice, 50e18);
    }

    function test_SingletonProductStorage_BacksWalletAccounting() public {
        StEVEViewFacet.ProductConfigView memory beforeMint = StEVEViewFacet(diamond).getProductConfig();
        assertEq(beforeMint.productId, steveBasketId);
        assertEq(beforeMint.totalUnits, 0);
        assertEq(beforeMint.name, "stEVE");
        assertTrue(beforeMint.steveConfigured);

        _mintWalletBasket(alice, steveBasketId, eve, 10e18);

        StEVEViewFacet.ProductConfigView memory afterMint = StEVEViewFacet(diamond).getProductConfig();
        assertEq(afterMint.totalUnits, 10e18);
        assertEq(StEVEViewFacet(diamond).getProductVaultBalance(address(eve)), 10e18);
        assertEq(StEVEViewFacet(diamond).getProductFeePot(address(eve)), 0);

        vm.prank(alice);
        StEVEWalletFacet(diamond).burnStEVE(10e18, alice);

        StEVEViewFacet.ProductConfigView memory afterBurn = StEVEViewFacet(diamond).getProductConfig();
        assertEq(afterBurn.totalUnits, 0);
        assertEq(StEVEViewFacet(diamond).getProductVaultBalance(address(eve)), 0);
    }

    function test_RevertWhen_ConfiguringSecondEdenProduct() public {
        StEVEProductBase.CreateBasketParams memory params =
            _singleAssetParams("ALT Basket", "ALTB", address(alt), "ipfs://alt", 2, 0, 0);
        vm.expectRevert();
        ILegacyStEVEWalletFacet(diamond).createBasket(params);
    }
}
