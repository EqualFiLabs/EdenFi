// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT, EncumbranceUnderflow} from "src/libraries/Errors.sol";
import {Types} from "src/libraries/Types.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

library LibEqualScaleAlphaShared {
    uint40 internal constant DEFAULT_CHARGE_OFF_THRESHOLD = 30 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant YEAR_SECS = 365 days;

    function requireBorrowerPositionOwner(uint256 positionId) internal view returns (bytes32 borrowerPositionKey) {
        PositionNFT positionNftContract = positionNft();
        address owner = positionNftContract.ownerOf(positionId);
        if (owner != msg.sender) {
            revert IEqualScaleAlphaErrors.BorrowerPositionNotOwned(msg.sender, positionId);
        }

        borrowerPositionKey = positionNftContract.getPositionKey(positionId);
    }

    function requireLenderPositionOwner(uint256 lenderPositionId, uint256 settlementPoolId)
        internal
        view
        returns (bytes32 lenderPositionKey)
    {
        PositionNFT positionNftContract = positionNft();
        address owner = positionNftContract.ownerOf(lenderPositionId);
        if (owner != msg.sender) {
            revert IEqualScaleAlphaErrors.LenderPositionNotOwned(msg.sender, lenderPositionId);
        }
        if (positionNftContract.getPoolId(lenderPositionId) != settlementPoolId) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("lender position not in settlement pool");
        }

        lenderPositionKey = positionNftContract.getPositionKey(lenderPositionId);
    }

    function allocateRepayment(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 interestComponent,
        uint256 principalComponent
    ) internal {
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

    function recordPaymentRecord(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 effectiveAmount,
        uint256 principalComponent,
        uint256 interestComponent
    ) internal {
        store.paymentRecords[lineId].push(
            LibEqualScaleAlphaStorage.PaymentRecord({
                paidAt: uint40(block.timestamp),
                amount: effectiveAmount,
                principalComponent: principalComponent,
                interestComponent: interestComponent
            })
        );
    }

    function accrueInterest(LibEqualScaleAlphaStorage.CreditLine storage line) internal {
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

    function requiredMinimumDue(LibEqualScaleAlphaStorage.CreditLine storage line) internal view returns (uint256) {
        return line.interestAccruedSinceLastDue > line.minimumPaymentPerPeriod
            ? line.interestAccruedSinceLastDue
            : line.minimumPaymentPerPeriod;
    }

    function advanceDueCheckpoint(LibEqualScaleAlphaStorage.CreditLine storage line) internal {
        uint40 newDueAt = line.nextDueAt + line.paymentIntervalSecs;
        if (newDueAt > line.termEndAt) {
            newDueAt = line.termEndAt;
        }
        line.nextDueAt = newDueAt;
        line.interestAccruedSinceLastDue = 0;
        line.paidSinceLastDue = 0;
    }

    function cureLineIfCovered(LibEqualScaleAlphaStorage.CreditLine storage line, bool minimumDueSatisfied) internal {
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
                && line.currentCommittedAmount >= line.minimumViableLine
        ) {
            restartLineTerm(line, line.currentCommittedAmount);
        }
    }

    function restartLineTerm(LibEqualScaleAlphaStorage.CreditLine storage line, uint256 activeLimit) internal {
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

    function reduceBorrowerDebt(
        Types.PoolData storage settlementPool,
        uint256 settlementPoolId,
        bytes32 borrowerPositionKey,
        uint256 principalComponent
    ) internal {
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

    function repaymentAllowed(LibEqualScaleAlphaStorage.CreditLineStatus status) internal pure returns (bool) {
        return status == LibEqualScaleAlphaStorage.CreditLineStatus.Active
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen;
    }

    function emitCreditPaymentMade(
        uint256 lineId,
        uint256 effectiveAmount,
        uint256 principalComponent,
        uint256 interestComponent,
        LibEqualScaleAlphaStorage.CreditLine storage line
    ) internal {
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

    function delinquencyEligible(LibEqualScaleAlphaStorage.CreditLineStatus status) internal pure returns (bool) {
        return status == LibEqualScaleAlphaStorage.CreditLineStatus.Active
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff;
    }

    function chargeOffThresholdSecs(LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store)
        internal
        view
        returns (uint40)
    {
        uint40 configured = store.chargeOffThresholdSecs;
        return configured == 0 ? DEFAULT_CHARGE_OFF_THRESHOLD : configured;
    }

    function recoverBorrowerCollateral(LibEqualScaleAlphaStorage.CreditLine storage line, uint256 maxRecovery)
        internal
        returns (uint256 recovered)
    {
        if (
            maxRecovery == 0 || line.collateralMode != LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted
                || line.borrowerCollateralPoolId == 0 || line.lockedCollateralAmount == 0
        ) {
            return 0;
        }

        settlePosition(line.borrowerCollateralPoolId, line.borrowerPositionKey);

        Types.PoolData storage collateralPool = LibAppStorage.s().pools[line.borrowerCollateralPoolId];
        if (!collateralPool.initialized) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("borrower collateral pool not initialized");
        }

        Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
        if (collateralPool.underlying != settlementPool.underlying) {
            revert IEqualScaleAlphaErrors.InvalidProposalTerms("collateral underlying mismatch");
        }

        uint256 borrowerPrincipal = collateralPool.userPrincipal[line.borrowerPositionKey];
        uint256 lockedCollateralAmount = line.lockedCollateralAmount;
        recovered = lockedCollateralAmount;
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

        decreaseBorrowerCollateralReservation(
            collateralPool, line.borrowerCollateralPoolId, line.borrowerPositionKey, lockedCollateralAmount
        );
        line.lockedCollateralAmount = 0;
    }

    function allocateRecovery(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 recoveryAmount
    ) internal {
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

    function allocateWriteDown(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 writeDownAmount
    ) internal {
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

    function allocateInterestLoss(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 interestLossAmount
    ) internal {
        if (interestLossAmount == 0) {
            return;
        }

        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 totalLossBasis;
        uint256 activeCommitmentCount;
        uint256 len = lenderPositionIds.length;

        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            uint256 lossBasis = commitment.principalExposed + commitment.recoveryReceived + commitment.lossWrittenDown;
            if (lossBasis == 0) {
                continue;
            }

            totalLossBasis += lossBasis;
            activeCommitmentCount++;
        }

        if (totalLossBasis == 0 || activeCommitmentCount == 0) {
            return;
        }

        uint256 remainingInterestLoss = interestLossAmount;
        uint256 seenActiveCommitments;
        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            uint256 lossBasis = commitment.principalExposed + commitment.recoveryReceived + commitment.lossWrittenDown;
            if (lossBasis == 0) {
                continue;
            }

            seenActiveCommitments++;
            uint256 interestLossShare = remainingInterestLoss;
            if (seenActiveCommitments != activeCommitmentCount) {
                interestLossShare = Math.mulDiv(interestLossAmount, lossBasis, totalLossBasis);
                if (interestLossShare > remainingInterestLoss) {
                    interestLossShare = remainingInterestLoss;
                }
                remainingInterestLoss -= interestLossShare;
            }

            commitment.interestLossAllocated += interestLossShare;
        }
    }

    function totalExposedPrincipal(LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store, uint256 lineId)
        internal
        view
        returns (uint256 totalExposed)
    {
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 len = lenderPositionIds.length;
        for (uint256 i = 0; i < len; i++) {
            totalExposed += store.lineCommitments[lineId][lenderPositionIds[i]].principalExposed;
        }
    }

    function finalizeChargedOffLine(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        bool closedWithLoss
    ) internal {
        finalizeClosedLine(store, lineId, line, LibEqualScaleAlphaStorage.CreditLineStatus.ChargedOff, closedWithLoss);
    }

    function finalizeRepaidLine(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        LibEqualScaleAlphaStorage.CreditLineStatus previousStatus
    ) internal {
        finalizeClosedLine(store, lineId, line, previousStatus, false);
    }

    function finalizeClosedLine(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        LibEqualScaleAlphaStorage.CreditLineStatus previousStatus,
        bool closedWithLoss
    ) internal {
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 len = lenderPositionIds.length;

        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.lenderPositionKey != bytes32(0) && commitment.committedAmount != 0) {
                settleSettlementPosition(line.settlementPoolId, commitment.lenderPositionKey);
                decreaseSettlementCommitmentReservation(
                    LibAppStorage.s().pools[line.settlementPoolId],
                    line.settlementPoolId,
                    commitment.lenderPositionKey,
                    commitment.committedAmount
                );
            }

            commitment.committedAmount = 0;
            if (commitment.lossWrittenDown != 0) {
                commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.WrittenDown;
            } else if (commitment.status != LibEqualScaleAlphaStorage.CommitmentStatus.Canceled) {
                commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Closed;
            }
        }

        if (line.collateralMode == LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted && line.lockedCollateralAmount != 0) {
            settlePosition(line.borrowerCollateralPoolId, line.borrowerPositionKey);
            decreaseBorrowerCollateralReservation(
                LibAppStorage.s().pools[line.borrowerCollateralPoolId],
                line.borrowerCollateralPoolId,
                line.borrowerPositionKey,
                line.lockedCollateralAmount
            );
            line.lockedCollateralAmount = 0;
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

    function increaseSettlementCommitmentReservation(
        Types.PoolData storage settlementPool,
        uint256 settlementPoolId,
        bytes32 lenderPositionKey,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }

        LibEncumbrance.position(lenderPositionKey, settlementPoolId).encumberedCapital += amount;
        LibActiveCreditIndex.applyEncumbranceIncrease(settlementPool, settlementPoolId, lenderPositionKey, amount);
    }

    function decreaseSettlementCommitmentReservation(
        Types.PoolData storage settlementPool,
        uint256 settlementPoolId,
        bytes32 lenderPositionKey,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }

        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(lenderPositionKey, settlementPoolId);
        uint256 current = enc.encumberedCapital;
        if (amount > current) {
            revert EncumbranceUnderflow(amount, current);
        }
        enc.encumberedCapital = current - amount;
        LibActiveCreditIndex.applyEncumbranceDecrease(settlementPool, settlementPoolId, lenderPositionKey, amount);
    }

    function increaseBorrowerCollateralReservation(
        Types.PoolData storage collateralPool,
        uint256 collateralPoolId,
        bytes32 borrowerPositionKey,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }

        LibEncumbrance.position(borrowerPositionKey, collateralPoolId).lockedCapital += amount;
        LibActiveCreditIndex.applyEncumbranceIncrease(collateralPool, collateralPoolId, borrowerPositionKey, amount);
    }

    function decreaseBorrowerCollateralReservation(
        Types.PoolData storage collateralPool,
        uint256 collateralPoolId,
        bytes32 borrowerPositionKey,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }

        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(borrowerPositionKey, collateralPoolId);
        uint256 current = enc.lockedCapital;
        if (amount > current) {
            revert EncumbranceUnderflow(amount, current);
        }
        enc.lockedCapital = current - amount;
        LibActiveCreditIndex.applyEncumbranceDecrease(collateralPool, collateralPoolId, borrowerPositionKey, amount);
    }

    function settleSettlementPosition(uint256 settlementPoolId, bytes32 lenderPositionKey) internal {
        settlePosition(settlementPoolId, lenderPositionKey);
    }

    function settlePosition(uint256 poolId, bytes32 positionKey) internal {
        LibActiveCreditIndex.settle(poolId, positionKey);
        LibFeeIndex.settle(poolId, positionKey);
    }

    function positionNft() internal view returns (PositionNFT positionNftContract) {
        address positionNftAddress = LibPositionNFT.s().positionNFTContract;
        if (positionNftAddress == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        positionNftContract = PositionNFT(positionNftAddress);
    }

    function refinanceCommitmentMutable(LibEqualScaleAlphaStorage.CommitmentStatus status)
        internal
        pure
        returns (bool)
    {
        return status == LibEqualScaleAlphaStorage.CommitmentStatus.Active
            || status == LibEqualScaleAlphaStorage.CommitmentStatus.Rolled;
    }
}
