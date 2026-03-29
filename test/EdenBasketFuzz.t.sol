// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EdenBasketPositionFacet} from "src/eden/EdenBasketPositionFacet.sol";
import {EdenStEVEActionFacet} from "src/eden/EdenStEVEActionFacet.sol";
import {EdenStEVEWalletFacet} from "src/eden/EdenStEVEWalletFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";
import {ILegacyEdenPositionFacet} from "test/utils/LegacyEdenPositionFacet.sol";
import {ILegacyEdenWalletFacet} from "test/utils/LegacyEdenWalletFacet.sol";

contract EdenBasketFuzzTest is EdenLaunchFixture {
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
        ILegacyEdenWalletFacet(diamond).mintBasket(steveBasketId, units, bob, maxInputs);

        EdenStEVEWalletFacet(diamond).mintStEVE(units, bob, maxInputs);
        assertEq(ERC20(steveToken).balanceOf(bob), units);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyEdenWalletFacet(diamond).burnBasket(steveBasketId, units, bob);
        vm.stopPrank();

        assertEq(ERC20(steveToken).balanceOf(bob), units);
    }

    function testFuzz_LegacyPositionMintBurnStayUnavailableWhileStEVEPositionFlowWorks(
        uint96 depositSeed,
        uint96 mintSeed
    ) public {
        _bootstrapEdenProduct();

        uint256 depositAmount = _boundUint(uint256(depositSeed), 50, 300) * 1e18;
        uint256 mintUnits = _boundUint(uint256(mintSeed), 1, depositAmount / 1e18) * 1e18;

        alt.mint(alice, depositAmount);
        uint256 positionId = _mintPosition(alice, 2);

        vm.startPrank(alice);
        alt.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, depositAmount, depositAmount);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyEdenPositionFacet(diamond).mintBasketFromPosition(positionId, steveBasketId, mintUnits);

        EdenBasketPositionFacet(diamond).mintStEVEFromPosition(positionId, mintUnits);
        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), mintUnits);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyEdenPositionFacet(diamond).burnBasketFromPosition(positionId, steveBasketId, mintUnits);
        vm.stopPrank();

        assertEq(EdenStEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), mintUnits);
    }
}
