// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {LibEqualScaleAlphaShared} from "src/equalscale/LibEqualScaleAlphaShared.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {Types} from "src/libraries/Types.sol";

library LibEqualScaleAlphaLifecycle {
    function repayLine(uint256 lineId, uint256 amount) external {
        if (amount == 0) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("amount == 0");
        }

        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        bytes32 borrowerPositionKey = LibEqualScaleAlphaShared.requireBorrowerPositionOwner(line.borrowerPositionId);
        if (!LibEqualScaleAlphaShared.repaymentAllowed(line.status)) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not repayable during current status");
        }

        LibEqualScaleAlphaShared.accrueInterest(line);

        uint256 totalOutstanding = line.outstandingPrincipal + line.accruedInterest;
        if (totalOutstanding == 0) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line has no outstanding obligation");
        }

        uint256 effectiveAmount = amount > totalOutstanding ? totalOutstanding : amount;
        uint256 requiredMinimumDue = LibEqualScaleAlphaShared.requiredMinimumDue(line);
        bool dueWindowFreshlyResetThisBlock =
            line.interestAccruedAt == block.timestamp && line.interestAccruedSinceLastDue == 0 && line.paidSinceLastDue == 0;
        bool advanceCheckpoint = requiredMinimumDue != 0 && line.paidSinceLastDue < requiredMinimumDue
            && (
                line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent || block.timestamp >= line.nextDueAt
            ) && !dueWindowFreshlyResetThisBlock;
        uint256 interestComponent = effectiveAmount > line.accruedInterest ? line.accruedInterest : effectiveAmount;
        uint256 principalComponent = effectiveAmount - interestComponent;

        {
            Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
            uint256 received =
                LibCurrency.pullAtLeast(settlementPool.underlying, msg.sender, effectiveAmount, effectiveAmount);
            settlementPool.trackedBalance += received;

            LibEqualScaleAlphaShared.settleSettlementPosition(line.settlementPoolId, borrowerPositionKey);

            line.accruedInterest -= interestComponent;
            line.outstandingPrincipal -= principalComponent;
            line.totalInterestRepaid += interestComponent;
            line.totalPrincipalRepaid += principalComponent;
            line.paidSinceLastDue += effectiveAmount;

            if (principalComponent != 0) {
                LibEqualScaleAlphaShared.reduceBorrowerDebt(
                    settlementPool, line.settlementPoolId, borrowerPositionKey, principalComponent
                );
            }
        }

        LibEqualScaleAlphaShared.allocateRepayment(store, lineId, interestComponent, principalComponent);
        LibEqualScaleAlphaShared.recordPaymentRecord(store, lineId, effectiveAmount, principalComponent, interestComponent);

        bool minimumDueSatisfied = requiredMinimumDue == 0 || line.paidSinceLastDue >= requiredMinimumDue;
        if (minimumDueSatisfied && advanceCheckpoint) {
            LibEqualScaleAlphaShared.advanceDueCheckpoint(line);
        }

        LibEqualScaleAlphaShared.cureLineIfCovered(line, minimumDueSatisfied);

        LibEqualScaleAlphaShared.emitCreditPaymentMade(
            lineId, effectiveAmount, principalComponent, interestComponent, line
        );
    }

    function enterRefinancing(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not active for refinancing");
        }
        if (block.timestamp < line.termEndAt) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("facility term still active");
        }

        LibEqualScaleAlphaShared.accrueInterest(line);
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

        bytes32 lenderPositionKey =
            LibEqualScaleAlphaShared.requireLenderPositionOwner(lenderPositionId, line.settlementPoolId);
        LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionId];
        if (
            commitment.committedAmount == 0 || commitment.lenderPositionKey != lenderPositionKey
                || !LibEqualScaleAlphaShared.refinanceCommitmentMutable(commitment.status)
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

        bytes32 lenderPositionKey =
            LibEqualScaleAlphaShared.requireLenderPositionOwner(lenderPositionId, line.settlementPoolId);
        LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionId];
        if (
            commitment.committedAmount == 0 || commitment.lenderPositionKey != lenderPositionKey
                || !LibEqualScaleAlphaShared.refinanceCommitmentMutable(commitment.status)
        ) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("no active commitment");
        }

        uint256 exitedAmount = commitment.committedAmount;
        commitment.committedAmount = 0;
        commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Exited;
        line.currentCommittedAmount -= exitedAmount;

        LibEqualScaleAlphaShared.settleSettlementPosition(line.settlementPoolId, lenderPositionKey);
        LibEqualScaleAlphaShared.decreaseSettlementCommitmentReservation(
            LibAppStorage.s().pools[line.settlementPoolId], line.settlementPoolId, lenderPositionKey, exitedAmount
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

        LibEqualScaleAlphaShared.accrueInterest(line);

        if (line.currentCommittedAmount >= line.requestedTargetLimit) {
            LibEqualScaleAlphaShared.restartLineTerm(line, line.requestedTargetLimit);
        } else if (
            line.currentCommittedAmount >= line.outstandingPrincipal
                && line.currentCommittedAmount >= line.minimumViableLine
        ) {
            LibEqualScaleAlphaShared.restartLineTerm(line, line.currentCommittedAmount);
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
        if (!LibEqualScaleAlphaShared.delinquencyEligible(line.status)) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line not eligible for delinquency");
        }

        LibEqualScaleAlphaShared.accrueInterest(line);

        uint40 currentTimestamp = uint40(block.timestamp);
        if (currentTimestamp <= line.nextDueAt + line.gracePeriodSecs) {
            revert IEqualScaleAlphaErrors.DelinquencyTooEarly(lineId, line.nextDueAt, line.gracePeriodSecs, currentTimestamp);
        }

        uint256 currentMinimumDue = LibEqualScaleAlphaShared.requiredMinimumDue(line);
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

        uint40 chargeOffThresholdSecs = LibEqualScaleAlphaShared.chargeOffThresholdSecs(store);
        uint40 currentTimestamp = uint40(block.timestamp);
        if (currentTimestamp < line.delinquentSince + chargeOffThresholdSecs) {
            revert IEqualScaleAlphaErrors.ChargeOffTooEarly(
                lineId, line.delinquentSince, chargeOffThresholdSecs, currentTimestamp
            );
        }

        LibEqualScaleAlphaShared.accrueInterest(line);
        uint256 accruedInterestAtChargeOff = line.accruedInterest;

        uint256 totalExposedPrincipal = LibEqualScaleAlphaShared.totalExposedPrincipal(store, lineId);
        uint256 recoveryApplied = LibEqualScaleAlphaShared.recoverBorrowerCollateral(line, totalExposedPrincipal);
        if (recoveryApplied != 0) {
            LibEqualScaleAlphaShared.allocateRecovery(store, lineId, recoveryApplied);
        }

        uint256 principalWrittenDown = LibEqualScaleAlphaShared.totalExposedPrincipal(store, lineId);
        if (principalWrittenDown != 0) {
            LibEqualScaleAlphaShared.allocateWriteDown(store, lineId, principalWrittenDown);
        }
        if (accruedInterestAtChargeOff != 0) {
            LibEqualScaleAlphaShared.allocateInterestLoss(store, lineId, accruedInterestAtChargeOff);
            emit IEqualScaleAlphaEvents.CreditLineInterestLossRecorded(lineId, accruedInterestAtChargeOff);
        }

        if (line.outstandingPrincipal != 0) {
            Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
            LibEqualScaleAlphaShared.settleSettlementPosition(line.settlementPoolId, line.borrowerPositionKey);
            LibEqualScaleAlphaShared.reduceBorrowerDebt(
                settlementPool, line.settlementPoolId, line.borrowerPositionKey, line.outstandingPrincipal
            );
        }

        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.ChargedOff;
        emit IEqualScaleAlphaEvents.CreditLineChargedOff(lineId, recoveryApplied, principalWrittenDown);

        LibEqualScaleAlphaShared.finalizeChargedOffLine(store, lineId, line, principalWrittenDown != 0);
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

        LibEqualScaleAlphaShared.requireBorrowerPositionOwner(line.borrowerPositionId);
        LibEqualScaleAlphaShared.accrueInterest(line);
        if (line.outstandingPrincipal != 0 || line.accruedInterest != 0) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("line has outstanding obligation");
        }

        LibEqualScaleAlphaShared.finalizeRepaidLine(store, lineId, line, line.status);
    }
}
