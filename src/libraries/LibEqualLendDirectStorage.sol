// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {DirectError_InvalidConfiguration} from "src/libraries/Errors.sol";

/// @notice Canonical diamond storage and typed records for the EqualLend Direct rebuild.
library LibEqualLendDirectStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.equallend.direct.storage");
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    enum OfferKind {
        None,
        FixedLender,
        FixedBorrower,
        RatioTrancheLender,
        RatioTrancheBorrower,
        RollingLender,
        RollingBorrower
    }

    enum AgreementKind {
        None,
        Fixed,
        Rolling
    }

    enum AgreementStatus {
        None,
        Active,
        Repaid,
        Defaulted,
        Exercised
    }

    struct DirectConfig {
        uint16 platformFeeBps;
        uint16 interestLenderBps;
        uint16 platformFeeLenderBps;
        uint16 defaultLenderBps;
        uint40 minInterestDuration;
    }

    struct DirectRollingConfig {
        uint32 minPaymentIntervalSeconds;
        uint16 maxPaymentCount;
        uint16 maxUpfrontPremiumBps;
        uint16 minRollingApyBps;
        uint16 maxRollingApyBps;
        uint16 defaultPenaltyBps;
        uint16 minPaymentBps;
    }

    struct FixedLenderOffer {
        uint256 offerId;
        bytes32 lenderPositionKey;
        address lender;
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
        bool cancelled;
        bool filled;
    }

    struct FixedBorrowerOffer {
        uint256 offerId;
        bytes32 borrowerPositionKey;
        address borrower;
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
        bool cancelled;
        bool filled;
    }

    struct LenderRatioTrancheOffer {
        uint256 offerId;
        bytes32 lenderPositionKey;
        address lender;
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principalCap;
        uint256 principalRemaining;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 minPrincipalPerFill;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
        bool cancelled;
        bool filled;
    }

    struct BorrowerRatioTrancheOffer {
        uint256 offerId;
        bytes32 borrowerPositionKey;
        address borrower;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 collateralCap;
        uint256 collateralRemaining;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 minCollateralPerFill;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
        bool cancelled;
        bool filled;
    }

    struct RollingLenderOffer {
        uint256 offerId;
        bytes32 lenderPositionKey;
        address lender;
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
        bool cancelled;
        bool filled;
    }

    struct RollingBorrowerOffer {
        uint256 offerId;
        bytes32 borrowerPositionKey;
        address borrower;
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
        bool cancelled;
        bool filled;
    }

    struct FixedAgreement {
        uint256 agreementId;
        AgreementKind kind;
        AgreementStatus status;
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

    struct RollingAgreement {
        uint256 agreementId;
        AgreementKind kind;
        AgreementStatus status;
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
        uint256 outstandingPrincipal;
        uint256 collateralLocked;
        uint256 upfrontPremium;
        uint64 nextDue;
        uint64 lastAccrualTimestamp;
        uint256 arrears;
        uint16 paymentCount;
        uint32 paymentIntervalSeconds;
        uint16 rollingApyBps;
        uint32 gracePeriodSeconds;
        uint16 maxPaymentCount;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
    }

    struct PositionIdIndex {
        mapping(bytes32 => uint256[]) idsByPosition;
        mapping(bytes32 => mapping(uint256 => uint256)) indexPlusOneByPosition;
    }

    struct DirectStorage {
        DirectConfig config;
        DirectRollingConfig rollingConfig;
        uint256 nextOfferId;
        uint256 nextAgreementId;
        mapping(uint256 => OfferKind) offerKindById;
        mapping(uint256 => AgreementKind) agreementKindById;
        mapping(uint256 => FixedLenderOffer) fixedLenderOffers;
        mapping(uint256 => FixedBorrowerOffer) fixedBorrowerOffers;
        mapping(uint256 => LenderRatioTrancheOffer) lenderRatioOffers;
        mapping(uint256 => BorrowerRatioTrancheOffer) borrowerRatioOffers;
        mapping(uint256 => RollingLenderOffer) rollingLenderOffers;
        mapping(uint256 => RollingBorrowerOffer) rollingBorrowerOffers;
        mapping(uint256 => FixedAgreement) fixedAgreements;
        mapping(uint256 => RollingAgreement) rollingAgreements;
        PositionIdIndex fixedLenderOfferIndex;
        PositionIdIndex fixedBorrowerOfferIndex;
        PositionIdIndex lenderRatioOfferIndex;
        PositionIdIndex borrowerRatioOfferIndex;
        PositionIdIndex rollingLenderOfferIndex;
        PositionIdIndex rollingBorrowerOfferIndex;
        PositionIdIndex borrowerAgreementIndex;
        PositionIdIndex lenderAgreementIndex;
        PositionIdIndex rollingBorrowerAgreementIndex;
        PositionIdIndex rollingLenderAgreementIndex;
    }

    function s() internal pure returns (DirectStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function allocateOfferId(DirectStorage storage store) internal returns (uint256 offerId) {
        offerId = store.nextOfferId + 1;
        store.nextOfferId = offerId;
    }

    function allocateAgreementId(DirectStorage storage store) internal returns (uint256 agreementId) {
        agreementId = store.nextAgreementId + 1;
        store.nextAgreementId = agreementId;
    }

    function validateDirectConfig(DirectConfig memory cfg) internal pure {
        if (
            cfg.platformFeeBps > BPS_DENOMINATOR || cfg.interestLenderBps > BPS_DENOMINATOR
                || cfg.platformFeeLenderBps > BPS_DENOMINATOR || cfg.defaultLenderBps > BPS_DENOMINATOR
                || cfg.minInterestDuration == 0
        ) {
            revert DirectError_InvalidConfiguration();
        }
    }

    function validateRollingConfig(DirectRollingConfig memory cfg) internal pure {
        if (
            cfg.minPaymentIntervalSeconds == 0 || cfg.maxPaymentCount == 0 || cfg.maxUpfrontPremiumBps > BPS_DENOMINATOR
                || cfg.minRollingApyBps > cfg.maxRollingApyBps || cfg.maxRollingApyBps > BPS_DENOMINATOR
                || cfg.defaultPenaltyBps > BPS_DENOMINATOR || cfg.minPaymentBps == 0 || cfg.minPaymentBps > BPS_DENOMINATOR
        ) {
            revert DirectError_InvalidConfiguration();
        }
    }

    function isTerminalStatus(AgreementStatus status) internal pure returns (bool) {
        return status == AgreementStatus.Repaid || status == AgreementStatus.Defaulted
            || status == AgreementStatus.Exercised;
    }

    function addFixedLenderOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _addId(store.fixedLenderOfferIndex, positionKey, offerId);
    }

    function removeFixedLenderOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _removeId(store.fixedLenderOfferIndex, positionKey, offerId);
    }

    function addFixedBorrowerOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _addId(store.fixedBorrowerOfferIndex, positionKey, offerId);
    }

    function removeFixedBorrowerOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _removeId(store.fixedBorrowerOfferIndex, positionKey, offerId);
    }

    function addLenderRatioOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _addId(store.lenderRatioOfferIndex, positionKey, offerId);
    }

    function removeLenderRatioOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _removeId(store.lenderRatioOfferIndex, positionKey, offerId);
    }

    function addBorrowerRatioOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _addId(store.borrowerRatioOfferIndex, positionKey, offerId);
    }

    function removeBorrowerRatioOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _removeId(store.borrowerRatioOfferIndex, positionKey, offerId);
    }

    function addRollingLenderOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _addId(store.rollingLenderOfferIndex, positionKey, offerId);
    }

    function removeRollingLenderOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _removeId(store.rollingLenderOfferIndex, positionKey, offerId);
    }

    function addRollingBorrowerOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _addId(store.rollingBorrowerOfferIndex, positionKey, offerId);
    }

    function removeRollingBorrowerOffer(DirectStorage storage store, bytes32 positionKey, uint256 offerId) internal {
        _removeId(store.rollingBorrowerOfferIndex, positionKey, offerId);
    }

    function addBorrowerAgreement(DirectStorage storage store, bytes32 positionKey, uint256 agreementId) internal {
        _addId(store.borrowerAgreementIndex, positionKey, agreementId);
    }

    function removeBorrowerAgreement(DirectStorage storage store, bytes32 positionKey, uint256 agreementId) internal {
        _removeId(store.borrowerAgreementIndex, positionKey, agreementId);
    }

    function addLenderAgreement(DirectStorage storage store, bytes32 positionKey, uint256 agreementId) internal {
        _addId(store.lenderAgreementIndex, positionKey, agreementId);
    }

    function removeLenderAgreement(DirectStorage storage store, bytes32 positionKey, uint256 agreementId) internal {
        _removeId(store.lenderAgreementIndex, positionKey, agreementId);
    }

    function addRollingBorrowerAgreement(DirectStorage storage store, bytes32 positionKey, uint256 agreementId) internal {
        _addId(store.rollingBorrowerAgreementIndex, positionKey, agreementId);
    }

    function removeRollingBorrowerAgreement(DirectStorage storage store, bytes32 positionKey, uint256 agreementId) internal {
        _removeId(store.rollingBorrowerAgreementIndex, positionKey, agreementId);
    }

    function addRollingLenderAgreement(DirectStorage storage store, bytes32 positionKey, uint256 agreementId) internal {
        _addId(store.rollingLenderAgreementIndex, positionKey, agreementId);
    }

    function removeRollingLenderAgreement(DirectStorage storage store, bytes32 positionKey, uint256 agreementId) internal {
        _removeId(store.rollingLenderAgreementIndex, positionKey, agreementId);
    }

    function ids(PositionIdIndex storage index, bytes32 positionKey)
        internal
        view
        returns (uint256[] storage positionIds)
    {
        return index.idsByPosition[positionKey];
    }

    function contains(PositionIdIndex storage index, bytes32 positionKey, uint256 id) internal view returns (bool) {
        return index.indexPlusOneByPosition[positionKey][id] != 0;
    }

    function count(PositionIdIndex storage index, bytes32 positionKey) internal view returns (uint256) {
        return index.idsByPosition[positionKey].length;
    }

    function _addId(PositionIdIndex storage index, bytes32 positionKey, uint256 id) private {
        if (index.indexPlusOneByPosition[positionKey][id] != 0) {
            return;
        }

        index.idsByPosition[positionKey].push(id);
        index.indexPlusOneByPosition[positionKey][id] = index.idsByPosition[positionKey].length;
    }

    function _removeId(PositionIdIndex storage index, bytes32 positionKey, uint256 id) private {
        uint256 indexPlusOne = index.indexPlusOneByPosition[positionKey][id];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 removeIndex = indexPlusOne - 1;
        uint256 lastIndex = index.idsByPosition[positionKey].length - 1;
        if (removeIndex != lastIndex) {
            uint256 swappedId = index.idsByPosition[positionKey][lastIndex];
            index.idsByPosition[positionKey][removeIndex] = swappedId;
            index.indexPlusOneByPosition[positionKey][swappedId] = removeIndex + 1;
        }

        index.idsByPosition[positionKey].pop();
        delete index.indexPlusOneByPosition[positionKey][id];
    }
}
