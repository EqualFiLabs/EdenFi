// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {AumFeeOutOfBounds, PoolNotInitialized} from "src/libraries/Errors.sol";
import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract PoolAumFacetTest is EdenLaunchFixture {
    event PoolAumFeeUpdated(uint256 indexed pid, uint16 oldFeeBps, uint16 newFeeBps);

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_SetAumFee_IsTimelockOnlyAndEmitsEvent() public {
        vm.expectRevert(bytes("LibAccess: not timelock"));
        PoolManagementFacet(diamond).setAumFee(1, 25);

        vm.recordLogs();
        _timelockCall(diamond, abi.encodeWithSelector(PoolManagementFacet.setAumFee.selector, 1, uint16(25)));
        _assertIndexedEventEmitted(keccak256("PoolAumFeeUpdated(uint256,uint16,uint16)"), bytes32(uint256(1)));

        PoolManagementFacet.PoolConfigView memory config = PoolManagementFacet(diamond).getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), 25);
        assertEq(uint256(config.aumFeeMinBps), 10);
        assertEq(uint256(config.aumFeeMaxBps), 100);
    }

    function test_SetAumFee_EnforcesImmutableBounds() public {
        PoolManagementFacet.PoolConfigView memory config = PoolManagementFacet(diamond).getPoolConfigView(1);
        bytes memory lowData = abi.encodeWithSelector(
            PoolManagementFacet.setAumFee.selector, 1, uint16(config.aumFeeMinBps - 1)
        );
        bytes32 lowSalt = keccak256("aum-fee-below-min");
        timelockController.schedule(diamond, 0, lowData, bytes32(0), lowSalt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                AumFeeOutOfBounds.selector,
                uint16(config.aumFeeMinBps - 1),
                config.aumFeeMinBps,
                config.aumFeeMaxBps
            )
        );
        timelockController.execute(diamond, 0, lowData, bytes32(0), lowSalt);

        bytes memory highData = abi.encodeWithSelector(
            PoolManagementFacet.setAumFee.selector, 1, uint16(config.aumFeeMaxBps + 1)
        );
        bytes32 highSalt = keccak256("aum-fee-above-max");
        timelockController.schedule(diamond, 0, highData, bytes32(0), highSalt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                AumFeeOutOfBounds.selector,
                uint16(config.aumFeeMaxBps + 1),
                config.aumFeeMinBps,
                config.aumFeeMaxBps
            )
        );
        timelockController.execute(diamond, 0, highData, bytes32(0), highSalt);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(PoolManagementFacet.setAumFee.selector, 1, config.aumFeeMaxBps)
        );
        config = PoolManagementFacet(diamond).getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), uint256(config.aumFeeMaxBps));
    }

    function test_PoolLevelAumViews_ReportConfigInfoAndMaintenanceState() public {
        PoolManagementFacet.PoolConfigView memory config = PoolManagementFacet(diamond).getPoolConfigView(1);
        assertEq(config.underlying, address(eve));
        assertTrue(config.initialized);
        assertEq(uint256(config.rollingApyBps), 500);
        assertEq(uint256(config.depositorLTVBps), 8000);
        assertEq(uint256(config.maintenanceRateBps), 100);
        assertEq(uint256(config.currentAumFeeBps), 10);
        assertEq(uint256(config.aumFeeMinBps), 10);
        assertEq(uint256(config.aumFeeMaxBps), 100);
        assertEq(config.fixedTermConfigs.length, 1);
        assertEq(uint256(config.fixedTermConfigs[0].durationSecs), 7 days);
        assertEq(uint256(config.fixedTermConfigs[0].apyBps), 500);
        assertEq(uint256(config.borrowFee.amount), 0);
        assertTrue(!config.borrowFee.enabled);

        PoolManagementFacet.PoolInfoView memory info = PoolManagementFacet(diamond).getPoolInfoView(1);
        assertEq(info.underlying, address(eve));
        assertTrue(info.initialized);
        assertTrue(!info.isManagedPool);
        assertEq(info.manager, address(0));
        assertTrue(!info.whitelistEnabled);
        assertTrue(!info.deprecated);
        assertEq(info.totalDeposits, 0);
        assertEq(info.indexEncumberedTotal, 0);
        assertEq(info.trackedBalance, 0);
        assertEq(info.yieldReserve, 0);
        assertEq(info.feeIndex, 0);
        assertEq(info.activeCreditIndex, 0);
        assertEq(info.activeCreditPrincipalTotal, 0);
        assertEq(info.activeCreditMaturedTotal, 0);
        assertEq(info.userCount, 0);

        PoolManagementFacet.PoolMaintenanceView memory maintenance =
            PoolManagementFacet(diamond).getPoolMaintenanceView(1);
        assertEq(maintenance.foundationReceiver, address(0));
        assertEq(uint256(maintenance.maintenanceRateBps), 100);
        assertGt(uint256(maintenance.lastMaintenanceTimestamp), 0);
        assertEq(maintenance.pendingMaintenance, 0);
        assertEq(maintenance.maintenanceIndex, 0);
        assertEq(maintenance.maintenanceIndexRemainder, 0);
        assertEq(maintenance.epochLength, 1 days);

        vm.expectRevert(abi.encodeWithSelector(PoolNotInitialized.selector, 99));
        PoolManagementFacet(diamond).getPoolConfigView(99);

        vm.expectRevert(abi.encodeWithSelector(PoolNotInitialized.selector, 99));
        PoolManagementFacet(diamond).getPoolInfoView(99);

        vm.expectRevert(abi.encodeWithSelector(PoolNotInitialized.selector, 99));
        PoolManagementFacet(diamond).getPoolMaintenanceView(99);
    }

    function test_PoolMaintenanceView_ReflectsLiveAccrualAndPayout() public {
        testSupport.setFoundationReceiver(carol);

        eve.mint(alice, 250e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 250e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        PoolManagementFacet.PoolMaintenanceView memory beforeMaintenance =
            PoolManagementFacet(diamond).getPoolMaintenanceView(1);
        uint256 receiverBefore = eve.balanceOf(carol);

        vm.warp(block.timestamp + 365 days + 1);

        vm.prank(alice);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 10e18, 10e18);

        PoolManagementFacet.PoolMaintenanceView memory afterMaintenance =
            PoolManagementFacet(diamond).getPoolMaintenanceView(1);
        PoolManagementFacet.PoolInfoView memory info = PoolManagementFacet(diamond).getPoolInfoView(1);

        assertEq(afterMaintenance.foundationReceiver, carol);
        assertGt(uint256(afterMaintenance.lastMaintenanceTimestamp), uint256(beforeMaintenance.lastMaintenanceTimestamp));
        assertGt(afterMaintenance.maintenanceIndex, beforeMaintenance.maintenanceIndex);
        assertEq(afterMaintenance.pendingMaintenance, 0);
        assertGt(eve.balanceOf(carol), receiverBefore);
        assertTrue(info.totalDeposits < 210e18);
        assertTrue(info.trackedBalance < 210e18);
    }

    function _assertIndexedEventEmitted(bytes32 topic0, bytes32 topic1) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == diamond && logs[i].topics.length > 1 && logs[i].topics[0] == topic0
                    && logs[i].topics[1] == topic1
            ) {
                return;
            }
        }
        revert("expected indexed event not found");
    }
}
