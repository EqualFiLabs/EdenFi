// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";

interface IEqualScaleAlphaEvents {
    event BorrowerProfileRegistered(
        bytes32 indexed borrowerPositionKey,
        uint256 indexed borrowerPositionId,
        address treasuryWallet,
        address bankrToken,
        uint256 resolvedAgentId,
        bytes32 metadataHash
    );

    event BorrowerProfileUpdated(
        bytes32 indexed borrowerPositionKey,
        uint256 indexed borrowerPositionId,
        address treasuryWallet,
        address bankrToken,
        bytes32 metadataHash
    );

    event LineProposalCreated(
        uint256 indexed lineId,
        uint256 indexed borrowerPositionId,
        bytes32 indexed borrowerPositionKey,
        uint256 settlementPoolId,
        uint256 requestedTargetLimit,
        uint256 minimumViableLine,
        uint16 aprBps,
        uint256 minimumPaymentPerPeriod,
        uint256 maxDrawPerPeriod,
        uint32 paymentIntervalSecs,
        uint32 gracePeriodSecs,
        uint40 facilityTermSecs,
        uint40 refinanceWindowSecs,
        LibEqualScaleAlphaStorage.CollateralMode collateralMode,
        uint256 borrowerCollateralPoolId,
        uint256 borrowerCollateralAmount
    );

    event LineProposalUpdated(
        uint256 indexed lineId,
        uint256 indexed borrowerPositionId,
        bytes32 indexed borrowerPositionKey,
        uint256 settlementPoolId,
        uint256 requestedTargetLimit,
        uint256 minimumViableLine,
        uint16 aprBps,
        uint256 minimumPaymentPerPeriod,
        uint256 maxDrawPerPeriod,
        uint32 paymentIntervalSecs,
        uint32 gracePeriodSecs,
        uint40 facilityTermSecs,
        uint40 refinanceWindowSecs,
        LibEqualScaleAlphaStorage.CollateralMode collateralMode,
        uint256 borrowerCollateralPoolId,
        uint256 borrowerCollateralAmount
    );

    event ProposalCancelled(
        uint256 indexed lineId, uint256 indexed borrowerPositionId, bytes32 indexed borrowerPositionKey
    );

    event CreditLineEnteredSoloWindow(uint256 indexed lineId, uint40 soloExclusiveUntil);

    event CreditLineOpenedToPool(uint256 indexed lineId);

    event CommitmentAdded(
        uint256 indexed lineId,
        uint256 indexed lenderPositionId,
        bytes32 indexed lenderPositionKey,
        uint256 amount,
        uint256 currentCommittedAmount
    );

    event CommitmentCancelled(
        uint256 indexed lineId,
        uint256 indexed lenderPositionId,
        bytes32 indexed lenderPositionKey,
        uint256 amount,
        uint256 currentCommittedAmount
    );

    event CommitmentRolled(
        uint256 indexed lineId,
        uint256 indexed lenderPositionId,
        bytes32 indexed lenderPositionKey,
        uint256 amount,
        uint256 currentCommittedAmount
    );

    event CommitmentExited(
        uint256 indexed lineId,
        uint256 indexed lenderPositionId,
        bytes32 indexed lenderPositionKey,
        uint256 amount,
        uint256 currentCommittedAmount
    );

    event CreditLineActivated(
        uint256 indexed lineId,
        uint256 activeLimit,
        LibEqualScaleAlphaStorage.CollateralMode collateralMode,
        uint40 nextDueAt,
        uint40 termEndAt,
        uint40 refinanceEndAt
    );

    event CreditDrawn(uint256 indexed lineId, uint256 amount, uint256 outstandingPrincipal, uint256 currentPeriodDrawn);

    event CreditPaymentMade(
        uint256 indexed lineId,
        uint256 amount,
        uint256 principalComponent,
        uint256 interestComponent,
        uint256 outstandingPrincipal,
        uint256 accruedInterest,
        uint40 nextDueAt
    );

    event CreditLineEnteredRefinancing(
        uint256 indexed lineId, uint40 refinanceEndAt, uint256 currentCommittedAmount, uint256 outstandingPrincipal
    );

    event CreditLineRefinancingResolved(
        uint256 indexed lineId,
        LibEqualScaleAlphaStorage.CreditLineStatus outcomeStatus,
        uint256 activeLimit,
        uint256 currentCommittedAmount
    );

    event CreditLineEnteredRunoff(uint256 indexed lineId, uint256 outstandingPrincipal, uint256 currentCommittedAmount);

    event CreditLineMarkedDelinquent(
        uint256 indexed lineId, uint40 delinquentSince, uint256 currentMinimumDue, uint40 nextDueAt
    );

    event CreditLineChargedOff(uint256 indexed lineId, uint256 recoveryApplied, uint256 principalWrittenDown);

    event CreditLineClosed(
        uint256 indexed lineId, LibEqualScaleAlphaStorage.CreditLineStatus previousStatus, bool closedWithLoss
    );

    event CreditLineFreezeUpdated(uint256 indexed lineId, bool frozen, bytes32 reason);

    event ChargeOffThresholdUpdated(uint40 previousThresholdSecs, uint40 newThresholdSecs);
}
