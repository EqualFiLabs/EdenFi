// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    DirectError_InvalidAgreementState,
    RollingError_AmortizationDisabled,
    RollingError_DustPayment,
    RollingError_InterestExceedsMax
} from "src/libraries/Errors.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectRolling} from "src/libraries/LibEqualLendDirectRolling.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "src/libraries/LibReentrancyGuard.sol";

/// @notice Scheduled rolling payments with arrears accrual, current-period interest, and optional amortization.
contract EqualLendDirectRollingPaymentFacet is ReentrancyGuardModifiers {
    struct PaymentAllocation {
        uint256 received;
        uint256 refund;
        uint256 arrearsPaid;
        uint256 currentInterestPaid;
        uint256 principalPaid;
    }

    event RollingPaymentMade(
        uint256 indexed agreementId,
        address indexed payer,
        uint256 paymentAmount,
        uint256 arrearsReduction,
        uint256 interestPaid,
        uint256 principalReduction,
        uint64 nextDue,
        uint16 paymentCount,
        uint256 newOutstandingPrincipal,
        uint256 newArrears
    );

    function makeRollingPayment(uint256 agreementId, uint256 amount, uint256 maxPayment, uint256 maxInterestDue)
        external
        payable
        nonReentrant
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingAgreement storage agreement = _requireActiveAgreement(store, agreementId);

        LibPositionHelpers.requireOwnership(agreement.borrowerPositionId);
        _settleAgreementPositions(agreement);

        uint256 minPayment = (agreement.outstandingPrincipal * store.rollingConfig.minPaymentBps + 9_999)
            / LibEqualLendDirectStorage.BPS_DENOMINATOR;
        if (amount == 0 || amount < minPayment) {
            revert RollingError_DustPayment(amount, minPayment);
        }

        uint256 asOf = block.timestamp;
        LibEqualLendDirectRolling.AccrualSnapshot memory snapshot = LibEqualLendDirectRolling.previewAccrual(agreement, asOf);
        uint256 totalInterest = snapshot.arrearsDue + snapshot.currentInterestDue;
        if (totalInterest > maxInterestDue) {
            revert RollingError_InterestExceedsMax(totalInterest, maxInterestDue);
        }
        PaymentAllocation memory allocation = _collectPayment(agreement, snapshot, amount, maxPayment);
        _applyPaymentAccounting(store, agreement, snapshot, allocation, asOf);

        emit RollingPaymentMade(
            agreementId,
            msg.sender,
            allocation.received - allocation.refund,
            allocation.arrearsPaid,
            allocation.currentInterestPaid,
            allocation.principalPaid,
            agreement.nextDue,
            agreement.paymentCount,
            agreement.outstandingPrincipal,
            agreement.arrears
        );
    }

    function _collectPayment(
        LibEqualLendDirectStorage.RollingAgreement storage agreement,
        LibEqualLendDirectRolling.AccrualSnapshot memory snapshot,
        uint256 amount,
        uint256 maxPayment
    ) internal returns (PaymentAllocation memory allocation) {
        uint256 interestDue = snapshot.arrearsDue + snapshot.currentInterestDue;
        if (!agreement.allowAmortization && amount > interestDue) {
            revert RollingError_AmortizationDisabled();
        }

        allocation.received = LibCurrency.pullAtLeast(agreement.borrowAsset, msg.sender, amount, maxPayment);
        if (LibCurrency.isNative(agreement.borrowAsset)) {
            LibAppStorage.s().nativeTrackedTotal -= allocation.received;
        }

        uint256 remaining = allocation.received;
        allocation.arrearsPaid = remaining < snapshot.arrearsDue ? remaining : snapshot.arrearsDue;
        remaining -= allocation.arrearsPaid;

        allocation.currentInterestPaid = remaining < snapshot.currentInterestDue ? remaining : snapshot.currentInterestDue;
        remaining -= allocation.currentInterestPaid;

        if (remaining != 0) {
            if (!agreement.allowAmortization) {
                revert RollingError_AmortizationDisabled();
            }
            allocation.principalPaid = remaining > agreement.outstandingPrincipal ? agreement.outstandingPrincipal : remaining;
            remaining -= allocation.principalPaid;
        }

        allocation.refund = remaining;
    }

    function _applyPaymentAccounting(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.RollingAgreement storage agreement,
        LibEqualLendDirectRolling.AccrualSnapshot memory snapshot,
        PaymentAllocation memory allocation,
        uint256 asOf
    ) internal {
        uint256 lenderCredit = allocation.arrearsPaid + allocation.currentInterestPaid;
        if (lenderCredit != 0) {
            LibEqualLendDirectAccounting.restoreLenderCapital(agreement.lenderPositionKey, agreement.lenderPoolId, lenderCredit);
        }

        if (allocation.principalPaid != 0) {
            agreement.outstandingPrincipal -= allocation.principalPaid;
            LibEqualLendDirectAccounting.settlePrincipal(
                store,
                LibEqualLendDirectAccounting.PrincipalSettlementParams({
                    lenderPositionKey: agreement.lenderPositionKey,
                    borrowerPositionKey: agreement.borrowerPositionKey,
                    borrowerPositionId: agreement.borrowerPositionId,
                    lenderPoolId: agreement.lenderPoolId,
                    collateralPoolId: agreement.collateralPoolId,
                    borrowAsset: agreement.borrowAsset,
                    collateralAsset: agreement.collateralAsset,
                    principalDelta: allocation.principalPaid,
                    collateralDelta: 0,
                    releaseLockedCollateral: false
                })
            );
        }

        LibEqualLendDirectRolling.applyPaymentState(
            agreement, snapshot, allocation.arrearsPaid, allocation.currentInterestPaid, asOf
        );

        if (allocation.refund != 0) {
            LibCurrency.transfer(agreement.borrowAsset, msg.sender, allocation.refund);
        }
    }

    function _requireActiveAgreement(LibEqualLendDirectStorage.DirectStorage storage store, uint256 agreementId)
        internal
        view
        returns (LibEqualLendDirectStorage.RollingAgreement storage agreement)
    {
        if (store.agreementKindById[agreementId] != LibEqualLendDirectStorage.AgreementKind.Rolling) {
            revert DirectError_InvalidAgreementState();
        }

        agreement = store.rollingAgreements[agreementId];
        if (agreement.status != LibEqualLendDirectStorage.AgreementStatus.Active) {
            revert DirectError_InvalidAgreementState();
        }
    }

    function _settleAgreementPositions(LibEqualLendDirectStorage.RollingAgreement storage agreement) internal {
        LibPositionHelpers.settlePosition(agreement.lenderPoolId, agreement.lenderPositionKey);
        if (
            agreement.collateralPoolId != agreement.lenderPoolId
                || agreement.borrowerPositionKey != agreement.lenderPositionKey
        ) {
            LibPositionHelpers.settlePosition(agreement.collateralPoolId, agreement.borrowerPositionKey);
        }
    }
}