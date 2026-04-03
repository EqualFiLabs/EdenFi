// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    DirectError_InvalidConfiguration,
    DirectError_InvalidOffer,
    DirectError_InvalidTimestamp,
    InsufficientPrincipal,
    SolvencyViolation
} from "src/libraries/Errors.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "src/libraries/LibReentrancyGuard.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Rolling agreement acceptance and origination for the clean EqualLend Direct rebuild.
contract EqualLendDirectRollingAgreementFacet is ReentrancyGuardModifiers {
    event RollingLenderOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed borrowerPositionId
    );
    event RollingBorrowerOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed lenderPositionId
    );

    function acceptRollingLenderOffer(
        uint256 offerId,
        uint256 borrowerPositionId,
        uint256 minReceivedLender,
        uint256 minReceivedBorrower
    ) external nonReentrant returns (uint256 agreementId) {
        LibCurrency.assertZeroMsgValue();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingLenderOffer storage offer = store.rollingLenderOffers[offerId];
        if (
            store.offerKindById[offerId] != LibEqualLendDirectStorage.OfferKind.RollingLender || offer.cancelled
                || offer.filled
        ) {
            revert DirectError_InvalidOffer();
        }
        if (offer.lenderPositionId == borrowerPositionId) revert DirectError_InvalidOffer();

        bytes32 borrowerKey = _requireOwnedRollingAcceptancePosition(borrowerPositionId);
        agreementId =
            _acceptRollingLenderOffer(store, offer, borrowerKey, borrowerPositionId, minReceivedLender, minReceivedBorrower);
        emit RollingLenderOfferAccepted(offerId, agreementId, borrowerPositionId);
    }

    function acceptRollingBorrowerOffer(
        uint256 offerId,
        uint256 lenderPositionId,
        uint256 minReceivedLender,
        uint256 minReceivedBorrower
    ) external nonReentrant returns (uint256 agreementId) {
        LibCurrency.assertZeroMsgValue();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingBorrowerOffer storage offer = store.rollingBorrowerOffers[offerId];
        if (
            store.offerKindById[offerId] != LibEqualLendDirectStorage.OfferKind.RollingBorrower || offer.cancelled
                || offer.filled
        ) {
            revert DirectError_InvalidOffer();
        }
        if (offer.borrowerPositionId == lenderPositionId) revert DirectError_InvalidOffer();

        bytes32 lenderKey = _requireOwnedRollingAcceptancePosition(lenderPositionId);
        agreementId =
            _acceptRollingBorrowerOffer(store, offer, lenderKey, lenderPositionId, minReceivedLender, minReceivedBorrower);
        emit RollingBorrowerOfferAccepted(offerId, agreementId, lenderPositionId);
    }

    function _acceptRollingLenderOffer(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.RollingLenderOffer storage offer,
        bytes32 borrowerKey,
        uint256 borrowerPositionId,
        uint256 minReceivedLender,
        uint256 minReceivedBorrower
    ) internal returns (uint256 agreementId) {
        bytes32 lenderKey = offer.lenderPositionKey;
        address borrowerOwner = msg.sender;

        _validateRollingAcceptanceContext(lenderKey, borrowerKey, offer.lenderPoolId, offer.collateralPoolId);

        Types.PoolData storage lenderPool = LibPositionHelpers.pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(offer.collateralPoolId);

        _requireRollingLenderFundingState(lenderPool, lenderKey, offer.lenderPoolId, offer.principal, true);
        _requireRollingBorrowerCollateralState(
            collateralPool,
            borrowerKey,
            offer.collateralPoolId,
            offer.collateralLocked,
            offer.borrowAsset == offer.collateralAsset,
            offer.principal
        );
        _checkRollingLenderSolvency(lenderPool, lenderKey, offer.principal);

        uint64 nextDue = _quoteRollingNextDue(offer.paymentIntervalSeconds);
        if (offer.principal > lenderPool.trackedBalance) {
            revert InsufficientPrincipal(offer.principal, lenderPool.trackedBalance);
        }
        if (offer.upfrontPremium > offer.principal) revert DirectError_InvalidOffer();

        LibEqualLendDirectAccounting.originate(
            store,
            LibEqualLendDirectAccounting.OriginationParams({
                lenderPositionKey: lenderKey,
                borrowerPositionKey: borrowerKey,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: offer.lenderPoolId,
                collateralPoolId: offer.collateralPoolId,
                borrowAsset: offer.borrowAsset,
                collateralAsset: offer.collateralAsset,
                principal: offer.principal,
                collateralToLock: offer.collateralLocked,
                convertOfferEscrow: true,
                lockCollateralNow: true
            })
        );

        agreementId = _storeRollingLenderOfferAgreement(
            store, offer, lenderKey, borrowerKey, borrowerOwner, borrowerPositionId, nextDue
        );

        offer.filled = true;
        LibEqualLendDirectStorage.removeRollingLenderOffer(store, lenderKey, offer.offerId);

        if (offer.upfrontPremium > 0) {
            LibCurrency.transferWithMin(offer.borrowAsset, offer.lender, offer.upfrontPremium, minReceivedLender);
        }
        LibCurrency.transferWithMin(
            offer.borrowAsset, borrowerOwner, offer.principal - offer.upfrontPremium, minReceivedBorrower
        );
    }

    function _acceptRollingBorrowerOffer(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.RollingBorrowerOffer storage offer,
        bytes32 lenderKey,
        uint256 lenderPositionId,
        uint256 minReceivedLender,
        uint256 minReceivedBorrower
    ) internal returns (uint256 agreementId) {
        bytes32 borrowerKey = offer.borrowerPositionKey;

        _validateRollingAcceptanceContext(lenderKey, borrowerKey, offer.lenderPoolId, offer.collateralPoolId);

        Types.PoolData storage lenderPool = LibPositionHelpers.pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(offer.collateralPoolId);

        _requireRollingLenderFundingState(lenderPool, lenderKey, offer.lenderPoolId, offer.principal, false);
        _requireRollingBorrowerOfferLock(borrowerKey, offer.collateralPoolId, offer.collateralLocked);
        _checkRollingLenderSolvency(lenderPool, lenderKey, offer.principal);
        _checkRollingBorrowerSolvency(
            collateralPool,
            borrowerKey,
            offer.borrowAsset == offer.collateralAsset,
            collateralPool.userPrincipal[borrowerKey],
            offer.principal
        );

        uint64 nextDue = _quoteRollingNextDue(offer.paymentIntervalSeconds);
        if (offer.principal > lenderPool.trackedBalance) {
            revert InsufficientPrincipal(offer.principal, lenderPool.trackedBalance);
        }
        if (offer.upfrontPremium > offer.principal) revert DirectError_InvalidOffer();

        LibEqualLendDirectAccounting.originate(
            store,
            LibEqualLendDirectAccounting.OriginationParams({
                lenderPositionKey: lenderKey,
                borrowerPositionKey: borrowerKey,
                borrowerPositionId: offer.borrowerPositionId,
                lenderPoolId: offer.lenderPoolId,
                collateralPoolId: offer.collateralPoolId,
                borrowAsset: offer.borrowAsset,
                collateralAsset: offer.collateralAsset,
                principal: offer.principal,
                collateralToLock: offer.collateralLocked,
                convertOfferEscrow: false,
                lockCollateralNow: false
            })
        );

        agreementId = _storeRollingBorrowerOfferAgreement(
            store, offer, lenderKey, borrowerKey, msg.sender, lenderPositionId, nextDue
        );

        offer.filled = true;
        LibEqualLendDirectStorage.removeRollingBorrowerOffer(store, borrowerKey, offer.offerId);

        if (offer.upfrontPremium > 0) {
            LibCurrency.transferWithMin(offer.borrowAsset, msg.sender, offer.upfrontPremium, minReceivedLender);
        }
        LibCurrency.transferWithMin(
            offer.borrowAsset, offer.borrower, offer.principal - offer.upfrontPremium, minReceivedBorrower
        );
    }

    function _storeRollingLenderOfferAgreement(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.RollingLenderOffer storage offer,
        bytes32 lenderKey,
        bytes32 borrowerKey,
        address borrower,
        uint256 borrowerPositionId,
        uint64 nextDue
    ) internal returns (uint256 agreementId) {
        agreementId = LibEqualLendDirectStorage.allocateAgreementId(store);
        store.agreementKindById[agreementId] = LibEqualLendDirectStorage.AgreementKind.Rolling;
        store.rollingAgreements[agreementId] = LibEqualLendDirectStorage.RollingAgreement({
            agreementId: agreementId,
            kind: LibEqualLendDirectStorage.AgreementKind.Rolling,
            status: LibEqualLendDirectStorage.AgreementStatus.Active,
            lenderPositionKey: lenderKey,
            borrowerPositionKey: borrowerKey,
            lender: offer.lender,
            borrower: borrower,
            lenderPositionId: offer.lenderPositionId,
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: offer.lenderPoolId,
            collateralPoolId: offer.collateralPoolId,
            borrowAsset: offer.borrowAsset,
            collateralAsset: offer.collateralAsset,
            principal: offer.principal,
            outstandingPrincipal: offer.principal,
            collateralLocked: offer.collateralLocked,
            upfrontPremium: offer.upfrontPremium,
            nextDue: nextDue,
            lastAccrualTimestamp: uint64(block.timestamp),
            arrears: 0,
            paymentCount: 0,
            paymentIntervalSeconds: offer.paymentIntervalSeconds,
            rollingApyBps: offer.rollingApyBps,
            gracePeriodSeconds: offer.gracePeriodSeconds,
            maxPaymentCount: offer.maxPaymentCount,
            allowAmortization: offer.allowAmortization,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise
        });
        LibEqualLendDirectStorage.addBorrowerAgreement(store, borrowerKey, agreementId);
        LibEqualLendDirectStorage.addLenderAgreement(store, lenderKey, agreementId);
        LibEqualLendDirectStorage.addRollingBorrowerAgreement(store, borrowerKey, agreementId);
        LibEqualLendDirectStorage.addRollingLenderAgreement(store, lenderKey, agreementId);
    }

    function _storeRollingBorrowerOfferAgreement(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.RollingBorrowerOffer storage offer,
        bytes32 lenderKey,
        bytes32 borrowerKey,
        address lender,
        uint256 lenderPositionId,
        uint64 nextDue
    ) internal returns (uint256 agreementId) {
        agreementId = LibEqualLendDirectStorage.allocateAgreementId(store);
        store.agreementKindById[agreementId] = LibEqualLendDirectStorage.AgreementKind.Rolling;
        store.rollingAgreements[agreementId] = LibEqualLendDirectStorage.RollingAgreement({
            agreementId: agreementId,
            kind: LibEqualLendDirectStorage.AgreementKind.Rolling,
            status: LibEqualLendDirectStorage.AgreementStatus.Active,
            lenderPositionKey: lenderKey,
            borrowerPositionKey: borrowerKey,
            lender: lender,
            borrower: offer.borrower,
            lenderPositionId: lenderPositionId,
            borrowerPositionId: offer.borrowerPositionId,
            lenderPoolId: offer.lenderPoolId,
            collateralPoolId: offer.collateralPoolId,
            borrowAsset: offer.borrowAsset,
            collateralAsset: offer.collateralAsset,
            principal: offer.principal,
            outstandingPrincipal: offer.principal,
            collateralLocked: offer.collateralLocked,
            upfrontPremium: offer.upfrontPremium,
            nextDue: nextDue,
            lastAccrualTimestamp: uint64(block.timestamp),
            arrears: 0,
            paymentCount: 0,
            paymentIntervalSeconds: offer.paymentIntervalSeconds,
            rollingApyBps: offer.rollingApyBps,
            gracePeriodSeconds: offer.gracePeriodSeconds,
            maxPaymentCount: offer.maxPaymentCount,
            allowAmortization: offer.allowAmortization,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise
        });
        LibEqualLendDirectStorage.addBorrowerAgreement(store, borrowerKey, agreementId);
        LibEqualLendDirectStorage.addLenderAgreement(store, lenderKey, agreementId);
        LibEqualLendDirectStorage.addRollingBorrowerAgreement(store, borrowerKey, agreementId);
        LibEqualLendDirectStorage.addRollingLenderAgreement(store, lenderKey, agreementId);
    }

    function _validateRollingAcceptanceContext(
        bytes32 lenderKey,
        bytes32 borrowerKey,
        uint256 lenderPoolId,
        uint256 collateralPoolId
    ) internal {
        LibPositionHelpers.ensurePoolMembership(lenderKey, lenderPoolId, true);
        LibPositionHelpers.ensurePoolMembership(borrowerKey, collateralPoolId, true);
        LibPositionHelpers.settlePosition(lenderPoolId, lenderKey);
        if (collateralPoolId != lenderPoolId || borrowerKey != lenderKey) {
            LibPositionHelpers.settlePosition(collateralPoolId, borrowerKey);
        }
    }

    function _requireRollingLenderFundingState(
        Types.PoolData storage lenderPool,
        bytes32 lenderKey,
        uint256 lenderPoolId,
        uint256 principal,
        bool requireEscrow
    ) internal view {
        uint256 lenderPrincipal = lenderPool.userPrincipal[lenderKey];
        if (lenderPrincipal < principal) {
            revert InsufficientPrincipal(principal, lenderPrincipal);
        }

        if (requireEscrow) {
            uint256 offerEscrow = LibEncumbrance.get(lenderKey, lenderPoolId).offerEscrowedCapital;
            if (offerEscrow < principal) {
                revert InsufficientPrincipal(principal, offerEscrow);
            }
            return;
        }

        uint256 available =
            _availableRollingPrincipal(lenderPool, lenderKey, lenderPoolId, lenderPool.userSameAssetDebt[lenderKey], 0);
        if (principal > available) {
            revert InsufficientPrincipal(principal, available);
        }
    }

    function _requireRollingBorrowerCollateralState(
        Types.PoolData storage collateralPool,
        bytes32 borrowerKey,
        uint256 collateralPoolId,
        uint256 collateralLocked,
        bool sameAsset,
        uint256 principal
    ) internal view returns (uint256 borrowerPrincipal) {
        borrowerPrincipal = collateralPool.userPrincipal[borrowerKey];
        uint256 available = _availableRollingPrincipal(
            collateralPool,
            borrowerKey,
            collateralPoolId,
            collateralPool.userSameAssetDebt[borrowerKey],
            0
        );
        if (collateralLocked > available) {
            revert InsufficientPrincipal(collateralLocked, available);
        }
        _checkRollingBorrowerSolvency(collateralPool, borrowerKey, sameAsset, borrowerPrincipal, principal);
    }

    function _requireRollingBorrowerOfferLock(bytes32 borrowerKey, uint256 collateralPoolId, uint256 collateralLocked)
        internal
        view
    {
        uint256 lockedCapital = LibEncumbrance.get(borrowerKey, collateralPoolId).lockedCapital;
        if (lockedCapital < collateralLocked) {
            revert InsufficientPrincipal(collateralLocked, lockedCapital);
        }
    }

    function _checkRollingLenderSolvency(Types.PoolData storage lenderPool, bytes32 lenderKey, uint256 principal)
        internal
        view
    {
        uint256 currentPrincipal = lenderPool.userPrincipal[lenderKey];
        uint256 debt = lenderPool.userSameAssetDebt[lenderKey];
        uint256 newPrincipal = currentPrincipal > principal ? currentPrincipal - principal : 0;
        if (!_isRollingSolvent(lenderPool, newPrincipal, debt)) {
            revert SolvencyViolation(newPrincipal, debt, lenderPool.poolConfig.depositorLTVBps);
        }
    }

    function _checkRollingBorrowerSolvency(
        Types.PoolData storage collateralPool,
        bytes32 borrowerKey,
        bool sameAsset,
        uint256 borrowerPrincipal,
        uint256 principalIncrease
    ) internal view {
        if (!sameAsset) {
            return;
        }
        uint256 newDebt = collateralPool.userSameAssetDebt[borrowerKey] + principalIncrease;
        if (!_isRollingSolvent(collateralPool, borrowerPrincipal, newDebt)) {
            revert SolvencyViolation(borrowerPrincipal, newDebt, collateralPool.poolConfig.depositorLTVBps);
        }
    }

    function _isRollingSolvent(Types.PoolData storage pool, uint256 principal, uint256 debt)
        internal
        view
        returns (bool)
    {
        if (debt == 0) return true;
        uint16 ltvBps = pool.poolConfig.depositorLTVBps;
        if (ltvBps == 0) return false;
        return debt <= Math.mulDiv(principal, ltvBps, 10_000);
    }

    function _availableRollingPrincipal(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 poolId,
        uint256 sameAssetDebt,
        uint256 extraReserved
    ) internal view returns (uint256 available) {
        uint256 principal = pool.userPrincipal[positionKey];
        uint256 reserved = LibEncumbrance.total(positionKey, poolId) + extraReserved;
        if (sameAssetDebt > reserved) {
            reserved = sameAssetDebt;
        }
        if (reserved >= principal) return 0;
        available = principal - reserved;
    }

    function _quoteRollingNextDue(uint32 paymentIntervalSeconds) internal view returns (uint64 nextDue) {
        if (paymentIntervalSeconds == 0) revert DirectError_InvalidConfiguration();
        uint256 nextDueCalc = block.timestamp + paymentIntervalSeconds;
        if (nextDueCalc > type(uint64).max) revert DirectError_InvalidTimestamp();
        nextDue = uint64(nextDueCalc);
    }

    function _requireOwnedRollingAcceptancePosition(uint256 positionId) internal view returns (bytes32 positionKey) {
        LibPositionHelpers.requireOwnership(positionId);
        positionKey = LibPositionHelpers.positionKey(positionId);
    }
}
