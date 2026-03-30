// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";
import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";

contract TimelockTarget {
    uint256 public value;

    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

contract FixedDelayTimelockControllerTest is StEVELaunchFixture {
    FixedDelayTimelockController internal controller;
    TimelockTarget internal target;

    function setUp() public override {
        super.setUp();

        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);

        controller = new FixedDelayTimelockController(proposers, executors, address(this));
        target = new TimelockTarget();
    }

    function test_RoleRestrictions_BlockUnauthorizedSchedulingAndExecution() public {
        bytes memory data = abi.encodeWithSelector(TimelockTarget.setValue.selector, 7);
        bytes32 salt = keccak256("role-restrictions");

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, controller.PROPOSER_ROLE()
            )
        );
        controller.schedule(address(target), 0, data, bytes32(0), salt, 7 days);
        vm.stopPrank();

        controller.schedule(address(target), 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, controller.EXECUTOR_ROLE()
            )
        );
        controller.execute(address(target), 0, data, bytes32(0), salt);
        vm.stopPrank();
    }

    function test_ScheduleExecuteAndDelayEnforcement() public {
        bytes memory data = abi.encodeWithSelector(TimelockTarget.setValue.selector, 11);
        bytes32 salt = keccak256("delay-enforcement");
        bytes32 opId = controller.hashOperation(address(target), 0, data, bytes32(0), salt);

        controller.schedule(address(target), 0, data, bytes32(0), salt, 7 days);

        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, opId, bytes32(uint256(4)))
        );
        controller.execute(address(target), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + 7 days + 1);
        controller.execute(address(target), 0, data, bytes32(0), salt);
        assertEq(target.value(), 11);
    }

    function test_UpdateDelay_IsImmutableExceptForCanonicalSevenDays() public {
        bytes memory sameDelay = abi.encodeWithSelector(FixedDelayTimelockController.updateDelay.selector, 7 days);
        bytes32 sameSalt = keccak256("same-delay");

        controller.schedule(address(controller), 0, sameDelay, bytes32(0), sameSalt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        controller.execute(address(controller), 0, sameDelay, bytes32(0), sameSalt);
        assertEq(controller.getMinDelay(), 7 days);

        bytes memory badDelay = abi.encodeWithSelector(FixedDelayTimelockController.updateDelay.selector, 1 days);
        bytes32 badSalt = keccak256("bad-delay");
        controller.schedule(address(controller), 0, badDelay, bytes32(0), badSalt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                FixedDelayTimelockController.FixedDelayTimelockController_InvalidDelay.selector, 1 days, 7 days
            )
        );
        controller.execute(address(controller), 0, badDelay, bytes32(0), badSalt);
    }
}
