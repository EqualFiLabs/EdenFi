// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibEqualXCurveEngine} from "../libraries/LibEqualXCurveEngine.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";

/// @notice Creation surface for EqualX curve liquidity.
contract EqualXCurveCreationFacet is ReentrancyGuardModifiers {
    event EqualXCurveProfileSet(uint16 indexed profileId, address impl, uint32 flags, bool approved);

    function createEqualXCurve(
        LibEqualXCurveEngine.CurveDescriptor calldata desc
    ) external nonReentrant returns (uint256 curveId) {
        curveId = LibEqualXCurveEngine.createCurve(desc);
    }

    function setEqualXCurveProfile(uint16 profileId, address impl, uint32 flags, bool approved) external {
        LibAccess.enforceOwnerOrTimelock();
        LibEqualXCurveEngine.setCurveProfile(profileId, impl, flags, approved);
        emit EqualXCurveProfileSet(profileId, impl, flags, approved);
    }
}
