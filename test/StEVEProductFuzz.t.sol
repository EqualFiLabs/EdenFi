// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StEVEActionFacet} from "src/steve/StEVEActionFacet.sol";
import {StEVEViewFacet} from "src/steve/StEVEViewFacet.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";

contract StEVEProductFuzzTest is StEVELaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
    }

    function testFuzz_StEVEEligibilityTracksWalletAndPositionTransitions(
        uint96 walletSeed,
        uint96 depositSeed,
        uint96 withdrawSeed
    ) public {
        uint256 walletUnits = _boundUint(uint256(walletSeed), 2, 80) * 1e18;
        uint256 depositUnits = _boundUint(uint256(depositSeed), 1, walletUnits / 1e18) * 1e18;
        uint256 withdrawUnits = _boundUint(uint256(withdrawSeed), 0, depositUnits / 1e18) * 1e18;

        eve.mint(bob, walletUnits);
        _mintWalletBasket(bob, steveBasketId, eve, walletUnits);

        uint256 positionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(bob, positionId, depositUnits);

        if (withdrawUnits > 0) {
            vm.prank(bob);
            StEVEActionFacet(diamond).withdrawStEVEFromPosition(positionId, withdrawUnits, withdrawUnits);
        }

        uint256 expectedEligible = depositUnits - withdrawUnits;
        StEVEViewFacet.PositionPortfolio memory portfolio = StEVEViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(StEVEActionFacet(diamond).eligibleSupply(), expectedEligible);
        assertEq(StEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), expectedEligible);
        assertEq(portfolio.rewards.eligiblePrincipal, expectedEligible);
        assertEq(portfolio.product.units, expectedEligible);
        assertEq(ERC20(steveToken).balanceOf(bob), walletUnits - depositUnits + withdrawUnits);
    }
}
