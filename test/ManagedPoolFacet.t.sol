// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {Types} from "src/libraries/Types.sol";
import {
    WhitelistRequired,
    NotPoolManager,
    OnlyManagerAllowed
} from "src/libraries/Errors.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";
import {ProtocolTestSupportFacet} from "test/utils/ProtocolTestSupport.sol";

contract ManagedPoolFacetTest is LaunchFixture {
    uint256 internal constant MANAGED_PID = 7;
    uint256 internal constant CREATION_FEE = 1 ether;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
        testSupport.setManagedPoolCreationFee(CREATION_FEE);
    }

    function test_InitManagedPool_SetsManagerWhitelistAndCanonicalState() public {
        Types.PoolConfig memory cfg = _poolConfig();

        vm.deal(alice, CREATION_FEE);
        vm.prank(alice);
        PoolManagementFacet(diamond).initManagedPool{value: CREATION_FEE}(MANAGED_PID, address(alt), cfg);

        ProtocolTestSupportFacet.PoolView memory pool = testSupport.getPoolView(MANAGED_PID);
        assertTrue(pool.initialized);
        assertTrue(pool.isManagedPool);
        assertEq(pool.manager, alice);
        assertTrue(pool.whitelistEnabled);
        assertEq(pool.currentAumFeeBps, cfg.aumFeeMinBps);
        assertEq(pool.underlying, address(alt));

        assertEq(testSupport.assetToPoolId(address(alt)), 2);
    }

    function test_ManagerOnlyMutableConfigAndTransferLifecycle() public {
        _createManagedPool(alice, MANAGED_PID, address(alt));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, bob, alice));
        PoolManagementFacet(diamond).setRollingApy(MANAGED_PID, 900);

        vm.prank(alice);
        PoolManagementFacet(diamond).setRollingApy(MANAGED_PID, 900);
        assertEq(testSupport.getPoolView(MANAGED_PID).currentAumFeeBps, _poolConfig().aumFeeMinBps);

        vm.prank(alice);
        PoolManagementFacet(diamond).transferManager(MANAGED_PID, carol);
        assertEq(testSupport.getPoolView(MANAGED_PID).manager, carol);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotPoolManager.selector, alice, carol));
        PoolManagementFacet(diamond).setDepositCap(MANAGED_PID, 10e18);

        vm.prank(carol);
        PoolManagementFacet(diamond).setDepositCap(MANAGED_PID, 10e18);

        vm.prank(carol);
        PoolManagementFacet(diamond).renounceManager(MANAGED_PID);
        assertEq(testSupport.getPoolView(MANAGED_PID).manager, address(0));

        vm.prank(carol);
        vm.expectRevert(OnlyManagerAllowed.selector);
        PoolManagementFacet(diamond).setDepositCap(MANAGED_PID, 11e18);
    }

    function test_WhitelistAddRemoveAndToggleControlsDeposits() public {
        _createManagedPool(alice, MANAGED_PID, address(alt));

        uint256 positionId = _mintPosition(bob, MANAGED_PID);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        alt.mint(bob, 30e18);
        vm.startPrank(bob);
        alt.approve(diamond, 30e18);
        vm.expectRevert(abi.encodeWithSelector(WhitelistRequired.selector, positionKey, MANAGED_PID));
        PositionManagementFacet(diamond).depositToPosition(positionId, MANAGED_PID, 10e18, 10e18);
        vm.stopPrank();

        vm.prank(alice);
        PoolManagementFacet(diamond).addToWhitelist(MANAGED_PID, positionId);
        assertTrue(testSupport.isWhitelisted(MANAGED_PID, positionId));

        vm.prank(bob);
        PositionManagementFacet(diamond).depositToPosition(positionId, MANAGED_PID, 10e18, 10e18);

        uint256 secondPositionId = _mintPosition(carol, MANAGED_PID);
        bytes32 secondKey = positionNft.getPositionKey(secondPositionId);
        alt.mint(carol, 30e18);
        vm.startPrank(carol);
        alt.approve(diamond, 30e18);
        vm.expectRevert(abi.encodeWithSelector(WhitelistRequired.selector, secondKey, MANAGED_PID));
        PositionManagementFacet(diamond).depositToPosition(secondPositionId, MANAGED_PID, 10e18, 10e18);
        vm.stopPrank();

        vm.prank(alice);
        PoolManagementFacet(diamond).setWhitelistEnabled(MANAGED_PID, false);
        assertTrue(!testSupport.getPoolView(MANAGED_PID).whitelistEnabled);

        vm.prank(carol);
        PositionManagementFacet(diamond).depositToPosition(secondPositionId, MANAGED_PID, 10e18, 10e18);

        vm.prank(alice);
        PoolManagementFacet(diamond).removeFromWhitelist(MANAGED_PID, positionId);
        assertTrue(!testSupport.isWhitelisted(MANAGED_PID, positionId));
    }

    function _createManagedPool(address manager, uint256 pid, address underlying) internal {
        vm.deal(manager, CREATION_FEE);
        vm.prank(manager);
        PoolManagementFacet(diamond).initManagedPool{value: CREATION_FEE}(pid, underlying, _poolConfig());
    }
}
