// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic subsystem coverage only: managed routing is exercised through the test support facet
// until a first-class product flow routes through routeManagedShare.

import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {Types} from "src/libraries/Types.sol";

import {EdenLaunchFixture, MockERC20Launch} from "test/utils/EdenLaunchFixture.t.sol";
import {ProtocolTestSupportFacet} from "test/utils/ProtocolTestSupport.sol";

contract ManagedFeeRoutingTest is EdenLaunchFixture {
    uint256 internal constant MANAGED_PID = 7;
    uint256 internal constant CREATION_FEE = 1 ether;
    bytes32 internal constant SOURCE = keccak256("managed-route-test");

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
        testSupport.setManagedPoolCreationFee(CREATION_FEE);
    }

    function test_RouteManagedShare_FallsBackToTreasuryWhenBasePoolHasNoDeposits() public {
        MockERC20Launch gamma = new MockERC20Launch("GAMMA", "GAMMA");
        _createManagedPool(alice, MANAGED_PID, address(gamma));

        uint256 managedPositionId = _whitelistedPosition(alice, MANAGED_PID);
        gamma.mint(alice, 200e18);
        vm.startPrank(alice);
        gamma.approve(diamond, 100e18);
        PositionManagementFacet(diamond).depositToPosition(managedPositionId, MANAGED_PID, 100e18, 100e18);
        gamma.transfer(diamond, 100e18);
        vm.stopPrank();

        uint256 treasuryBefore = gamma.balanceOf(treasury);
        ProtocolTestSupportFacet.PoolView memory managedBefore = testSupport.getPoolView(MANAGED_PID);
        uint256 basePid = testSupport.assetToPoolId(address(gamma));
        ProtocolTestSupportFacet.PoolView memory baseBefore = testSupport.getPoolView(basePid);

        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) =
            testSupport.routeManagedShareExternal(MANAGED_PID, 50e18, SOURCE, true, 100e18);

        ProtocolTestSupportFacet.PoolView memory managedAfter = testSupport.getPoolView(MANAGED_PID);
        ProtocolTestSupportFacet.PoolView memory baseAfter = testSupport.getPoolView(basePid);

        assertEq(toTreasury, 14e18);
        assertEq(toActiveCredit, 0);
        assertEq(toFeeIndex, 36e18);
        assertEq(gamma.balanceOf(treasury), treasuryBefore + 14e18);
        assertEq(managedAfter.trackedBalance, managedBefore.trackedBalance - 14e18);
        assertEq(managedAfter.yieldReserve, managedBefore.yieldReserve + 36e18);
        assertEq(baseAfter.trackedBalance, baseBefore.trackedBalance);
        assertEq(baseAfter.yieldReserve, baseBefore.yieldReserve);
    }

    function test_RouteManagedShare_RoutesSystemShareIntoBackedBasePool() public {
        _createManagedPool(alice, MANAGED_PID, address(alt));

        uint256 basePositionId = _mintPosition(alice, 2);
        alt.mint(alice, 250e18);
        vm.startPrank(alice);
        alt.approve(diamond, 250e18);
        PositionManagementFacet(diamond).depositToPosition(basePositionId, 2, 50e18, 50e18);
        vm.stopPrank();

        uint256 managedPositionId = _whitelistedPosition(alice, MANAGED_PID);
        vm.startPrank(alice);
        alt.approve(diamond, 250e18);
        PositionManagementFacet(diamond).depositToPosition(managedPositionId, MANAGED_PID, 100e18, 100e18);
        alt.transfer(diamond, 100e18);
        vm.stopPrank();

        uint256 treasuryBefore = alt.balanceOf(treasury);
        ProtocolTestSupportFacet.PoolView memory managedBefore = testSupport.getPoolView(MANAGED_PID);
        ProtocolTestSupportFacet.PoolView memory baseBefore = testSupport.getPoolView(2);

        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) =
            testSupport.routeManagedShareExternal(MANAGED_PID, 50e18, SOURCE, true, 100e18);

        ProtocolTestSupportFacet.PoolView memory managedAfter = testSupport.getPoolView(MANAGED_PID);
        ProtocolTestSupportFacet.PoolView memory baseAfter = testSupport.getPoolView(2);

        assertEq(toTreasury, 5e18);
        assertEq(toActiveCredit, 0);
        assertEq(toFeeIndex, 45e18);
        assertEq(alt.balanceOf(treasury), treasuryBefore + 5e18);
        assertEq(managedAfter.trackedBalance, managedBefore.trackedBalance - 14e18);
        assertEq(managedAfter.yieldReserve, managedBefore.yieldReserve + 36e18);
        assertEq(baseAfter.trackedBalance, baseBefore.trackedBalance + 9e18);
        assertEq(baseAfter.yieldReserve, baseBefore.yieldReserve + 9e18);
    }

    function _createManagedPool(address manager, uint256 pid, address underlying) internal {
        vm.deal(manager, CREATION_FEE);
        vm.prank(manager);
        PoolManagementFacet(diamond).initManagedPool{value: CREATION_FEE}(pid, underlying, _poolConfig());
    }

    function _whitelistedPosition(address owner, uint256 pid) internal returns (uint256 positionId) {
        positionId = _mintPosition(owner, pid);
        vm.prank(alice);
        PoolManagementFacet(diamond).addToWhitelist(pid, positionId);
    }
}
