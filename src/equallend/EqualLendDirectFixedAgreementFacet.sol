// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    DirectError_InvalidFillAmount,
    DirectError_InvalidConfiguration,
    DirectError_InvalidOffer,
    DirectError_InvalidRatio,
    DirectError_InvalidTimestamp,
    InsufficientPrincipal,
    SolvencyViolation
} from "src/libraries/Errors.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibFeeRouter} from "src/libraries/LibFeeRouter.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "src/libraries/LibReentrancyGuard.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Fixed agreement acceptance and origination for the clean EqualLend Direct rebuild.
contract EqualLendDirectFixedAgreementFacet is ReentrancyGuardModifiers {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant YEAR = 365 days;

    struct FixedFeeQuote {
        uint256 platformFee;
        uint256 interestAmount;
        uint256 totalFee;
        uint64 dueTimestamp;
    }

    struct LenderAgreementParams {
        bytes32 lenderPositionKey;
        bytes32 borrowerPositionKey;
        address lender;
        address borrower;
        uint256 lenderPositionId;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principal;
        uint256 userInterest;
        uint64 dueTimestamp;
        uint256 collateralLocked;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    struct LenderRatioFillContext {
        bytes32 lenderKey;
        address borrowerOwner;
        uint256 collateralRequired;
        FixedFeeQuote quote;
    }

    struct BorrowerAgreementParams {
        bytes32 lenderPositionKey;
        bytes32 borrowerPositionKey;
        address lender;
        address borrower;
        uint256 lenderPositionId;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principal;
        uint256 userInterest;
        uint64 dueTimestamp;
        uint256 collateralLocked;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    struct BorrowerRatioFillContext {
        bytes32 lenderKey;
        bytes32 borrowerKey;
        address lenderOwner;
        uint256 principalAmount;
        FixedFeeQuote quote;
    }

    bytes32 internal constant DIRECT_FIXED_INTEREST_FEE_SOURCE = keccak256("DIRECT_FIXED_INTEREST");
    bytes32 internal constant DIRECT_FIXED_PLATFORM_FEE_SOURCE = keccak256("DIRECT_FIXED_PLATFORM");

    event FixedLenderOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed borrowerPositionId
    );
    event FixedBorrowerOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed lenderPositionId
    );
    event LenderRatioTrancheOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed borrowerPositionId,
        uint256 principalFilled,
        uint256 principalRemaining,
        uint256 collateralLocked
    );
    event BorrowerRatioTrancheOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed lenderPositionId,
        uint256 collateralFilled,
        uint256 collateralRemaining,
        uint256 principalAmount
    );

    function acceptFixedLenderOffer(uint256 offerId, uint256 borrowerPositionId, uint256 minReceived)
        external
        nonReentrant
        returns (uint256 agreementId)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.FixedLenderOffer storage offer = store.fixedLenderOffers[offerId];
        if (store.offerKindById[offerId] != LibEqualLendDirectStorage.OfferKind.FixedLender || offer.cancelled || offer.filled)
        {
            revert DirectError_InvalidOffer();
        }
        if (offer.lenderPositionId == borrowerPositionId) revert DirectError_InvalidOffer();

        bytes32 borrowerKey = _requireOwnedAcceptancePosition(borrowerPositionId);
        agreementId = _acceptFixedLenderOffer(store, offer, borrowerKey, borrowerPositionId, minReceived);
        emit FixedLenderOfferAccepted(offerId, agreementId, borrowerPositionId);
    }

    function acceptFixedBorrowerOffer(uint256 offerId, uint256 lenderPositionId, uint256 minReceived)
        external
        nonReentrant
        returns (uint256 agreementId)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.FixedBorrowerOffer storage offer = store.fixedBorrowerOffers[offerId];
        if (
            store.offerKindById[offerId] != LibEqualLendDirectStorage.OfferKind.FixedBorrower || offer.cancelled
                || offer.filled
        ) {
            revert DirectError_InvalidOffer();
        }
        if (offer.borrowerPositionId == lenderPositionId) revert DirectError_InvalidOffer();

        bytes32 lenderKey = _requireOwnedAcceptancePosition(lenderPositionId);
        agreementId = _acceptFixedBorrowerOffer(store, offer, lenderKey, lenderPositionId, minReceived);
        emit FixedBorrowerOfferAccepted(offerId, agreementId, lenderPositionId);
    }

    function acceptLenderRatioTrancheOffer(
        uint256 offerId,
        uint256 borrowerPositionId,
        uint256 principalAmount,
        uint256 minReceived
    ) external nonReentrant returns (uint256 agreementId) {
        if (principalAmount == 0) revert DirectError_InvalidFillAmount();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.LenderRatioTrancheOffer storage offer = store.lenderRatioOffers[offerId];
        if (
            store.offerKindById[offerId] != LibEqualLendDirectStorage.OfferKind.RatioTrancheLender || offer.cancelled
                || offer.filled
        ) {
            revert DirectError_InvalidOffer();
        }
        if (offer.lenderPositionId == borrowerPositionId) revert DirectError_InvalidOffer();

        bytes32 borrowerKey = _requireOwnedAcceptancePosition(borrowerPositionId);
        agreementId = _acceptLenderRatioTrancheOffer(store, offer, borrowerKey, borrowerPositionId, principalAmount, minReceived);

        emit LenderRatioTrancheOfferAccepted(
            offerId,
            agreementId,
            borrowerPositionId,
            principalAmount,
            offer.principalRemaining,
            store.fixedAgreements[agreementId].collateralLocked
        );
    }

    function acceptBorrowerRatioTrancheOffer(
        uint256 offerId,
        uint256 lenderPositionId,
        uint256 collateralAmount,
        uint256 minReceived
    ) external nonReentrant returns (uint256 agreementId) {
        if (collateralAmount == 0) revert DirectError_InvalidFillAmount();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        LibEqualLendDirectStorage.BorrowerRatioTrancheOffer storage offer = store.borrowerRatioOffers[offerId];
        if (
            store.offerKindById[offerId] != LibEqualLendDirectStorage.OfferKind.RatioTrancheBorrower || offer.cancelled
                || offer.filled
        ) {
            revert DirectError_InvalidOffer();
        }
        if (offer.borrowerPositionId == lenderPositionId) revert DirectError_InvalidOffer();

        agreementId = _acceptBorrowerRatioTrancheOffer(store, offer, lenderPositionId, collateralAmount, minReceived);

        emit BorrowerRatioTrancheOfferAccepted(
            offerId,
            agreementId,
            lenderPositionId,
            collateralAmount,
            offer.collateralRemaining,
            store.fixedAgreements[agreementId].principal
        );
    }

    function _acceptFixedLenderOffer(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.FixedLenderOffer storage offer,
        bytes32 borrowerKey,
        uint256 borrowerPositionId,
        uint256 minReceived
    ) internal returns (uint256 agreementId) {
        bytes32 lenderKey = offer.lenderPositionKey;
        address borrowerOwner = msg.sender;

        _validateAcceptanceContext(lenderKey, borrowerKey, offer.lenderPoolId, offer.collateralPoolId);

        Types.PoolData storage lenderPool = LibPositionHelpers.pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(offer.collateralPoolId);

        _requireLenderFundingState(lenderPool, lenderKey, offer.lenderPoolId, offer.principal, true);
        _requireBorrowerCollateralState(
            collateralPool, borrowerKey, offer.collateralPoolId, offer.collateralLocked, offer.borrowAsset == offer.collateralAsset, offer.principal
        );
        _checkLenderSolvency(lenderPool, lenderKey, offer.principal);

        FixedFeeQuote memory quote = _quoteFixedFees(offer.principal, offer.aprBps, offer.durationSeconds, store.config);
        if (offer.principal > lenderPool.trackedBalance) {
            revert InsufficientPrincipal(offer.principal, lenderPool.trackedBalance);
        }

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

        agreementId =
            _storeLenderOfferAgreement(
                store, offer, lenderKey, borrowerKey, borrowerOwner, borrowerPositionId, quote.interestAmount, quote.dueTimestamp
            );

        offer.filled = true;
        LibEqualLendDirectStorage.removeFixedLenderOffer(store, lenderKey, offer.offerId);

        LibCurrency.transferWithMin(offer.borrowAsset, borrowerOwner, offer.principal - quote.totalFee, minReceived);
        _distributeLenderOfferFees(lenderPool, lenderKey, store.config, offer, quote);
    }

    function _acceptFixedBorrowerOffer(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.FixedBorrowerOffer storage offer,
        bytes32 lenderKey,
        uint256 lenderPositionId,
        uint256 minReceived
    ) internal returns (uint256 agreementId) {
        bytes32 borrowerKey = offer.borrowerPositionKey;
        Types.PoolData storage lenderPool = LibPositionHelpers.pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(offer.collateralPoolId);

        _validateAcceptanceContext(lenderKey, borrowerKey, offer.lenderPoolId, offer.collateralPoolId);
        _requireLenderFundingState(lenderPool, lenderKey, offer.lenderPoolId, offer.principal, false);
        _requireBorrowerOfferLock(borrowerKey, offer.collateralPoolId, offer.collateralLocked);
        _checkLenderSolvency(lenderPool, lenderKey, offer.principal);
        _checkBorrowerSolvency(
            collateralPool,
            borrowerKey,
            offer.borrowAsset == offer.collateralAsset,
            collateralPool.userPrincipal[borrowerKey],
            offer.principal
        );

        FixedFeeQuote memory quote = _quoteFixedFees(offer.principal, offer.aprBps, offer.durationSeconds, store.config);
        if (offer.principal > lenderPool.trackedBalance) {
            revert InsufficientPrincipal(offer.principal, lenderPool.trackedBalance);
        }

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

        agreementId =
            _storeBorrowerOfferAgreement(
                store, offer, lenderKey, borrowerKey, msg.sender, lenderPositionId, quote.interestAmount, quote.dueTimestamp
            );

        offer.filled = true;
        LibEqualLendDirectStorage.removeFixedBorrowerOffer(store, borrowerKey, offer.offerId);

        LibCurrency.transferWithMin(offer.borrowAsset, offer.borrower, offer.principal - quote.totalFee, minReceived);
        _distributeBorrowerOfferFees(lenderPool, lenderKey, store.config, offer, quote);
    }

    function _acceptLenderRatioTrancheOffer(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.LenderRatioTrancheOffer storage offer,
        bytes32 borrowerKey,
        uint256 borrowerPositionId,
        uint256 principalAmount,
        uint256 minReceived
    ) internal returns (uint256 agreementId) {
        if (principalAmount < offer.minPrincipalPerFill || principalAmount > offer.principalRemaining) {
            revert DirectError_InvalidFillAmount();
        }

        LenderRatioFillContext memory ctx;
        ctx.lenderKey = offer.lenderPositionKey;
        ctx.borrowerOwner = msg.sender;
        ctx.collateralRequired = _validateLenderRatioFill(offer, borrowerKey, principalAmount, ctx.lenderKey);
        ctx.quote = _quoteFixedFees(principalAmount, offer.aprBps, offer.durationSeconds, store.config);

        Types.PoolData storage lenderPool = LibPositionHelpers.pool(offer.lenderPoolId);
        if (principalAmount > lenderPool.trackedBalance) {
            revert InsufficientPrincipal(principalAmount, lenderPool.trackedBalance);
        }

        LibEqualLendDirectAccounting.originate(
            store,
            LibEqualLendDirectAccounting.OriginationParams({
                lenderPositionKey: ctx.lenderKey,
                borrowerPositionKey: borrowerKey,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: offer.lenderPoolId,
                collateralPoolId: offer.collateralPoolId,
                borrowAsset: offer.borrowAsset,
                collateralAsset: offer.collateralAsset,
                principal: principalAmount,
                collateralToLock: ctx.collateralRequired,
                convertOfferEscrow: true,
                lockCollateralNow: true
            })
        );

        agreementId = _storeLenderAgreement(
            store,
            LenderAgreementParams({
                lenderPositionKey: ctx.lenderKey,
                borrowerPositionKey: borrowerKey,
                lender: offer.lender,
                borrower: ctx.borrowerOwner,
                lenderPositionId: offer.lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: offer.lenderPoolId,
                collateralPoolId: offer.collateralPoolId,
                borrowAsset: offer.borrowAsset,
                collateralAsset: offer.collateralAsset,
                principal: principalAmount,
                userInterest: ctx.quote.interestAmount,
                dueTimestamp: ctx.quote.dueTimestamp,
                collateralLocked: ctx.collateralRequired,
                allowEarlyRepay: offer.allowEarlyRepay,
                allowEarlyExercise: offer.allowEarlyExercise,
                allowLenderCall: offer.allowLenderCall
            })
        );

        offer.principalRemaining -= principalAmount;
        if (offer.principalRemaining == 0) {
            offer.filled = true;
            LibEqualLendDirectStorage.removeLenderRatioOffer(store, ctx.lenderKey, offer.offerId);
        }

        LibCurrency.transferWithMin(offer.borrowAsset, ctx.borrowerOwner, principalAmount - ctx.quote.totalFee, minReceived);
        _distributeDirectFees(
            lenderPool,
            ctx.lenderKey,
            store.config,
            offer.borrowAsset,
            offer.collateralAsset,
            offer.lenderPoolId,
            offer.collateralPoolId,
            ctx.quote.interestAmount,
            ctx.quote.platformFee
        );
    }

    function _acceptBorrowerRatioTrancheOffer(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.BorrowerRatioTrancheOffer storage offer,
        uint256 lenderPositionId,
        uint256 collateralAmount,
        uint256 minReceived
    ) internal returns (uint256 agreementId) {
        if (collateralAmount < offer.minCollateralPerFill || collateralAmount > offer.collateralRemaining) {
            revert DirectError_InvalidFillAmount();
        }

        BorrowerRatioFillContext memory ctx = _validateBorrowerRatioFill(offer, lenderPositionId, collateralAmount);
        ctx.quote = _quoteFixedFees(ctx.principalAmount, offer.aprBps, offer.durationSeconds, store.config);

        Types.PoolData storage lenderPool = LibPositionHelpers.pool(offer.lenderPoolId);
        if (ctx.principalAmount > lenderPool.trackedBalance) {
            revert InsufficientPrincipal(ctx.principalAmount, lenderPool.trackedBalance);
        }

        LibEqualLendDirectAccounting.originate(
            store,
            LibEqualLendDirectAccounting.OriginationParams({
                lenderPositionKey: ctx.lenderKey,
                borrowerPositionKey: ctx.borrowerKey,
                borrowerPositionId: offer.borrowerPositionId,
                lenderPoolId: offer.lenderPoolId,
                collateralPoolId: offer.collateralPoolId,
                borrowAsset: offer.borrowAsset,
                collateralAsset: offer.collateralAsset,
                principal: ctx.principalAmount,
                collateralToLock: collateralAmount,
                convertOfferEscrow: false,
                lockCollateralNow: false
            })
        );

        agreementId = _storeBorrowerAgreement(
            store,
            BorrowerAgreementParams({
                lenderPositionKey: ctx.lenderKey,
                borrowerPositionKey: ctx.borrowerKey,
                lender: ctx.lenderOwner,
                borrower: offer.borrower,
                lenderPositionId: lenderPositionId,
                borrowerPositionId: offer.borrowerPositionId,
                lenderPoolId: offer.lenderPoolId,
                collateralPoolId: offer.collateralPoolId,
                borrowAsset: offer.borrowAsset,
                collateralAsset: offer.collateralAsset,
                principal: ctx.principalAmount,
                userInterest: ctx.quote.interestAmount,
                dueTimestamp: ctx.quote.dueTimestamp,
                collateralLocked: collateralAmount,
                allowEarlyRepay: offer.allowEarlyRepay,
                allowEarlyExercise: offer.allowEarlyExercise,
                allowLenderCall: offer.allowLenderCall
            })
        );

        offer.collateralRemaining -= collateralAmount;
        if (offer.collateralRemaining == 0) {
            offer.filled = true;
            LibEqualLendDirectStorage.removeBorrowerRatioOffer(store, ctx.borrowerKey, offer.offerId);
        }

        LibCurrency.transferWithMin(
            offer.borrowAsset, offer.borrower, ctx.principalAmount - ctx.quote.totalFee, minReceived
        );
        _distributeDirectFees(
            lenderPool,
            ctx.lenderKey,
            store.config,
            offer.borrowAsset,
            offer.collateralAsset,
            offer.lenderPoolId,
            offer.collateralPoolId,
            ctx.quote.interestAmount,
            ctx.quote.platformFee
        );
    }

    function _validateLenderRatioFill(
        LibEqualLendDirectStorage.LenderRatioTrancheOffer storage offer,
        bytes32 borrowerKey,
        uint256 principalAmount,
        bytes32 lenderKey
    ) internal returns (uint256 collateralRequired) {
        collateralRequired = Math.mulDiv(principalAmount, offer.priceNumerator, offer.priceDenominator);
        if (collateralRequired == 0) revert DirectError_InvalidRatio();

        _validateAcceptanceContext(lenderKey, borrowerKey, offer.lenderPoolId, offer.collateralPoolId);

        Types.PoolData storage lenderPool = LibPositionHelpers.pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(offer.collateralPoolId);

        _requireLenderFundingState(lenderPool, lenderKey, offer.lenderPoolId, principalAmount, true);
        _requireBorrowerCollateralState(
            collateralPool,
            borrowerKey,
            offer.collateralPoolId,
            collateralRequired,
            offer.borrowAsset == offer.collateralAsset,
            principalAmount
        );
        _checkLenderSolvency(lenderPool, lenderKey, principalAmount);
    }

    function _validateBorrowerRatioFill(
        LibEqualLendDirectStorage.BorrowerRatioTrancheOffer storage offer,
        uint256 lenderPositionId,
        uint256 collateralAmount
    ) internal returns (BorrowerRatioFillContext memory ctx) {
        ctx.principalAmount = Math.mulDiv(collateralAmount, offer.priceNumerator, offer.priceDenominator);
        if (ctx.principalAmount == 0) revert DirectError_InvalidRatio();

        ctx.lenderKey = _requireOwnedAcceptancePosition(lenderPositionId);
        ctx.lenderOwner = msg.sender;
        ctx.borrowerKey = offer.borrowerPositionKey;

        _validateAcceptanceContext(ctx.lenderKey, ctx.borrowerKey, offer.lenderPoolId, offer.collateralPoolId);

        Types.PoolData storage lenderPool = LibPositionHelpers.pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibPositionHelpers.pool(offer.collateralPoolId);

        _requireLenderFundingState(lenderPool, ctx.lenderKey, offer.lenderPoolId, ctx.principalAmount, false);
        _requireBorrowerOfferLock(ctx.borrowerKey, offer.collateralPoolId, collateralAmount);
        _checkLenderSolvency(lenderPool, ctx.lenderKey, ctx.principalAmount);
        _checkBorrowerSolvency(
            collateralPool,
            ctx.borrowerKey,
            offer.borrowAsset == offer.collateralAsset,
            collateralPool.userPrincipal[ctx.borrowerKey],
            ctx.principalAmount
        );
    }

    function _storeLenderOfferAgreement(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.FixedLenderOffer storage offer,
        bytes32 lenderKey,
        bytes32 borrowerKey,
        address borrower,
        uint256 borrowerPositionId,
        uint256 userInterest,
        uint64 dueTimestamp
    ) internal returns (uint256 agreementId) {
        agreementId = _storeLenderAgreement(
            store,
            LenderAgreementParams({
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
                userInterest: userInterest,
                dueTimestamp: dueTimestamp,
                collateralLocked: offer.collateralLocked,
                allowEarlyRepay: offer.allowEarlyRepay,
                allowEarlyExercise: offer.allowEarlyExercise,
                allowLenderCall: offer.allowLenderCall
            })
        );
    }

    function _storeLenderAgreement(LibEqualLendDirectStorage.DirectStorage storage store, LenderAgreementParams memory params)
        internal
        returns (uint256 agreementId)
    {
        agreementId = LibEqualLendDirectStorage.allocateAgreementId(store);
        store.agreementKindById[agreementId] = LibEqualLendDirectStorage.AgreementKind.Fixed;
        store.fixedAgreements[agreementId] = LibEqualLendDirectStorage.FixedAgreement({
            agreementId: agreementId,
            kind: LibEqualLendDirectStorage.AgreementKind.Fixed,
            status: LibEqualLendDirectStorage.AgreementStatus.Active,
            lenderPositionKey: params.lenderPositionKey,
            borrowerPositionKey: params.borrowerPositionKey,
            lender: params.lender,
            borrower: params.borrower,
            lenderPositionId: params.lenderPositionId,
            borrowerPositionId: params.borrowerPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            borrowAsset: params.borrowAsset,
            collateralAsset: params.collateralAsset,
            principal: params.principal,
            userInterest: params.userInterest,
            dueTimestamp: params.dueTimestamp,
            collateralLocked: params.collateralLocked,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall
        });
        LibEqualLendDirectStorage.addBorrowerAgreement(store, params.borrowerPositionKey, agreementId);
        LibEqualLendDirectStorage.addLenderAgreement(store, params.lenderPositionKey, agreementId);
    }

    function _storeBorrowerOfferAgreement(
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.FixedBorrowerOffer storage offer,
        bytes32 lenderKey,
        bytes32 borrowerKey,
        address lender,
        uint256 lenderPositionId,
        uint256 userInterest,
        uint64 dueTimestamp
    ) internal returns (uint256 agreementId) {
        agreementId = _storeBorrowerAgreement(
            store,
            BorrowerAgreementParams({
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
                userInterest: userInterest,
                dueTimestamp: dueTimestamp,
                collateralLocked: offer.collateralLocked,
                allowEarlyRepay: offer.allowEarlyRepay,
                allowEarlyExercise: offer.allowEarlyExercise,
                allowLenderCall: offer.allowLenderCall
            })
        );
    }

    function _storeBorrowerAgreement(
        LibEqualLendDirectStorage.DirectStorage storage store,
        BorrowerAgreementParams memory params
    ) internal returns (uint256 agreementId) {
        agreementId = LibEqualLendDirectStorage.allocateAgreementId(store);
        store.agreementKindById[agreementId] = LibEqualLendDirectStorage.AgreementKind.Fixed;
        store.fixedAgreements[agreementId] = LibEqualLendDirectStorage.FixedAgreement({
            agreementId: agreementId,
            kind: LibEqualLendDirectStorage.AgreementKind.Fixed,
            status: LibEqualLendDirectStorage.AgreementStatus.Active,
            lenderPositionKey: params.lenderPositionKey,
            borrowerPositionKey: params.borrowerPositionKey,
            lender: params.lender,
            borrower: params.borrower,
            lenderPositionId: params.lenderPositionId,
            borrowerPositionId: params.borrowerPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            borrowAsset: params.borrowAsset,
            collateralAsset: params.collateralAsset,
            principal: params.principal,
            userInterest: params.userInterest,
            dueTimestamp: params.dueTimestamp,
            collateralLocked: params.collateralLocked,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall
        });
        LibEqualLendDirectStorage.addBorrowerAgreement(store, params.borrowerPositionKey, agreementId);
        LibEqualLendDirectStorage.addLenderAgreement(store, params.lenderPositionKey, agreementId);
    }

    function _validateAcceptanceContext(
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

    function _requireLenderFundingState(
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
        } else {
            uint256 available = _availablePrincipal(lenderPool, lenderKey, lenderPoolId, lenderPool.userSameAssetDebt[lenderKey], 0);
            if (principal > available) {
                revert InsufficientPrincipal(principal, available);
            }
        }
    }

    function _requireBorrowerCollateralState(
        Types.PoolData storage collateralPool,
        bytes32 borrowerKey,
        uint256 collateralPoolId,
        uint256 collateralLocked,
        bool sameAsset,
        uint256 principal
    ) internal view returns (uint256 borrowerPrincipal) {
        borrowerPrincipal = collateralPool.userPrincipal[borrowerKey];
        uint256 available = _availablePrincipal(
            collateralPool,
            borrowerKey,
            collateralPoolId,
            collateralPool.userSameAssetDebt[borrowerKey],
            0
        );
        if (collateralLocked > available) {
            revert InsufficientPrincipal(collateralLocked, available);
        }
        _checkBorrowerSolvency(collateralPool, borrowerKey, sameAsset, borrowerPrincipal, principal);
    }

    function _requireBorrowerOfferLock(bytes32 borrowerKey, uint256 collateralPoolId, uint256 collateralLocked)
        internal
        view
    {
        uint256 lockedCapital = LibEncumbrance.get(borrowerKey, collateralPoolId).lockedCapital;
        if (lockedCapital < collateralLocked) {
            revert InsufficientPrincipal(collateralLocked, lockedCapital);
        }
    }

    function _checkLenderSolvency(Types.PoolData storage lenderPool, bytes32 lenderKey, uint256 principal) internal view {
        uint256 currentPrincipal = lenderPool.userPrincipal[lenderKey];
        uint256 debt = lenderPool.userSameAssetDebt[lenderKey];
        uint256 newPrincipal = currentPrincipal > principal ? currentPrincipal - principal : 0;
        if (!_isSolvent(lenderPool, newPrincipal, debt)) {
            revert SolvencyViolation(newPrincipal, debt, lenderPool.poolConfig.depositorLTVBps);
        }
    }

    function _checkBorrowerSolvency(
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
        if (!_isSolvent(collateralPool, borrowerPrincipal, newDebt)) {
            revert SolvencyViolation(borrowerPrincipal, newDebt, collateralPool.poolConfig.depositorLTVBps);
        }
    }

    function _isSolvent(Types.PoolData storage pool, uint256 principal, uint256 debt) internal view returns (bool) {
        if (debt == 0) return true;
        uint16 ltvBps = pool.poolConfig.depositorLTVBps;
        if (ltvBps == 0) return false;
        return debt <= Math.mulDiv(principal, ltvBps, BPS_DENOMINATOR);
    }

    function _quoteFixedFees(
        uint256 principal,
        uint16 aprBps,
        uint64 durationSeconds,
        LibEqualLendDirectStorage.DirectConfig storage cfg
    ) internal view returns (FixedFeeQuote memory quote) {
        if (durationSeconds == 0) revert DirectError_InvalidConfiguration();
        quote.platformFee = Math.mulDiv(principal, cfg.platformFeeBps, BPS_DENOMINATOR);
        uint256 effectiveDuration = durationSeconds < cfg.minInterestDuration ? cfg.minInterestDuration : durationSeconds;
        if (aprBps != 0 && principal != 0 && effectiveDuration != 0) {
            quote.interestAmount = Math.mulDiv(principal, uint256(aprBps) * effectiveDuration, YEAR * BPS_DENOMINATOR);
        }
        quote.totalFee = quote.interestAmount + quote.platformFee;
        uint256 dueTimestampCalc = block.timestamp + durationSeconds;
        if (dueTimestampCalc > type(uint64).max) revert DirectError_InvalidTimestamp();
        quote.dueTimestamp = uint64(dueTimestampCalc);
        if (quote.totalFee > principal) revert DirectError_InvalidOffer();
    }

    function _distributeDirectFees(
        Types.PoolData storage lenderPool,
        bytes32 lenderKey,
        LibEqualLendDirectStorage.DirectConfig storage cfg,
        address borrowAsset,
        address collateralAsset,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        uint256 interestAmount,
        uint256 platformFee
    ) internal {
        uint256 lenderInterestShare = Math.mulDiv(interestAmount, cfg.interestLenderBps, BPS_DENOMINATOR);
        uint256 lenderPlatformShare = Math.mulDiv(platformFee, cfg.platformFeeLenderBps, BPS_DENOMINATOR);
        uint256 lenderAmount = lenderInterestShare + lenderPlatformShare;
        if (lenderAmount > 0) {
            lenderPool.userAccruedYield[lenderKey] += lenderAmount;
            lenderPool.trackedBalance += lenderAmount;
            lenderPool.yieldReserve += lenderAmount;
            if (LibCurrency.isNative(lenderPool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += lenderAmount;
            }
        }

        uint256 feePid = borrowAsset == collateralAsset ? collateralPoolId : lenderPoolId;
        Types.PoolData storage feePool = LibPositionHelpers.pool(feePid);

        uint256 interestRemainder = interestAmount - lenderInterestShare;
        if (interestRemainder > 0) {
            _trackFeeBacking(feePool, interestRemainder);
            LibFeeRouter.routeSamePool(feePid, interestRemainder, DIRECT_FIXED_INTEREST_FEE_SOURCE, true, 0);
        }

        uint256 platformRemainder = platformFee - lenderPlatformShare;
        if (platformRemainder > 0) {
            _trackFeeBacking(feePool, platformRemainder);
            LibFeeRouter.routeSamePool(feePid, platformRemainder, DIRECT_FIXED_PLATFORM_FEE_SOURCE, true, 0);
        }
    }

    function _distributeLenderOfferFees(
        Types.PoolData storage lenderPool,
        bytes32 lenderKey,
        LibEqualLendDirectStorage.DirectConfig storage cfg,
        LibEqualLendDirectStorage.FixedLenderOffer storage offer,
        FixedFeeQuote memory quote
    ) internal {
        _distributeDirectFees(
            lenderPool,
            lenderKey,
            cfg,
            offer.borrowAsset,
            offer.collateralAsset,
            offer.lenderPoolId,
            offer.collateralPoolId,
            quote.interestAmount,
            quote.platformFee
        );
    }

    function _distributeBorrowerOfferFees(
        Types.PoolData storage lenderPool,
        bytes32 lenderKey,
        LibEqualLendDirectStorage.DirectConfig storage cfg,
        LibEqualLendDirectStorage.FixedBorrowerOffer storage offer,
        FixedFeeQuote memory quote
    ) internal {
        _distributeDirectFees(
            lenderPool,
            lenderKey,
            cfg,
            offer.borrowAsset,
            offer.collateralAsset,
            offer.lenderPoolId,
            offer.collateralPoolId,
            quote.interestAmount,
            quote.platformFee
        );
    }

    function _trackFeeBacking(Types.PoolData storage pool, uint256 amount) internal {
        pool.trackedBalance += amount;
        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal += amount;
        }
    }

    function _availablePrincipal(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 poolId,
        uint256 sameAssetDebt,
        uint256 extraReserved
    )
        internal
        view
        returns (uint256 available)
    {
        uint256 principal = pool.userPrincipal[positionKey];
        uint256 reserved = LibEncumbrance.total(positionKey, poolId) + extraReserved;
        if (sameAssetDebt > reserved) {
            reserved = sameAssetDebt;
        }
        if (reserved >= principal) return 0;
        available = principal - reserved;
    }

    function _requireOwnedAcceptancePosition(uint256 positionId) internal view returns (bytes32 positionKey) {
        LibPositionHelpers.requireOwnership(positionId);
        positionKey = LibPositionHelpers.positionKey(positionId);
    }
}
