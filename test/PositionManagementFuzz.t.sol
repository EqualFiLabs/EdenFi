// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NoClaimableYield} from "src/libraries/Errors.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";

contract PositionManagementFuzzTest is StEVELaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function testFuzz_PositionDepositWithdrawCleanupAndYieldClaim(
        uint96 depositSeed,
        uint96 mintSeed,
        uint96 withdrawSeed
    ) public {
        uint256 depositAmount = _boundUint(uint256(depositSeed), 20, 200) * 1e18;
        uint256 mintUnits = _boundUint(uint256(mintSeed), 2, 30) * 1e18;
        uint256 firstWithdraw = _boundUint(uint256(withdrawSeed), 1, depositAmount / 1e18) * 1e18;

        eve.mint(alice, depositAmount);
        eve.mint(bob, mintUnits * 3);

        uint256 alicePositionId = _mintPosition(alice, 1);
        vm.startPrank(alice);
        eve.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, depositAmount, depositAmount);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Yield Index", "YIDX", address(eve), 1000, 1000));

        vm.startPrank(bob);
        eve.approve(diamond, mintUnits * 3);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = mintUnits * 2;
        EqualIndexActionsFacetV3(diamond).mint(indexId, mintUnits, bob, maxInputs);
        EqualIndexActionsFacetV3(diamond).burn(indexId, mintUnits, bob);
        vm.stopPrank();

        uint256 claimable = PositionManagementFacet(diamond).previewPositionYield(alicePositionId, 1);
        assertGt(claimable, 0);

        uint256 balanceBeforeClaim = eve.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = PositionManagementFacet(diamond).claimPositionYield(alicePositionId, 1, alice, claimable);
        assertEq(claimed, claimable);
        assertEq(eve.balanceOf(alice), balanceBeforeClaim + claimable);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(NoClaimableYield.selector, positionNft.getPositionKey(alicePositionId), 1)
        );
        vm.prank(alice);
        PositionManagementFacet(diamond).claimPositionYield(alicePositionId, 1, alice, 0);

        if (firstWithdraw >= depositAmount) {
            firstWithdraw = depositAmount - 1e18;
        }

        vm.prank(alice);
        PositionManagementFacet(diamond).withdrawFromPosition(alicePositionId, 1, firstWithdraw, firstWithdraw);

        uint256 remaining = depositAmount - firstWithdraw;
        vm.prank(alice);
        PositionManagementFacet(diamond).withdrawFromPosition(alicePositionId, 1, remaining, remaining);

        vm.prank(alice);
        PositionManagementFacet(diamond).cleanupMembership(alicePositionId, 1);
    }
}
