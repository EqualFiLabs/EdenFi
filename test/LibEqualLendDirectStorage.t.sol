// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibEqualXCommunityAmmStorage} from "src/libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCurveStorage} from "src/libraries/LibEqualXCurveStorage.sol";
import {LibEqualXSoloAmmStorage} from "src/libraries/LibEqualXSoloAmmStorage.sol";
import {LibOptionTokenStorage} from "src/libraries/LibOptionTokenStorage.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {DirectError_InvalidConfiguration} from "src/libraries/Errors.sol";

contract EqualLendDirectStorageHarness {
    function directSlot() external pure returns (bytes32) {
        return LibEqualLendDirectStorage.STORAGE_POSITION;
    }

    function setDirectConfig(LibEqualLendDirectStorage.DirectConfig calldata cfg) external {
        LibEqualLendDirectStorage.validateDirectConfig(cfg);
        LibEqualLendDirectStorage.s().config = cfg;
    }

    function getDirectConfig() external view returns (LibEqualLendDirectStorage.DirectConfig memory) {
        return LibEqualLendDirectStorage.s().config;
    }

    function setRollingConfig(LibEqualLendDirectStorage.DirectRollingConfig calldata cfg) external {
        LibEqualLendDirectStorage.validateRollingConfig(cfg);
        LibEqualLendDirectStorage.s().rollingConfig = cfg;
    }

    function getRollingConfig() external view returns (LibEqualLendDirectStorage.DirectRollingConfig memory) {
        return LibEqualLendDirectStorage.s().rollingConfig;
    }

    function allocateOfferId() external returns (uint256) {
        return LibEqualLendDirectStorage.allocateOfferId(LibEqualLendDirectStorage.s());
    }

    function allocateAgreementId() external returns (uint256) {
        return LibEqualLendDirectStorage.allocateAgreementId(LibEqualLendDirectStorage.s());
    }

    function setFixedLenderOffer(
        uint256 offerId,
        bytes32 lenderPositionKey,
        address lender,
        uint256 lenderPositionId,
        uint256 principal,
        uint256 collateralLocked
    ) external {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.FixedLender;
        store.fixedLenderOffers[offerId] = LibEqualLendDirectStorage.FixedLenderOffer({
            offerId: offerId,
            lenderPositionKey: lenderPositionKey,
            lender: lender,
            lenderPositionId: lenderPositionId,
            lenderPoolId: 11,
            collateralPoolId: 22,
            borrowAsset: address(0xB0),
            collateralAsset: address(0xC0),
            principal: principal,
            collateralLocked: collateralLocked,
            aprBps: 700,
            durationSeconds: 30 days,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: true,
            cancelled: false,
            filled: false
        });
    }

    function getFixedLenderOffer(uint256 offerId)
        external
        view
        returns (
            LibEqualLendDirectStorage.OfferKind kind,
            bytes32 lenderPositionKey,
            address lender,
            uint256 lenderPositionId,
            uint256 principal,
            uint256 collateralLocked,
            bool allowLenderCall
        )
    {
        LibEqualLendDirectStorage.FixedLenderOffer storage offer = LibEqualLendDirectStorage.s().fixedLenderOffers[offerId];
        return (
            LibEqualLendDirectStorage.s().offerKindById[offerId],
            offer.lenderPositionKey,
            offer.lender,
            offer.lenderPositionId,
            offer.principal,
            offer.collateralLocked,
            offer.allowLenderCall
        );
    }

    function setLenderRatioOffer(
        uint256 offerId,
        bytes32 lenderPositionKey,
        address lender,
        uint256 lenderPositionId,
        uint256 principalCap,
        uint256 principalRemaining
    ) external {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.RatioTrancheLender;
        store.lenderRatioOffers[offerId] = LibEqualLendDirectStorage.LenderRatioTrancheOffer({
            offerId: offerId,
            lenderPositionKey: lenderPositionKey,
            lender: lender,
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            borrowAsset: address(0xD0),
            collateralAsset: address(0xE0),
            principalCap: principalCap,
            principalRemaining: principalRemaining,
            priceNumerator: 3,
            priceDenominator: 2,
            minPrincipalPerFill: 5 ether,
            aprBps: 800,
            durationSeconds: 14 days,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false,
            cancelled: false,
            filled: false
        });
    }

    function getLenderRatioOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.OfferKind kind, uint256 principalCap, uint256 principalRemaining, uint256 priceNumerator)
    {
        LibEqualLendDirectStorage.LenderRatioTrancheOffer storage offer =
            LibEqualLendDirectStorage.s().lenderRatioOffers[offerId];
        return (
            LibEqualLendDirectStorage.s().offerKindById[offerId],
            offer.principalCap,
            offer.principalRemaining,
            offer.priceNumerator
        );
    }

    function setRollingBorrowerOffer(
        uint256 offerId,
        bytes32 borrowerPositionKey,
        address borrower,
        uint256 borrowerPositionId,
        uint256 principal
    ) external {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        store.offerKindById[offerId] = LibEqualLendDirectStorage.OfferKind.RollingBorrower;
        store.rollingBorrowerOffers[offerId] = LibEqualLendDirectStorage.RollingBorrowerOffer({
            offerId: offerId,
            borrowerPositionKey: borrowerPositionKey,
            borrower: borrower,
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 5,
            collateralPoolId: 6,
            borrowAsset: address(0xF0),
            collateralAsset: address(0xF1),
            principal: principal,
            collateralLocked: principal / 2,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 900,
            gracePeriodSeconds: 1 days,
            maxPaymentCount: 52,
            upfrontPremium: 1 ether,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            cancelled: false,
            filled: false
        });
    }

    function getRollingBorrowerOffer(uint256 offerId)
        external
        view
        returns (
            LibEqualLendDirectStorage.OfferKind kind,
            bytes32 borrowerPositionKey,
            uint256 principal,
            uint32 paymentIntervalSeconds,
            bool allowAmortization
        )
    {
        LibEqualLendDirectStorage.RollingBorrowerOffer storage offer =
            LibEqualLendDirectStorage.s().rollingBorrowerOffers[offerId];
        return (
            LibEqualLendDirectStorage.s().offerKindById[offerId],
            offer.borrowerPositionKey,
            offer.principal,
            offer.paymentIntervalSeconds,
            offer.allowAmortization
        );
    }

    function setFixedAgreement(
        uint256 agreementId,
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 principal
    ) external {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        store.agreementKindById[agreementId] = LibEqualLendDirectStorage.AgreementKind.Fixed;
        store.fixedAgreements[agreementId] = LibEqualLendDirectStorage.FixedAgreement({
            agreementId: agreementId,
            kind: LibEqualLendDirectStorage.AgreementKind.Fixed,
            status: LibEqualLendDirectStorage.AgreementStatus.Active,
            lenderPositionKey: lenderPositionKey,
            borrowerPositionKey: borrowerPositionKey,
            lender: address(0xAA),
            borrower: address(0xBB),
            lenderPositionId: 101,
            borrowerPositionId: 202,
            lenderPoolId: 1,
            collateralPoolId: 2,
            borrowAsset: address(0xCC),
            collateralAsset: address(0xDD),
            principal: principal,
            userInterest: 2 ether,
            dueTimestamp: uint64(block.timestamp + 30 days),
            collateralLocked: principal / 2,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: true
        });
    }

    function getFixedAgreement(uint256 agreementId)
        external
        view
        returns (
            LibEqualLendDirectStorage.AgreementKind kind,
            LibEqualLendDirectStorage.AgreementStatus status,
            bytes32 lenderPositionKey,
            bytes32 borrowerPositionKey,
            uint256 principal
        )
    {
        LibEqualLendDirectStorage.FixedAgreement storage agreement =
            LibEqualLendDirectStorage.s().fixedAgreements[agreementId];
        return (
            LibEqualLendDirectStorage.s().agreementKindById[agreementId],
            agreement.status,
            agreement.lenderPositionKey,
            agreement.borrowerPositionKey,
            agreement.principal
        );
    }

    function setRollingAgreement(
        uint256 agreementId,
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 principal
    ) external {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        store.agreementKindById[agreementId] = LibEqualLendDirectStorage.AgreementKind.Rolling;
        store.rollingAgreements[agreementId] = LibEqualLendDirectStorage.RollingAgreement({
            agreementId: agreementId,
            kind: LibEqualLendDirectStorage.AgreementKind.Rolling,
            status: LibEqualLendDirectStorage.AgreementStatus.Active,
            lenderPositionKey: lenderPositionKey,
            borrowerPositionKey: borrowerPositionKey,
            lender: address(0xAB),
            borrower: address(0xBC),
            lenderPositionId: 303,
            borrowerPositionId: 404,
            lenderPoolId: 3,
            collateralPoolId: 4,
            borrowAsset: address(0xCD),
            collateralAsset: address(0xDE),
            principal: principal,
            outstandingPrincipal: principal - 1 ether,
            collateralLocked: principal / 3,
            upfrontPremium: 1 ether,
            nextDue: uint64(block.timestamp + 7 days),
            lastAccrualTimestamp: uint64(block.timestamp),
            arrears: 2 ether,
            paymentCount: 4,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 950,
            gracePeriodSeconds: 1 days,
            maxPaymentCount: 52,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: false
        });
    }

    function getRollingAgreement(uint256 agreementId)
        external
        view
        returns (
            LibEqualLendDirectStorage.AgreementKind kind,
            LibEqualLendDirectStorage.AgreementStatus status,
            bytes32 lenderPositionKey,
            bytes32 borrowerPositionKey,
            uint256 outstandingPrincipal,
            uint16 paymentCount
        )
    {
        LibEqualLendDirectStorage.RollingAgreement storage agreement =
            LibEqualLendDirectStorage.s().rollingAgreements[agreementId];
        return (
            LibEqualLendDirectStorage.s().agreementKindById[agreementId],
            agreement.status,
            agreement.lenderPositionKey,
            agreement.borrowerPositionKey,
            agreement.outstandingPrincipal,
            agreement.paymentCount
        );
    }

    function addFixedLenderOfferIndex(bytes32 positionKey, uint256 offerId) external {
        LibEqualLendDirectStorage.addFixedLenderOffer(LibEqualLendDirectStorage.s(), positionKey, offerId);
    }

    function removeFixedLenderOfferIndex(bytes32 positionKey, uint256 offerId) external {
        LibEqualLendDirectStorage.removeFixedLenderOffer(LibEqualLendDirectStorage.s(), positionKey, offerId);
    }

    function fixedLenderOfferIndexContains(bytes32 positionKey, uint256 offerId) external view returns (bool) {
        return LibEqualLendDirectStorage.contains(LibEqualLendDirectStorage.s().fixedLenderOfferIndex, positionKey, offerId);
    }

    function fixedLenderOfferIndexCount(bytes32 positionKey) external view returns (uint256) {
        return LibEqualLendDirectStorage.count(LibEqualLendDirectStorage.s().fixedLenderOfferIndex, positionKey);
    }

    function fixedLenderOfferIndexIds(bytes32 positionKey) external view returns (uint256[] memory ids_) {
        return _copyIds(LibEqualLendDirectStorage.ids(LibEqualLendDirectStorage.s().fixedLenderOfferIndex, positionKey));
    }

    function addBorrowerAgreementIndex(bytes32 positionKey, uint256 agreementId) external {
        LibEqualLendDirectStorage.addBorrowerAgreement(LibEqualLendDirectStorage.s(), positionKey, agreementId);
    }

    function removeBorrowerAgreementIndex(bytes32 positionKey, uint256 agreementId) external {
        LibEqualLendDirectStorage.removeBorrowerAgreement(LibEqualLendDirectStorage.s(), positionKey, agreementId);
    }

    function borrowerAgreementIndexContains(bytes32 positionKey, uint256 agreementId) external view returns (bool) {
        return LibEqualLendDirectStorage.contains(LibEqualLendDirectStorage.s().borrowerAgreementIndex, positionKey, agreementId);
    }

    function borrowerAgreementIndexIds(bytes32 positionKey) external view returns (uint256[] memory ids_) {
        return _copyIds(LibEqualLendDirectStorage.ids(LibEqualLendDirectStorage.s().borrowerAgreementIndex, positionKey));
    }

    function setAlphaNextLineId(uint256 nextLineId) external {
        LibEqualScaleAlphaStorage.s().nextLineId = nextLineId;
    }

    function alphaNextLineId() external view returns (uint256) {
        return LibEqualScaleAlphaStorage.s().nextLineId;
    }

    function setOptionsNextSeriesId(uint256 nextOptionSeriesId) external {
        LibOptionsStorage.s().nextOptionSeriesId = nextOptionSeriesId;
    }

    function optionsNextSeriesId() external view returns (uint256) {
        return LibOptionsStorage.s().nextOptionSeriesId;
    }

    function setOptionTokenImplementation(address implementation) external {
        LibOptionTokenStorage.s().optionToken = implementation;
    }

    function optionTokenImplementation() external view returns (address) {
        return LibOptionTokenStorage.s().optionToken;
    }

    function isTerminalStatus(LibEqualLendDirectStorage.AgreementStatus status) external pure returns (bool) {
        return LibEqualLendDirectStorage.isTerminalStatus(status);
    }

    function setRewardAccrued(uint256 programId, bytes32 positionKey, uint256 amount) external {
        LibEdenRewardsStorage.s().accruedRewards[programId][positionKey] = amount;
    }

    function rewardAccrued(uint256 programId, bytes32 positionKey) external view returns (uint256) {
        return LibEdenRewardsStorage.s().accruedRewards[programId][positionKey];
    }

    function _copyIds(uint256[] storage source) private view returns (uint256[] memory target) {
        target = new uint256[](source.length);
        for (uint256 i = 0; i < source.length; i++) {
            target[i] = source[i];
        }
    }
}

