// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract EqualIndexFuzzTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function testFuzz_EqualIndexWalletModeMintBurnRoutesFees(uint96 depositSeed, uint96 mintSeed) public {
        uint256 depositAmount = _boundUint(uint256(depositSeed), 50, 250) * 1e18;
        uint256 mintUnits = _boundUint(uint256(mintSeed), 1, 30) * 1e18;

        eve.mint(alice, depositAmount);
        eve.mint(bob, mintUnits * 3);

        uint256 positionId = _mintPosition(alice, 1);
        vm.startPrank(alice);
        eve.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, depositAmount, depositAmount);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Wallet Index", "WIDX", address(eve), 1000, 1000));

        vm.startPrank(bob);
        eve.approve(diamond, mintUnits * 3);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = mintUnits * 2;
        EqualIndexActionsFacetV3(diamond).mint(indexId, mintUnits, bob, maxInputs);
        assertEq(ERC20(indexToken).balanceOf(bob), mintUnits);
        EqualIndexActionsFacetV3(diamond).burn(indexId, mintUnits, bob);
        vm.stopPrank();

        assertEq(ERC20(indexToken).balanceOf(bob), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
        assertGt(PositionManagementFacet(diamond).previewPositionYield(positionId, 1), 0);
        assertGt(eve.balanceOf(treasury), 0);
    }

    function testFuzz_EqualIndexPositionModeMintBurnSettlesThroughPrincipal(
        uint96 depositSeed,
        uint96 mintSeed
    ) public {
        uint256 depositAmount = _boundUint(uint256(depositSeed), 20, 200) * 1e18;
        uint256 maxMintWholeUnits = (depositAmount / 1e18) * 10 / 11;
        if (maxMintWholeUnits == 0) {
            maxMintWholeUnits = 1;
        }
        uint256 mintUnits = _boundUint(uint256(mintSeed), 1, maxMintWholeUnits) * 1e18;

        eve.mint(alice, depositAmount);

        uint256 positionId = _mintPosition(alice, 1);
        vm.startPrank(alice);
        eve.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, depositAmount, depositAmount);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Position Index", "PIDX", address(eve), 1000, 1000));

        vm.prank(alice);
        uint256 minted = EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, mintUnits);
        assertEq(minted, mintUnits);
        assertEq(ERC20(indexToken).balanceOf(diamond), mintUnits);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(positionId, indexId, mintUnits);

        assertEq(ERC20(indexToken).balanceOf(diamond), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
    }
}
