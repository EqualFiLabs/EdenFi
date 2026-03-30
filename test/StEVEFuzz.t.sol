// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StEVEPositionFacet} from "src/steve/StEVEPositionFacet.sol";
import {StEVEActionFacet} from "src/steve/StEVEActionFacet.sol";
import {StEVEWalletFacet} from "src/steve/StEVEWalletFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";
import {ILegacyStEVEPositionFacet} from "test/utils/LegacyStEVEPositionFacet.sol";
import {ILegacyStEVEWalletFacet} from "test/utils/LegacyStEVEWalletFacet.sol";

contract StEVEFuzzTest is StEVELaunchFixture {
    function testFuzz_LegacyWalletMintBurnStayUnavailableWhileStEVEWalletFlowWorks(uint96 unitsSeed) public {
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));

        uint256 units = _boundUint(uint256(unitsSeed), 1, 40) * 1e18;
        eve.mint(bob, units * 2);

        vm.startPrank(bob);
        eve.approve(diamond, units * 2);

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = units;

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyStEVEWalletFacet(diamond).mintBasket(steveBasketId, units, bob, maxInputs);

        StEVEWalletFacet(diamond).mintStEVE(units, bob, maxInputs);
        assertEq(ERC20(steveToken).balanceOf(bob), units);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyStEVEWalletFacet(diamond).burnBasket(steveBasketId, units, bob);
        vm.stopPrank();

        assertEq(ERC20(steveToken).balanceOf(bob), units);
    }

    function testFuzz_LegacyPositionMintBurnStayUnavailableWhileStEVEPositionFlowWorks(
        uint96 depositSeed,
        uint96 mintSeed
    ) public {
        _bootstrapStEVEProduct();

        uint256 depositAmount = _boundUint(uint256(depositSeed), 50, 300) * 1e18;
        uint256 mintUnits = _boundUint(uint256(mintSeed), 1, depositAmount / 1e18) * 1e18;

        alt.mint(alice, depositAmount);
        uint256 positionId = _mintPosition(alice, 2);

        vm.startPrank(alice);
        alt.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, depositAmount, depositAmount);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyStEVEPositionFacet(diamond).mintBasketFromPosition(positionId, steveBasketId, mintUnits);

        StEVEPositionFacet(diamond).mintStEVEFromPosition(positionId, mintUnits);
        assertEq(StEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), mintUnits);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyStEVEPositionFacet(diamond).burnBasketFromPosition(positionId, steveBasketId, mintUnits);
        vm.stopPrank();

        assertEq(StEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), mintUnits);
    }
}
