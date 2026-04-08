// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DirectError_InvalidTimestamp} from "src/libraries/Errors.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";

/// @notice Rolling-loan accrual helpers shared by payment and terminal closeout flows.
library LibEqualLendDirectRolling {
    uint256 internal constant YEAR_IN_SECONDS = 365 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    struct AccrualSnapshot {
        uint256 arrearsDue;
        uint256 currentInterestDue;
        uint64 latestPassedDue;
        uint256 dueCountDelta;
    }

    function rollingInterest(uint256 principal, uint16 apyBps, uint256 durationSeconds)
        internal
        pure
        returns (uint256)
    {
        if (principal == 0 || apyBps == 0 || durationSeconds == 0) {
            return 0;
        }

        return Math.mulDiv(principal, uint256(apyBps) * durationSeconds, YEAR_IN_SECONDS * BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    function previewAccrual(LibEqualLendDirectStorage.RollingAgreement storage agreement, uint256 asOf)
        internal
        view
        returns (AccrualSnapshot memory snapshot)
    {
        snapshot.arrearsDue = agreement.arrears;

        uint256 latestPassedDue = _latestPassedDue(agreement, asOf);
        if (latestPassedDue != 0) {
            snapshot.latestPassedDue = uint64(latestPassedDue);
            snapshot.dueCountDelta = ((latestPassedDue - uint256(agreement.nextDue)) / agreement.paymentIntervalSeconds) + 1;

            if (latestPassedDue > agreement.lastAccrualTimestamp) {
                snapshot.arrearsDue += rollingInterest(
                    agreement.outstandingPrincipal,
                    agreement.rollingApyBps,
                    latestPassedDue - agreement.lastAccrualTimestamp
                );
            }
        }

        uint256 currentInterestStart = agreement.lastAccrualTimestamp;
        if (latestPassedDue > currentInterestStart) {
            currentInterestStart = latestPassedDue;
        }
        if (asOf > currentInterestStart) {
            snapshot.currentInterestDue =
                rollingInterest(agreement.outstandingPrincipal, agreement.rollingApyBps, asOf - currentInterestStart);
        }
    }

    function applyPaymentState(
        LibEqualLendDirectStorage.RollingAgreement storage agreement,
        AccrualSnapshot memory snapshot,
        uint256 arrearsPaid,
        uint256 currentInterestPaid,
        uint256 asOf
    ) internal {
        uint256 remainingArrears = snapshot.arrearsDue > arrearsPaid ? snapshot.arrearsDue - arrearsPaid : 0;
        uint256 unpaidCurrentInterest =
            snapshot.currentInterestDue > currentInterestPaid ? snapshot.currentInterestDue - currentInterestPaid : 0;

        agreement.arrears = remainingArrears + unpaidCurrentInterest;
        if (asOf > type(uint64).max) {
            revert DirectError_InvalidTimestamp();
        }
        agreement.lastAccrualTimestamp = uint64(asOf);

        if (remainingArrears == 0 && snapshot.dueCountDelta != 0) {
            uint256 nextDueCalc = uint256(snapshot.latestPassedDue) + agreement.paymentIntervalSeconds;
            if (nextDueCalc > type(uint64).max) {
                revert DirectError_InvalidTimestamp();
            }
            agreement.nextDue = uint64(nextDueCalc);

            uint256 paymentCount = uint256(agreement.paymentCount) + snapshot.dueCountDelta;
            if (paymentCount > agreement.maxPaymentCount) {
                paymentCount = agreement.maxPaymentCount;
            }
            agreement.paymentCount = uint16(paymentCount);
        }
    }

    function _latestPassedDue(LibEqualLendDirectStorage.RollingAgreement storage agreement, uint256 asOf)
        private
        view
        returns (uint256 latestPassedDue)
    {
        if (asOf < agreement.nextDue) {
            return 0;
        }

        uint256 passedIntervals = (asOf - uint256(agreement.nextDue)) / agreement.paymentIntervalSeconds;
        latestPassedDue = uint256(agreement.nextDue) + (passedIntervals * agreement.paymentIntervalSeconds);
    }
}