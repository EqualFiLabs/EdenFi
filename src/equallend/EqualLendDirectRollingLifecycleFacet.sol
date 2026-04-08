// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    DirectError_EarlyExerciseNotAllowed,
    DirectError_EarlyRepayNotAllowed,
    DirectError_InvalidAgreementState,
    DirectError_InvalidConfiguration,
    InsufficientPrincipal,
    MaxUserCountExceeded,
    RollingError_RecoveryNotEligible
} from "src/libraries/Errors.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectRolling} from "src/libraries/LibEqualLendDirectRolling.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibFeeRouter} from "src/libraries/LibFeeRouter.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "src/libraries/LibReentrancyGuard.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Borrower full-closeout settlement for rolling agreements.
contract EqualLendDirectRollingLifecycleFacet is ReentrancyGuardModifiers {
    bytes32 internal constant DIRECT_ROLLING_DEFAULT_SOURCE = keccak256("DIRECT_ROLLING_DEFAULT");

    struct RecoverySettlement {
        uint256 collateralSeized;
        uint256 penaltyPaid;
        uint256 interestRecovered;
        uint256 principalRecovered;
        uint256 borrowerRefund;
        uint256 debtValueApplied;
        uint256 lenderShare;
        uint256 treasuryShare;
        uint256 activeCreditShare;
        uint256 feeIndexShare;
    }

    event RollingAgreementRepaid(
        uint256 indexed agreementId,
        address indexed borrower,
        uint256 repaymentAmount,
        uint256 interestCleared,
        uint256 principalCleared
    );
    event RollingAgreementExercised(
        uint256 indexed agreementId,
        address indexed borrower,
        uint256 interestRecovered,
        uint256 principalRecovered,
        uint256 borrowerRefund,
        uint256 treasuryShare,
        uint256 feeIndexShare,
        uint256 activeCreditShare
    );
    event RollingAgreementRecovered(
        uint256 indexed agreementId,
        address indexed executor,
        uint256 penaltyPaid,
        uint256 interestRecovered,
        uint256 principalRecovered,
        uint256 borrowerRefund,
        uint256 treasuryShare,
        uint256 feeIndexShare,
        uint256 activeCreditShare
    );

    function exerciseRolling(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingAgreement storage agreement = _requireActiveRollingAgreement(store, agreementId);

        LibPositionHelpers.requireOwnership(agreement.borrowerPositionId);
        if (!agreement.allowEarlyExercise) {
            revert DirectError_EarlyExerciseNotAllowed();
        }

        _settleRollingAgreementPositions(agreement);
        RecoverySettlement memory settlement = _settleRollingDefaultPath(
            store, agreement, LibEqualLendDirectStorage.AgreementStatus.Exercised, false
        );

        emit RollingAgreementExercised(
            agreementId,
            msg.sender,
            settlement.interestRecovered,
            settlement.principalRecovered,
            settlement.borrowerRefund,
            settlement.treasuryShare,
            settlement.feeIndexShare,
            settlement.activeCreditShare
        );
    }

    function recoverRolling(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingAgreement storage agreement = _requireActiveRollingAgreement(store, agreementId);

        if (block.timestamp <= uint256(agreement.nextDue) + agreement.gracePeriodSeconds) {
            revert RollingError_RecoveryNotEligible();
        }

        _settleRollingAgreementPositions(agreement);
        RecoverySettlement memory settlement = _settleRollingDefaultPath(
            store, agreement, LibEqualLendDirectStorage.AgreementStatus.Defaulted, true
        );

        emit RollingAgreementRecovered(
            agreementId,
            msg.sender,
            settlement.penaltyPaid,
            settlement.interestRecovered,
            settlement.principalRecovered,
            settlement.borrowerRefund,
            settlement.treasuryShare,
            settlement.feeIndexShare,
            settlement.activeCreditShare
        );
    }

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

    function _settleRollingDefaultPath(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.RollingAgreement storage agreement,
        LibEqualLendDirectStorage.AgreementStatus terminalStatus,
        bool applyPenalty
    ) internal returns (RecoverySettlement memory settlement) {
        uint256 asOf = block.timestamp;
        LibEqualLendDirectRolling.AccrualSnapshot memory snapshot = LibEqualLendDirectRolling.previewAccrual(agreement, asOf);
        uint256 interestDue = snapshot.arrearsDue + snapshot.currentInterestDue;
        uint256 principalDue = agreement.outstandingPrincipal;
        uint256 totalDebt = interestDue + principalDue;

        Types.PoolData storage collateralPool = LibPositionHelpers.pool(agreement.collateralPoolId);
        settlement.collateralSeized = _seizeBorrowerCollateral(agreement, collateralPool);

        uint256 availableForDebt = settlement.collateralSeized;
        if (applyPenalty && settlement.collateralSeized != 0) {
            settlement.penaltyPaid = (totalDebt * store.rollingConfig.defaultPenaltyBps)
                / LibEqualLendDirectStorage.BPS_DENOMINATOR;
            if (settlement.penaltyPaid > settlement.collateralSeized) {
                settlement.penaltyPaid = settlement.collateralSeized;
            }
            availableForDebt -= settlement.penaltyPaid;
        }

        settlement.debtValueApplied = availableForDebt < totalDebt ? availableForDebt : totalDebt;
        settlement.interestRecovered = settlement.debtValueApplied < interestDue ? settlement.debtValueApplied : interestDue;

        uint256 remainingAfterInterest = settlement.debtValueApplied - settlement.interestRecovered;
        settlement.principalRecovered = remainingAfterInterest < principalDue ? remainingAfterInterest : principalDue;
        settlement.borrowerRefund = availableForDebt - settlement.debtValueApplied;

        (settlement.lenderShare, settlement.treasuryShare, settlement.activeCreditShare, settlement.feeIndexShare) =
            _splitRecoveredDebt(settlement.debtValueApplied, store.config);

        _applyRecoveredValue(agreement, collateralPool, settlement);
        _finalizeRollingTerminalState(store, agreement, principalDue, asOf, terminalStatus);
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

    function _seizeBorrowerCollateral(
        LibEqualLendDirectStorage.RollingAgreement storage agreement,
        Types.PoolData storage collateralPool
    ) internal returns (uint256 collateralSeized) {
        uint256 borrowerPrincipal = collateralPool.userPrincipal[agreement.borrowerPositionKey];
        collateralSeized = borrowerPrincipal < agreement.collateralLocked ? borrowerPrincipal : agreement.collateralLocked;

        if (collateralSeized == 0) {
            return 0;
        }

        collateralPool.userPrincipal[agreement.borrowerPositionKey] = borrowerPrincipal - collateralSeized;
        collateralPool.totalDeposits -= collateralSeized;
        if (borrowerPrincipal == collateralSeized && collateralPool.userCount > 0) {
            collateralPool.userCount -= 1;
        }
    }

    function _splitRecoveredDebt(uint256 amount, LibEqualLendDirectStorage.DirectConfig storage cfg)
        internal
        view
        returns (uint256 lenderShare, uint256 treasuryShare, uint256 activeCreditShare, uint256 feeIndexShare)
    {
        if (amount == 0) {
            return (0, 0, 0, 0);
        }

        lenderShare = (amount * uint256(cfg.defaultLenderBps)) / LibEqualLendDirectStorage.BPS_DENOMINATOR;
        if (lenderShare > amount) {
            lenderShare = amount;
        }

        uint256 remainder = amount - lenderShare;
        (treasuryShare, activeCreditShare, feeIndexShare) = LibFeeRouter.previewSplit(remainder);
    }

    function _applyRecoveredValue(
        LibEqualLendDirectStorage.RollingAgreement storage agreement,
        Types.PoolData storage collateralPool,
        RecoverySettlement memory settlement
    ) internal {
        if (settlement.lenderShare != 0) {
            _creditLenderSettlement(agreement, settlement.lenderShare);
        }

        uint256 routedAmount = settlement.treasuryShare + settlement.activeCreditShare + settlement.feeIndexShare;
        if (routedAmount != 0) {
            LibFeeRouter.routeSamePool(
                agreement.collateralPoolId, routedAmount, DIRECT_ROLLING_DEFAULT_SOURCE, true, 0
            );
        }
        if (settlement.penaltyPaid != 0) {
            _transferPenaltyToTreasury(collateralPool, settlement.penaltyPaid);
        }
        if (settlement.borrowerRefund != 0) {
            _creditPrincipal(collateralPool, agreement.borrowerPositionKey, settlement.borrowerRefund);
        }
    }

    function _finalizeRollingTerminalState(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.RollingAgreement storage agreement,
        uint256 principalDue,
        uint256 asOf,
        LibEqualLendDirectStorage.AgreementStatus terminalStatus
    ) internal {
        agreement.status = terminalStatus;
        agreement.outstandingPrincipal = 0;
        agreement.arrears = 0;
        agreement.lastAccrualTimestamp = uint64(asOf);
        agreement.nextDue = uint64(asOf);

        LibEqualLendDirectAccounting.cleanupTerminal(
            store,
            LibEqualLendDirectAccounting.TerminalCleanupParams({
                lenderPositionKey: agreement.lenderPositionKey,
                borrowerPositionKey: agreement.borrowerPositionKey,
                borrowerPositionId: agreement.borrowerPositionId,
                lenderPoolId: agreement.lenderPoolId,
                collateralPoolId: agreement.collateralPoolId,
                borrowAsset: agreement.borrowAsset,
                collateralAsset: agreement.collateralAsset,
                borrowedPrincipalToClear: principalDue,
                exposureToClear: principalDue,
                collateralToUnlock: agreement.collateralLocked
            })
        );
        _clearAgreementIndexes(store, agreement);
    }

    function _creditLenderSettlement(LibEqualLendDirectStorage.RollingAgreement storage agreement, uint256 lenderShare)
        internal
    {
        bool sameAsset = agreement.borrowAsset == agreement.collateralAsset;

        if (sameAsset && agreement.lenderPoolId != agreement.collateralPoolId) {
            Types.PoolData storage collateralPool = LibPositionHelpers.pool(agreement.collateralPoolId);
            Types.PoolData storage lenderPool = LibPositionHelpers.pool(agreement.lenderPoolId);
            _moveTrackedBacking(collateralPool, lenderPool, lenderShare);
            _creditPrincipal(lenderPool, agreement.lenderPositionKey, lenderShare);
            return;
        }

        Types.PoolData storage settlementPool = LibPositionHelpers.pool(agreement.collateralPoolId);
        LibPositionHelpers.ensurePoolMembership(agreement.lenderPositionKey, agreement.collateralPoolId, true);
        _creditPrincipal(settlementPool, agreement.lenderPositionKey, lenderShare);
    }

    function _creditPrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 amount) internal {
        uint256 principalBefore = pool.userPrincipal[positionKey];
        pool.userPrincipal[positionKey] = principalBefore + amount;
        pool.totalDeposits += amount;
        if (principalBefore == 0) {
            uint256 maxUsers = pool.poolConfig.maxUserCount;
            if (maxUsers > 0 && pool.userCount >= maxUsers) {
                revert MaxUserCountExceeded(maxUsers);
            }
            pool.userCount += 1;
        }
    }

    function _moveTrackedBacking(
        Types.PoolData storage fromPool,
        Types.PoolData storage toPool,
        uint256 amount
    ) internal {
        if (amount > fromPool.trackedBalance) {
            revert InsufficientPrincipal(amount, fromPool.trackedBalance);
        }

        fromPool.trackedBalance -= amount;
        toPool.trackedBalance += amount;
    }

    function _transferPenaltyToTreasury(Types.PoolData storage collateralPool, uint256 amount) internal {
        address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
        if (treasury == address(0)) {
            revert DirectError_InvalidConfiguration();
        }
        if (amount > collateralPool.trackedBalance) {
            revert InsufficientPrincipal(amount, collateralPool.trackedBalance);
        }

        collateralPool.trackedBalance -= amount;
        LibCurrency.transfer(collateralPool.underlying, treasury, amount);
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
