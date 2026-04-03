// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    DirectError_EarlyExerciseNotAllowed,
    DirectError_EarlyRepayNotAllowed,
    DirectError_GracePeriodActive,
    DirectError_GracePeriodExpired,
    DirectError_InvalidAgreementState,
    DirectError_InvalidTimestamp,
    DirectError_LenderCallNotAllowed,
    InsufficientPrincipal
} from "src/libraries/Errors.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibFeeRouter} from "src/libraries/LibFeeRouter.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "src/libraries/LibReentrancyGuard.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Fixed-term lifecycle settlement for the clean EqualLend Direct rebuild.
contract EqualLendDirectLifecycleFacet is ReentrancyGuardModifiers {
    uint256 internal constant FIXED_GRACE_PERIOD = 1 days;
    bytes32 internal constant DIRECT_FIXED_DEFAULT_SOURCE = keccak256("DIRECT_FIXED_DEFAULT");

    struct DefaultSettlement {
        uint256 collateralApplied;
        uint256 lenderShare;
        uint256 treasuryShare;
        uint256 activeCreditShare;
        uint256 feeIndexShare;
    }

    event DirectAgreementRepaid(uint256 indexed agreementId, address indexed borrower, uint256 principalPaid);
    event DirectAgreementExercised(
        uint256 indexed agreementId,
        address indexed borrower,
        uint256 lenderShare,
        uint256 treasuryShare,
        uint256 feeIndexShare
    );
    event DirectAgreementRecovered(
        uint256 indexed agreementId,
        address indexed executor,
        uint256 lenderShare,
        uint256 treasuryShare,
        uint256 feeIndexShare
    );
    event DirectAgreementCalled(uint256 indexed agreementId, uint256 indexed lenderPositionId, uint64 newDueTimestamp);

    function repay(uint256 agreementId, uint256 maxPayment) external payable nonReentrant {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.FixedAgreement storage agreement = _requireActiveAgreement(store, agreementId);

        LibPositionHelpers.requireOwnership(agreement.borrowerPositionId);
        _enforceRepayWindow(agreement);
        _settleAgreementPositions(agreement);

        uint256 principal = agreement.principal;
        uint256 received = LibCurrency.pullAtLeast(agreement.borrowAsset, msg.sender, principal, maxPayment);
        uint256 surplus = received > principal ? received - principal : 0;

        if (LibCurrency.isNative(agreement.borrowAsset)) {
            LibAppStorage.s().nativeTrackedTotal -= received;
        }

        agreement.status = LibEqualLendDirectStorage.AgreementStatus.Repaid;
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
                principalDelta: principal,
                collateralDelta: agreement.collateralLocked,
                releaseLockedCollateral: true
            })
        );
        _clearAgreementIndexes(store, agreement);

        if (surplus > 0) {
            LibCurrency.transfer(agreement.borrowAsset, msg.sender, surplus);
        }

        emit DirectAgreementRepaid(agreementId, msg.sender, principal);
    }

    function exerciseDirect(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.FixedAgreement storage agreement = _requireActiveAgreement(store, agreementId);

        LibPositionHelpers.requireOwnership(agreement.borrowerPositionId);
        _enforceExerciseWindow(agreement);
        _settleAgreementPositions(agreement);

        agreement.status = LibEqualLendDirectStorage.AgreementStatus.Exercised;
        DefaultSettlement memory settlement = _settleDefaultPath(store, agreement);

        emit DirectAgreementExercised(
            agreementId, msg.sender, settlement.lenderShare, settlement.treasuryShare, settlement.feeIndexShare
        );
    }

    function callDirect(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.FixedAgreement storage agreement = _requireActiveAgreement(store, agreementId);

        if (!agreement.allowLenderCall) revert DirectError_LenderCallNotAllowed();
        if (block.timestamp >= agreement.dueTimestamp) revert DirectError_InvalidTimestamp();
        LibPositionHelpers.requireOwnership(agreement.lenderPositionId);

        uint64 newDueTimestamp = uint64(block.timestamp);
        agreement.dueTimestamp = newDueTimestamp;

        emit DirectAgreementCalled(agreementId, agreement.lenderPositionId, newDueTimestamp);
    }

    function recover(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.FixedAgreement storage agreement = _requireActiveAgreement(store, agreementId);

        if (block.timestamp < uint256(agreement.dueTimestamp) + FIXED_GRACE_PERIOD) {
            revert DirectError_GracePeriodActive();
        }

        _settleAgreementPositions(agreement);
        agreement.status = LibEqualLendDirectStorage.AgreementStatus.Defaulted;
        DefaultSettlement memory settlement = _settleDefaultPath(store, agreement);

        emit DirectAgreementRecovered(
            agreementId, msg.sender, settlement.lenderShare, settlement.treasuryShare, settlement.feeIndexShare
        );
    }

    function _settleDefaultPath(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.FixedAgreement storage agreement
    ) internal returns (DefaultSettlement memory settlement) {
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(agreement.collateralPoolId);
        settlement = _burnBorrowerCollateralAndSplit(agreement, collateralPool, store.config);

        if (settlement.lenderShare > 0) {
            _creditLenderSettlement(agreement, settlement.lenderShare);
        }
        uint256 routedAmount = settlement.treasuryShare + settlement.activeCreditShare + settlement.feeIndexShare;
        if (routedAmount > 0) {
            LibFeeRouter.routeSamePool(agreement.collateralPoolId, routedAmount, DIRECT_FIXED_DEFAULT_SOURCE, true, 0);
        }

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
                borrowedPrincipalToClear: agreement.principal,
                exposureToClear: agreement.principal,
                collateralToUnlock: agreement.collateralLocked
            })
        );
        _clearAgreementIndexes(store, agreement);
    }

    function _burnBorrowerCollateralAndSplit(
        LibEqualLendDirectStorage.FixedAgreement storage agreement,
        Types.PoolData storage collateralPool,
        LibEqualLendDirectStorage.DirectConfig storage cfg
    ) internal returns (DefaultSettlement memory settlement) {
        uint256 borrowerPrincipal = collateralPool.userPrincipal[agreement.borrowerPositionKey];
        settlement.collateralApplied =
            borrowerPrincipal >= agreement.collateralLocked ? agreement.collateralLocked : borrowerPrincipal;

        if (settlement.collateralApplied == 0) {
            return settlement;
        }

        uint256 newBorrowerPrincipal = borrowerPrincipal - settlement.collateralApplied;
        collateralPool.userPrincipal[agreement.borrowerPositionKey] = newBorrowerPrincipal;
        collateralPool.totalDeposits -= settlement.collateralApplied;
        if (newBorrowerPrincipal == 0 && collateralPool.userCount > 0) {
            collateralPool.userCount -= 1;
        }

        settlement.lenderShare =
            (settlement.collateralApplied * uint256(cfg.defaultLenderBps)) / LibEqualLendDirectStorage.BPS_DENOMINATOR;
        if (settlement.lenderShare > settlement.collateralApplied) {
            settlement.lenderShare = settlement.collateralApplied;
        }

        uint256 remainder = settlement.collateralApplied - settlement.lenderShare;
        if (remainder == 0) {
            return settlement;
        }

        (settlement.treasuryShare, settlement.activeCreditShare, settlement.feeIndexShare) =
            LibFeeRouter.previewSplit(remainder);
    }

    function _creditLenderSettlement(
        LibEqualLendDirectStorage.FixedAgreement storage agreement,
        uint256 lenderShare
    ) internal {
        bool sameAsset = agreement.borrowAsset == agreement.collateralAsset;

        if (sameAsset && agreement.lenderPoolId != agreement.collateralPoolId) {
            Types.PoolData storage collateralPool = LibPositionHelpers.pool(agreement.collateralPoolId);
            Types.PoolData storage lenderPool = LibPositionHelpers.pool(agreement.lenderPoolId);
            _moveTrackedBacking(collateralPool, lenderPool, lenderShare);
            _creditPrincipal(lenderPool, agreement.lenderPositionKey, lenderShare);
            return;
        }

        LibPositionHelpers.ensurePoolMembership(agreement.lenderPositionKey, agreement.collateralPoolId, true);
        _creditPrincipal(LibPositionHelpers.pool(agreement.collateralPoolId), agreement.lenderPositionKey, lenderShare);
    }

    function _creditPrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 amount) internal {
        uint256 principalBefore = pool.userPrincipal[positionKey];
        pool.userPrincipal[positionKey] = principalBefore + amount;
        pool.totalDeposits += amount;
        if (principalBefore == 0) {
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

    function _requireActiveAgreement(LibEqualLendDirectStorage.DirectStorage storage store, uint256 agreementId)
        internal
        view
        returns (LibEqualLendDirectStorage.FixedAgreement storage agreement)
    {
        if (store.agreementKindById[agreementId] != LibEqualLendDirectStorage.AgreementKind.Fixed) {
            revert DirectError_InvalidAgreementState();
        }
        agreement = store.fixedAgreements[agreementId];
        if (agreement.status != LibEqualLendDirectStorage.AgreementStatus.Active) {
            revert DirectError_InvalidAgreementState();
        }
    }

    function _enforceRepayWindow(LibEqualLendDirectStorage.FixedAgreement storage agreement) internal view {
        uint256 dueTimestamp = agreement.dueTimestamp;
        if (block.timestamp > dueTimestamp + FIXED_GRACE_PERIOD) {
            revert DirectError_GracePeriodExpired();
        }
        if (!agreement.allowEarlyRepay && dueTimestamp > FIXED_GRACE_PERIOD) {
            if (block.timestamp < dueTimestamp - FIXED_GRACE_PERIOD) {
                revert DirectError_EarlyRepayNotAllowed();
            }
        }
    }

    function _enforceExerciseWindow(LibEqualLendDirectStorage.FixedAgreement storage agreement) internal view {
        uint256 dueTimestamp = agreement.dueTimestamp;
        if (block.timestamp < dueTimestamp && !agreement.allowEarlyExercise) {
            revert DirectError_EarlyExerciseNotAllowed();
        }
        if (block.timestamp > dueTimestamp + FIXED_GRACE_PERIOD) {
            revert DirectError_GracePeriodExpired();
        }
    }

    function _settleAgreementPositions(LibEqualLendDirectStorage.FixedAgreement storage agreement) internal {
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
        LibEqualLendDirectStorage.FixedAgreement storage agreement
    ) internal {
        LibEqualLendDirectStorage.removeBorrowerAgreement(store, agreement.borrowerPositionKey, agreement.agreementId);
        LibEqualLendDirectStorage.removeLenderAgreement(store, agreement.lenderPositionKey, agreement.agreementId);
    }
}
