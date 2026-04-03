// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "src/equallend/EqualLendDirectRollingOfferFacet.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {Types} from "src/libraries/Types.sol";
import {NotNFTOwner} from "src/libraries/Errors.sol";

import {
    EqualLendDirectLifecycleHarness,
    MockERC20DirectLifecycle
} from "test/EqualLendDirectLifecycleFacet.t.sol";
import {
    EqualLendDirectRollingPaymentHarness,
    MockERC20RollingPayments
} from "test/EqualLendDirectRollingPaymentFacet.t.sol";

contract EqualLendDirectFixedLaunchTest is Test {
    uint256 internal constant FIXED_GRACE_PERIOD = 1 days;

    EqualLendDirectLifecycleHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20DirectLifecycle internal borrowToken;
    MockERC20DirectLifecycle internal collateralToken;
    MockERC20DirectLifecycle internal sameAssetToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        harness = new EqualLendDirectLifecycleHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1_000, 0);
        harness.setDirectConfig(100, 6_000, 2_500, 8_000, 1 days);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        borrowToken = new MockERC20DirectLifecycle("Borrow", "BRW");
        collateralToken = new MockERC20DirectLifecycle("Collateral", "COL");
        sameAssetToken = new MockERC20DirectLifecycle("Same Asset", "SAM");

        _initPool(1, address(borrowToken));
        _initPool(2, address(collateralToken));
        _initPool(3, address(sameAssetToken));
    }

    function test_LiveFlow_LenderPostedFixedOffer_PostAcceptRepay() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 80 ether,
                collateralLocked: 100 ether,
                aprBps: 800,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        vm.prank(bob);
        uint256 agreementId = harness.acceptFixedLenderOffer(offerId, borrowerPositionId, _borrowerNetFor(80 ether, 800, 21 days));

        borrowToken.mint(bob, 80 ether);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), 80 ether);
        harness.repay(agreementId, 80 ether);
        vm.stopPrank();

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "agreement status");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 0, "borrowed principal");
        assertEq(harness.principalOf(1, lenderKey), 100 ether, "lender principal restored");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement index");

        uint256 aliceBefore = borrowToken.balanceOf(alice);
        vm.prank(alice);
        harness.withdrawFromPosition(lenderPositionId, 1, 100 ether, 100 ether);
        assertEq(borrowToken.balanceOf(alice) - aliceBefore, 100 ether, "lender withdrawal");
    }

    function test_LiveFlow_BorrowerPostedFixedOffer_PostAcceptRecover() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 60 ether,
                collateralLocked: 100 ether,
                aprBps: 700,
                durationSeconds: 10 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        uint256 agreementId = harness.acceptFixedBorrowerOffer(offerId, lenderPositionId, _borrowerNetFor(60 ether, 700, 10 days));

        vm.warp(block.timestamp + 10 days + FIXED_GRACE_PERIOD + 1);
        vm.prank(carol);
        harness.recover(agreementId);

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Defaulted), "agreement status");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 0, "borrowed principal");
        assertEq(harness.principalOf(2, lenderKey), 80 ether, "lender collateral principal");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement index");

        uint256 aliceBefore = collateralToken.balanceOf(alice);
        vm.prank(alice);
        harness.withdrawFromPosition(lenderPositionId, 2, 80 ether, 80 ether);
        assertEq(collateralToken.balanceOf(alice) - aliceBefore, 80 ether, "lender recovered withdrawal");
    }

    function test_LiveFlow_LenderPostedRatioTranche_MultiFillLifecycle() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 300 ether, borrowToken);
        uint256 borrowerOnePositionId = _mintAndDeposit(bob, 2, 500 ether, collateralToken);
        uint256 borrowerTwoPositionId = _mintAndDeposit(carol, 2, 500 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerOneKey = positionNft.getPositionKey(borrowerOnePositionId);
        bytes32 borrowerTwoKey = positionNft.getPositionKey(borrowerTwoPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postLenderRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principalCap: 180 ether,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: 60 ether,
                aprBps: 1_000,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        vm.prank(bob);
        uint256 repaidAgreementId = harness.acceptLenderRatioTrancheOffer(
            offerId, borrowerOnePositionId, 60 ether, _borrowerNetFor(60 ether, 1_000, 21 days)
        );

        vm.prank(carol);
        uint256 defaultedAgreementId = harness.acceptLenderRatioTrancheOffer(
            offerId, borrowerTwoPositionId, 120 ether, _borrowerNetFor(120 ether, 1_000, 21 days)
        );

        borrowToken.mint(bob, 60 ether);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), 60 ether);
        harness.repay(repaidAgreementId, 60 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 21 days + FIXED_GRACE_PERIOD + 1);
        vm.prank(dave);
        harness.recover(defaultedAgreementId);

        (LibEqualLendDirectStorage.FixedAgreement memory repaidAgreement,) = harness.getFixedAgreement(repaidAgreementId);
        (LibEqualLendDirectStorage.FixedAgreement memory defaultedAgreement,) = harness.getFixedAgreement(defaultedAgreementId);
        assertEq(uint256(repaidAgreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "repaid tranche status");
        assertEq(
            uint256(defaultedAgreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Defaulted), "defaulted tranche status"
        );
        assertFalse(harness.hasOpenOffers(lenderKey), "ratio offer still open");
        assertEq(harness.borrowerAgreementCount(borrowerOneKey), 0, "borrower one agreements");
        assertEq(harness.borrowerAgreementCount(borrowerTwoKey), 0, "borrower two agreements");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreements");
        assertEq(harness.principalOf(1, lenderKey), 180 ether, "lender borrow-pool principal");
        assertEq(harness.principalOf(2, lenderKey), 192 ether, "lender recovered collateral principal");
    }

    function test_LiveFlow_BorrowerPostedRatioTranche_MultiFillLifecycle() external {
        uint256 lenderOnePositionId = _mintAndDeposit(alice, 1, 200 ether, borrowToken);
        uint256 lenderTwoPositionId = _mintAndDeposit(carol, 1, 200 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 300 ether, collateralToken);
        bytes32 lenderOneKey = positionNft.getPositionKey(lenderOnePositionId);
        bytes32 lenderTwoKey = positionNft.getPositionKey(lenderTwoPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postBorrowerRatioTrancheOffer(
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
                aprBps: 1_000,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        vm.prank(alice);
        uint256 repaidAgreementId = harness.acceptBorrowerRatioTrancheOffer(
            offerId, lenderOnePositionId, 60 ether, _borrowerNetFor(30 ether, 1_000, 21 days)
        );

        vm.prank(carol);
        uint256 defaultedAgreementId = harness.acceptBorrowerRatioTrancheOffer(
            offerId, lenderTwoPositionId, 120 ether, _borrowerNetFor(60 ether, 1_000, 21 days)
        );

        borrowToken.mint(bob, 30 ether);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), 30 ether);
        harness.repay(repaidAgreementId, 30 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 21 days + FIXED_GRACE_PERIOD + 1);
        vm.prank(dave);
        harness.recover(defaultedAgreementId);

        (LibEqualLendDirectStorage.FixedAgreement memory repaidAgreement,) = harness.getFixedAgreement(repaidAgreementId);
        (LibEqualLendDirectStorage.FixedAgreement memory defaultedAgreement,) = harness.getFixedAgreement(defaultedAgreementId);
        assertEq(uint256(repaidAgreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "repaid tranche status");
        assertEq(
            uint256(defaultedAgreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Defaulted), "defaulted tranche status"
        );
        assertFalse(harness.hasOpenOffers(borrowerKey), "borrower ratio offer still open");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreements");
        assertEq(harness.lenderAgreementCount(lenderOneKey), 0, "lender one agreements");
        assertEq(harness.lenderAgreementCount(lenderTwoKey), 0, "lender two agreements");
        assertEq(harness.principalOf(1, lenderOneKey), 200 ether, "lender one principal restored");
        assertEq(harness.principalOf(2, lenderTwoKey), 96 ether, "lender two recovered collateral principal");
    }

    function test_LiveFlow_SameAsset_FixedBorrowerOffer_RepayClearsDebt() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 100 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 150 ether, sameAssetToken);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                principal: 40 ether,
                collateralLocked: 80 ether,
                aprBps: 900,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: true,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        uint256 agreementId = harness.acceptFixedBorrowerOffer(offerId, lenderPositionId, _borrowerNetFor(40 ether, 900, 14 days));

        sameAssetToken.mint(bob, 40 ether);
        vm.startPrank(bob);
        sameAssetToken.approve(address(harness), 40 ether);
        harness.repay(agreementId, 40 ether);
        vm.stopPrank();

        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 0, "borrowed principal");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 0, "same-asset debt");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 0, "active credit principal total");
    }

    function test_LiveFlow_SameAsset_LenderRatio_RepayClearsDebt() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 200 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 300 ether, sameAssetToken);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postLenderRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                principalCap: 80 ether,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: 20 ether,
                aprBps: 900,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: true,
                allowLenderCall: false
            })
        );

        vm.prank(bob);
        uint256 agreementId = harness.acceptLenderRatioTrancheOffer(
            offerId, borrowerPositionId, 40 ether, _borrowerNetFor(40 ether, 900, 14 days)
        );

        sameAssetToken.mint(bob, 40 ether);
        vm.startPrank(bob);
        sameAssetToken.approve(address(harness), 40 ether);
        harness.repay(agreementId, 40 ether);
        vm.stopPrank();

        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 0, "borrowed principal");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 0, "same-asset debt");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 0, "active credit principal total");
    }

    function test_LiveFlow_SameAsset_BorrowerRatio_RepayClearsDebt() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 200 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 300 ether, sameAssetToken);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postBorrowerRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.BorrowerRatioTrancheOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                collateralCap: 80 ether,
                priceNumerator: 1,
                priceDenominator: 2,
                minCollateralPerFill: 20 ether,
                aprBps: 900,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: true,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        uint256 agreementId = harness.acceptBorrowerRatioTrancheOffer(
            offerId, lenderPositionId, 40 ether, _borrowerNetFor(20 ether, 900, 14 days)
        );

        sameAssetToken.mint(bob, 20 ether);
        vm.startPrank(bob);
        sameAssetToken.approve(address(harness), 20 ether);
        harness.repay(agreementId, 20 ether);
        vm.stopPrank();

        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 0, "borrowed principal");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 0, "same-asset debt");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 0, "active credit principal total");
    }

    function test_LiveFlow_PNFTTransfer_BlocksOpenFixedAndRatioOffers() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 250 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 250 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        uint256 fixedOfferId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 80 ether,
                collateralLocked: 100 ether,
                aprBps: 800,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        vm.prank(alice);
        uint256 lenderRatioOfferId = harness.postLenderRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principalCap: 60 ether,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: 20 ether,
                aprBps: 900,
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
                collateralCap: 60 ether,
                priceNumerator: 1,
                priceDenominator: 2,
                minCollateralPerFill: 20 ether,
                aprBps: 900,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, lenderKey));
        positionNft.transferFrom(alice, carol, lenderPositionId);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, borrowerKey));
        positionNft.transferFrom(bob, dave, borrowerPositionId);

        vm.prank(alice);
        harness.cancelFixedOffer(fixedOfferId);
        vm.prank(alice);
        harness.cancelLenderRatioTrancheOffer(lenderRatioOfferId);
        vm.prank(bob);
        harness.cancelBorrowerRatioTrancheOffer(borrowerRatioOfferId);

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, lenderPositionId);
        vm.prank(bob);
        positionNft.transferFrom(bob, dave, borrowerPositionId);

        assertEq(positionNft.ownerOf(lenderPositionId), carol, "lender transfer after cancel");
        assertEq(positionNft.ownerOf(borrowerPositionId), dave, "borrower transfer after cancel");
    }

    function test_LiveFlow_PNFTTransfer_ActiveFixedAgreementFollowsNewOwners() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);

        vm.prank(alice);
        uint256 offerId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 80 ether,
                collateralLocked: 100 ether,
                aprBps: 800,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        vm.prank(bob);
        uint256 agreementId = harness.acceptFixedLenderOffer(offerId, borrowerPositionId, _borrowerNetFor(80 ether, 800, 21 days));

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, lenderPositionId);
        vm.prank(bob);
        positionNft.transferFrom(bob, dave, borrowerPositionId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, alice, lenderPositionId));
        harness.callDirect(agreementId);

        vm.prank(carol);
        harness.callDirect(agreementId);

        borrowToken.mint(dave, 80 ether);
        vm.startPrank(dave);
        borrowToken.approve(address(harness), 80 ether);
        harness.repay(agreementId, 80 ether);
        vm.stopPrank();

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "agreement status");
    }

    function _borrowerNetFor(uint256 principal, uint16 aprBps, uint64 duration) internal pure returns (uint256) {
        uint256 platformFee = (principal * 100) / 10_000;
        uint256 effectiveDuration = duration < 1 days ? 1 days : duration;
        uint256 interestAmount = (principal * uint256(aprBps) * effectiveDuration) / (365 days * 10_000);
        return principal - platformFee - interestAmount;
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount, MockERC20DirectLifecycle token)
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

    function _initPool(uint256 pid, address underlying) internal {
        harness.initPoolWithActionFees(pid, underlying, _poolConfig(), _actionFees());
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

    function _actionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        return actionFees;
    }
}

