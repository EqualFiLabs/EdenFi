// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibGovernanceConfig} from "./LibGovernanceConfig.sol";
import {InvalidTimelockController, InvalidTimelockDelay} from "./Errors.sol";

interface ITimelockControllerLike {
    function getMinDelay() external view returns (uint256);
}

library LibTimelock {
    uint256 internal constant FIXED_DELAY_SECONDS = LibGovernanceConfig.TIMELOCK_DELAY_SECONDS;

    function validateFixedDelayController(address controller) internal view {
        if (controller == address(0) || controller.code.length == 0) {
            revert InvalidTimelockController(controller);
        }

        uint256 delay;
        try ITimelockControllerLike(controller).getMinDelay() returns (uint256 currentDelay) {
            delay = currentDelay;
        } catch {
            revert InvalidTimelockController(controller);
        }

        uint256 expectedDelay = FIXED_DELAY_SECONDS;
        if (delay != expectedDelay) {
            revert InvalidTimelockDelay(expectedDelay, delay);
        }
    }
}
