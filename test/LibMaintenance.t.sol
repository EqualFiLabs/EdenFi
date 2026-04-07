// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
