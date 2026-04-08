// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract LibMaintenanceBugConditionTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
        testSupport.setFoundationReceiver(makeAddr("foundation"));
    }

    function test_BugCondition_MaintenanceSettlement_ShouldChargeOnlyChargeablePrincipal() public {
        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);
        bytes32 alicePositionKey = positionNft.getPositionKey(alicePositionId);
        bytes32 bobPositionKey = positionNft.getPositionKey(bobPositionId);

        eve.mint(alice, 101e18);
        eve.mint(bob, 101e18);

        vm.startPrank(alice);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Maintenance Index", "MIDX", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 50e18);

        assertEq(testSupport.indexEncumberedOf(alicePositionKey, 1), 50e18);
        assertEq(testSupport.principalOf(1, alicePositionKey), 100e18);
        assertEq(testSupport.principalOf(1, bobPositionKey), 100e18);

        PoolManagementFacet.PoolMaintenanceView memory maintenanceBefore =
            PoolManagementFacet(diamond).getPoolMaintenanceView(1);
        uint256 totalDepositsBefore = testSupport.getPoolView(1).totalDeposits;
        uint256 chargeableTvlBefore = totalDepositsBefore - testSupport.getPoolView(1).indexEncumberedTotal;

        vm.warp(block.timestamp + 365 days);

        uint256 epochs = (block.timestamp - uint256(maintenanceBefore.lastMaintenanceTimestamp)) / maintenanceBefore.epochLength;
        uint256 amountAccrued = (
            chargeableTvlBefore * uint256(maintenanceBefore.maintenanceRateBps) * epochs
        ) / (365 * 10_000);
        uint256 maintenanceDelta =
            (amountAccrued * 1e18 + maintenanceBefore.maintenanceIndexRemainder) / chargeableTvlBefore;
        uint256 aliceMaintenanceFee = ((100e18 - 50e18) * maintenanceDelta) / 1e18;
        uint256 bobMaintenanceFee = (100e18 * maintenanceDelta) / 1e18;

        vm.prank(alice);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 1e18, 1e18);

        vm.prank(bob);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 1e18, 1e18);

        uint256 aliceAfter = testSupport.principalOf(1, alicePositionKey);
        uint256 bobAfter = testSupport.principalOf(1, bobPositionKey);

        assertEq(aliceAfter, 101e18 - aliceMaintenanceFee);
        assertEq(bobAfter, 101e18 - bobMaintenanceFee);
    }
}

