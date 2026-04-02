// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {
    CannotClearMembership,
    NoClaimableYield
} from "src/libraries/Errors.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract PositionManagementFacetTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_ClaimPositionYield_RevertsWhenMinReceivedIsTooHigh() public {
        uint256 positionId = _seedYieldBearingPosition();
        uint256 claimable = PositionManagementFacet(diamond).previewPositionYield(positionId, 1);
        assertGt(claimable, 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, claimable, claimable + 1)
        );
        PositionManagementFacet(diamond).claimPositionYield(positionId, 1, alice, claimable + 1);
    }

    function test_CleanupMembership_RevertsWhileDirtyAndClearsOnceClean() public {
        eve.mint(alice, 50e18);
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        vm.startPrank(alice);
        eve.approve(diamond, 50e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 20e18, 20e18);
        vm.stopPrank();

        assertEq(testSupport.principalOf(1, positionKey), 20e18);
        (bool canClear, string memory reason) = testSupport.canClearMembership(1, positionKey);
        assertTrue(!canClear);
        assertEq(reason, "principal>0");
        (bool ok, bytes memory revertData) =
            _callAs(alice, abi.encodeWithSelector(PositionManagementFacet.cleanupMembership.selector, positionId, 1));
        assertTrue(!ok);
        assertEq(_revertSelector(revertData), CannotClearMembership.selector);

        vm.startPrank(alice);
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, 1, 20e18, 20e18);
        PositionManagementFacet(diamond).cleanupMembership(positionId, 1);
        vm.stopPrank();
    }

    function test_ClaimPositionYield_RevertsWhenNothingClaimable() public {
        eve.mint(alice, 20e18);
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 20e18, 20e18);
        vm.expectRevert(abi.encodeWithSelector(NoClaimableYield.selector, positionKey, 1));
        PositionManagementFacet(diamond).claimPositionYield(positionId, 1, alice, 0);
        vm.stopPrank();
    }

    function test_DepositSettlesExistingYieldBeforePrincipalIncreaseAndClaimRemainsAvailable() public {
        uint256 positionId = _seedYieldBearingPosition();
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        uint256 claimableBefore = PositionManagementFacet(diamond).previewPositionYield(positionId, 1);
        assertGt(claimableBefore, 0);

        eve.mint(alice, 10e18);
        vm.startPrank(alice);
        eve.approve(diamond, 10e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 10e18, 10e18);
        vm.stopPrank();

        assertEq(testSupport.principalOf(1, positionKey), 110e18);

        uint256 claimableAfter = PositionManagementFacet(diamond).previewPositionYield(positionId, 1);
        assertEq(claimableAfter, claimableBefore);

        uint256 balanceBeforeClaim = eve.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = PositionManagementFacet(diamond).claimPositionYield(positionId, 1, alice, claimableAfter);

        assertEq(claimed, claimableBefore);
        assertEq(eve.balanceOf(alice), balanceBeforeClaim + claimableBefore);
    }

    function test_PositionCanDepositWithdrawAndCleanupAcrossJoinedPools() public {
        eve.mint(alice, 20e18);
        alt.mint(alice, 30e18);

        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        alt.approve(diamond, 30e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 20e18, 20e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 30e18, 30e18);
        vm.stopPrank();

        assertEq(testSupport.principalOf(1, positionKey), 20e18);
        assertEq(testSupport.principalOf(2, positionKey), 30e18);

        vm.startPrank(alice);
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, 2, 30e18, 30e18);
        PositionManagementFacet(diamond).cleanupMembership(positionId, 2);
        vm.stopPrank();

        assertEq(testSupport.principalOf(2, positionKey), 0);
        (bool canClear, string memory reason) = testSupport.canClearMembership(2, positionKey);
        assertTrue(canClear);
        assertEq(bytes(reason).length, 0);
    }

    function _seedYieldBearingPosition() internal returns (uint256 positionId) {
        eve.mint(alice, 100e18);
        eve.mint(bob, 60e18);

        positionId = _mintPosition(alice, 1);
        vm.startPrank(alice);
        eve.approve(diamond, 100e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100e18, 100e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Yield Index", "YIDX", address(eve), 1000, 1000));

        vm.startPrank(bob);
        eve.approve(diamond, 60e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 22e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 20e18, bob, maxInputs);
        EqualIndexActionsFacetV3(diamond).burn(indexId, 20e18, bob);
        vm.stopPrank();
    }

    function _callAs(address caller, bytes memory data) internal returns (bool ok, bytes memory result) {
        vm.prank(caller);
        (ok, result) = diamond.call(data);
    }

    function _revertSelector(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := mload(add(revertData, 0x20))
        }
    }
}
