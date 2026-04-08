// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {AumFeeOutOfBounds, PoolNotInitialized} from "src/libraries/Errors.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {Types} from "src/libraries/Types.sol";
import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract MockERC20PoolAum is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract PoolAumAccessHarness is PoolManagementFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }
}

abstract contract PoolAumAccessHarnessBase {
    function _deployAumAccessHarness(address owner_, address timelock_)
        internal
        returns (PoolAumAccessHarness harness_, MockERC20PoolAum token_)
    {
        harness_ = new PoolAumAccessHarness();
        harness_.setOwner(owner_);
        harness_.setTimelock(timelock_);

        token_ = new MockERC20PoolAum("AUM", "AUM");
        harness_.initPoolWithActionFees(1, address(token_), _localPoolConfig(), _localActionFees());
    }

    function _localPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](1);
        fixedTerms[0] = Types.FixedTermConfig({durationSecs: 7 days, apyBps: 500});

        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8_000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 20;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMinBps = 10;
        cfg.aumFeeMaxBps = 100;
        cfg.fixedTermConfigs = fixedTerms;
    }

    function _localActionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        return actionFees;
    }
}

contract PoolAumFacetTest is LaunchFixture, PoolAumAccessHarnessBase {
    event PoolAumFeeUpdated(uint256 indexed pid, uint16 oldFeeBps, uint16 newFeeBps);

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_SetAumFee_IsTimelockOnlyAndEmitsEvent() public {
        address timelock = makeAddr("aum-timelock");
        (PoolAumAccessHarness harness,) = _deployAumAccessHarness(address(this), timelock);

        vm.recordLogs();
        harness.setAumFee(1, 25);
        _assertIndexedEventEmitted(address(harness), keccak256("PoolAumFeeUpdated(uint256,uint16,uint16)"), bytes32(uint256(1)));

        PoolManagementFacet.PoolConfigView memory config = harness.getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), 25);
        assertEq(uint256(config.aumFeeMinBps), 10);
        assertEq(uint256(config.aumFeeMaxBps), 100);

        vm.recordLogs();
        vm.prank(timelock);
        harness.setAumFee(1, 40);
        _assertIndexedEventEmitted(address(harness), keccak256("PoolAumFeeUpdated(uint256,uint16,uint16)"), bytes32(uint256(1)));

        config = harness.getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), 40);

        vm.prank(carol);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        harness.setAumFee(1, 55);

        config = harness.getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), 40);
    }

    function test_SetAumFee_AdminLifecycleAllowsOwnerAndTimelockButRejectsUnauthorized() public {
        address timelock = makeAddr("aum-admin-timelock");
        (PoolAumAccessHarness harness,) = _deployAumAccessHarness(address(this), timelock);

        harness.setAumFee(1, 30);

        PoolManagementFacet.PoolConfigView memory config = harness.getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), 30);

        vm.prank(timelock);
        harness.setAumFee(1, 60);

        config = harness.getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), 60);

        vm.prank(carol);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        harness.setAumFee(1, 45);

        config = harness.getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), 60);
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

    function _assertIndexedEventEmitted(address emitter, bytes32 topic0, bytes32 topic1) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length > 1 && logs[i].topics[0] == topic0
                    && logs[i].topics[1] == topic1
            ) {
                return;
            }
        }
        revert("expected indexed event not found");
    }
}

contract PoolAumFacetBugConditionTest is LaunchFixture, PoolAumAccessHarnessBase {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function test_BugCondition_SetAumFee_ShouldAllowOwnerWhenTimelockIsConfigured() public {
        address timelock = makeAddr("aum-bug-timelock");
        (PoolAumAccessHarness harness,) = _deployAumAccessHarness(address(this), timelock);

        harness.setAumFee(1, 25);

        PoolManagementFacet.PoolConfigView memory config = harness.getPoolConfigView(1);
        assertEq(uint256(config.currentAumFeeBps), 25);
    }
}