contract LibMaintenancePreservationTest is LaunchFixture {
    struct MaintenanceExpectations {
        uint256 totalDepositsBefore;
        uint256 amountAccrued;
        uint256 maintenanceDelta;
        uint256 aliceMaintenanceFee;
        uint256 bobMaintenanceFee;
    }

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_Preservation_MaintenanceZeroEncumbrance_ShouldAccrueAndPayCurrentFormula() public {
        address foundation = makeAddr("foundation");
        testSupport.setFoundationReceiver(foundation);

        uint256 alicePositionId = _mintPosition(alice, 1);
        bytes32 alicePositionKey = positionNft.getPositionKey(alicePositionId);

        eve.mint(alice, 101e18);
        vm.startPrank(alice);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 1e18, 1e18);

        assertEq(testSupport.principalOf(1, alicePositionKey), 100e18);
        assertEq(testSupport.getPoolView(1).totalDeposits, 100e18);
        assertEq(testSupport.getPoolView(1).trackedBalance, 100e18);
        assertEq(eve.balanceOf(foundation), 1e18);
    }

    function test_Preservation_MaintenanceWithoutFoundationReceiver_ShouldShortCircuit() public {
        uint256 alicePositionId = _mintPosition(alice, 1);
        bytes32 alicePositionKey = positionNft.getPositionKey(alicePositionId);

        eve.mint(alice, 101e18);
        vm.startPrank(alice);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 1e18, 1e18);

        assertEq(testSupport.principalOf(1, alicePositionKey), 101e18);
        assertEq(testSupport.getPoolView(1).totalDeposits, 101e18);
        assertEq(testSupport.getPoolView(1).trackedBalance, 101e18);
    }

    function test_Preservation_FeeIndexSettle_ShouldContinueToAccrueYieldForUnencumberedUsers() public {
        uint256 alicePositionId = _mintPosition(alice, 1);

        eve.mint(alice, 100e18);
        eve.mint(bob, 11e18);

        vm.startPrank(alice);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Fee Yield Index", "FYI", address(eve), 1000, 0));

        vm.startPrank(bob);
        eve.approve(diamond, type(uint256).max);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();

        uint256 preview = PositionManagementFacet(diamond).previewPositionYield(alicePositionId, 1);
        assertGt(preview, 0);

        uint256 balanceBefore = eve.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = PositionManagementFacet(diamond).claimPositionYield(alicePositionId, 1, alice, 0);

        assertEq(eve.balanceOf(alice), balanceBefore + claimed);
        assertEq(PositionManagementFacet(diamond).previewPositionYield(alicePositionId, 1), 0);
    }

    function test_Preservation_FeeIndexSettle_ZeroPrincipalUserShouldSnapIndexesWithoutYieldResurrection() public {
        uint256 alicePositionId = _mintPosition(alice, 1);

        eve.mint(alice, 101e18);
        eve.mint(bob, 11e18);

        vm.startPrank(alice);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 100e18, 100e18);
        PositionManagementFacet(diamond).withdrawFromPosition(alicePositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Reentry Index", "REI", address(eve), 1000, 0));

        vm.startPrank(bob);
        eve.approve(diamond, type(uint256).max);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();

        vm.prank(alice);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 1e18, 1e18);

        assertEq(PositionManagementFacet(diamond).previewPositionYield(alicePositionId, 1), 0);
    }

    function test_Integration_MaintenanceMixedEncumbrance_ShouldTrackChargeablePrincipalAcrossEpochs() public {
        address foundation = makeAddr("foundation");
        testSupport.setFoundationReceiver(foundation);

        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);
        bytes32 alicePositionKey = positionNft.getPositionKey(alicePositionId);
        bytes32 bobPositionKey = positionNft.getPositionKey(bobPositionId);

        eve.mint(alice, 121e18);
        eve.mint(bob, 81e18);

        vm.startPrank(alice);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 120e18, 120e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 80e18, 80e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Mixed Maintenance Index", "MMI", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 30e18);

        vm.warp(block.timestamp + 30 days);
        MaintenanceExpectations memory expected = _maintenanceExpectations(alicePositionKey, bobPositionKey);

        vm.prank(alice);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 1e18, 1e18);

        vm.prank(bob);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 1e18, 1e18);

        uint256 alicePrincipalAfter = testSupport.principalOf(1, alicePositionKey);
        uint256 bobPrincipalAfter = testSupport.principalOf(1, bobPositionKey);
        uint256 totalDepositsAfter = testSupport.getPoolView(1).totalDeposits;
        uint256 aliceMaintenanceFeeActual = 121e18 - alicePrincipalAfter;
        uint256 bobMaintenanceFeeActual = 81e18 - bobPrincipalAfter;
        uint256 aliceFullPrincipalCounterfactual = Math.mulDiv(120e18, expected.maintenanceDelta, 1e18);

        assertTrue(_absDiff(aliceMaintenanceFeeActual, expected.aliceMaintenanceFee) <= 100);
        assertTrue(_absDiff(bobMaintenanceFeeActual, expected.bobMaintenanceFee) <= 100);
        assertTrue(aliceMaintenanceFeeActual < aliceFullPrincipalCounterfactual);
        assertEq(
            totalDepositsAfter,
            expected.totalDepositsBefore + 2e18 - expected.amountAccrued
        );
    }

    function _maintenanceExpectations(bytes32 alicePositionKey, bytes32 bobPositionKey)
        internal
        view
        returns (MaintenanceExpectations memory expected)
    {
        PoolManagementFacet.PoolMaintenanceView memory maintenanceBefore =
            PoolManagementFacet(diamond).getPoolMaintenanceView(1);
        expected.totalDepositsBefore = testSupport.getPoolView(1).totalDeposits;
        uint256 chargeableTvlBefore = expected.totalDepositsBefore - testSupport.getPoolView(1).indexEncumberedTotal;
        uint256 aliceChargeablePrincipal =
            testSupport.principalOf(1, alicePositionKey) - testSupport.indexEncumberedOf(alicePositionKey, 1);
        uint256 bobChargeablePrincipal = testSupport.principalOf(1, bobPositionKey);
        uint256 epochs = (block.timestamp - uint256(maintenanceBefore.lastMaintenanceTimestamp)) / maintenanceBefore.epochLength;
        uint256 amountAccrued =
            (chargeableTvlBefore * uint256(maintenanceBefore.maintenanceRateBps) * epochs) / (365 * 10_000);
        uint256 maintenanceDelta =
            (amountAccrued * 1e18 + maintenanceBefore.maintenanceIndexRemainder) / chargeableTvlBefore;

        expected.amountAccrued = amountAccrued;
        expected.maintenanceDelta = maintenanceDelta;
        expected.aliceMaintenanceFee = (aliceChargeablePrincipal * maintenanceDelta) / 1e18;
        expected.bobMaintenanceFee = (bobChargeablePrincipal * maintenanceDelta) / 1e18;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}
