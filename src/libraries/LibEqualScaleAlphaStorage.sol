// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Isolated diamond storage for the EqualScale Alpha credit-line module.
library LibEqualScaleAlphaStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalscale.alpha.storage");

    enum CollateralMode {
        None,
        BorrowerPosted
    }

    enum CreditLineStatus {
        SoloWindow,
        PooledOpen,
        Active,
        Refinancing,
        Runoff,
        Delinquent,
        Frozen,
        ChargedOff,
        Closed
    }

    enum CommitmentStatus {
        Active,
        Canceled,
        Rolled,
        Exited,
        WrittenDown,
        Closed
    }

    /// @notice Borrower-specific profile metadata. Canonical wallet identity stays in the position-agent stack.
    struct BorrowerProfile {
        bytes32 borrowerPositionKey;
        address treasuryWallet;
        address bankrToken;
        bytes32 metadataHash;
        bool active;
    }

    struct CreditLine {
        bytes32 borrowerPositionKey;
        uint256 borrowerPositionId;

        // Proposal terms
        uint256 settlementPoolId;
        uint256 requestedTargetLimit;
        uint256 minimumViableLine;
        uint16 aprBps;
        uint256 minimumPaymentPerPeriod;
        uint256 maxDrawPerPeriod;
        uint32 paymentIntervalSecs;
        uint32 gracePeriodSecs;
        uint40 facilityTermSecs;
        uint40 refinanceWindowSecs;
        CollateralMode collateralMode;
        uint256 borrowerCollateralPoolId;
        uint256 borrowerCollateralAmount;

        // Live accounting and lifecycle state
        uint256 activeLimit;
        uint256 currentCommittedAmount;
        uint256 lockedCollateralAmount;
        uint256 outstandingPrincipal;
        uint256 accruedInterest;
        uint256 interestAccruedSinceLastDue;
        uint256 totalPrincipalRepaid;
        uint256 totalInterestRepaid;
        uint256 paidSinceLastDue;
        uint256 currentPeriodDrawn;
        uint40 currentPeriodStartedAt;
        uint40 interestAccruedAt;
        uint40 nextDueAt;
        uint40 termStartedAt;
        uint40 termEndAt;
        uint40 refinanceEndAt;
        uint40 soloExclusiveUntil;
        uint40 delinquentSince;
        uint8 missedPayments;
        CreditLineStatus status;
    }

    struct Commitment {
        uint256 lenderPositionId;
        bytes32 lenderPositionKey;
        uint256 settlementPoolId;
        uint256 committedAmount;
        uint256 principalExposed;
        uint256 principalRepaid;
        uint256 interestReceived;
        uint256 recoveryReceived;
        uint256 lossWrittenDown;
        uint256 interestLossAllocated;
        CommitmentStatus status;
    }

    struct PaymentRecord {
        uint40 paidAt;
        uint256 amount;
        uint256 principalComponent;
        uint256 interestComponent;
    }

    struct TreasuryTelemetryView {
        uint256 treasuryBalance;
        uint256 outstandingPrincipal;
        uint256 accruedInterest;
        uint256 nextDueAmount;
        bool paymentCurrent;
        bool drawsFrozen;
        uint256 currentPeriodDrawn;
        uint256 maxDrawPerPeriod;
        CreditLineStatus status;
    }

    struct RefinanceStatusView {
        uint40 termEndAt;
        uint40 refinanceEndAt;
        uint256 currentCommittedAmount;
        uint256 activeLimit;
        uint256 outstandingPrincipal;
        bool refinanceWindowActive;
    }

    struct EqualScaleAlphaStorage {
        uint256 nextLineId;
        uint40 chargeOffThresholdSecs;
        mapping(bytes32 => BorrowerProfile) borrowerProfiles;
        mapping(uint256 => CreditLine) lines;
        mapping(bytes32 => uint256[]) borrowerLineIds;
        mapping(uint256 => mapping(uint256 => Commitment)) lineCommitments;
        mapping(uint256 => uint256[]) lineCommitmentPositionIds;
        mapping(uint256 => mapping(uint256 => bool)) lineHasCommitmentPosition;
        mapping(uint256 => PaymentRecord[]) paymentRecords;
        mapping(uint256 => uint256[]) lenderPositionLineIds;
        mapping(uint256 => mapping(uint256 => bool)) lenderPositionHasLine;
    }

    function s() internal pure returns (EqualScaleAlphaStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}
