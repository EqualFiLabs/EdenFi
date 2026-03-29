// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibModuleEncumbrance} from "src/libraries/LibModuleEncumbrance.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "src/libraries/Errors.sol";
import {Types} from "src/libraries/Types.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

library LibEqualScaleAlphaLifecycle {
    uint40 internal constant DEFAULT_CHARGE_OFF_THRESHOLD = 30 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant YEAR_SECS = 365 days;

    function repayLine(uint256 lineId, uint256 amount) external {
        if (amount == 0) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("amount == 0");
        }

        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(line.borrowerPositionId);
        if (!_repaymentAllowed(line.status)) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not repayable during current status");
        }

        _accrueInterest(line);

        uint256 totalOutstanding = line.outstandingPrincipal + line.accruedInterest;
        if (totalOutstanding == 0) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line has no outstanding obligation");
        }

        uint256 effectiveAmount = amount > totalOutstanding ? totalOutstanding : amount;
        uint256 requiredMinimumDue = _requiredMinimumDue(line);
        uint256 interestComponent = effectiveAmount > line.accruedInterest ? line.accruedInterest : effectiveAmount;
        uint256 principalComponent = effectiveAmount - interestComponent;

        Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
        uint256 received =
            LibCurrency.pullAtLeast(settlementPool.underlying, msg.sender, effectiveAmount, effectiveAmount);
        settlementPool.trackedBalance += received;

        _settleSettlementPosition(line.settlementPoolId, borrowerPositionKey);

        line.accruedInterest -= interestComponent;
        line.outstandingPrincipal -= principalComponent;
        line.totalInterestRepaid += interestComponent;
        line.totalPrincipalRepaid += principalComponent;
        line.paidSinceLastDue += effectiveAmount;

        if (principalComponent != 0) {
            _reduceBorrowerDebt(settlementPool, line.settlementPoolId, borrowerPositionKey, principalComponent);
        }

        _allocateRepayment(store, lineId, interestComponent, principalComponent);
        _recordPaymentRecord(store, lineId, effectiveAmount, principalComponent, interestComponent);

        bool minimumDueSatisfied = requiredMinimumDue == 0 || line.paidSinceLastDue >= requiredMinimumDue;
        if (minimumDueSatisfied) {
            _advanceDueCheckpoint(line);
        }

        _cureLineIfCovered(line, minimumDueSatisfied);

        _emitCreditPaymentMade(lineId, effectiveAmount, principalComponent, interestComponent, line);
    }

    function enterRefinancing(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (
            line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active
                && line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Frozen
        ) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not active for refinancing");
        }
        if (block.timestamp < line.termEndAt) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("facility term still active");
        }

        _accrueInterest(line);
        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing;

        emit IEqualScaleAlphaEvents.CreditLineEnteredRefinancing(
            lineId, line.refinanceEndAt, line.currentCommittedAmount, line.outstandingPrincipal
        );
    }

    function rollCommitment(uint256 lineId, uint256 lenderPositionId) external {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not in refinancing");
        }

        bytes32 lenderPositionKey = _requireLenderPositionOwner(lenderPositionId, line.settlementPoolId);
        LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionId];
        if (
            commitment.committedAmount == 0 || commitment.lenderPositionKey != lenderPositionKey
                || !_refinanceCommitmentMutable(commitment.status)
        ) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("no active commitment");
        }

        commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Rolled;

        emit IEqualScaleAlphaEvents.CommitmentRolled(
            lineId, lenderPositionId, lenderPositionKey, commitment.committedAmount, line.currentCommittedAmount
        );
    }

    function exitCommitment(uint256 lineId, uint256 lenderPositionId) external {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not in refinancing");
        }

        bytes32 lenderPositionKey = _requireLenderPositionOwner(lenderPositionId, line.settlementPoolId);
        LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionId];
        if (
            commitment.committedAmount == 0 || commitment.lenderPositionKey != lenderPositionKey
                || !_refinanceCommitmentMutable(commitment.status)
        ) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("no active commitment");
        }

        uint256 exitedAmount = commitment.committedAmount;
        commitment.committedAmount = 0;
        commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Exited;
        line.currentCommittedAmount -= exitedAmount;

        _settleSettlementPosition(line.settlementPoolId, lenderPositionKey);
        LibModuleEncumbrance.unencumber(
            lenderPositionKey, line.settlementPoolId, _settlementCommitmentModuleId(lineId), exitedAmount
        );

        emit IEqualScaleAlphaEvents.CommitmentExited(
            lineId, lenderPositionId, lenderPositionKey, exitedAmount, line.currentCommittedAmount
        );
    }

    function resolveRefinancing(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not in refinancing");
        }
        if (block.timestamp < line.refinanceEndAt) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("refinance window still active");
        }

        _accrueInterest(line);

        if (line.currentCommittedAmount >= line.requestedTargetLimit) {
            _restartLineTerm(line, line.requestedTargetLimit);
        } else if (
            line.currentCommittedAmount >= line.outstandingPrincipal
                && line.currentCommittedAmount >= line.minimumViableLine
        ) {
            _restartLineTerm(line, line.currentCommittedAmount);
        } else {
            line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Runoff;
            line.activeLimit = line.currentCommittedAmount;
            line.currentPeriodDrawn = 0;

            emit IEqualScaleAlphaEvents.CreditLineEnteredRunoff(
                lineId, line.outstandingPrincipal, line.currentCommittedAmount
            );
        }

        emit IEqualScaleAlphaEvents.CreditLineRefinancingResolved(
            lineId, line.status, line.activeLimit, line.currentCommittedAmount
        );
    }

    function markDelinquent(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (!_delinquencyEligible(line.status)) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not eligible for delinquency");
        }

        _accrueInterest(line);

        uint40 currentTimestamp = uint40(block.timestamp);
        if (currentTimestamp <= line.nextDueAt + line.gracePeriodSecs) {
            revert IEqualScaleAlphaErrors.DelinquencyTooEarly(lineId, line.nextDueAt, line.gracePeriodSecs, currentTimestamp);
        }

        uint256 currentMinimumDue = _requiredMinimumDue(line);
        if (currentMinimumDue == 0 || line.paidSinceLastDue >= currentMinimumDue) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("current minimum due satisfied");
        }

        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent;
        line.delinquentSince = currentTimestamp;
        unchecked {
            ++line.missedPayments;
        }

        emit IEqualScaleAlphaEvents.CreditLineMarkedDelinquent(
            lineId, currentTimestamp, currentMinimumDue, line.nextDueAt
        );
    }

    function chargeOffLine(uint256 lineId) external {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent) {
            revert IEqualScaleAlphaErrors.InvalidWriteDownState(lineId, line.status);
        }

        uint40 chargeOffThresholdSecs = _chargeOffThresholdSecs(store);
        uint40 currentTimestamp = uint40(block.timestamp);
        if (currentTimestamp < line.delinquentSince + chargeOffThresholdSecs) {
            revert IEqualScaleAlphaErrors.ChargeOffTooEarly(
                lineId, line.delinquentSince, chargeOffThresholdSecs, currentTimestamp
            );
        }

        _accrueInterest(line);

        uint256 totalExposedPrincipal = _totalExposedPrincipal(store, lineId);
        uint256 recoveryApplied = _recoverBorrowerCollateral(lineId, line, totalExposedPrincipal);
        if (recoveryApplied != 0) {
            _allocateRecovery(store, lineId, recoveryApplied);
        }

        uint256 principalWrittenDown = _totalExposedPrincipal(store, lineId);
        if (principalWrittenDown != 0) {
            _allocateWriteDown(store, lineId, principalWrittenDown);
        }

        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.ChargedOff;
        emit IEqualScaleAlphaEvents.CreditLineChargedOff(lineId, recoveryApplied, principalWrittenDown);

        _finalizeChargedOffLine(store, lineId, line, principalWrittenDown != 0);
    }

    function closeLine(uint256 lineId) external {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        if (
            line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active
                && line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Frozen
        ) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not closable during current status");
        }

        _requireBorrowerPositionOwner(line.borrowerPositionId);
        _accrueInterest(line);
        if (line.outstandingPrincipal != 0 || line.accruedInterest != 0) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line has outstanding obligation");
        }

        _finalizeRepaidLine(store, lineId, line, line.status);
    }

    function _allocateRepayment(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 interestComponent,
        uint256 principalComponent
    ) private {
        if (interestComponent == 0 && principalComponent == 0) {
            return;
        }

        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 totalExposed;
        uint256 activeCommitmentCount;
        uint256 len = lenderPositionIds.length;

        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.principalExposed != 0) {
                totalExposed += commitment.principalExposed;
                activeCommitmentCount++;
            }
        }

        if (totalExposed == 0 || activeCommitmentCount == 0) {
            return;
        }

        uint256 remainingInterest = interestComponent;
        uint256 remainingPrincipal = principalComponent;
        uint256 seenActiveCommitments;
        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.principalExposed == 0) {
                continue;
            }

            seenActiveCommitments++;
            uint256 interestShare = remainingInterest;
            uint256 principalShare = remainingPrincipal;
            if (seenActiveCommitments != activeCommitmentCount) {
                interestShare = Math.mulDiv(interestComponent, commitment.principalExposed, totalExposed);
                principalShare = Math.mulDiv(principalComponent, commitment.principalExposed, totalExposed);
                remainingInterest -= interestShare;
                remainingPrincipal -= principalShare;
            }

            commitment.interestReceived += interestShare;
            commitment.principalRepaid += principalShare;
            commitment.principalExposed -= principalShare;
        }
    }

    function _recordPaymentRecord(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 effectiveAmount,
        uint256 principalComponent,
        uint256 interestComponent
    ) private {
        store.paymentRecords[lineId].push(
            LibEqualScaleAlphaStorage.PaymentRecord({
                paidAt: uint40(block.timestamp),
                amount: effectiveAmount,
                principalComponent: principalComponent,
                interestComponent: interestComponent
            })
        );
    }

    function _accrueInterest(LibEqualScaleAlphaStorage.CreditLine storage line) private {
        uint40 accruedAt = line.interestAccruedAt;
        if (accruedAt == 0 || line.outstandingPrincipal == 0) {
            line.interestAccruedAt = uint40(block.timestamp);
            return;
        }

        uint256 elapsed = block.timestamp - uint256(accruedAt);
        if (elapsed == 0) {
            return;
        }

        uint256 accrued =
            Math.mulDiv(line.outstandingPrincipal, uint256(line.aprBps) * elapsed, BPS_DENOMINATOR * YEAR_SECS);
        if (accrued != 0) {
            line.accruedInterest += accrued;
            line.interestAccruedSinceLastDue += accrued;
        }
        line.interestAccruedAt = uint40(block.timestamp);
    }

    function _requiredMinimumDue(LibEqualScaleAlphaStorage.CreditLine storage line) private view returns (uint256) {
        return line.interestAccruedSinceLastDue > line.minimumPaymentPerPeriod
            ? line.interestAccruedSinceLastDue
            : line.minimumPaymentPerPeriod;
    }

    function _advanceDueCheckpoint(LibEqualScaleAlphaStorage.CreditLine storage line) private {
        line.nextDueAt += line.paymentIntervalSecs;
        line.interestAccruedSinceLastDue = 0;
        line.paidSinceLastDue = 0;
    }

    function _cureLineIfCovered(LibEqualScaleAlphaStorage.CreditLine storage line, bool minimumDueSatisfied) private {
        if (line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent && minimumDueSatisfied) {
            if (line.delinquentSince != 0) {
                line.delinquentSince = 0;
            }
            line.missedPayments = 0;
            if (line.outstandingPrincipal > line.currentCommittedAmount) {
                line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Runoff;
            } else {
                line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Active;
            }
            return;
        }

        if (
            line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff
                && line.outstandingPrincipal <= line.currentCommittedAmount
        ) {
            _restartLineTerm(line, line.currentCommittedAmount);
        }
    }

    function _restartLineTerm(LibEqualScaleAlphaStorage.CreditLine storage line, uint256 activeLimit) private {
        uint40 restartedAt = uint40(block.timestamp);
        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Active;
        line.activeLimit = activeLimit;
        line.currentPeriodDrawn = 0;
        line.currentPeriodStartedAt = restartedAt;
        line.interestAccruedAt = restartedAt;
        line.nextDueAt = restartedAt + line.paymentIntervalSecs;
        line.termStartedAt = restartedAt;
        line.termEndAt = restartedAt + line.facilityTermSecs;
        line.refinanceEndAt = line.termEndAt + line.refinanceWindowSecs;
        line.delinquentSince = 0;
        line.missedPayments = 0;
        line.interestAccruedSinceLastDue = 0;
        line.paidSinceLastDue = 0;
    }

    function _reduceBorrowerDebt(
        Types.PoolData storage settlementPool,
        uint256 settlementPoolId,
        bytes32 borrowerPositionKey,
        uint256 principalComponent
    ) private {
        uint256 sameAssetDebt = settlementPool.userSameAssetDebt[borrowerPositionKey];
        settlementPool.userSameAssetDebt[borrowerPositionKey] =
            sameAssetDebt > principalComponent ? sameAssetDebt - principalComponent : 0;

        Types.ActiveCreditState storage debtState = settlementPool.userActiveCreditStateDebt[borrowerPositionKey];
        uint256 debtPrincipalBefore = debtState.principal;
        uint256 debtDecrease = debtPrincipalBefore > principalComponent ? principalComponent : debtPrincipalBefore;
        LibActiveCreditIndex.applyPrincipalDecrease(settlementPool, debtState, debtDecrease);

        if (debtPrincipalBefore <= principalComponent || debtState.principal == 0) {
            LibActiveCreditIndex.resetIfZeroWithGate(debtState, settlementPoolId, borrowerPositionKey, true);
        } else {
            debtState.indexSnapshot = settlementPool.activeCreditIndex;
        }

        if (settlementPool.activeCreditPrincipalTotal >= debtDecrease) {
            settlementPool.activeCreditPrincipalTotal -= debtDecrease;
        } else {
            settlementPool.activeCreditPrincipalTotal = 0;
        }
    }

    function _repaymentAllowed(LibEqualScaleAlphaStorage.CreditLineStatus status) private pure returns (bool) {
        return status == LibEqualScaleAlphaStorage.CreditLineStatus.Active
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen;
    }

    function _emitCreditPaymentMade(
        uint256 lineId,
        uint256 effectiveAmount,
        uint256 principalComponent,
        uint256 interestComponent,
        LibEqualScaleAlphaStorage.CreditLine storage line
    ) private {
        emit IEqualScaleAlphaEvents.CreditPaymentMade(
            lineId,
            effectiveAmount,
            principalComponent,
            interestComponent,
            line.outstandingPrincipal,
            line.accruedInterest,
            line.nextDueAt
        );
    }

    function _delinquencyEligible(LibEqualScaleAlphaStorage.CreditLineStatus status) private pure returns (bool) {
        return status == LibEqualScaleAlphaStorage.CreditLineStatus.Active
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff;
    }

    function _chargeOffThresholdSecs(LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store)
        private
        view
        returns (uint40)
    {
        uint40 configured = store.chargeOffThresholdSecs;
        return configured == 0 ? DEFAULT_CHARGE_OFF_THRESHOLD : configured;
    }

    function _recoverBorrowerCollateral(
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        uint256 maxRecovery
    ) private returns (uint256 recovered) {
        if (
            maxRecovery == 0 || line.collateralMode != LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted
                || line.borrowerCollateralPoolId == 0
        ) {
            return 0;
        }

        uint256 collateralModuleId = _borrowerCollateralModuleId(lineId);
        uint256 encumbered = LibModuleEncumbrance.getEncumberedForModule(
            line.borrowerPositionKey, line.borrowerCollateralPoolId, collateralModuleId
        );
        if (encumbered == 0) {
            return 0;
        }

        _settlePosition(line.borrowerCollateralPoolId, line.borrowerPositionKey);

        Types.PoolData storage collateralPool = LibAppStorage.s().pools[line.borrowerCollateralPoolId];
        if (!collateralPool.initialized) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("borrower collateral pool not initialized");
        }

        Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
        if (collateralPool.underlying != settlementPool.underlying) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("collateral underlying mismatch");
        }

        uint256 borrowerPrincipal = collateralPool.userPrincipal[line.borrowerPositionKey];
        recovered = encumbered;
        if (recovered > borrowerPrincipal) {
            recovered = borrowerPrincipal;
        }
        if (recovered > maxRecovery) {
            recovered = maxRecovery;
        }

        if (recovered != 0) {
            collateralPool.userPrincipal[line.borrowerPositionKey] = borrowerPrincipal - recovered;
            if (collateralPool.totalDeposits >= recovered) {
                collateralPool.totalDeposits -= recovered;
            } else {
                collateralPool.totalDeposits = 0;
            }
            if (collateralPool.trackedBalance >= recovered) {
                collateralPool.trackedBalance -= recovered;
            } else {
                collateralPool.trackedBalance = 0;
            }
            settlementPool.trackedBalance += recovered;
            if (borrowerPrincipal == recovered && collateralPool.userCount > 0) {
                collateralPool.userCount -= 1;
            }
            collateralPool.userFeeIndex[line.borrowerPositionKey] = collateralPool.feeIndex;
            collateralPool.userMaintenanceIndex[line.borrowerPositionKey] = collateralPool.maintenanceIndex;
        }

        LibModuleEncumbrance.unencumber(
            line.borrowerPositionKey, line.borrowerCollateralPoolId, collateralModuleId, encumbered
        );
    }

    function _allocateRecovery(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 recoveryAmount
    ) private {
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 totalExposed;
        uint256 activeCommitmentCount;
        uint256 len = lenderPositionIds.length;

        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.principalExposed == 0) {
                continue;
            }

            totalExposed += commitment.principalExposed;
            activeCommitmentCount++;
        }

        if (totalExposed == 0 || activeCommitmentCount == 0) {
            return;
        }

        uint256 remainingRecovery = recoveryAmount > totalExposed ? totalExposed : recoveryAmount;
        uint256 seenActiveCommitments;
        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.principalExposed == 0) {
                continue;
            }

            seenActiveCommitments++;
            uint256 recoveryShare = remainingRecovery;
            if (seenActiveCommitments != activeCommitmentCount) {
                recoveryShare = Math.mulDiv(recoveryAmount, commitment.principalExposed, totalExposed);
                if (recoveryShare > remainingRecovery) {
                    recoveryShare = remainingRecovery;
                }
                remainingRecovery -= recoveryShare;
            }

            if (recoveryShare > commitment.principalExposed) {
                recoveryShare = commitment.principalExposed;
            }
            commitment.recoveryReceived += recoveryShare;
            commitment.principalExposed -= recoveryShare;
        }
    }

    function _allocateWriteDown(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 writeDownAmount
    ) private {
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 totalExposed;
        uint256 activeCommitmentCount;
        uint256 len = lenderPositionIds.length;

        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.principalExposed == 0) {
                continue;
            }

            totalExposed += commitment.principalExposed;
            activeCommitmentCount++;
        }

        if (totalExposed == 0 || activeCommitmentCount == 0) {
            return;
        }

        uint256 remainingWriteDown = writeDownAmount > totalExposed ? totalExposed : writeDownAmount;
        uint256 seenActiveCommitments;
        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.principalExposed == 0) {
                continue;
            }

            seenActiveCommitments++;
            uint256 writeDownShare = remainingWriteDown;
            if (seenActiveCommitments != activeCommitmentCount) {
                writeDownShare = Math.mulDiv(writeDownAmount, commitment.principalExposed, totalExposed);
                if (writeDownShare > remainingWriteDown) {
                    writeDownShare = remainingWriteDown;
                }
                remainingWriteDown -= writeDownShare;
            }

            if (writeDownShare > commitment.principalExposed) {
                writeDownShare = commitment.principalExposed;
            }
            commitment.lossWrittenDown += writeDownShare;
            commitment.principalExposed -= writeDownShare;
        }
    }

    function _totalExposedPrincipal(LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store, uint256 lineId)
        private
        view
        returns (uint256 totalExposed)
    {
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 len = lenderPositionIds.length;
        for (uint256 i = 0; i < len; i++) {
            totalExposed += store.lineCommitments[lineId][lenderPositionIds[i]].principalExposed;
        }
    }

    function _finalizeChargedOffLine(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        bool closedWithLoss
    ) private {
        _finalizeClosedLine(
            store, lineId, line, LibEqualScaleAlphaStorage.CreditLineStatus.ChargedOff, closedWithLoss, false
        );
    }

    function _finalizeRepaidLine(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        LibEqualScaleAlphaStorage.CreditLineStatus previousStatus
    ) private {
        if (line.collateralMode == LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted && line.borrowerCollateralPoolId != 0)
        {
            uint256 collateralModuleId = _borrowerCollateralModuleId(lineId);
            uint256 encumbered = LibModuleEncumbrance.getEncumberedForModule(
                line.borrowerPositionKey, line.borrowerCollateralPoolId, collateralModuleId
            );
            if (encumbered != 0) {
                _settlePosition(line.borrowerCollateralPoolId, line.borrowerPositionKey);
                LibModuleEncumbrance.unencumber(
                    line.borrowerPositionKey, line.borrowerCollateralPoolId, collateralModuleId, encumbered
                );
            }
        }

        _finalizeClosedLine(store, lineId, line, previousStatus, false, true);
    }

    function _finalizeClosedLine(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        LibEqualScaleAlphaStorage.CreditLineStatus previousStatus,
        bool closedWithLoss,
        bool releaseCollateral
    ) private {
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 commitmentModuleId = _settlementCommitmentModuleId(lineId);
        uint256 len = lenderPositionIds.length;

        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.lenderPositionKey != bytes32(0)) {
                _settleSettlementPosition(line.settlementPoolId, commitment.lenderPositionKey);
                uint256 encumbered = LibModuleEncumbrance.getEncumberedForModule(
                    commitment.lenderPositionKey, line.settlementPoolId, commitmentModuleId
                );
                if (encumbered != 0) {
                    LibModuleEncumbrance.unencumber(
                        commitment.lenderPositionKey, line.settlementPoolId, commitmentModuleId, encumbered
                    );
                }
            }

            commitment.committedAmount = 0;
            if (commitment.lossWrittenDown != 0) {
                commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.WrittenDown;
            } else if (commitment.status != LibEqualScaleAlphaStorage.CommitmentStatus.Canceled) {
                commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Closed;
            }
        }

        if (!releaseCollateral && line.collateralMode == LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted) {
            uint256 collateralModuleId = _borrowerCollateralModuleId(lineId);
            uint256 collateralEncumbered = LibModuleEncumbrance.getEncumberedForModule(
                line.borrowerPositionKey, line.borrowerCollateralPoolId, collateralModuleId
            );
            if (collateralEncumbered != 0) {
                LibModuleEncumbrance.unencumber(
                    line.borrowerPositionKey, line.borrowerCollateralPoolId, collateralModuleId, collateralEncumbered
                );
            }
        }

        line.activeLimit = 0;
        line.currentCommittedAmount = 0;
        line.outstandingPrincipal = 0;
        line.accruedInterest = 0;
        line.interestAccruedSinceLastDue = 0;
        line.paidSinceLastDue = 0;
        line.currentPeriodDrawn = 0;
        line.delinquentSince = 0;
        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Closed;

        emit IEqualScaleAlphaEvents.CreditLineClosed(lineId, previousStatus, closedWithLoss);
    }

    function _requireBorrowerPositionOwner(uint256 positionId) private view returns (bytes32 borrowerPositionKey) {
        PositionNFT positionNft = _positionNft();
        address owner = positionNft.ownerOf(positionId);
        if (owner != msg.sender) {
            revert IEqualScaleAlphaErrors.BorrowerPositionNotOwned(msg.sender, positionId);
        }

        borrowerPositionKey = positionNft.getPositionKey(positionId);
    }

    function _requireLenderPositionOwner(uint256 lenderPositionId, uint256 settlementPoolId)
        private
        view
        returns (bytes32 lenderPositionKey)
    {
        PositionNFT positionNft = _positionNft();
        address owner = positionNft.ownerOf(lenderPositionId);
        if (owner != msg.sender) {
            revert IEqualScaleAlphaErrors.LenderPositionNotOwned(msg.sender, lenderPositionId);
        }
        if (positionNft.getPoolId(lenderPositionId) != settlementPoolId) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("lender position not in settlement pool");
        }

        lenderPositionKey = positionNft.getPositionKey(lenderPositionId);
    }

    function _settlementCommitmentModuleId(uint256 lineId) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("equalscale.alpha.commitment.", lineId)));
    }

    function _borrowerCollateralModuleId(uint256 lineId) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("equalscale.alpha.collateral.", lineId)));
    }

    function _settleSettlementPosition(uint256 settlementPoolId, bytes32 lenderPositionKey) private {
        _settlePosition(settlementPoolId, lenderPositionKey);
    }

    function _settlePosition(uint256 poolId, bytes32 positionKey) private {
        LibActiveCreditIndex.settle(poolId, positionKey);
        LibFeeIndex.settle(poolId, positionKey);
    }

    function _positionNft() private view returns (PositionNFT positionNft) {
        address positionNftAddress = LibPositionNFT.s().positionNFTContract;
        if (positionNftAddress == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        positionNft = PositionNFT(positionNftAddress);
    }

    function _refinanceCommitmentMutable(LibEqualScaleAlphaStorage.CommitmentStatus status)
        private
        pure
        returns (bool)
    {
        return status == LibEqualScaleAlphaStorage.CommitmentStatus.Active
            || status == LibEqualScaleAlphaStorage.CommitmentStatus.Rolled;
    }
}
