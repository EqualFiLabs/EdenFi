// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract LibMaintenanceBugConditionTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
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
        uint256 indexPoolId = EqualIndexAdminFacetV3(diamond).getIndexPoolId(indexId);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 50e18);

        assertEq(testSupport.indexEncumberedOf(alicePositionKey, indexPoolId), 50e18);
        assertEq(testSupport.principalOf(1, alicePositionKey), 100e18);
        assertEq(testSupport.principalOf(1, bobPositionKey), 100e18);

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 1e18, 1e18);

        vm.prank(bob);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 1e18, 1e18);

        assertEq(testSupport.principalOf(1, alicePositionKey), 100.5e18);
        assertEq(testSupport.principalOf(1, bobPositionKey), 100e18);
    }
}

contract LibMaintenancePreservationTest is LaunchFixture {
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
}
