// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {DirectError_EarlyRepayNotAllowed, DirectError_InvalidAgreementState} from "src/libraries/Errors.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectRolling} from "src/libraries/LibEqualLendDirectRolling.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "src/libraries/LibReentrancyGuard.sol";

/// @notice Borrower full-closeout settlement for rolling agreements.
contract EqualLendDirectRollingLifecycleFacet is ReentrancyGuardModifiers {
    event RollingAgreementRepaid(
        uint256 indexed agreementId,
        address indexed borrower,
        uint256 repaymentAmount,
        uint256 interestCleared,
        uint256 principalCleared
    );

    function repayRollingInFull(uint256 agreementId, uint256 maxPayment, uint256 minReceived)
        external
        payable
        nonReentrant
    {
        minReceived;

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingAgreement storage agreement = _requireActiveRollingAgreement(store, agreementId);

        LibPositionHelpers.requireOwnership(agreement.borrowerPositionId);
        if (!agreement.allowEarlyRepay && agreement.paymentCount < agreement.maxPaymentCount) {
            revert DirectError_EarlyRepayNotAllowed();
        }

        _settleRollingAgreementPositions(agreement);

        uint256 asOf = block.timestamp;
        LibEqualLendDirectRolling.AccrualSnapshot memory snapshot = LibEqualLendDirectRolling.previewAccrual(agreement, asOf);
        uint256 interestDue = snapshot.arrearsDue + snapshot.currentInterestDue;
        uint256 principalDue = agreement.outstandingPrincipal;
        uint256 totalDue = interestDue + principalDue;

        uint256 received = LibCurrency.pullAtLeast(agreement.borrowAsset, msg.sender, totalDue, maxPayment);
        if (LibCurrency.isNative(agreement.borrowAsset)) {
            LibAppStorage.s().nativeTrackedTotal -= received;
        }

        if (interestDue != 0) {
            LibEqualLendDirectAccounting.restoreLenderCapital(agreement.lenderPositionKey, agreement.lenderPoolId, interestDue);
        }
        if (principalDue != 0) {
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
                    principalDelta: principalDue,
                    collateralDelta: agreement.collateralLocked,
                    releaseLockedCollateral: true
                })
            );
        }

        agreement.status = LibEqualLendDirectStorage.AgreementStatus.Repaid;
        agreement.outstandingPrincipal = 0;
        agreement.arrears = 0;
        agreement.lastAccrualTimestamp = uint64(asOf);

        _clearAgreementIndexes(store, agreement);

        uint256 surplus = received > totalDue ? received - totalDue : 0;
        if (surplus != 0) {
            LibCurrency.transfer(agreement.borrowAsset, msg.sender, surplus);
        }

        emit RollingAgreementRepaid(agreementId, msg.sender, totalDue, interestDue, principalDue);
    }

    function _requireActiveRollingAgreement(LibEqualLendDirectStorage.DirectStorage storage store, uint256 agreementId)
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

    function _settleRollingAgreementPositions(LibEqualLendDirectStorage.RollingAgreement storage agreement) internal {
        LibPositionHelpers.settlePosition(agreement.lenderPoolId, agreement.lenderPositionKey);
        if (
            agreement.collateralPoolId != agreement.lenderPoolId
                || agreement.borrowerPositionKey != agreement.lenderPositionKey
        ) {
            LibPositionHelpers.settlePosition(agreement.collateralPoolId, agreement.borrowerPositionKey);
        }
    }

    function _clearAgreementIndexes(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.RollingAgreement storage agreement
    ) internal {
        LibEqualLendDirectStorage.removeBorrowerAgreement(store, agreement.borrowerPositionKey, agreement.agreementId);
        LibEqualLendDirectStorage.removeLenderAgreement(store, agreement.lenderPositionKey, agreement.agreementId);
        LibEqualLendDirectStorage.removeRollingBorrowerAgreement(store, agreement.borrowerPositionKey, agreement.agreementId);
        LibEqualLendDirectStorage.removeRollingLenderAgreement(store, agreement.lenderPositionKey, agreement.agreementId);
    }
}