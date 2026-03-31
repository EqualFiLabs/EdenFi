// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibEqualXCurveEngine} from "../libraries/LibEqualXCurveEngine.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";

/// @notice Creation surface for EqualX curve liquidity.
contract EqualXCurveCreationFacet is ReentrancyGuardModifiers {
    function createEqualXCurve(
        LibEqualXCurveEngine.CurveDescriptor calldata desc
    ) external nonReentrant returns (uint256 curveId) {
        curveId = LibEqualXCurveEngine.createCurve(desc);
    }
}
