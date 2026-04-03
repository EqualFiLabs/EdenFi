// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualLendDirectConfigFacet} from "src/equallend/EqualLendDirectConfigFacet.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "src/equallend/EqualLendDirectRollingOfferFacet.sol";
import {EqualLendDirectViewFacet} from "src/equallend/EqualLendDirectViewFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {DirectError_InvalidConfiguration} from "src/libraries/Errors.sol";

contract MockERC20DirectView is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualLendDirectViewHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectFixedOfferFacet,
    EqualLendDirectRollingOfferFacet,
    EqualLendDirectViewFacet,
    EqualLendDirectConfigFacet
{
    struct SeedFixedAgreementParams {
        uint256 lenderPositionId;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principal;
        uint256 userInterest;
        uint256 dueTimestamp;
        uint256 collateralLocked;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    struct SeedRollingAgreementParams {
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
        uint256 nextDue;
        uint256 lastAccrualTimestamp;
        uint256 arrears;
        uint256 paymentCount;
        uint256 paymentIntervalSeconds;
        uint256 rollingApyBps;
        uint256 gracePeriodSeconds;
        uint256 maxPaymentCount;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
    }

    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setTreasury(address treasury_) external {
        LibAppStorage.s().treasury = treasury_;
    }

    function setFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = uint16(treasuryBps);
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
        store.activeCreditShareConfigured = true;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function seedFixedAgreement(SeedFixedAgreementParams calldata params) external returns (uint256 agreementId) {
        if (params.dueTimestamp > type(uint64).max) revert();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        bytes32 lenderKey = nft.getPositionKey(params.lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(params.borrowerPositionId);

        agreementId = LibEqualLendDirectStorage.allocateAgreementId(store);
        store.agreementKindById[agreementId] = LibEqualLendDirectStorage.AgreementKind.Fixed;
        store.fixedAgreements[agreementId] = LibEqualLendDirectStorage.FixedAgreement({
            agreementId: agreementId,
            kind: LibEqualLendDirectStorage.AgreementKind.Fixed,
            status: LibEqualLendDirectStorage.AgreementStatus.Active,
            lenderPositionKey: lenderKey,
            borrowerPositionKey: borrowerKey,
            lender: nft.ownerOf(params.lenderPositionId),
            borrower: nft.ownerOf(params.borrowerPositionId),
            lenderPositionId: params.lenderPositionId,
            borrowerPositionId: params.borrowerPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            borrowAsset: params.borrowAsset,
            collateralAsset: params.collateralAsset,
            principal: params.principal,
            userInterest: params.userInterest,
            dueTimestamp: uint64(params.dueTimestamp),
            collateralLocked: params.collateralLocked,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall
        });

        LibEqualLendDirectStorage.addBorrowerAgreement(store, borrowerKey, agreementId);
        LibEqualLendDirectStorage.addLenderAgreement(store, lenderKey, agreementId);
    }

    function seedRollingAgreement(SeedRollingAgreementParams calldata params) external returns (uint256 agreementId) {
        if (
            params.nextDue > type(uint64).max || params.lastAccrualTimestamp > type(uint64).max
                || params.paymentCount > type(uint16).max || params.paymentIntervalSeconds > type(uint32).max
                || params.rollingApyBps > type(uint16).max || params.gracePeriodSeconds > type(uint32).max
                || params.maxPaymentCount > type(uint16).max
        ) revert();

        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        bytes32 lenderKey = nft.getPositionKey(params.lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(params.borrowerPositionId);

        agreementId = LibEqualLendDirectStorage.allocateAgreementId(store);
        store.agreementKindById[agreementId] = LibEqualLendDirectStorage.AgreementKind.Rolling;
        store.rollingAgreements[agreementId] = LibEqualLendDirectStorage.RollingAgreement({
            agreementId: agreementId,
            kind: LibEqualLendDirectStorage.AgreementKind.Rolling,
            status: LibEqualLendDirectStorage.AgreementStatus.Active,
            lenderPositionKey: lenderKey,
            borrowerPositionKey: borrowerKey,
            lender: nft.ownerOf(params.lenderPositionId),
            borrower: nft.ownerOf(params.borrowerPositionId),
            lenderPositionId: params.lenderPositionId,
            borrowerPositionId: params.borrowerPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            borrowAsset: params.borrowAsset,
            collateralAsset: params.collateralAsset,
            principal: params.principal,
            outstandingPrincipal: params.outstandingPrincipal,
            collateralLocked: params.collateralLocked,
            upfrontPremium: params.upfrontPremium,
            nextDue: uint64(params.nextDue),
            lastAccrualTimestamp: uint64(params.lastAccrualTimestamp),
            arrears: params.arrears,
            paymentCount: uint16(params.paymentCount),
            paymentIntervalSeconds: uint32(params.paymentIntervalSeconds),
            rollingApyBps: uint16(params.rollingApyBps),
            gracePeriodSeconds: uint32(params.gracePeriodSeconds),
            maxPaymentCount: uint16(params.maxPaymentCount),
            allowAmortization: params.allowAmortization,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise
        });

        LibEqualLendDirectStorage.addBorrowerAgreement(store, borrowerKey, agreementId);
        LibEqualLendDirectStorage.addLenderAgreement(store, lenderKey, agreementId);
        LibEqualLendDirectStorage.addRollingBorrowerAgreement(store, borrowerKey, agreementId);
        LibEqualLendDirectStorage.addRollingLenderAgreement(store, lenderKey, agreementId);
    }

    function setLenderRatioOfferState(uint256 offerId, uint256 principalRemaining, bool cancelled, bool filled) external {
        LibEqualLendDirectStorage.LenderRatioTrancheOffer storage offer = LibEqualLendDirectStorage.s().lenderRatioOffers[offerId];
        offer.principalRemaining = principalRemaining;
        offer.cancelled = cancelled;
        offer.filled = filled;
    }

    function setBorrowerRatioOfferState(uint256 offerId, uint256 collateralRemaining, bool cancelled, bool filled)
        external
    {
        LibEqualLendDirectStorage.BorrowerRatioTrancheOffer storage offer =
            LibEqualLendDirectStorage.s().borrowerRatioOffers[offerId];
        offer.collateralRemaining = collateralRemaining;
        offer.cancelled = cancelled;
        offer.filled = filled;
    }
}

contract EqualLendDirectViewFacetTest is Test {
    uint256 internal constant YEAR_IN_SECONDS = 365 days;

    struct OfferIds {
        uint256 fixedLenderOfferId;
        uint256 lenderRatioOfferId;
        uint256 rollingLenderOfferId;
        uint256 fixedBorrowerOfferId;
        uint256 borrowerRatioOfferId;
        uint256 rollingBorrowerOfferId;
    }

    struct AgreementIds {
        uint256 fixedAgreementId;
        uint256 rollingAgreementId;
    }

    EqualLendDirectViewHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20DirectView internal borrowToken;
    MockERC20DirectView internal collateralToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal treasury = makeAddr("treasury");
    address internal timelock = makeAddr("timelock");

    function setUp() public {
        harness = new EqualLendDirectViewHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1_000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        borrowToken = new MockERC20DirectView("Borrow", "BRW");
        collateralToken = new MockERC20DirectView("Collateral", "COL");

        _initPool(1, address(borrowToken));
        _initPool(2, address(collateralToken));

        harness.setDirectConfig(
            LibEqualLendDirectStorage.DirectConfig({
                platformFeeBps: 100,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 10_000,
                defaultLenderBps: 8_000,
                minInterestDuration: 1 days
            })
        );
        harness.setRollingConfig(
            LibEqualLendDirectStorage.DirectRollingConfig({
                minPaymentIntervalSeconds: 7 days,
                maxPaymentCount: 12,
                maxUpfrontPremiumBps: 1_000,
                minRollingApyBps: 200,
                maxRollingApyBps: 2_000,
                defaultPenaltyBps: 500,
                minPaymentBps: 500
            })
        );
    }

    function test_roundTripReads_returnTypedDirectOffersAndAgreements() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 900 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 900 ether, collateralToken);

        OfferIds memory offers = _postOfferKinds(lenderPositionId, borrowerPositionId);
        AgreementIds memory agreements = _seedAgreementKinds(lenderPositionId, borrowerPositionId, 100 ether, 140 ether, 120 ether, 170 ether);

        assertEq(
            uint256(harness.getOfferKind(offers.fixedLenderOfferId)),
            uint256(LibEqualLendDirectStorage.OfferKind.FixedLender),
            "fixed lender kind"
        );
        assertEq(
            uint256(harness.getOfferKind(offers.fixedBorrowerOfferId)),
            uint256(LibEqualLendDirectStorage.OfferKind.FixedBorrower),
            "fixed borrower kind"
        );
        assertEq(
            uint256(harness.getOfferKind(offers.lenderRatioOfferId)),
            uint256(LibEqualLendDirectStorage.OfferKind.RatioTrancheLender),
            "lender ratio kind"
        );
        assertEq(
            uint256(harness.getOfferKind(offers.borrowerRatioOfferId)),
            uint256(LibEqualLendDirectStorage.OfferKind.RatioTrancheBorrower),
            "borrower ratio kind"
        );
        assertEq(
            uint256(harness.getOfferKind(offers.rollingLenderOfferId)),
            uint256(LibEqualLendDirectStorage.OfferKind.RollingLender),
            "rolling lender kind"
        );
        assertEq(
            uint256(harness.getOfferKind(offers.rollingBorrowerOfferId)),
            uint256(LibEqualLendDirectStorage.OfferKind.RollingBorrower),
            "rolling borrower kind"
        );

        _assertTypedOffers(offers, lenderPositionId, borrowerPositionId);

        assertEq(
            uint256(harness.getAgreementKind(agreements.fixedAgreementId)),
            uint256(LibEqualLendDirectStorage.AgreementKind.Fixed),
            "fixed agreement kind"
        );
        assertEq(
            uint256(harness.getAgreementKind(agreements.rollingAgreementId)),
            uint256(LibEqualLendDirectStorage.AgreementKind.Rolling),
            "rolling agreement kind"
        );

        _assertTypedAgreements(agreements, borrowerPositionId);
    }

    function test_positionLookups_groupBorrowerAndLenderIdsAcrossFamilies() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 700 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 700 ether, collateralToken);

        vm.startPrank(alice);
        uint256 fixedLenderOfferId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 90 ether,
                collateralLocked: 135 ether,
                aprBps: 600,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
        uint256 lenderRatioOfferId = harness.postLenderRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principalCap: 120 ether,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: 40 ether,
                aprBps: 650,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );
        uint256 rollingLenderOfferId = harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 110 ether,
                collateralLocked: 150 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 3,
                upfrontPremium: 2 ether,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 fixedBorrowerOfferId = harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 70 ether,
                collateralLocked: 100 ether,
                aprBps: 800,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
        uint256 borrowerRatioOfferId = harness.postBorrowerRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.BorrowerRatioTrancheOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                collateralCap: 150 ether,
                priceNumerator: 1,
                priceDenominator: 2,
                minCollateralPerFill: 50 ether,
                aprBps: 900,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );
        uint256 rollingBorrowerOfferId = harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 80 ether,
                collateralLocked: 120 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 950,
                gracePeriodSeconds: 3 days,
                maxPaymentCount: 4,
                upfrontPremium: 1 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );
        vm.stopPrank();

        uint256 fixedAgreementId = harness.seedFixedAgreement(
            EqualLendDirectViewHarness.SeedFixedAgreementParams({
                lenderPositionId: lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 90 ether,
                userInterest: _fixedInterest(90 ether, 600, 14 days),
                dueTimestamp: block.timestamp + 14 days,
                collateralLocked: 135 ether,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
        uint256 rollingAgreementId = harness.seedRollingAgreement(
            EqualLendDirectViewHarness.SeedRollingAgreementParams({
                lenderPositionId: lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 110 ether,
                outstandingPrincipal: 110 ether,
                collateralLocked: 150 ether,
                upfrontPremium: 2 ether,
                nextDue: block.timestamp + 7 days,
                lastAccrualTimestamp: block.timestamp,
                arrears: 0,
                paymentCount: 0,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 3,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        EqualLendDirectViewFacet.PositionOfferIds memory borrowerOffers = harness.getBorrowerOfferIds(borrowerPositionId);
        EqualLendDirectViewFacet.PositionOfferIds memory lenderOffers = harness.getLenderOfferIds(lenderPositionId);
        EqualLendDirectViewFacet.PositionAgreementIds memory borrowerAgreements =
            harness.getBorrowerAgreementIds(borrowerPositionId);
        EqualLendDirectViewFacet.PositionAgreementIds memory lenderAgreements = harness.getLenderAgreementIds(lenderPositionId);

        assertEq(borrowerOffers.allOfferIds.length, 3, "borrower all offer count");
        assertEq(borrowerOffers.fixedOfferIds[0], fixedBorrowerOfferId, "borrower fixed offer lookup");
        assertEq(borrowerOffers.ratioOfferIds[0], borrowerRatioOfferId, "borrower ratio offer lookup");
        assertEq(borrowerOffers.rollingOfferIds[0], rollingBorrowerOfferId, "borrower rolling offer lookup");

        assertEq(lenderOffers.allOfferIds.length, 3, "lender all offer count");
        assertEq(lenderOffers.fixedOfferIds[0], fixedLenderOfferId, "lender fixed offer lookup");
        assertEq(lenderOffers.ratioOfferIds[0], lenderRatioOfferId, "lender ratio offer lookup");
        assertEq(lenderOffers.rollingOfferIds[0], rollingLenderOfferId, "lender rolling offer lookup");

        assertEq(borrowerAgreements.allAgreementIds.length, 2, "borrower all agreement count");
        assertEq(borrowerAgreements.fixedAgreementIds.length, 1, "borrower fixed agreement count");
        assertEq(borrowerAgreements.fixedAgreementIds[0], fixedAgreementId, "borrower fixed agreement lookup");
        assertEq(borrowerAgreements.rollingAgreementIds.length, 1, "borrower rolling agreement count");
        assertEq(borrowerAgreements.rollingAgreementIds[0], rollingAgreementId, "borrower rolling agreement lookup");

        assertEq(lenderAgreements.allAgreementIds.length, 2, "lender all agreement count");
        assertEq(lenderAgreements.fixedAgreementIds[0], fixedAgreementId, "lender fixed agreement lookup");
        assertEq(lenderAgreements.rollingAgreementIds[0], rollingAgreementId, "lender rolling agreement lookup");
    }

    function test_previewRollingPaymentAndStatus_trackGraceRecoveryAndPaymentCap() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 400 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 500 ether, collateralToken);

        uint256 recoverAgreementId = harness.seedRollingAgreement(
            EqualLendDirectViewHarness.SeedRollingAgreementParams({
                lenderPositionId: lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 100 ether,
                outstandingPrincipal: 100 ether,
                collateralLocked: 140 ether,
                upfrontPremium: 0,
                nextDue: block.timestamp + 7 days,
                lastAccrualTimestamp: block.timestamp,
                arrears: 0,
                paymentCount: 0,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 3,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        vm.warp(block.timestamp + 8 days);

        EqualLendDirectViewFacet.RollingPaymentPreview memory preview = harness.previewRollingPayment(recoverAgreementId);
        uint256 expectedIntervalInterest = _rollingInterest(100 ether, 900, 7 days);
        uint256 expectedCurrentInterest = _rollingInterest(100 ether, 900, 1 days);
        assertEq(preview.arrearsDue, expectedIntervalInterest, "rolling arrears preview");
        assertEq(preview.currentInterestDue, expectedCurrentInterest, "rolling current interest preview");
        assertEq(preview.totalDue, expectedIntervalInterest + expectedCurrentInterest, "rolling total due preview");
        assertEq(preview.minPayment, 5 ether, "rolling min payment preview");
        assertEq(preview.dueCountDelta, 1, "rolling due count delta preview");

        EqualLendDirectViewFacet.RollingStatusView memory status = harness.getRollingStatus(recoverAgreementId);
        assertTrue(status.isOverdue, "rolling status overdue");
        assertTrue(status.inGracePeriod, "rolling status in grace");
        assertFalse(status.canRecover, "rolling status recoverability during grace");
        assertFalse(status.isAtPaymentCap, "rolling status payment cap before threshold");

        vm.warp(block.timestamp + 2 days + 1);
        status = harness.getRollingStatus(recoverAgreementId);
        assertTrue(status.canRecover, "rolling status recoverable after grace");

        uint256 capAgreementId = harness.seedRollingAgreement(
            EqualLendDirectViewHarness.SeedRollingAgreementParams({
                lenderPositionId: lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 60 ether,
                outstandingPrincipal: 60 ether,
                collateralLocked: 90 ether,
                upfrontPremium: 0,
                nextDue: block.timestamp + 7 days,
                lastAccrualTimestamp: block.timestamp,
                arrears: 0,
                paymentCount: 1,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 1_000,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 1,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );
        status = harness.getRollingStatus(capAgreementId);
        assertTrue(status.isAtPaymentCap, "rolling status at payment cap");
    }

    function test_agreementReads_resolveLiveOwnersAfterPositionTransfer() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 500 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 600 ether, collateralToken);

        uint256 fixedAgreementId = harness.seedFixedAgreement(
            EqualLendDirectViewHarness.SeedFixedAgreementParams({
                lenderPositionId: lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 90 ether,
                userInterest: _fixedInterest(90 ether, 700, 14 days),
                dueTimestamp: block.timestamp + 14 days,
                collateralLocked: 130 ether,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );
        uint256 rollingAgreementId = harness.seedRollingAgreement(
            EqualLendDirectViewHarness.SeedRollingAgreementParams({
                lenderPositionId: lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 110 ether,
                outstandingPrincipal: 105 ether,
                collateralLocked: 150 ether,
                upfrontPremium: 2 ether,
                nextDue: block.timestamp + 7 days,
                lastAccrualTimestamp: block.timestamp,
                arrears: 0,
                paymentCount: 0,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 3,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, lenderPositionId);
        vm.prank(bob);
        positionNft.transferFrom(bob, dave, borrowerPositionId);

        LibEqualLendDirectStorage.FixedAgreement memory fixedAgreement = harness.getFixedAgreement(fixedAgreementId);
        LibEqualLendDirectStorage.RollingAgreement memory rollingAgreement = harness.getRollingAgreement(rollingAgreementId);
        EqualLendDirectViewFacet.PositionAgreementIds memory borrowerAgreements =
            harness.getBorrowerAgreementIds(borrowerPositionId);
        EqualLendDirectViewFacet.PositionAgreementIds memory lenderAgreements = harness.getLenderAgreementIds(lenderPositionId);

        assertEq(fixedAgreement.lender, carol, "fixed agreement lender owner");
        assertEq(fixedAgreement.borrower, dave, "fixed agreement borrower owner");
        assertEq(rollingAgreement.lender, carol, "rolling agreement lender owner");
        assertEq(rollingAgreement.borrower, dave, "rolling agreement borrower owner");
        assertEq(borrowerAgreements.allAgreementIds.length, 2, "borrower agreements after transfer");
        assertEq(lenderAgreements.allAgreementIds.length, 2, "lender agreements after transfer");
        assertEq(borrowerAgreements.fixedAgreementIds[0], fixedAgreementId, "borrower fixed agreement after transfer");
        assertEq(lenderAgreements.rollingAgreementIds[0], rollingAgreementId, "lender rolling agreement after transfer");
    }

    function test_trancheStatus_tracksRemainingCapacityFillabilityAndDepletion() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 400 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 500 ether, collateralToken);

        vm.prank(alice);
        uint256 lenderRatioOfferId = harness.postLenderRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principalCap: 50 ether,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: 20 ether,
                aprBps: 700,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(bob);
        uint256 borrowerRatioOfferId = harness.postBorrowerRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.BorrowerRatioTrancheOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                collateralCap: 70 ether,
                priceNumerator: 1,
                priceDenominator: 2,
                minCollateralPerFill: 30 ether,
                aprBps: 800,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        EqualLendDirectViewFacet.RatioTrancheStatus memory lenderStatus =
            harness.getLenderRatioTrancheStatus(lenderRatioOfferId);
        EqualLendDirectViewFacet.RatioTrancheStatus memory borrowerStatus =
            harness.getBorrowerRatioTrancheStatus(borrowerRatioOfferId);
        assertEq(lenderStatus.remainingCapacity, 50 ether, "initial lender ratio remaining");
        assertEq(lenderStatus.fillsRemaining, 2, "initial lender ratio fills remaining");
        assertFalse(lenderStatus.isDepleted, "initial lender ratio depletion");
        assertEq(borrowerStatus.remainingCapacity, 70 ether, "initial borrower ratio remaining");
        assertEq(borrowerStatus.fillsRemaining, 2, "initial borrower ratio fills remaining");
        assertFalse(borrowerStatus.isDepleted, "initial borrower ratio depletion");

        harness.setLenderRatioOfferState(lenderRatioOfferId, 10 ether, false, false);
        harness.setBorrowerRatioOfferState(borrowerRatioOfferId, 20 ether, false, false);

        lenderStatus = harness.getLenderRatioTrancheStatus(lenderRatioOfferId);
        borrowerStatus = harness.getBorrowerRatioTrancheStatus(borrowerRatioOfferId);
        assertEq(lenderStatus.remainingCapacity, 10 ether, "post-fill lender ratio remaining");
        assertEq(lenderStatus.fillsRemaining, 0, "post-fill lender ratio fills remaining");
        assertTrue(lenderStatus.isDepleted, "post-fill lender ratio depleted");
        assertFalse(lenderStatus.filled, "post-fill lender ratio filled flag");
        assertEq(borrowerStatus.remainingCapacity, 20 ether, "post-fill borrower ratio remaining");
        assertEq(borrowerStatus.fillsRemaining, 0, "post-fill borrower ratio fills remaining");
        assertTrue(borrowerStatus.isDepleted, "post-fill borrower ratio depleted");
        assertFalse(borrowerStatus.filled, "post-fill borrower ratio filled flag");
    }

    function test_configWrites_areOwnerOrTimelockBoundedAndValidated() external {
        vm.prank(bob);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        harness.setDirectConfig(
            LibEqualLendDirectStorage.DirectConfig({
                platformFeeBps: 150,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 9_000,
                defaultLenderBps: 8_500,
                minInterestDuration: 2 days
            })
        );

        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        harness.setDirectConfig(
            LibEqualLendDirectStorage.DirectConfig({
                platformFeeBps: 150,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 9_000,
                defaultLenderBps: 8_500,
                minInterestDuration: 0
            })
        );

        harness.setDirectConfig(
            LibEqualLendDirectStorage.DirectConfig({
                platformFeeBps: 150,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 9_000,
                defaultLenderBps: 8_500,
                minInterestDuration: 2 days
            })
        );
        LibEqualLendDirectStorage.DirectConfig memory directConfig = harness.getDirectConfig();
        assertEq(directConfig.platformFeeBps, 150, "owner direct config write");
        assertEq(directConfig.minInterestDuration, 2 days, "owner direct min duration write");

        harness.setTimelock(timelock);

        vm.prank(bob);
        vm.expectRevert(bytes("LibAccess: not owner or timelock"));
        harness.setRollingConfig(
            LibEqualLendDirectStorage.DirectRollingConfig({
                minPaymentIntervalSeconds: 1 days,
                maxPaymentCount: 8,
                maxUpfrontPremiumBps: 700,
                minRollingApyBps: 300,
                maxRollingApyBps: 1_700,
                defaultPenaltyBps: 600,
                minPaymentBps: 400
            })
        );

        vm.prank(timelock);
        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        harness.setRollingConfig(
            LibEqualLendDirectStorage.DirectRollingConfig({
                minPaymentIntervalSeconds: 0,
                maxPaymentCount: 8,
                maxUpfrontPremiumBps: 700,
                minRollingApyBps: 300,
                maxRollingApyBps: 1_700,
                defaultPenaltyBps: 600,
                minPaymentBps: 400
            })
        );

        vm.prank(timelock);
        harness.setRollingConfig(
            LibEqualLendDirectStorage.DirectRollingConfig({
                minPaymentIntervalSeconds: 1 days,
                maxPaymentCount: 8,
                maxUpfrontPremiumBps: 700,
                minRollingApyBps: 300,
                maxRollingApyBps: 1_700,
                defaultPenaltyBps: 600,
                minPaymentBps: 400
            })
        );

        LibEqualLendDirectStorage.DirectRollingConfig memory rollingConfig = harness.getDirectRollingConfig();
        assertEq(rollingConfig.minPaymentIntervalSeconds, 1 days, "timelock rolling interval write");
        assertEq(rollingConfig.maxPaymentCount, 8, "timelock rolling payment count write");
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount, MockERC20DirectView token)
        internal
        returns (uint256 positionId)
    {
        token.mint(user, amount);

        vm.prank(user);
        token.approve(address(harness), amount);

        vm.prank(user);
        positionId = harness.mintPosition(homePoolId);

        vm.prank(user);
        harness.depositToPosition(positionId, homePoolId, amount, amount);
    }

    function _initPool(uint256 poolId, address asset) internal {
        harness.initPoolWithActionFees(poolId, asset, _poolConfig(), _actionFees());
    }

    function _poolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8_000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 30;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 1_000;
    }

    function _actionFees() internal pure returns (Types.ActionFeeSet memory fees) {
        fees.borrowFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        fees.repayFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        fees.withdrawFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        fees.flashFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        fees.closeRollingFee = Types.ActionFeeConfig({amount: 0, enabled: false});
    }

    function _postOfferKinds(uint256 lenderPositionId, uint256 borrowerPositionId)
        internal
        returns (OfferIds memory offers)
    {
        vm.startPrank(alice);
        offers.fixedLenderOfferId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 100 ether,
                collateralLocked: 140 ether,
                aprBps: 700,
                durationSeconds: 30 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );
        offers.lenderRatioOfferId = harness.postLenderRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principalCap: 150 ether,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: 50 ether,
                aprBps: 650,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
        offers.rollingLenderOfferId = harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 120 ether,
                collateralLocked: 170 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 3,
                upfrontPremium: 4 ether,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );
        vm.stopPrank();

        vm.startPrank(bob);
        offers.fixedBorrowerOfferId = harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 80 ether,
                collateralLocked: 120 ether,
                aprBps: 800,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
        offers.borrowerRatioOfferId = harness.postBorrowerRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.BorrowerRatioTrancheOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                collateralCap: 180 ether,
                priceNumerator: 1,
                priceDenominator: 2,
                minCollateralPerFill: 60 ether,
                aprBps: 850,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );
        offers.rollingBorrowerOfferId = harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 90 ether,
                collateralLocked: 130 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 950,
                gracePeriodSeconds: 3 days,
                maxPaymentCount: 4,
                upfrontPremium: 3 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );
        vm.stopPrank();
    }

    function _seedAgreementKinds(
        uint256 lenderPositionId,
        uint256 borrowerPositionId,
        uint256 fixedPrincipal,
        uint256 fixedCollateral,
        uint256 rollingPrincipal,
        uint256 rollingCollateral
    ) internal returns (AgreementIds memory agreements) {
        agreements.fixedAgreementId = harness.seedFixedAgreement(
            EqualLendDirectViewHarness.SeedFixedAgreementParams({
                lenderPositionId: lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: fixedPrincipal,
                userInterest: _fixedInterest(fixedPrincipal, 700, 30 days),
                dueTimestamp: block.timestamp + 30 days,
                collateralLocked: fixedCollateral,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );
        agreements.rollingAgreementId = harness.seedRollingAgreement(
            EqualLendDirectViewHarness.SeedRollingAgreementParams({
                lenderPositionId: lenderPositionId,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: rollingPrincipal,
                outstandingPrincipal: rollingPrincipal,
                collateralLocked: rollingCollateral,
                upfrontPremium: 4 ether,
                nextDue: block.timestamp + 7 days,
                lastAccrualTimestamp: block.timestamp,
                arrears: 0,
                paymentCount: 0,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 3,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );
    }

    function _assertTypedOffers(OfferIds memory offers, uint256 lenderPositionId, uint256 borrowerPositionId) internal view {
        LibEqualLendDirectStorage.FixedLenderOffer memory fixedLenderOffer = harness.getFixedLenderOffer(offers.fixedLenderOfferId);
        LibEqualLendDirectStorage.FixedBorrowerOffer memory fixedBorrowerOffer =
            harness.getFixedBorrowerOffer(offers.fixedBorrowerOfferId);
        LibEqualLendDirectStorage.LenderRatioTrancheOffer memory lenderRatioOffer =
            harness.getLenderRatioTrancheOffer(offers.lenderRatioOfferId);
        LibEqualLendDirectStorage.BorrowerRatioTrancheOffer memory borrowerRatioOffer =
            harness.getBorrowerRatioTrancheOffer(offers.borrowerRatioOfferId);
        LibEqualLendDirectStorage.RollingLenderOffer memory rollingLenderOffer =
            harness.getRollingLenderOffer(offers.rollingLenderOfferId);
        LibEqualLendDirectStorage.RollingBorrowerOffer memory rollingBorrowerOffer =
            harness.getRollingBorrowerOffer(offers.rollingBorrowerOfferId);

        assertEq(fixedLenderOffer.lenderPositionId, lenderPositionId, "fixed lender offer read");
        assertEq(fixedBorrowerOffer.borrowerPositionId, borrowerPositionId, "fixed borrower offer read");
        assertEq(lenderRatioOffer.principalCap, 150 ether, "lender ratio principal cap read");
        assertEq(borrowerRatioOffer.collateralCap, 180 ether, "borrower ratio collateral cap read");
        assertEq(rollingLenderOffer.upfrontPremium, 4 ether, "rolling lender premium read");
        assertEq(rollingBorrowerOffer.maxPaymentCount, 4, "rolling borrower payment count read");
    }

    function _assertTypedAgreements(AgreementIds memory agreements, uint256 borrowerPositionId) internal view {
        LibEqualLendDirectStorage.FixedAgreement memory fixedAgreement = harness.getFixedAgreement(agreements.fixedAgreementId);
        LibEqualLendDirectStorage.RollingAgreement memory rollingAgreement = harness.getRollingAgreement(agreements.rollingAgreementId);
        assertEq(fixedAgreement.principal, 100 ether, "fixed agreement principal read");
        assertEq(fixedAgreement.borrowerPositionId, borrowerPositionId, "fixed agreement borrower read");
        assertEq(rollingAgreement.principal, 120 ether, "rolling agreement principal read");
        assertEq(rollingAgreement.upfrontPremium, 4 ether, "rolling agreement premium read");
    }

    function _fixedInterest(uint256 principal, uint16 aprBps, uint64 durationSeconds)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(principal, uint256(aprBps) * durationSeconds, YEAR_IN_SECONDS * 10_000, Math.Rounding.Ceil);
    }

    function _rollingInterest(uint256 principal, uint16 apyBps, uint256 durationSeconds)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(principal, uint256(apyBps) * durationSeconds, YEAR_IN_SECONDS * 10_000, Math.Rounding.Ceil);
    }
}