// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibDiamond} from "./LibDiamond.sol";
import {LibAppStorage} from "./LibAppStorage.sol";

/// @notice Minimal access helpers for owner/timelock gated calls
library LibAccess {
    function enforceTimelock() internal view {
        require(msg.sender == LibAppStorage.timelockAddress(LibAppStorage.s()), "LibAccess: not timelock");
    }

    function enforceOwner() internal view {
        LibDiamond.enforceIsContractOwner();
    }

    function enforceTimelockOrOwnerIfUnset() internal view {
        address timelock = LibAppStorage.timelockAddress(LibAppStorage.s());
        if (timelock == address(0)) {
            LibDiamond.enforceIsContractOwner();
            return;
        }
        require(msg.sender == timelock, "LibAccess: not timelock");
    }

    function enforceOwnerOrTimelock() internal view {
        address sender = msg.sender;
        if (sender == LibDiamond.diamondStorage().contractOwner) return;
        require(sender == LibAppStorage.timelockAddress(LibAppStorage.s()), "LibAccess: not owner or timelock");
    }

    function isTimelockOrOwnerIfUnset(address account) internal view returns (bool) {
        address timelock = LibAppStorage.timelockAddress(LibAppStorage.s());
        if (timelock == address(0)) {
            return account == LibDiamond.diamondStorage().contractOwner;
        }
        return account == timelock;
    }

    function isOwnerOrTimelock(address account) internal view returns (bool) {
        if (account == LibDiamond.diamondStorage().contractOwner) return true;
        return account == LibAppStorage.timelockAddress(LibAppStorage.s());
    }
}
