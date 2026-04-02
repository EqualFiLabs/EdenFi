// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEqualXCurveEngine} from "../libraries/LibEqualXCurveEngine.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";

/// @notice Management surface for EqualX curve liquidity.
contract EqualXCurveManagementFacet is ReentrancyGuardModifiers {
    function updateEqualXCurve(uint256 curveId, LibEqualXCurveEngine.CurveUpdateParams calldata params)
        external
        nonReentrant
    {
        LibEqualXCurveEngine.updateCurve(curveId, params);
    }

    function cancelEqualXCurve(uint256 curveId) external nonReentrant {
        LibEqualXCurveEngine.cancelCurve(curveId);
    }

    function expireEqualXCurve(uint256 curveId) external nonReentrant {
        LibEqualXCurveEngine.expireCurve(curveId);
    }
}
