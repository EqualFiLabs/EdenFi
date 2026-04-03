// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    DirectError_InvalidAsset,
    DirectError_InvalidConfiguration,
    DirectError_InvalidOffer,
    DirectError_ZeroAmount,
    InsufficientPrincipal,
    RollingError_ExcessivePremium,
    RollingError_InvalidAPY,
    RollingError_InvalidGracePeriod,
    RollingError_InvalidInterval,
    RollingError_InvalidPaymentCount
} from "src/libraries/Errors.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Rolling offer posting and cancellation for the clean EqualLend Direct rebuild.
contract EqualLendDirectRollingOfferFacet {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    struct RollingLenderOfferParams {
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principal;
        uint256 collateralLocked;
        uint32 paymentIntervalSeconds;
        uint16 rollingApyBps;
        uint32 gracePeriodSeconds;
        uint16 maxPaymentCount;
        uint256 upfrontPremium;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
    }

    struct RollingBorrowerOfferParams {
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principal;
        uint256 collateralLocked;
        uint32 paymentIntervalSeconds;
        uint16 rollingApyBps;
        uint32 gracePeriodSeconds;
        uint16 maxPaymentCount;
        uint256 upfrontPremium;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
    }

    event RollingLenderOfferPosted(
        uint256 indexed offerId,
        uint256 indexed lenderPositionId,
        uint256 indexed lenderPoolId,
        uint256 collateralPoolId,
        uint256 principal,
        uint256 collateralLocked
    );
    event RollingBorrowerOfferPosted(
        uint256 indexed offerId,
        uint256 indexed borrowerPositionId,
        uint256 indexed lenderPoolId,
        uint256 collateralPoolId,
        uint256 principal,
        uint256 collateralLocked
    );
    event RollingOfferCancelled(
        uint256 indexed offerId,
        LibEqualLendDirectStorage.OfferKind indexed kind,
        bytes32 indexed positionKey
    );

    function postRollingLenderOffer(RollingLenderOfferParams calldata params) external returns (uint256 offerId) {
        if (params.principal == 0 || params.collateralLocked == 0) revert DirectError_ZeroAmount();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _validateRollingParams(store.rollingConfig, params.principal, params.paymentIntervalSeconds, params.rollingApyBps, params.gracePeriodSeconds, params.maxPaymentCount, params.upfrontPremium);

        bytes32 lenderPositionKey = _requireOwnedRollingPositionKey(params.lenderPositionId);
        Types.PoolData storage lenderPool = LibPositionHelpers.pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(params.collateralPoolId);
        _validateRollingOfferPools(lenderPool, collateralPool, params.borrowAsset, params.collateralAsset);

        LibPositionHelpers.ensurePoolMembership(lenderPositionKey, params.lenderPoolId, true);
        uint256 availablePrincipal = _settledRollingAvailablePrincipal(lenderPool, lenderPositionKey, params.lenderPoolId);
        if (params.principal > availablePrincipal) {
            revert InsufficientPrincipal(params.principal, availablePrincipal);
        }

        offerId = LibEqualLendDirectStorage.allocateOfferId(store);
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.RollingLender;
        store.rollingLenderOffers[offerId] = LibEqualLendDirectStorage.RollingLenderOffer({
            offerId: offerId,
            lenderPositionKey: lenderPositionKey,
            lender: msg.sender,
            lenderPositionId: params.lenderPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            borrowAsset: params.borrowAsset,
            collateralAsset: params.collateralAsset,
            principal: params.principal,
            collateralLocked: params.collateralLocked,
            paymentIntervalSeconds: params.paymentIntervalSeconds,
            rollingApyBps: params.rollingApyBps,
            gracePeriodSeconds: params.gracePeriodSeconds,
            maxPaymentCount: params.maxPaymentCount,
            upfrontPremium: params.upfrontPremium,
            allowAmortization: params.allowAmortization,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            cancelled: false,
            filled: false
        });
        LibEqualLendDirectStorage.addRollingLenderOffer(store, lenderPositionKey, offerId);
        LibEqualLendDirectAccounting.increaseOfferEscrow(lenderPositionKey, params.lenderPoolId, params.principal);

        emit RollingLenderOfferPosted(
            offerId,
            params.lenderPositionId,
            params.lenderPoolId,
            params.collateralPoolId,
            params.principal,
            params.collateralLocked
        );
    }

    function postRollingBorrowerOffer(RollingBorrowerOfferParams calldata params) external returns (uint256 offerId) {
        if (params.principal == 0 || params.collateralLocked == 0) revert DirectError_ZeroAmount();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _validateRollingParams(store.rollingConfig, params.principal, params.paymentIntervalSeconds, params.rollingApyBps, params.gracePeriodSeconds, params.maxPaymentCount, params.upfrontPremium);

        bytes32 borrowerPositionKey = _requireOwnedRollingPositionKey(params.borrowerPositionId);
        Types.PoolData storage lenderPool = LibPositionHelpers.pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(params.collateralPoolId);
        _validateRollingOfferPools(lenderPool, collateralPool, params.borrowAsset, params.collateralAsset);

        LibPositionHelpers.ensurePoolMembership(borrowerPositionKey, params.collateralPoolId, true);
        uint256 availablePrincipal =
            _settledRollingAvailablePrincipal(collateralPool, borrowerPositionKey, params.collateralPoolId);
        if (params.collateralLocked > availablePrincipal) {
            revert InsufficientPrincipal(params.collateralLocked, availablePrincipal);
        }

        offerId = LibEqualLendDirectStorage.allocateOfferId(store);
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.RollingBorrower;
        store.rollingBorrowerOffers[offerId] = LibEqualLendDirectStorage.RollingBorrowerOffer({
            offerId: offerId,
            borrowerPositionKey: borrowerPositionKey,
            borrower: msg.sender,
            borrowerPositionId: params.borrowerPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            borrowAsset: params.borrowAsset,
            collateralAsset: params.collateralAsset,
            principal: params.principal,
            collateralLocked: params.collateralLocked,
            paymentIntervalSeconds: params.paymentIntervalSeconds,
            rollingApyBps: params.rollingApyBps,
            gracePeriodSeconds: params.gracePeriodSeconds,
            maxPaymentCount: params.maxPaymentCount,
            upfrontPremium: params.upfrontPremium,
            allowAmortization: params.allowAmortization,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            cancelled: false,
            filled: false
        });
        LibEqualLendDirectStorage.addRollingBorrowerOffer(store, borrowerPositionKey, offerId);
        LibEqualLendDirectAccounting.increaseLockedCapital(borrowerPositionKey, params.collateralPoolId, params.collateralLocked);

        emit RollingBorrowerOfferPosted(
            offerId,
            params.borrowerPositionId,
            params.lenderPoolId,
            params.collateralPoolId,
            params.principal,
            params.collateralLocked
        );
    }

    function cancelRollingOffer(uint256 offerId) external {
        LibEqualLendDirectStorage.OfferKind kind = LibEqualLendDirectStorage.s().offerKindById[offerId];
        if (kind == LibEqualLendDirectStorage.OfferKind.RollingLender) {
            _cancelRollingLenderOfferManual(offerId, true);
            return;
        }
        if (kind == LibEqualLendDirectStorage.OfferKind.RollingBorrower) {
            _cancelRollingBorrowerOfferManual(offerId, true);
            return;
        }
        revert DirectError_InvalidOffer();
    }

    function _cancelRollingLenderOfferManual(uint256 offerId, bool enforceOwner) internal {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingLenderOffer storage offer = store.rollingLenderOffers[offerId];
        if (offer.offerId == 0 || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (enforceOwner) {
            _requireOwnedRollingPositionKey(offer.lenderPositionId);
        }

        offer.cancelled = true;
        LibEqualLendDirectStorage.removeRollingLenderOffer(store, offer.lenderPositionKey, offerId);
        LibEqualLendDirectAccounting.decreaseOfferEscrow(offer.lenderPositionKey, offer.lenderPoolId, offer.principal);

        emit RollingOfferCancelled(offerId, LibEqualLendDirectStorage.OfferKind.RollingLender, offer.lenderPositionKey);
    }

    function _cancelRollingBorrowerOfferManual(uint256 offerId, bool enforceOwner) internal {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingBorrowerOffer storage offer = store.rollingBorrowerOffers[offerId];
        if (offer.offerId == 0 || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (enforceOwner) {
            _requireOwnedRollingPositionKey(offer.borrowerPositionId);
        }

        offer.cancelled = true;
        LibEqualLendDirectStorage.removeRollingBorrowerOffer(store, offer.borrowerPositionKey, offerId);
        LibEqualLendDirectAccounting.decreaseLockedCapital(
            offer.borrowerPositionKey, offer.collateralPoolId, offer.collateralLocked
        );

        emit RollingOfferCancelled(
            offerId, LibEqualLendDirectStorage.OfferKind.RollingBorrower, offer.borrowerPositionKey
        );
    }

    function _validateRollingParams(
        LibEqualLendDirectStorage.DirectRollingConfig storage cfg,
        uint256 principal,
        uint32 paymentIntervalSeconds,
        uint16 rollingApyBps,
        uint32 gracePeriodSeconds,
        uint16 maxPaymentCount,
        uint256 upfrontPremium
    ) internal view {
        LibEqualLendDirectStorage.validateRollingConfig(cfg);
        if (paymentIntervalSeconds < cfg.minPaymentIntervalSeconds) {
            revert RollingError_InvalidInterval(paymentIntervalSeconds, cfg.minPaymentIntervalSeconds);
        }
        if (maxPaymentCount > cfg.maxPaymentCount) {
            revert RollingError_InvalidPaymentCount(maxPaymentCount, cfg.maxPaymentCount);
        }
        if (gracePeriodSeconds >= paymentIntervalSeconds) {
            revert RollingError_InvalidGracePeriod(gracePeriodSeconds, paymentIntervalSeconds);
        }
        if (rollingApyBps < cfg.minRollingApyBps || rollingApyBps > cfg.maxRollingApyBps) {
            revert RollingError_InvalidAPY(rollingApyBps, cfg.minRollingApyBps, cfg.maxRollingApyBps);
        }
        uint256 maxPremium = (principal * cfg.maxUpfrontPremiumBps) / BPS_DENOMINATOR;
        if (upfrontPremium > maxPremium) {
            revert RollingError_ExcessivePremium(upfrontPremium, maxPremium);
        }
    }

    function _requireOwnedRollingPositionKey(uint256 positionId) internal view returns (bytes32 positionKey) {
        LibPositionHelpers.requireOwnership(positionId);
        positionKey = LibPositionHelpers.positionKey(positionId);
    }

    function _validateRollingOfferPools(
        Types.PoolData storage lenderPool,
        Types.PoolData storage collateralPool,
        address borrowAsset,
        address collateralAsset
    ) internal view {
        if (lenderPool.underlying != borrowAsset) revert DirectError_InvalidAsset();
        if (collateralPool.underlying != collateralAsset) revert DirectError_InvalidAsset();
    }

    function _settledRollingAvailablePrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 poolId)
        internal
        returns (uint256 availablePrincipal)
    {
        LibPositionHelpers.settlePosition(poolId, positionKey);
        uint256 principal = pool.userPrincipal[positionKey];
        uint256 reserved = LibEncumbrance.total(positionKey, poolId);
        uint256 sameAssetDebt = pool.userSameAssetDebt[positionKey];
        if (sameAssetDebt > reserved) {
            reserved = sameAssetDebt;
        }
        if (reserved >= principal) {
            return 0;
        }
        availablePrincipal = principal - reserved;
    }
}
