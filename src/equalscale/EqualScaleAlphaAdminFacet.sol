// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {LibAccess} from "src/libraries/LibAccess.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {InvalidParameterRange} from "src/libraries/Errors.sol";

/// @notice Narrow timelock-governed controls for EqualScale Alpha.
contract EqualScaleAlphaAdminFacet is IEqualScaleAlphaEvents, IEqualScaleAlphaErrors {
    uint40 internal constant MIN_CHARGE_OFF_THRESHOLD = 1 days;
    uint40 internal constant MAX_CHARGE_OFF_THRESHOLD = 365 days;

    function freezeLine(uint256 lineId, bytes32 reason) external {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active) {
            revert InvalidProposalTerms("line not active for freeze");
        }

        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Frozen;
        emit CreditLineFreezeUpdated(lineId, true, reason);
    }

    function unfreezeLine(uint256 lineId) external {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Frozen) {
            revert InvalidProposalTerms("line not frozen");
        }

        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Active;
        emit CreditLineFreezeUpdated(lineId, false, bytes32(0));
    }

    function setChargeOffThreshold(uint256 thresholdSecs) external {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        if (thresholdSecs > MAX_CHARGE_OFF_THRESHOLD) {
            revert InvalidParameterRange("chargeOffThresholdSecs too high");
        }
        if (thresholdSecs != 0 && thresholdSecs < MIN_CHARGE_OFF_THRESHOLD) {
            revert InvalidParameterRange("chargeOffThresholdSecs too low");
        }

        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        uint40 previousThresholdSecs = store.chargeOffThresholdSecs;
        uint40 newThresholdSecs = uint40(thresholdSecs);
        store.chargeOffThresholdSecs = newThresholdSecs;

        emit ChargeOffThresholdUpdated(previousThresholdSecs, newThresholdSecs);
    }
}