contract EqualLendDirectRollingLaunchTest is Test {
    struct RollingAccrualExpectation {
        uint256 arrearsDue;
        uint256 currentInterestDue;
        uint64 latestPassedDue;
        uint256 dueCountDelta;
    }

    EqualLendDirectRollingPaymentHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20RollingPayments internal borrowToken;
    MockERC20RollingPayments internal collateralToken;
    MockERC20RollingPayments internal sameAssetToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        harness = new EqualLendDirectRollingPaymentHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1_000, 0);
        harness.setDirectConfig(100, 10_000, 10_000, 8_000, 1 days);
        harness.setRollingConfig(1 days, 24, 2_500, 300, 2_000, 500, 1);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        borrowToken = new MockERC20RollingPayments("Borrow", "BRW");
        collateralToken = new MockERC20RollingPayments("Collateral", "COL");
        sameAssetToken = new MockERC20RollingPayments("Same Asset", "SAM");

        _initPool(1, address(borrowToken));
        _initPool(2, address(collateralToken));
        _initPool(3, address(sameAssetToken));
    }

    function test_LiveFlow_LenderPostedRollingOffer_MultiplePaymentsAndCloseout() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 60 ether,
                collateralLocked: 90 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 12,
                upfrontPremium: 0,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        uint64 acceptedAt = uint64(block.timestamp);
        vm.prank(bob);
        uint256 agreementId = harness.acceptRollingLenderOffer(offerId, borrowerPositionId, 0, 60 ether);

        vm.warp(acceptedAt + 10 days);
        uint256 firstPayment = _interestDue(agreementId);
        borrowToken.mint(bob, firstPayment);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), type(uint256).max);
        harness.makeRollingPayment(agreementId, firstPayment, firstPayment, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        (uint256 closeoutInterest, uint256 closeoutTotal) = _closeoutTotals(agreementId);
        closeoutInterest;

        borrowToken.mint(bob, closeoutTotal);
        vm.startPrank(bob);
        harness.repayRollingInFull(agreementId, closeoutTotal, 0);
        vm.stopPrank();

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "agreement status");
        assertEq(agreement.outstandingPrincipal, 0, "outstanding principal");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 0, "borrowed principal");
        assertEq(harness.principalOf(1, lenderKey), 40 ether + firstPayment + closeoutTotal, "lender principal restored");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement index");
        assertEq(harness.rollingBorrowerAgreementCount(borrowerKey), 0, "rolling borrower agreement index");
        assertEq(harness.rollingLenderAgreementCount(lenderKey), 0, "rolling lender agreement index");
    }

    function test_LiveFlow_BorrowerPostedRollingOffer_Recovery() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 60 ether,
                collateralLocked: 90 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 12,
                upfrontPremium: 0,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        uint64 acceptedAt = uint64(block.timestamp);
        vm.prank(alice);
        uint256 agreementId = harness.acceptRollingBorrowerOffer(offerId, lenderPositionId, 0, 60 ether);

        vm.warp(acceptedAt + 8 days + 1);
        vm.prank(dave);
        harness.recoverRolling(agreementId);

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Defaulted), "agreement status");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 0, "borrowed principal");
        assertGt(harness.principalOf(2, lenderKey), 0, "lender recovered collateral principal");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement index");
        assertEq(harness.rollingBorrowerAgreementCount(borrowerKey), 0, "rolling borrower agreement index");
        assertEq(harness.rollingLenderAgreementCount(lenderKey), 0, "rolling lender agreement index");
    }

    function test_LiveFlow_SameAsset_RollingBorrowerOffer_CloseoutClearsDebt() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 100 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 150 ether, sameAssetToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                principal: 40 ether,
                collateralLocked: 80 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 850,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 10,
                upfrontPremium: 0,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );

        uint64 acceptedAt = uint64(block.timestamp);
        vm.prank(alice);
        uint256 agreementId = harness.acceptRollingBorrowerOffer(offerId, lenderPositionId, 0, 40 ether);

        vm.warp(acceptedAt + 10 days);
        uint256 firstPayment = 5 ether;
        sameAssetToken.mint(bob, firstPayment);
        vm.startPrank(bob);
        sameAssetToken.approve(address(harness), type(uint256).max);
        harness.makeRollingPayment(agreementId, firstPayment, firstPayment, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        (, uint256 closeoutTotal) = _closeoutTotals(agreementId);

        sameAssetToken.mint(bob, closeoutTotal);
        vm.startPrank(bob);
        harness.repayRollingInFull(agreementId, closeoutTotal, 0);
        vm.stopPrank();

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "agreement status");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 0, "borrowed principal");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 0, "same-asset debt");
        assertEq(harness.sameAssetDebtByAsset(borrowerKey, address(sameAssetToken)), 0, "same-asset debt by asset");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 0, "active credit principal total");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement index");
    }

    function test_LiveFlow_PNFTTransfer_BlocksOpenRollingOffers() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        uint256 lenderOfferId = harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 60 ether,
                collateralLocked: 90 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 12,
                upfrontPremium: 0,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        vm.prank(bob);
        uint256 borrowerOfferId = harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 60 ether,
                collateralLocked: 90 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 12,
                upfrontPremium: 0,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, lenderKey));
        positionNft.transferFrom(alice, carol, lenderPositionId);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, borrowerKey));
        positionNft.transferFrom(bob, dave, borrowerPositionId);

        vm.prank(alice);
        harness.cancelRollingOffer(lenderOfferId);
        vm.prank(bob);
        harness.cancelRollingOffer(borrowerOfferId);

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, lenderPositionId);
        vm.prank(bob);
        positionNft.transferFrom(bob, dave, borrowerPositionId);

        assertEq(positionNft.ownerOf(lenderPositionId), carol, "lender transfer after cancel");
        assertEq(positionNft.ownerOf(borrowerPositionId), dave, "borrower transfer after cancel");
    }

    function test_LiveFlow_PNFTTransfer_ActiveRollingAgreementFollowsNewBorrowerOwner() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);

        vm.prank(alice);
        uint256 offerId = harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 60 ether,
                collateralLocked: 90 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 12,
                upfrontPremium: 0,
                allowAmortization: false,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        uint64 acceptedAt = uint64(block.timestamp);
        vm.prank(bob);
        uint256 agreementId = harness.acceptRollingLenderOffer(offerId, borrowerPositionId, 0, 60 ether);

        vm.prank(bob);
        positionNft.transferFrom(bob, carol, borrowerPositionId);

        vm.warp(acceptedAt + 10 days);
        uint256 paymentDue = _interestDue(agreementId);
        borrowToken.mint(bob, paymentDue);
        borrowToken.mint(carol, paymentDue);

        vm.startPrank(bob);
        borrowToken.approve(address(harness), paymentDue);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, bob, borrowerPositionId));
        harness.makeRollingPayment(agreementId, paymentDue, paymentDue, 0);
        vm.stopPrank();

        vm.startPrank(carol);
        borrowToken.approve(address(harness), paymentDue);
        harness.makeRollingPayment(agreementId, paymentDue, paymentDue, 0);
        vm.stopPrank();

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        assertEq(agreement.paymentCount, 1, "rolling payment count");
    }

    function _interestDue(uint256 agreementId) internal view returns (uint256) {
        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        RollingAccrualExpectation memory accrual = _previewAccrual(agreement, block.timestamp);
        return accrual.arrearsDue + accrual.currentInterestDue;
    }

    function _closeoutTotals(uint256 agreementId) internal view returns (uint256 closeoutInterest, uint256 closeoutTotal) {
        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        RollingAccrualExpectation memory accrual = _previewAccrual(agreement, block.timestamp);
        closeoutInterest = accrual.arrearsDue + accrual.currentInterestDue;
        closeoutTotal = agreement.outstandingPrincipal + closeoutInterest;
    }

    function _previewAccrual(LibEqualLendDirectStorage.RollingAgreement memory agreement, uint256 asOf)
        internal
        pure
        returns (RollingAccrualExpectation memory accrual)
    {
        accrual.arrearsDue = agreement.arrears;

        if (asOf >= agreement.nextDue) {
            accrual.dueCountDelta = ((asOf - uint256(agreement.nextDue)) / agreement.paymentIntervalSeconds) + 1;
            accrual.latestPassedDue = uint64(
                uint256(agreement.nextDue) + ((accrual.dueCountDelta - 1) * agreement.paymentIntervalSeconds)
            );
            if (uint256(accrual.latestPassedDue) > agreement.lastAccrualTimestamp) {
                accrual.arrearsDue += _rollingInterest(
                    agreement.outstandingPrincipal,
                    agreement.rollingApyBps,
                    uint256(accrual.latestPassedDue) - agreement.lastAccrualTimestamp
                );
            }
        }

        uint256 currentStart = agreement.lastAccrualTimestamp;
        if (uint256(accrual.latestPassedDue) > currentStart) {
            currentStart = uint256(accrual.latestPassedDue);
        }
        if (asOf > currentStart) {
            accrual.currentInterestDue =
                _rollingInterest(agreement.outstandingPrincipal, agreement.rollingApyBps, asOf - currentStart);
        }
    }

    function _rollingInterest(uint256 principal, uint16 apyBps, uint256 durationSeconds)
        internal
        pure
        returns (uint256)
    {
        if (principal == 0 || apyBps == 0 || durationSeconds == 0) {
            return 0;
        }

        return Math.mulDiv(principal, uint256(apyBps) * durationSeconds, 365 days * 10_000, Math.Rounding.Ceil);
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount, MockERC20RollingPayments token)
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

    function _initPool(uint256 pid, address underlying) internal {
        harness.initPoolWithActionFees(pid, underlying, _poolConfig(), _actionFees());
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

    function _actionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        return actionFees;
    }
}