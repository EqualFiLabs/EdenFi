// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Unauthorized} from "src/libraries/Errors.sol";
import {
    DirectError_InvalidAsset,
    DirectError_InvalidConfiguration,
    DirectError_InvalidRatio,
    DirectError_InvalidOffer,
    DirectError_ZeroAmount,
    InsufficientPrincipal
} from "src/libraries/Errors.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Fixed offer posting and cancellation for the clean EqualLend Direct rebuild.
contract EqualLendDirectFixedOfferFacet {
    struct FixedLenderOfferParams {
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principal;
        uint256 collateralLocked;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    struct FixedBorrowerOfferParams {
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principal;
        uint256 collateralLocked;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    struct LenderRatioTrancheOfferParams {
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principalCap;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 minPrincipalPerFill;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    struct BorrowerRatioTrancheOfferParams {
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 collateralCap;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 minCollateralPerFill;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    event FixedLenderOfferPosted(
        uint256 indexed offerId,
        uint256 indexed lenderPositionId,
        uint256 indexed lenderPoolId,
        uint256 collateralPoolId,
        uint256 principal,
        uint256 collateralLocked
    );
    event FixedBorrowerOfferPosted(
        uint256 indexed offerId,
        uint256 indexed borrowerPositionId,
        uint256 indexed lenderPoolId,
        uint256 collateralPoolId,
        uint256 principal,
        uint256 collateralLocked
    );
    event LenderRatioTrancheOfferPosted(
        uint256 indexed offerId,
        uint256 indexed lenderPositionId,
        uint256 indexed lenderPoolId,
        uint256 collateralPoolId,
        uint256 principalCap,
        uint256 principalRemaining,
        uint256 priceNumerator,
        uint256 priceDenominator,
        uint256 minPrincipalPerFill
    );
    event BorrowerRatioTrancheOfferPosted(
        uint256 indexed offerId,
        uint256 indexed borrowerPositionId,
        uint256 indexed lenderPoolId,
        uint256 collateralPoolId,
        uint256 collateralCap,
        uint256 collateralRemaining,
        uint256 priceNumerator,
        uint256 priceDenominator,
        uint256 minCollateralPerFill
    );
    event FixedOfferCancelled(
        uint256 indexed offerId,
        LibEqualLendDirectStorage.OfferKind indexed kind,
        bytes32 indexed positionKey
    );

    function postFixedLenderOffer(FixedLenderOfferParams calldata params) external returns (uint256 offerId) {
        if (params.principal == 0 || params.collateralLocked == 0) revert DirectError_ZeroAmount();
        if (params.durationSeconds == 0) revert DirectError_InvalidConfiguration();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        bytes32 lenderPositionKey = _requireOwnedPosition(params.lenderPositionId);
        Types.PoolData storage lenderPool = LibPositionHelpers.pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(params.collateralPoolId);
        _validateOfferPools(lenderPool, collateralPool, params.borrowAsset, params.collateralAsset);

        LibPositionHelpers.ensurePoolMembership(lenderPositionKey, params.lenderPoolId, true);
        uint256 availablePrincipal = _settledAvailablePrincipal(lenderPool, lenderPositionKey, params.lenderPoolId);
        if (params.principal > availablePrincipal) {
            revert InsufficientPrincipal(params.principal, availablePrincipal);
        }

        offerId = LibEqualLendDirectStorage.allocateOfferId(store);
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.FixedLender;
        store.fixedLenderOffers[offerId] = LibEqualLendDirectStorage.FixedLenderOffer({
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
            aprBps: params.aprBps,
            durationSeconds: params.durationSeconds,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall,
            cancelled: false,
            filled: false
        });
        LibEqualLendDirectStorage.addFixedLenderOffer(store, lenderPositionKey, offerId);
        LibEqualLendDirectAccounting.increaseOfferEscrow(lenderPositionKey, params.lenderPoolId, params.principal);

        emit FixedLenderOfferPosted(
            offerId,
            params.lenderPositionId,
            params.lenderPoolId,
            params.collateralPoolId,
            params.principal,
            params.collateralLocked
        );
    }

    function postFixedBorrowerOffer(FixedBorrowerOfferParams calldata params) external returns (uint256 offerId) {
        if (params.principal == 0 || params.collateralLocked == 0) revert DirectError_ZeroAmount();
        if (params.durationSeconds == 0) revert DirectError_InvalidConfiguration();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        bytes32 borrowerPositionKey = _requireOwnedPosition(params.borrowerPositionId);
        Types.PoolData storage lenderPool = LibPositionHelpers.pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(params.collateralPoolId);
        _validateOfferPools(lenderPool, collateralPool, params.borrowAsset, params.collateralAsset);

        LibPositionHelpers.ensurePoolMembership(borrowerPositionKey, params.collateralPoolId, true);
        uint256 availablePrincipal = _settledAvailablePrincipal(collateralPool, borrowerPositionKey, params.collateralPoolId);
        if (params.collateralLocked > availablePrincipal) {
            revert InsufficientPrincipal(params.collateralLocked, availablePrincipal);
        }

        offerId = LibEqualLendDirectStorage.allocateOfferId(store);
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.FixedBorrower;
        store.fixedBorrowerOffers[offerId] = LibEqualLendDirectStorage.FixedBorrowerOffer({
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
            aprBps: params.aprBps,
            durationSeconds: params.durationSeconds,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall,
            cancelled: false,
            filled: false
        });
        LibEqualLendDirectStorage.addFixedBorrowerOffer(store, borrowerPositionKey, offerId);
        LibEqualLendDirectAccounting.increaseLockedCapital(borrowerPositionKey, params.collateralPoolId, params.collateralLocked);

        emit FixedBorrowerOfferPosted(
            offerId,
            params.borrowerPositionId,
            params.lenderPoolId,
            params.collateralPoolId,
            params.principal,
            params.collateralLocked
        );
    }

    function postLenderRatioTrancheOffer(LenderRatioTrancheOfferParams calldata params) external returns (uint256 offerId) {
        if (params.durationSeconds == 0) revert DirectError_InvalidConfiguration();
        if (
            params.principalCap == 0 || params.priceNumerator == 0 || params.priceDenominator == 0
                || params.minPrincipalPerFill == 0 || params.minPrincipalPerFill > params.principalCap
                || Math.mulDiv(params.minPrincipalPerFill, params.priceNumerator, params.priceDenominator) == 0
        ) {
            revert DirectError_InvalidRatio();
        }

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        bytes32 lenderPositionKey = _requireOwnedPosition(params.lenderPositionId);
        Types.PoolData storage lenderPool = LibPositionHelpers.pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(params.collateralPoolId);
        _validateOfferPools(lenderPool, collateralPool, params.borrowAsset, params.collateralAsset);

        LibPositionHelpers.ensurePoolMembership(lenderPositionKey, params.lenderPoolId, true);
        uint256 availablePrincipal = _settledAvailablePrincipal(lenderPool, lenderPositionKey, params.lenderPoolId);
        if (params.principalCap > availablePrincipal) {
            revert InsufficientPrincipal(params.principalCap, availablePrincipal);
        }

        offerId = LibEqualLendDirectStorage.allocateOfferId(store);
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.RatioTrancheLender;
        store.lenderRatioOffers[offerId] = LibEqualLendDirectStorage.LenderRatioTrancheOffer({
            offerId: offerId,
            lenderPositionKey: lenderPositionKey,
            lender: msg.sender,
            lenderPositionId: params.lenderPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            borrowAsset: params.borrowAsset,
            collateralAsset: params.collateralAsset,
            principalCap: params.principalCap,
            principalRemaining: params.principalCap,
            priceNumerator: params.priceNumerator,
            priceDenominator: params.priceDenominator,
            minPrincipalPerFill: params.minPrincipalPerFill,
            aprBps: params.aprBps,
            durationSeconds: params.durationSeconds,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall,
            cancelled: false,
            filled: false
        });
        LibEqualLendDirectStorage.addLenderRatioOffer(store, lenderPositionKey, offerId);
        LibEqualLendDirectAccounting.increaseOfferEscrow(lenderPositionKey, params.lenderPoolId, params.principalCap);

        emit LenderRatioTrancheOfferPosted(
            offerId,
            params.lenderPositionId,
            params.lenderPoolId,
            params.collateralPoolId,
            params.principalCap,
            params.principalCap,
            params.priceNumerator,
            params.priceDenominator,
            params.minPrincipalPerFill
        );
    }

    function postBorrowerRatioTrancheOffer(BorrowerRatioTrancheOfferParams calldata params)
        external
        returns (uint256 offerId)
    {
        if (params.durationSeconds == 0) revert DirectError_InvalidConfiguration();
        if (
            params.collateralCap == 0 || params.priceNumerator == 0 || params.priceDenominator == 0
                || params.minCollateralPerFill == 0 || params.minCollateralPerFill > params.collateralCap
                || Math.mulDiv(params.minCollateralPerFill, params.priceNumerator, params.priceDenominator) == 0
        ) {
            revert DirectError_InvalidRatio();
        }

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        bytes32 borrowerPositionKey = _requireOwnedPosition(params.borrowerPositionId);
        Types.PoolData storage lenderPool = LibPositionHelpers.pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(params.collateralPoolId);
        _validateOfferPools(lenderPool, collateralPool, params.borrowAsset, params.collateralAsset);

        LibPositionHelpers.ensurePoolMembership(borrowerPositionKey, params.collateralPoolId, true);
        uint256 availablePrincipal = _settledAvailablePrincipal(collateralPool, borrowerPositionKey, params.collateralPoolId);
        if (params.collateralCap > availablePrincipal) {
            revert InsufficientPrincipal(params.collateralCap, availablePrincipal);
        }

        offerId = LibEqualLendDirectStorage.allocateOfferId(store);
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.RatioTrancheBorrower;
        store.borrowerRatioOffers[offerId] = LibEqualLendDirectStorage.BorrowerRatioTrancheOffer({
            offerId: offerId,
            borrowerPositionKey: borrowerPositionKey,
            borrower: msg.sender,
            borrowerPositionId: params.borrowerPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            borrowAsset: params.borrowAsset,
            collateralAsset: params.collateralAsset,
            collateralCap: params.collateralCap,
            collateralRemaining: params.collateralCap,
            priceNumerator: params.priceNumerator,
            priceDenominator: params.priceDenominator,
            minCollateralPerFill: params.minCollateralPerFill,
            aprBps: params.aprBps,
            durationSeconds: params.durationSeconds,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall,
            cancelled: false,
            filled: false
        });
        LibEqualLendDirectStorage.addBorrowerRatioOffer(store, borrowerPositionKey, offerId);
        LibEqualLendDirectAccounting.increaseLockedCapital(
            borrowerPositionKey, params.collateralPoolId, params.collateralCap
        );

        emit BorrowerRatioTrancheOfferPosted(
            offerId,
            params.borrowerPositionId,
            params.lenderPoolId,
            params.collateralPoolId,
            params.collateralCap,
            params.collateralCap,
            params.priceNumerator,
            params.priceDenominator,
            params.minCollateralPerFill
        );
    }

    function cancelFixedOffer(uint256 offerId) external {
        LibEqualLendDirectStorage.OfferKind kind = LibEqualLendDirectStorage.s().offerKindById[offerId];
        if (kind == LibEqualLendDirectStorage.OfferKind.FixedLender) {
            _cancelFixedLenderOffer(offerId, true);
            return;
        }
        if (kind == LibEqualLendDirectStorage.OfferKind.FixedBorrower) {
            _cancelFixedBorrowerOffer(offerId, true);
            return;
        }
        revert DirectError_InvalidOffer();
    }

    function cancelLenderRatioTrancheOffer(uint256 offerId) external {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        if (store.offerKindById[offerId] != LibEqualLendDirectStorage.OfferKind.RatioTrancheLender) {
            revert DirectError_InvalidOffer();
        }
        _cancelLenderRatioTrancheOffer(offerId, true);
    }

    function cancelBorrowerRatioTrancheOffer(uint256 offerId) external {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        if (store.offerKindById[offerId] != LibEqualLendDirectStorage.OfferKind.RatioTrancheBorrower) {
            revert DirectError_InvalidOffer();
        }
        _cancelBorrowerRatioTrancheOffer(offerId, true);
    }

    function cancelOffersForPosition(bytes32 positionKey) external {
        address positionNft = LibPositionNFT.s().positionNFTContract;
        if (msg.sender != positionNft) revert Unauthorized();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        while (LibEqualLendDirectStorage.count(store.fixedLenderOfferIndex, positionKey) > 0) {
            uint256[] storage lenderOffers = LibEqualLendDirectStorage.ids(store.fixedLenderOfferIndex, positionKey);
            _cancelFixedLenderOffer(lenderOffers[lenderOffers.length - 1], false);
        }
        while (LibEqualLendDirectStorage.count(store.fixedBorrowerOfferIndex, positionKey) > 0) {
            uint256[] storage borrowerOffers = LibEqualLendDirectStorage.ids(store.fixedBorrowerOfferIndex, positionKey);
            _cancelFixedBorrowerOffer(borrowerOffers[borrowerOffers.length - 1], false);
        }
        while (LibEqualLendDirectStorage.count(store.lenderRatioOfferIndex, positionKey) > 0) {
            uint256[] storage lenderRatioOffers = LibEqualLendDirectStorage.ids(store.lenderRatioOfferIndex, positionKey);
            _cancelLenderRatioTrancheOffer(lenderRatioOffers[lenderRatioOffers.length - 1], false);
        }
        while (LibEqualLendDirectStorage.count(store.borrowerRatioOfferIndex, positionKey) > 0) {
            uint256[] storage borrowerRatioOffers =
                LibEqualLendDirectStorage.ids(store.borrowerRatioOfferIndex, positionKey);
            _cancelBorrowerRatioTrancheOffer(borrowerRatioOffers[borrowerRatioOffers.length - 1], false);
        }
        while (LibEqualLendDirectStorage.count(store.rollingLenderOfferIndex, positionKey) > 0) {
            uint256[] storage lenderRollingOffers = LibEqualLendDirectStorage.ids(store.rollingLenderOfferIndex, positionKey);
            _cancelRollingLenderOffer(lenderRollingOffers[lenderRollingOffers.length - 1], false);
        }
        while (LibEqualLendDirectStorage.count(store.rollingBorrowerOfferIndex, positionKey) > 0) {
            uint256[] storage borrowerRollingOffers =
                LibEqualLendDirectStorage.ids(store.rollingBorrowerOfferIndex, positionKey);
            _cancelRollingBorrowerOffer(borrowerRollingOffers[borrowerRollingOffers.length - 1], false);
        }
    }

    function hasOpenOffers(bytes32 positionKey) external view returns (bool) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return LibEqualLendDirectStorage.count(store.fixedLenderOfferIndex, positionKey) != 0
            || LibEqualLendDirectStorage.count(store.fixedBorrowerOfferIndex, positionKey) != 0
            || LibEqualLendDirectStorage.count(store.lenderRatioOfferIndex, positionKey) != 0
            || LibEqualLendDirectStorage.count(store.borrowerRatioOfferIndex, positionKey) != 0
            || LibEqualLendDirectStorage.count(store.rollingLenderOfferIndex, positionKey) != 0
            || LibEqualLendDirectStorage.count(store.rollingBorrowerOfferIndex, positionKey) != 0;
    }

    function getPositionTokenURI(uint256) external pure returns (string memory) {
        return "";
    }

    function _cancelFixedLenderOffer(uint256 offerId, bool enforceOwner) internal {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.FixedLenderOffer storage offer = store.fixedLenderOffers[offerId];
        if (offer.offerId == 0 || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (enforceOwner) {
            _requireOwnedPosition(offer.lenderPositionId);
        }

        offer.cancelled = true;
        LibEqualLendDirectStorage.removeFixedLenderOffer(store, offer.lenderPositionKey, offerId);
        LibEqualLendDirectAccounting.decreaseOfferEscrow(offer.lenderPositionKey, offer.lenderPoolId, offer.principal);

        emit FixedOfferCancelled(offerId, LibEqualLendDirectStorage.OfferKind.FixedLender, offer.lenderPositionKey);
    }

    function _cancelFixedBorrowerOffer(uint256 offerId, bool enforceOwner) internal {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.FixedBorrowerOffer storage offer = store.fixedBorrowerOffers[offerId];
        if (offer.offerId == 0 || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (enforceOwner) {
            _requireOwnedPosition(offer.borrowerPositionId);
        }

        offer.cancelled = true;
        LibEqualLendDirectStorage.removeFixedBorrowerOffer(store, offer.borrowerPositionKey, offerId);
        LibEqualLendDirectAccounting.decreaseLockedCapital(
            offer.borrowerPositionKey, offer.collateralPoolId, offer.collateralLocked
        );

        emit FixedOfferCancelled(offerId, LibEqualLendDirectStorage.OfferKind.FixedBorrower, offer.borrowerPositionKey);
    }

    function _cancelLenderRatioTrancheOffer(uint256 offerId, bool enforceOwner) internal {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.LenderRatioTrancheOffer storage offer = store.lenderRatioOffers[offerId];
        if (offer.offerId == 0 || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (enforceOwner) {
            _requireOwnedPosition(offer.lenderPositionId);
        }

        uint256 releaseAmount = offer.principalRemaining;
        offer.cancelled = true;
        offer.filled = true;
        offer.principalRemaining = 0;
        LibEqualLendDirectStorage.removeLenderRatioOffer(store, offer.lenderPositionKey, offerId);
        LibEqualLendDirectAccounting.decreaseOfferEscrow(offer.lenderPositionKey, offer.lenderPoolId, releaseAmount);

        emit FixedOfferCancelled(
            offerId, LibEqualLendDirectStorage.OfferKind.RatioTrancheLender, offer.lenderPositionKey
        );
    }

    function _cancelBorrowerRatioTrancheOffer(uint256 offerId, bool enforceOwner) internal {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.BorrowerRatioTrancheOffer storage offer = store.borrowerRatioOffers[offerId];
        if (offer.offerId == 0 || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (enforceOwner) {
            _requireOwnedPosition(offer.borrowerPositionId);
        }

        uint256 releaseAmount = offer.collateralRemaining;
        offer.cancelled = true;
        offer.filled = true;
        offer.collateralRemaining = 0;
        LibEqualLendDirectStorage.removeBorrowerRatioOffer(store, offer.borrowerPositionKey, offerId);
        LibEqualLendDirectAccounting.decreaseLockedCapital(
            offer.borrowerPositionKey, offer.collateralPoolId, releaseAmount
        );

        emit FixedOfferCancelled(
            offerId, LibEqualLendDirectStorage.OfferKind.RatioTrancheBorrower, offer.borrowerPositionKey
        );
    }

    function _cancelRollingLenderOffer(uint256 offerId, bool enforceOwner) internal {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingLenderOffer storage offer = store.rollingLenderOffers[offerId];
        if (offer.offerId == 0 || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (enforceOwner) {
            _requireOwnedPosition(offer.lenderPositionId);
        }

        offer.cancelled = true;
        LibEqualLendDirectStorage.removeRollingLenderOffer(store, offer.lenderPositionKey, offerId);
        LibEqualLendDirectAccounting.decreaseOfferEscrow(offer.lenderPositionKey, offer.lenderPoolId, offer.principal);

        emit FixedOfferCancelled(offerId, LibEqualLendDirectStorage.OfferKind.RollingLender, offer.lenderPositionKey);
    }

    function _cancelRollingBorrowerOffer(uint256 offerId, bool enforceOwner) internal {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.RollingBorrowerOffer storage offer = store.rollingBorrowerOffers[offerId];
        if (offer.offerId == 0 || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (enforceOwner) {
            _requireOwnedPosition(offer.borrowerPositionId);
        }

        offer.cancelled = true;
        LibEqualLendDirectStorage.removeRollingBorrowerOffer(store, offer.borrowerPositionKey, offerId);
        LibEqualLendDirectAccounting.decreaseLockedCapital(
            offer.borrowerPositionKey, offer.collateralPoolId, offer.collateralLocked
        );

        emit FixedOfferCancelled(offerId, LibEqualLendDirectStorage.OfferKind.RollingBorrower, offer.borrowerPositionKey);
    }

    function _requireOwnedPosition(uint256 positionId) internal view returns (bytes32 positionKey) {
        LibPositionHelpers.requireOwnership(positionId);
        positionKey = LibPositionHelpers.positionKey(positionId);
    }

    function _validateOfferPools(
        Types.PoolData storage lenderPool,
        Types.PoolData storage collateralPool,
        address borrowAsset,
        address collateralAsset
    ) internal view {
        if (lenderPool.underlying != borrowAsset) revert DirectError_InvalidAsset();
        if (collateralPool.underlying != collateralAsset) revert DirectError_InvalidAsset();
    }

    function _settledAvailablePrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 poolId)
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