contract LibEqualLendDirectStorageTest is Test {
    EqualLendDirectStorageHarness internal harness;

    bytes32 internal constant POSITION_KEY = keccak256("position-key");
    bytes32 internal constant OTHER_POSITION_KEY = keccak256("other-position-key");

    function setUp() public {
        harness = new EqualLendDirectStorageHarness();
    }

    function test_storageSlot_isIsolatedFromExistingNamespaces() external view {
        bytes32 slot_ = harness.directSlot();

        assertEq(slot_, keccak256("equalfi.equallend.direct.storage"), "unexpected direct slot");
        assertTrue(slot_ != LibAppStorage.APP_STORAGE_POSITION, "collides with app storage");
        assertTrue(slot_ != LibDiamond.DIAMOND_STORAGE_POSITION, "collides with diamond storage");
        assertTrue(slot_ != LibEncumbrance.STORAGE_POSITION, "collides with encumbrance");
        assertTrue(slot_ != LibPositionNFT.POSITION_NFT_STORAGE_POSITION, "collides with position nft");
        assertTrue(slot_ != LibPositionAgentStorage.STORAGE_POSITION, "collides with position agent");
        assertTrue(slot_ != LibEdenRewardsStorage.STORAGE_POSITION, "collides with eden rewards");
        assertTrue(slot_ != LibEqualScaleAlphaStorage.STORAGE_POSITION, "collides with equalscale alpha");
        assertTrue(slot_ != LibOptionsStorage.OPTIONS_STORAGE_POSITION, "collides with options");
        assertTrue(slot_ != LibOptionTokenStorage.OPTION_TOKEN_STORAGE_POSITION, "collides with option token");
        assertTrue(slot_ != LibEqualXSoloAmmStorage.STORAGE_POSITION, "collides with equalx solo amm");
        assertTrue(slot_ != LibEqualXCommunityAmmStorage.STORAGE_POSITION, "collides with equalx community amm");
        assertTrue(slot_ != LibEqualXCurveStorage.STORAGE_POSITION, "collides with equalx curve");
    }

    function test_configValidation_rejectsOutOfBoundsConfigs() external {
        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        harness.setDirectConfig(
            LibEqualLendDirectStorage.DirectConfig({
                platformFeeBps: 10_001,
                interestLenderBps: 7_000,
                platformFeeLenderBps: 2_000,
                defaultLenderBps: 8_000,
                minInterestDuration: 1 days
            })
        );

        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        harness.setDirectConfig(
            LibEqualLendDirectStorage.DirectConfig({
                platformFeeBps: 100,
                interestLenderBps: 7_000,
                platformFeeLenderBps: 2_000,
                defaultLenderBps: 8_000,
                minInterestDuration: 0
            })
        );

        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        harness.setRollingConfig(
            LibEqualLendDirectStorage.DirectRollingConfig({
                minPaymentIntervalSeconds: 0,
                maxPaymentCount: 52,
                maxUpfrontPremiumBps: 5_000,
                minRollingApyBps: 100,
                maxRollingApyBps: 2_000,
                defaultPenaltyBps: 800,
                minPaymentBps: 500
            })
        );

        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        harness.setRollingConfig(
            LibEqualLendDirectStorage.DirectRollingConfig({
                minPaymentIntervalSeconds: 1 days,
                maxPaymentCount: 52,
                maxUpfrontPremiumBps: 5_000,
                minRollingApyBps: 2_500,
                maxRollingApyBps: 2_000,
                defaultPenaltyBps: 800,
                minPaymentBps: 500
            })
        );
    }

    function test_storageWrites_doNotOverlapOptionsAlphaOrRewards() external {
        LibEqualLendDirectStorage.DirectConfig memory cfg = LibEqualLendDirectStorage.DirectConfig({
            platformFeeBps: 100,
            interestLenderBps: 7_000,
            platformFeeLenderBps: 2_500,
            defaultLenderBps: 8_000,
            minInterestDuration: 1 days
        });
        LibEqualLendDirectStorage.DirectRollingConfig memory rollingCfg = LibEqualLendDirectStorage.DirectRollingConfig({
            minPaymentIntervalSeconds: 1 days,
            maxPaymentCount: 52,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 100,
            maxRollingApyBps: 2_000,
            defaultPenaltyBps: 800,
            minPaymentBps: 500
        });

        harness.setDirectConfig(cfg);
        harness.setRollingConfig(rollingCfg);
        uint256 offerId = harness.allocateOfferId();
        uint256 agreementId = harness.allocateAgreementId();
        harness.setFixedLenderOffer(offerId, POSITION_KEY, address(0xA11CE), 7, 100 ether, 55 ether);
        harness.setLenderRatioOffer(offerId + 1, POSITION_KEY, address(0xB0B), 8, 150 ether, 120 ether);
        harness.setRollingBorrowerOffer(offerId + 2, OTHER_POSITION_KEY, address(0xCAFE), 9, 90 ether);
        harness.setFixedAgreement(agreementId, POSITION_KEY, OTHER_POSITION_KEY, 45 ether);
        harness.setRollingAgreement(agreementId + 1, OTHER_POSITION_KEY, POSITION_KEY, 60 ether);

        assertEq(harness.alphaNextLineId(), 0, "direct write mutated alpha");
        assertEq(harness.optionsNextSeriesId(), 0, "direct write mutated options");
        assertEq(harness.optionTokenImplementation(), address(0), "direct write mutated option token");
        assertEq(harness.rewardAccrued(1, POSITION_KEY), 0, "direct write mutated rewards");

        harness.setAlphaNextLineId(77);
        harness.setOptionsNextSeriesId(88);
        harness.setOptionTokenImplementation(address(0xDEAD));
        harness.setRewardAccrued(1, POSITION_KEY, 99);

        LibEqualLendDirectStorage.DirectConfig memory storedCfg = harness.getDirectConfig();
        assertEq(storedCfg.platformFeeBps, cfg.platformFeeBps, "config platform fee mutated");
        assertEq(storedCfg.interestLenderBps, cfg.interestLenderBps, "config interest share mutated");
        assertEq(storedCfg.platformFeeLenderBps, cfg.platformFeeLenderBps, "config platform share mutated");
        assertEq(storedCfg.defaultLenderBps, cfg.defaultLenderBps, "config default share mutated");
        assertEq(storedCfg.minInterestDuration, cfg.minInterestDuration, "config duration mutated");

        LibEqualLendDirectStorage.DirectRollingConfig memory storedRollingCfg = harness.getRollingConfig();
        assertEq(storedRollingCfg.minPaymentIntervalSeconds, rollingCfg.minPaymentIntervalSeconds, "rolling interval mutated");
        assertEq(storedRollingCfg.maxPaymentCount, rollingCfg.maxPaymentCount, "rolling payment count mutated");
        assertEq(storedRollingCfg.maxUpfrontPremiumBps, rollingCfg.maxUpfrontPremiumBps, "rolling premium mutated");
        assertEq(storedRollingCfg.maxRollingApyBps, rollingCfg.maxRollingApyBps, "rolling apy mutated");

        assertEq(harness.alphaNextLineId(), 77, "alpha write missing");
        assertEq(harness.optionsNextSeriesId(), 88, "options write missing");
        assertEq(harness.optionTokenImplementation(), address(0xDEAD), "option token write missing");
        assertEq(harness.rewardAccrued(1, POSITION_KEY), 99, "reward write missing");
    }

    function test_fixedLenderOffer_roundTripsWithKindDiscriminator() external {
        uint256 offerId = harness.allocateOfferId();
        harness.setFixedLenderOffer(offerId, POSITION_KEY, address(0xA11CE), 7, 100 ether, 55 ether);

        (
            LibEqualLendDirectStorage.OfferKind fixedKind,
            bytes32 fixedLenderKey,
            address fixedLender,
            uint256 fixedLenderPositionId,
            uint256 fixedPrincipal,
            uint256 fixedCollateralLocked,
            bool fixedAllowLenderCall
        ) = harness.getFixedLenderOffer(offerId);
        assertEq(uint256(fixedKind), uint256(LibEqualLendDirectStorage.OfferKind.FixedLender), "fixed offer kind");
        assertEq(fixedLenderKey, POSITION_KEY, "fixed offer key");
        assertEq(fixedLender, address(0xA11CE), "fixed offer lender");
        assertEq(fixedLenderPositionId, 7, "fixed offer lender position");
        assertEq(fixedPrincipal, 100 ether, "fixed offer principal");
        assertEq(fixedCollateralLocked, 55 ether, "fixed offer collateral");
        assertTrue(fixedAllowLenderCall, "fixed offer lender call");
    }

    function test_lenderRatioOffer_roundTripsWithRemainingCapacityState() external {
        uint256 offerId = harness.allocateOfferId();
        harness.setLenderRatioOffer(offerId, POSITION_KEY, address(0xB0B), 8, 150 ether, 120 ether);

        (
            LibEqualLendDirectStorage.OfferKind ratioKind,
            uint256 ratioPrincipalCap,
            uint256 ratioPrincipalRemaining,
            uint256 ratioPriceNumerator
        ) = harness.getLenderRatioOffer(offerId);
        assertEq(uint256(ratioKind), uint256(LibEqualLendDirectStorage.OfferKind.RatioTrancheLender), "ratio offer kind");
        assertEq(ratioPrincipalCap, 150 ether, "ratio cap");
        assertEq(ratioPrincipalRemaining, 120 ether, "ratio remaining");
        assertEq(ratioPriceNumerator, 3, "ratio numerator");
    }

    function test_rollingBorrowerOffer_roundTripsWithCadenceState() external {
        uint256 offerId = harness.allocateOfferId();
        harness.setRollingBorrowerOffer(offerId, OTHER_POSITION_KEY, address(0xCAFE), 9, 90 ether);

        (
            LibEqualLendDirectStorage.OfferKind rollingKind,
            bytes32 rollingBorrowerKey,
            uint256 rollingPrincipal,
            uint32 rollingInterval,
            bool rollingAllowAmortization
        ) = harness.getRollingBorrowerOffer(offerId);
        assertEq(uint256(rollingKind), uint256(LibEqualLendDirectStorage.OfferKind.RollingBorrower), "rolling offer kind");
        assertEq(rollingBorrowerKey, OTHER_POSITION_KEY, "rolling offer key");
        assertEq(rollingPrincipal, 90 ether, "rolling principal");
        assertEq(rollingInterval, 7 days, "rolling interval");
        assertTrue(rollingAllowAmortization, "rolling amortization");
    }

    function test_agreementStructs_roundTripWithExplicitKindsAndStatuses() external {
        uint256 agreementId = harness.allocateAgreementId();
        harness.setFixedAgreement(agreementId, POSITION_KEY, OTHER_POSITION_KEY, 45 ether);
        harness.setRollingAgreement(agreementId + 1, OTHER_POSITION_KEY, POSITION_KEY, 60 ether);

        (
            LibEqualLendDirectStorage.AgreementKind fixedAgreementKind,
            LibEqualLendDirectStorage.AgreementStatus fixedAgreementStatus,
            bytes32 fixedAgreementLenderKey,
            bytes32 fixedAgreementBorrowerKey,
            uint256 fixedAgreementPrincipal
        ) = harness.getFixedAgreement(agreementId);
        assertEq(uint256(fixedAgreementKind), uint256(LibEqualLendDirectStorage.AgreementKind.Fixed), "fixed agreement kind");
        assertEq(uint256(fixedAgreementStatus), uint256(LibEqualLendDirectStorage.AgreementStatus.Active), "fixed agreement status");
        assertEq(fixedAgreementLenderKey, POSITION_KEY, "fixed agreement lender key");
        assertEq(fixedAgreementBorrowerKey, OTHER_POSITION_KEY, "fixed agreement borrower key");
        assertEq(fixedAgreementPrincipal, 45 ether, "fixed agreement principal");

        (
            LibEqualLendDirectStorage.AgreementKind rollingAgreementKind,
            LibEqualLendDirectStorage.AgreementStatus rollingAgreementStatus,
            bytes32 rollingAgreementLenderKey,
            bytes32 rollingAgreementBorrowerKey,
            uint256 rollingOutstandingPrincipal,
            uint16 rollingPaymentCount
        ) = harness.getRollingAgreement(agreementId + 1);
        assertEq(uint256(rollingAgreementKind), uint256(LibEqualLendDirectStorage.AgreementKind.Rolling), "rolling agreement kind");
        assertEq(uint256(rollingAgreementStatus), uint256(LibEqualLendDirectStorage.AgreementStatus.Active), "rolling agreement status");
        assertEq(rollingAgreementLenderKey, OTHER_POSITION_KEY, "rolling agreement lender key");
        assertEq(rollingAgreementBorrowerKey, POSITION_KEY, "rolling agreement borrower key");
        assertEq(rollingOutstandingPrincipal, 59 ether, "rolling outstanding principal");
        assertEq(rollingPaymentCount, 4, "rolling payment count");
    }

    function test_agreementStatus_terminalStatesAreExplicit() external view {
        assertFalse(harness.isTerminalStatus(LibEqualLendDirectStorage.AgreementStatus.None), "none is terminal");
        assertFalse(harness.isTerminalStatus(LibEqualLendDirectStorage.AgreementStatus.Active), "active is terminal");
        assertTrue(harness.isTerminalStatus(LibEqualLendDirectStorage.AgreementStatus.Repaid), "repaid not terminal");
        assertTrue(harness.isTerminalStatus(LibEqualLendDirectStorage.AgreementStatus.Defaulted), "defaulted not terminal");
        assertTrue(harness.isTerminalStatus(LibEqualLendDirectStorage.AgreementStatus.Exercised), "exercised not terminal");
    }

    function test_positionIndexes_addAndRemoveSymmetrically() external {
        harness.addFixedLenderOfferIndex(POSITION_KEY, 11);
        harness.addFixedLenderOfferIndex(POSITION_KEY, 22);
        harness.addFixedLenderOfferIndex(POSITION_KEY, 33);
        harness.addFixedLenderOfferIndex(POSITION_KEY, 22);

        uint256[] memory offerIds = harness.fixedLenderOfferIndexIds(POSITION_KEY);
        assertEq(offerIds.length, 3, "duplicate offer insert");
        assertEq(harness.fixedLenderOfferIndexCount(POSITION_KEY), 3, "offer index count");
        assertTrue(harness.fixedLenderOfferIndexContains(POSITION_KEY, 11), "offer 11 missing");
        assertTrue(harness.fixedLenderOfferIndexContains(POSITION_KEY, 22), "offer 22 missing");
        assertTrue(harness.fixedLenderOfferIndexContains(POSITION_KEY, 33), "offer 33 missing");

        harness.removeFixedLenderOfferIndex(POSITION_KEY, 22);

        offerIds = harness.fixedLenderOfferIndexIds(POSITION_KEY);
        assertEq(offerIds.length, 2, "offer index remove");
        assertTrue(harness.fixedLenderOfferIndexContains(POSITION_KEY, 11), "offer 11 removed unexpectedly");
        assertFalse(harness.fixedLenderOfferIndexContains(POSITION_KEY, 22), "offer 22 still present");
        assertTrue(harness.fixedLenderOfferIndexContains(POSITION_KEY, 33), "offer 33 missing after swap-pop");

        harness.removeFixedLenderOfferIndex(POSITION_KEY, 999);
        assertEq(harness.fixedLenderOfferIndexCount(POSITION_KEY), 2, "missing remove mutated offer index");

        harness.addBorrowerAgreementIndex(OTHER_POSITION_KEY, 101);
        harness.addBorrowerAgreementIndex(OTHER_POSITION_KEY, 202);
        harness.addBorrowerAgreementIndex(OTHER_POSITION_KEY, 303);

        uint256[] memory agreementIds = harness.borrowerAgreementIndexIds(OTHER_POSITION_KEY);
        assertEq(agreementIds.length, 3, "agreement insert count");
        assertTrue(harness.borrowerAgreementIndexContains(OTHER_POSITION_KEY, 101), "agreement 101 missing");
        assertTrue(harness.borrowerAgreementIndexContains(OTHER_POSITION_KEY, 202), "agreement 202 missing");
        assertTrue(harness.borrowerAgreementIndexContains(OTHER_POSITION_KEY, 303), "agreement 303 missing");

        harness.removeBorrowerAgreementIndex(OTHER_POSITION_KEY, 101);
        agreementIds = harness.borrowerAgreementIndexIds(OTHER_POSITION_KEY);
        assertEq(agreementIds.length, 2, "agreement remove count");
        assertFalse(harness.borrowerAgreementIndexContains(OTHER_POSITION_KEY, 101), "agreement 101 still present");
        assertTrue(harness.borrowerAgreementIndexContains(OTHER_POSITION_KEY, 202), "agreement 202 missing after remove");
        assertTrue(harness.borrowerAgreementIndexContains(OTHER_POSITION_KEY, 303), "agreement 303 missing after remove");
    }
}
