// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {ManagedFeeRoutingTest} from "test/ManagedFeeRouting.t.sol";
import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";
import {ProtocolTestSupportFacet} from "test/utils/ProtocolTestSupport.sol";

contract MockSenderDeltaToken is ERC20 {
    uint256 internal constant BPS = 10_000;

    uint256 public extraSenderBps = 1000;
    address public feeSink = address(0xdead);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || extraSenderBps == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 extraSenderCharge = (value * extraSenderBps) / BPS;
        super._update(from, feeSink, extraSenderCharge);
        super._update(from, to, value);
    }
}

contract LibFeeRouterBugConditionTest is LaunchFixture {
    uint256 internal constant CANONICAL_PID = 170;
    uint256 internal constant MANAGED_PID = 180;
    uint256 internal constant CREATION_FEE = 1 ether;
    bytes32 internal constant SOURCE = keccak256("fee-router-bug-condition");

    MockSenderDeltaToken internal exotic;
    MockSenderDeltaToken internal managedOnlyExotic;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();

        exotic = new MockSenderDeltaToken("Exotic", "EXO");
        managedOnlyExotic = new MockSenderDeltaToken("Managed Exotic", "MEXO");

        testSupport.setManagedPoolCreationFee(CREATION_FEE);
        testSupport.setTreasuryShareBps(10_000);
        testSupport.setActiveCreditShareBps(0);
        testSupport.setManagedPoolSystemShareBps(2000);

        _initPoolWithActionFees(CANONICAL_PID, address(exotic), _poolConfig(), _actionFees());
        _createManagedPool(alice, MANAGED_PID, address(managedOnlyExotic));
    }

    function test_BugCondition_TreasuryRouting_ShouldUsePoolSideSenderDeltaForCanonicalPool() public {
        uint256 positionId = _mintPosition(alice, CANONICAL_PID);

        exotic.mint(alice, 110e18);
        vm.startPrank(alice);
        exotic.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(positionId, CANONICAL_PID, 100e18, 100e18);
        vm.stopPrank();

        uint256 trackedBefore = testSupport.getPoolView(CANONICAL_PID).trackedBalance;
        uint256 contractBalanceBefore = exotic.balanceOf(diamond);

        testSupport.routeManagedShareExternal(CANONICAL_PID, 10e18, SOURCE, true, 0);

        uint256 trackedAfter = testSupport.getPoolView(CANONICAL_PID).trackedBalance;
        uint256 contractBalanceAfter = exotic.balanceOf(diamond);

        assertEq(trackedBefore - trackedAfter, contractBalanceBefore - contractBalanceAfter);
    }

    function test_BugCondition_TreasuryRouting_ShouldUsePoolSideSenderDeltaForManagedFallback() public {
        uint256 positionId = _whitelistedPosition(alice, MANAGED_PID);

        managedOnlyExotic.mint(alice, 110e18);
        vm.startPrank(alice);
        managedOnlyExotic.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(positionId, MANAGED_PID, 100e18, 100e18);
        vm.stopPrank();

        uint256 trackedBefore = testSupport.getPoolView(MANAGED_PID).trackedBalance;
        uint256 contractBalanceBefore = managedOnlyExotic.balanceOf(diamond);

        testSupport.routeManagedShareExternal(MANAGED_PID, 50e18, SOURCE, true, 0);

        uint256 trackedAfter = testSupport.getPoolView(MANAGED_PID).trackedBalance;
        uint256 contractBalanceAfter = managedOnlyExotic.balanceOf(diamond);

        assertEq(trackedBefore - trackedAfter, contractBalanceBefore - contractBalanceAfter);
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

contract LibFeeRouterPreservationTest is ManagedFeeRoutingTest {
    bytes32 internal constant PRESERVATION_SOURCE = keccak256("fee-router-preservation");

    function test_Preservation_FeeRouterSplitAndTreasuryNominalDebit_ShouldRemainUnchangedForStandardToken() public {
        uint256 positionId = _mintPosition(alice, 2);

        alt.mint(alice, 110e18);
        vm.startPrank(alice);
        alt.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(positionId, 2, 100e18, 100e18);
        alt.transfer(diamond, 10e18);
        vm.stopPrank();

        uint256 treasuryBefore = alt.balanceOf(treasury);
        ProtocolTestSupportFacet.PoolView memory beforePool = testSupport.getPoolView(2);

        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) =
            testSupport.routeManagedShareExternal(2, 10e18, PRESERVATION_SOURCE, true, 10e18);

        ProtocolTestSupportFacet.PoolView memory afterPool = testSupport.getPoolView(2);

        assertEq(toTreasury, 1e18);
        assertEq(toActiveCredit, 0);
        assertEq(toFeeIndex, 9e18);
        assertEq(alt.balanceOf(treasury), treasuryBefore + 1e18);
        assertEq(beforePool.trackedBalance - afterPool.trackedBalance, 1e18);
        assertEq(afterPool.yieldReserve, beforePool.yieldReserve + 9e18);
    }

    function test_Integration_TreasuryRouting_ExoticTokenHelpersShouldShareOnePoolSideInvariant() public {
        MockSenderDeltaToken canonicalExotic = new MockSenderDeltaToken("Canonical Exotic", "CEXO");
        MockSenderDeltaToken managedExotic = new MockSenderDeltaToken("Managed Exotic", "MEXO");

        testSupport.setManagedPoolCreationFee(CREATION_FEE);
        testSupport.setTreasuryShareBps(10_000);
        testSupport.setActiveCreditShareBps(0);
        testSupport.setManagedPoolSystemShareBps(2000);

        _initPoolWithActionFees(170, address(canonicalExotic), _poolConfig(), _actionFees());
        _createManagedPool(alice, MANAGED_PID, address(managedExotic));

        uint256 canonicalPositionId = _mintPosition(alice, 170);
        canonicalExotic.mint(alice, 110e18);
        vm.startPrank(alice);
        canonicalExotic.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(canonicalPositionId, 170, 100e18, 100e18);
        vm.stopPrank();

        uint256 managedPositionId = _whitelistedPosition(alice, MANAGED_PID);
        managedExotic.mint(alice, 110e18);
        vm.startPrank(alice);
        managedExotic.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(managedPositionId, MANAGED_PID, 100e18, 100e18);
        vm.stopPrank();

        uint256 canonicalTrackedBefore = testSupport.getPoolView(170).trackedBalance;
        uint256 canonicalBalanceBefore = canonicalExotic.balanceOf(diamond);
        testSupport.routeManagedShareExternal(170, 10e18, PRESERVATION_SOURCE, true, 0);
        uint256 canonicalTrackedAfter = testSupport.getPoolView(170).trackedBalance;
        uint256 canonicalBalanceAfter = canonicalExotic.balanceOf(diamond);

        uint256 managedTrackedBefore = testSupport.getPoolView(MANAGED_PID).trackedBalance;
        uint256 managedBalanceBefore = managedExotic.balanceOf(diamond);
        testSupport.routeManagedShareExternal(MANAGED_PID, 50e18, PRESERVATION_SOURCE, true, 0);
        uint256 managedTrackedAfter = testSupport.getPoolView(MANAGED_PID).trackedBalance;
        uint256 managedBalanceAfter = managedExotic.balanceOf(diamond);

        assertEq(canonicalTrackedBefore - canonicalTrackedAfter, canonicalBalanceBefore - canonicalBalanceAfter);
        assertEq(managedTrackedBefore - managedTrackedAfter, managedBalanceBefore - managedBalanceAfter);
    }
}
