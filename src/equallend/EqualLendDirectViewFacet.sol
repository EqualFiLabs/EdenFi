// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "src/nft/PositionNFT.sol";
import {DirectError_InvalidAgreementState, DirectError_InvalidOffer} from "src/libraries/Errors.sol";
import {LibEqualLendDirectRolling} from "src/libraries/LibEqualLendDirectRolling.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";

/// @notice Read-only views over the clean EqualLend Direct offer, agreement, tranche, and rolling state.
contract EqualLendDirectViewFacet {
    struct PositionOfferIds {
        uint256[] allOfferIds;
        uint256[] fixedOfferIds;
        uint256[] ratioOfferIds;
        uint256[] rollingOfferIds;
    }

    struct PositionAgreementIds {
        uint256[] allAgreementIds;
        uint256[] fixedAgreementIds;
        uint256[] rollingAgreementIds;
    }

    struct RollingPaymentPreview {
        uint256 arrearsDue;
        uint256 currentInterestDue;
        uint256 totalDue;
        uint256 minPayment;
        uint64 latestPassedDue;
        uint256 dueCountDelta;
    }

    struct RollingStatusView {
        LibEqualLendDirectStorage.AgreementStatus status;
        bool isOverdue;
        bool inGracePeriod;
        bool canRecover;
        bool isAtPaymentCap;
        uint64 nextDue;
        uint64 recoverableAt;
        uint256 arrears;
        uint256 outstandingPrincipal;
    }

    struct RatioTrancheStatus {
        uint256 totalCapacity;
        uint256 remainingCapacity;
        uint256 minFillAmount;
        uint256 fillsRemaining;
        uint256 priceNumerator;
        uint256 priceDenominator;
        bool isDepleted;
        bool cancelled;
        bool filled;
    }

    function getDirectConfig() external view returns (LibEqualLendDirectStorage.DirectConfig memory) {
        return LibEqualLendDirectStorage.s().config;
    }

    function getDirectRollingConfig() external view returns (LibEqualLendDirectStorage.DirectRollingConfig memory) {
        return LibEqualLendDirectStorage.s().rollingConfig;
    }

    function getOfferKind(uint256 offerId) external view returns (LibEqualLendDirectStorage.OfferKind) {
        return LibEqualLendDirectStorage.s().offerKindById[offerId];
    }

    function getAgreementKind(uint256 agreementId) external view returns (LibEqualLendDirectStorage.AgreementKind) {
        return LibEqualLendDirectStorage.s().agreementKindById[agreementId];
    }

    function getFixedLenderOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.FixedLenderOffer memory)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireOfferKind(store, offerId, LibEqualLendDirectStorage.OfferKind.FixedLender);
        return store.fixedLenderOffers[offerId];
    }

    function getFixedBorrowerOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.FixedBorrowerOffer memory)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireOfferKind(store, offerId, LibEqualLendDirectStorage.OfferKind.FixedBorrower);
        return store.fixedBorrowerOffers[offerId];
    }

    function getLenderRatioTrancheOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.LenderRatioTrancheOffer memory)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireOfferKind(store, offerId, LibEqualLendDirectStorage.OfferKind.RatioTrancheLender);
        return store.lenderRatioOffers[offerId];
    }

    function getBorrowerRatioTrancheOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.BorrowerRatioTrancheOffer memory)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireOfferKind(store, offerId, LibEqualLendDirectStorage.OfferKind.RatioTrancheBorrower);
        return store.borrowerRatioOffers[offerId];
    }

    function getRollingLenderOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.RollingLenderOffer memory)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireOfferKind(store, offerId, LibEqualLendDirectStorage.OfferKind.RollingLender);
        return store.rollingLenderOffers[offerId];
    }

    function getRollingBorrowerOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.RollingBorrowerOffer memory)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireOfferKind(store, offerId, LibEqualLendDirectStorage.OfferKind.RollingBorrower);
        return store.rollingBorrowerOffers[offerId];
    }

    function getFixedAgreement(uint256 agreementId)
        external
        view
        returns (LibEqualLendDirectStorage.FixedAgreement memory)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireAgreementKind(store, agreementId, LibEqualLendDirectStorage.AgreementKind.Fixed);
        return store.fixedAgreements[agreementId];
    }

    function getRollingAgreement(uint256 agreementId)
        external
        view
        returns (LibEqualLendDirectStorage.RollingAgreement memory)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireAgreementKind(store, agreementId, LibEqualLendDirectStorage.AgreementKind.Rolling);
        return store.rollingAgreements[agreementId];
    }

    function getBorrowerOfferIds(uint256 positionId) external view returns (PositionOfferIds memory lookup) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        bytes32 positionKey = _positionKey(positionId);

        lookup.fixedOfferIds = _copyIds(LibEqualLendDirectStorage.ids(store.fixedBorrowerOfferIndex, positionKey));
        lookup.ratioOfferIds = _copyIds(LibEqualLendDirectStorage.ids(store.borrowerRatioOfferIndex, positionKey));
        lookup.rollingOfferIds = _copyIds(LibEqualLendDirectStorage.ids(store.rollingBorrowerOfferIndex, positionKey));
        lookup.allOfferIds = _concatThree(lookup.fixedOfferIds, lookup.ratioOfferIds, lookup.rollingOfferIds);
    }

    function getLenderOfferIds(uint256 positionId) external view returns (PositionOfferIds memory lookup) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        bytes32 positionKey = _positionKey(positionId);

        lookup.fixedOfferIds = _copyIds(LibEqualLendDirectStorage.ids(store.fixedLenderOfferIndex, positionKey));
        lookup.ratioOfferIds = _copyIds(LibEqualLendDirectStorage.ids(store.lenderRatioOfferIndex, positionKey));
        lookup.rollingOfferIds = _copyIds(LibEqualLendDirectStorage.ids(store.rollingLenderOfferIndex, positionKey));
        lookup.allOfferIds = _concatThree(lookup.fixedOfferIds, lookup.ratioOfferIds, lookup.rollingOfferIds);
    }

    function getBorrowerAgreementIds(uint256 positionId) external view returns (PositionAgreementIds memory lookup) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        bytes32 positionKey = _positionKey(positionId);

        uint256[] storage allAgreements = LibEqualLendDirectStorage.ids(store.borrowerAgreementIndex, positionKey);
        lookup.allAgreementIds = _copyIds(allAgreements);
        lookup.fixedAgreementIds = _filterAgreementIds(allAgreements, store, LibEqualLendDirectStorage.AgreementKind.Fixed);
        lookup.rollingAgreementIds = _copyIds(LibEqualLendDirectStorage.ids(store.rollingBorrowerAgreementIndex, positionKey));
    }

    function getLenderAgreementIds(uint256 positionId) external view returns (PositionAgreementIds memory lookup) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        bytes32 positionKey = _positionKey(positionId);

        uint256[] storage allAgreements = LibEqualLendDirectStorage.ids(store.lenderAgreementIndex, positionKey);
        lookup.allAgreementIds = _copyIds(allAgreements);
        lookup.fixedAgreementIds = _filterAgreementIds(allAgreements, store, LibEqualLendDirectStorage.AgreementKind.Fixed);
        lookup.rollingAgreementIds = _copyIds(LibEqualLendDirectStorage.ids(store.rollingLenderAgreementIndex, positionKey));
    }

    function previewRollingPayment(uint256 agreementId) external view returns (RollingPaymentPreview memory preview) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireAgreementKind(store, agreementId, LibEqualLendDirectStorage.AgreementKind.Rolling);

        LibEqualLendDirectStorage.RollingAgreement storage agreement = store.rollingAgreements[agreementId];
        LibEqualLendDirectRolling.AccrualSnapshot memory snapshot =
            LibEqualLendDirectRolling.previewAccrual(agreement, block.timestamp);

        preview = RollingPaymentPreview({
            arrearsDue: snapshot.arrearsDue,
            currentInterestDue: snapshot.currentInterestDue,
            totalDue: snapshot.arrearsDue + snapshot.currentInterestDue,
            minPayment: (agreement.outstandingPrincipal * store.rollingConfig.minPaymentBps + 9_999)
                / LibEqualLendDirectStorage.BPS_DENOMINATOR,
            latestPassedDue: snapshot.latestPassedDue,
            dueCountDelta: snapshot.dueCountDelta
        });
    }

    function getRollingStatus(uint256 agreementId) external view returns (RollingStatusView memory statusView) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireAgreementKind(store, agreementId, LibEqualLendDirectStorage.AgreementKind.Rolling);

        LibEqualLendDirectStorage.RollingAgreement storage agreement = store.rollingAgreements[agreementId];
        uint256 recoverableAt = uint256(agreement.nextDue) + agreement.gracePeriodSeconds;
        bool isOverdue = agreement.status == LibEqualLendDirectStorage.AgreementStatus.Active && block.timestamp > agreement.nextDue;
        bool inGracePeriod = isOverdue && block.timestamp <= recoverableAt;

        statusView = RollingStatusView({
            status: agreement.status,
            isOverdue: isOverdue,
            inGracePeriod: inGracePeriod,
            canRecover: isOverdue && !inGracePeriod,
            isAtPaymentCap: agreement.paymentCount >= agreement.maxPaymentCount,
            nextDue: agreement.nextDue,
            recoverableAt: recoverableAt > type(uint64).max ? type(uint64).max : uint64(recoverableAt),
            arrears: agreement.arrears,
            outstandingPrincipal: agreement.outstandingPrincipal
        });
    }

    function getLenderRatioTrancheStatus(uint256 offerId) external view returns (RatioTrancheStatus memory status) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireOfferKind(store, offerId, LibEqualLendDirectStorage.OfferKind.RatioTrancheLender);

        LibEqualLendDirectStorage.LenderRatioTrancheOffer storage offer = store.lenderRatioOffers[offerId];
        status = RatioTrancheStatus({
            totalCapacity: offer.principalCap,
            remainingCapacity: offer.principalRemaining,
            minFillAmount: offer.minPrincipalPerFill,
            fillsRemaining: _fillsRemaining(offer.principalRemaining, offer.minPrincipalPerFill),
            priceNumerator: offer.priceNumerator,
            priceDenominator: offer.priceDenominator,
            isDepleted: _isDepleted(offer.principalRemaining, offer.minPrincipalPerFill, offer.cancelled, offer.filled),
            cancelled: offer.cancelled,
            filled: offer.filled
        });
    }

    function getBorrowerRatioTrancheStatus(uint256 offerId) external view returns (RatioTrancheStatus memory status) {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        _requireOfferKind(store, offerId, LibEqualLendDirectStorage.OfferKind.RatioTrancheBorrower);

        LibEqualLendDirectStorage.BorrowerRatioTrancheOffer storage offer = store.borrowerRatioOffers[offerId];
        status = RatioTrancheStatus({
            totalCapacity: offer.collateralCap,
            remainingCapacity: offer.collateralRemaining,
            minFillAmount: offer.minCollateralPerFill,
            fillsRemaining: _fillsRemaining(offer.collateralRemaining, offer.minCollateralPerFill),
            priceNumerator: offer.priceNumerator,
            priceDenominator: offer.priceDenominator,
            isDepleted: _isDepleted(offer.collateralRemaining, offer.minCollateralPerFill, offer.cancelled, offer.filled),
            cancelled: offer.cancelled,
            filled: offer.filled
        });
    }

    function _positionKey(uint256 positionId) internal view returns (bytes32) {
        return PositionNFT(LibPositionNFT.s().positionNFTContract).getPositionKey(positionId);
    }

    function _requireOfferKind(
        LibEqualLendDirectStorage.DirectStorage storage store,
        uint256 offerId,
        LibEqualLendDirectStorage.OfferKind expected
    ) internal view {
        if (store.offerKindById[offerId] != expected) revert DirectError_InvalidOffer();
    }

    function _requireAgreementKind(
        LibEqualLendDirectStorage.DirectStorage storage store,
        uint256 agreementId,
        LibEqualLendDirectStorage.AgreementKind expected
    ) internal view {
        if (store.agreementKindById[agreementId] != expected) revert DirectError_InvalidAgreementState();
    }

    function _copyIds(uint256[] storage source) internal view returns (uint256[] memory copied) {
        uint256 length = source.length;
        copied = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            copied[i] = source[i];
        }
    }

    function _filterAgreementIds(
        uint256[] storage source,
        LibEqualLendDirectStorage.DirectStorage storage store,
        LibEqualLendDirectStorage.AgreementKind expected
    ) internal view returns (uint256[] memory filtered) {
        uint256 length = source.length;
        uint256 count;
        for (uint256 i = 0; i < length; ++i) {
            if (store.agreementKindById[source[i]] == expected) {
                ++count;
            }
        }

        filtered = new uint256[](count);
        uint256 outIndex;
        for (uint256 i = 0; i < length; ++i) {
            uint256 agreementId = source[i];
            if (store.agreementKindById[agreementId] == expected) {
                filtered[outIndex] = agreementId;
                ++outIndex;
            }
        }
    }

    function _concatThree(uint256[] memory first, uint256[] memory second, uint256[] memory third)
        internal
        pure
        returns (uint256[] memory joined)
    {
        joined = new uint256[](first.length + second.length + third.length);
        uint256 outIndex;

        for (uint256 i = 0; i < first.length; ++i) {
            joined[outIndex] = first[i];
            ++outIndex;
        }
        for (uint256 i = 0; i < second.length; ++i) {
            joined[outIndex] = second[i];
            ++outIndex;
        }
        for (uint256 i = 0; i < third.length; ++i) {
            joined[outIndex] = third[i];
            ++outIndex;
        }
    }

    function _fillsRemaining(uint256 remainingCapacity, uint256 minFillAmount) internal pure returns (uint256) {
        if (remainingCapacity == 0 || minFillAmount == 0 || remainingCapacity < minFillAmount) {
            return 0;
        }
        return remainingCapacity / minFillAmount;
    }

    function _isDepleted(uint256 remainingCapacity, uint256 minFillAmount, bool cancelled, bool filled)
        internal
        pure
        returns (bool)
    {
        if (cancelled || filled) {
            return true;
        }
        if (remainingCapacity == 0) {
            return true;
        }
        return remainingCapacity < minFillAmount;
    }
}