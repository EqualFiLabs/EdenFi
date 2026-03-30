// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {LibStEVEAdminStorage} from "../libraries/LibStEVEAdminStorage.sol";

contract FixedDelayTimelockController is TimelockController {
    error FixedDelayTimelockController_InvalidDelay(uint256 attempted, uint256 expected);

    constructor(address[] memory proposers, address[] memory executors, address admin)
        TimelockController(LibStEVEAdminStorage.TIMELOCK_DELAY_SECONDS, proposers, executors, admin)
    {}

    function updateDelay(uint256 newDelay) public override {
        uint256 expectedDelay = LibStEVEAdminStorage.TIMELOCK_DELAY_SECONDS;
        if (newDelay != expectedDelay) {
            revert FixedDelayTimelockController_InvalidDelay(newDelay, expectedDelay);
        }
        super.updateDelay(newDelay);
    }
}
