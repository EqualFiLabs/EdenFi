// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "src/equallend/EqualLendDirectRollingOfferFacet.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {Types} from "src/libraries/Types.sol";
import {InsufficientPrincipal, NotNFTOwner} from "src/libraries/Errors.sol";
import {EqualLendDirectLifecycleHarness, MockERC20DirectLifecycle} from "test/EqualLendDirectLifecycleFacet.t.sol";
import {EqualLendDirectRollingPaymentHarness, MockERC20RollingPayments} from "test/EqualLendDirectRollingPaymentFacet.t.sol";

contract EqualLendDirectFixedFuzzTest is Test {
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

    function testFuzz_FixedLenderPrincipalDepartureAndReturnIsSymmetric(
        uint96 lenderDepositSeed,
        uint96 principalSeed,
        uint32 durationSeed
    ) external {
        uint256 lenderDeposit = bound(uint256(lenderDepositSeed), 100 ether, 1_000 ether);
        uint256 principal = bound(uint256(principalSeed), 1 ether, lenderDeposit / 2);
        uint64 duration = uint64(bound(uint256(durationSeed), 1 days, 30 days));

        uint256 lenderPositionId = _mintAndDeposit(alice, 1, lenderDeposit, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, principal * 3, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: principal,
                collateralLocked: principal * 2,
                aprBps: 800,
                durationSeconds: duration,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(bob);
        uint256 agreementId = harness.acceptFixedLenderOffer(offerId, borrowerPositionId, _borrowerNetFor(principal, 800, duration));

        assertEq(harness.principalOf(1, lenderKey), lenderDeposit - principal, "lender principal after origination");

        borrowToken.mint(bob, principal);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), principal);
        harness.repay(agreementId, principal);
        vm.stopPrank();

        assertEq(harness.principalOf(1, lenderKey), lenderDeposit, "lender principal after repay");
    }

    function testFuzz_BorrowedPrincipalNeverExceedsActiveFixedAgreementSum(
        uint96 lenderDepositSeed,
        uint96 fixedPrincipalSeed,
        uint96 ratioPrincipalSeed
    ) external {
        uint256 lenderDeposit = bound(uint256(lenderDepositSeed), 300 ether, 1_000 ether);
        uint256 fixedPrincipal = bound(uint256(fixedPrincipalSeed), 10 ether, lenderDeposit / 4);
        uint256 ratioPrincipal = bound(uint256(ratioPrincipalSeed), 10 ether, (lenderDeposit - fixedPrincipal) / 4);

        uint256 lenderPositionId = _mintAndDeposit(alice, 1, lenderDeposit, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, (fixedPrincipal + ratioPrincipal) * 4, collateralToken);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.startPrank(alice);
        uint256 fixedOfferId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: fixedPrincipal,
                collateralLocked: fixedPrincipal * 2,
                aprBps: 700,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
        uint256 ratioOfferId = harness.postLenderRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principalCap: ratioPrincipal,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: ratioPrincipal,
                aprBps: 900,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 fixedAgreementId =
            harness.acceptFixedLenderOffer(fixedOfferId, borrowerPositionId, _borrowerNetFor(fixedPrincipal, 700, 14 days));
        uint256 ratioAgreementId = harness.acceptLenderRatioTrancheOffer(
            ratioOfferId, borrowerPositionId, ratioPrincipal, _borrowerNetFor(ratioPrincipal, 900, 21 days)
        );
        vm.stopPrank();

        uint256 activePrincipalSum = fixedPrincipal + ratioPrincipal;
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), activePrincipalSum, "borrowed principal after fills");

        borrowToken.mint(bob, fixedPrincipal);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), fixedPrincipal);
        harness.repay(fixedAgreementId, fixedPrincipal);
        vm.stopPrank();

        activePrincipalSum -= fixedPrincipal;
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), activePrincipalSum, "borrowed principal after fixed repay");

        vm.warp(block.timestamp + 21 days + FIXED_GRACE_PERIOD + 1);
        vm.prank(dave);
        harness.recover(ratioAgreementId);

        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 0, "borrowed principal after ratio recover");
    }

    function testFuzz_SameAssetDebtOriginationAndCleanupRemainSymmetricAcrossFixedAndRatio(uint96 depositSeed) external {
        uint256 lenderDeposit = bound(uint256(depositSeed), 250 ether, 1_000 ether);

        uint256 fixedLenderPositionId = _mintAndDeposit(alice, 3, lenderDeposit, sameAssetToken);
        uint256 fixedBorrowerPositionId = _mintAndDeposit(bob, 3, lenderDeposit * 2, sameAssetToken);
        bytes32 fixedBorrowerKey = positionNft.getPositionKey(fixedBorrowerPositionId);

        vm.prank(bob);
        uint256 fixedOfferId = harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: fixedBorrowerPositionId,
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
        uint256 fixedAgreementId = harness.acceptFixedBorrowerOffer(fixedOfferId, fixedLenderPositionId, _borrowerNetFor(40 ether, 900, 14 days));

        assertEq(harness.sameAssetDebtOf(3, fixedBorrowerKey), 40 ether, "fixed same-asset debt after origination");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 40 ether, "fixed active credit after origination");

        sameAssetToken.mint(bob, 40 ether);
        vm.startPrank(bob);
        sameAssetToken.approve(address(harness), 40 ether);
        harness.repay(fixedAgreementId, 40 ether);
        vm.stopPrank();

        assertEq(harness.sameAssetDebtOf(3, fixedBorrowerKey), 0, "fixed same-asset debt after repay");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 0, "fixed active credit after repay");

        uint256 ratioLenderPositionId = _mintAndDeposit(carol, 3, lenderDeposit, sameAssetToken);
        uint256 ratioBorrowerPositionId = _mintAndDeposit(dave, 3, lenderDeposit * 2, sameAssetToken);
        bytes32 ratioBorrowerKey = positionNft.getPositionKey(ratioBorrowerPositionId);

        vm.prank(carol);
        uint256 ratioOfferId = harness.postLenderRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                lenderPositionId: ratioLenderPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                principalCap: 40 ether,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: 40 ether,
                aprBps: 900,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: true,
                allowLenderCall: false
            })
        );

        vm.prank(dave);
        uint256 ratioAgreementId = harness.acceptLenderRatioTrancheOffer(
            ratioOfferId, ratioBorrowerPositionId, 40 ether, _borrowerNetFor(40 ether, 900, 14 days)
        );

        assertEq(harness.sameAssetDebtOf(3, ratioBorrowerKey), 40 ether, "ratio same-asset debt after origination");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 40 ether, "ratio active credit after origination");

        sameAssetToken.mint(dave, 40 ether);
        vm.startPrank(dave);
        sameAssetToken.approve(address(harness), 40 ether);
        harness.repay(ratioAgreementId, 40 ether);
        vm.stopPrank();

        assertEq(harness.sameAssetDebtOf(3, ratioBorrowerKey), 0, "ratio same-asset debt after repay");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 0, "ratio active credit after repay");
    }

    function testFuzz_FixedOfferAndAgreementIndexesStayCoherent(
        uint96 depositSeed,
        uint96 principalSeed,
        bool cancelPath,
        bool recoverPath
    ) external {
        uint256 lenderDeposit = bound(uint256(depositSeed), 120 ether, 600 ether);
        uint256 principal = bound(uint256(principalSeed), 10 ether, lenderDeposit / 2);

        uint256 lenderPositionId = _mintAndDeposit(alice, 1, lenderDeposit, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, principal * 4, collateralToken);
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
                principal: principal,
                collateralLocked: principal * 2,
                aprBps: 750,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, lenderKey));
        positionNft.transferFrom(alice, carol, lenderPositionId);

        if (cancelPath) {
            vm.prank(alice);
            harness.cancelFixedOffer(offerId);

            assertFalse(harness.hasOpenOffers(lenderKey), "open offers after cancel");

            vm.prank(alice);
            positionNft.transferFrom(alice, carol, lenderPositionId);
            assertEq(positionNft.ownerOf(lenderPositionId), carol, "transfer after cancel");
            return;
        }

        vm.prank(bob);
        uint256 agreementId = harness.acceptFixedLenderOffer(offerId, borrowerPositionId, _borrowerNetFor(principal, 750, 14 days));

        assertFalse(harness.hasOpenOffers(lenderKey), "open offers after accept");
        assertEq(harness.borrowerAgreementIds(borrowerKey).length, 1, "borrower agreement ids after accept");
        assertEq(harness.lenderAgreementIds(lenderKey).length, 1, "lender agreement ids after accept");

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, lenderPositionId);
        vm.prank(bob);
        positionNft.transferFrom(bob, dave, borrowerPositionId);

        if (recoverPath) {
            vm.warp(block.timestamp + 14 days + FIXED_GRACE_PERIOD + 1);
            vm.prank(carol);
            harness.recover(agreementId);
        } else {
            borrowToken.mint(dave, principal);
            vm.startPrank(dave);
            borrowToken.approve(address(harness), principal);
            harness.repay(agreementId, principal);
            vm.stopPrank();
        }

        assertEq(harness.borrowerAgreementIds(borrowerKey).length, 0, "borrower agreement ids after terminal");
        assertEq(harness.lenderAgreementIds(lenderKey).length, 0, "lender agreement ids after terminal");
    }

    function testFuzz_FixedExerciseClearsAgreementIndexesAndSameAssetDebt(uint96 depositSeed) external {
        uint256 lenderDeposit = bound(uint256(depositSeed), 150 ether, 800 ether);
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, lenderDeposit, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, lenderDeposit * 2, sameAssetToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
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

        vm.prank(bob);
        harness.exerciseDirect(agreementId);

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Exercised), "fixed exercise status");
        assertEq(harness.borrowerAgreementIds(borrowerKey).length, 0, "borrower agreement ids after fixed exercise");
        assertEq(harness.lenderAgreementIds(lenderKey).length, 0, "lender agreement ids after fixed exercise");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 0, "same-asset debt after fixed exercise");
    }

    function testFuzz_DirectOfferEncumbranceNeverExceedsAvailablePrincipal(
        uint96 lenderDepositSeed,
        uint96 firstOfferSeed,
        uint96 secondOfferSeed,
        uint96 borrowerDepositSeed,
        uint96 firstLockSeed,
        uint96 secondLockSeed
    ) external {
        uint256 lenderDeposit = bound(uint256(lenderDepositSeed), 100 ether, 800 ether);
        uint256 borrowerDeposit = bound(uint256(borrowerDepositSeed), 100 ether, 800 ether);
        uint256 firstOffer = bound(uint256(firstOfferSeed), 1 ether, lenderDeposit);
        uint256 secondOffer = bound(uint256(secondOfferSeed), 1 ether, lenderDeposit);
        uint256 firstLock = bound(uint256(firstLockSeed), 1 ether, borrowerDeposit);
        uint256 secondLock = bound(uint256(secondLockSeed), 1 ether, borrowerDeposit);

        uint256 lenderPositionId = _mintAndDeposit(alice, 1, lenderDeposit, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, borrowerDeposit, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: firstOffer,
                collateralLocked: firstOffer * 2,
                aprBps: 700,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        if (firstOffer + secondOffer > lenderDeposit) {
            vm.prank(alice);
            vm.expectRevert();
            harness.postLenderRatioTrancheOffer(
                EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                    lenderPositionId: lenderPositionId,
                    lenderPoolId: 1,
                    collateralPoolId: 2,
                    borrowAsset: address(borrowToken),
                    collateralAsset: address(collateralToken),
                    principalCap: secondOffer,
                    priceNumerator: 2,
                    priceDenominator: 1,
                    minPrincipalPerFill: secondOffer,
                    aprBps: 700,
                    durationSeconds: 14 days,
                    allowEarlyRepay: true,
                    allowEarlyExercise: false,
                    allowLenderCall: false
                })
            );
        } else {
            vm.prank(alice);
            harness.postLenderRatioTrancheOffer(
                EqualLendDirectFixedOfferFacet.LenderRatioTrancheOfferParams({
                    lenderPositionId: lenderPositionId,
                    lenderPoolId: 1,
                    collateralPoolId: 2,
                    borrowAsset: address(borrowToken),
                    collateralAsset: address(collateralToken),
                    principalCap: secondOffer,
                    priceNumerator: 2,
                    priceDenominator: 1,
                    minPrincipalPerFill: secondOffer,
                    aprBps: 700,
                    durationSeconds: 14 days,
                    allowEarlyRepay: true,
                    allowEarlyExercise: false,
                    allowLenderCall: false
                })
            );
        }

        (,, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 1);
        assertLe(lenderEscrow, lenderDeposit, "lender escrow exceeds deposit");

        vm.prank(bob);
        harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: firstLock / 2,
                collateralLocked: firstLock,
                aprBps: 700,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        if (firstLock + secondLock > borrowerDeposit) {
            vm.prank(bob);
            vm.expectRevert();
            harness.postBorrowerRatioTrancheOffer(
                EqualLendDirectFixedOfferFacet.BorrowerRatioTrancheOfferParams({
                    borrowerPositionId: borrowerPositionId,
                    lenderPoolId: 1,
                    collateralPoolId: 2,
                    borrowAsset: address(borrowToken),
                    collateralAsset: address(collateralToken),
                    collateralCap: secondLock,
                    priceNumerator: 1,
                    priceDenominator: 2,
                    minCollateralPerFill: secondLock,
                    aprBps: 700,
                    durationSeconds: 14 days,
                    allowEarlyRepay: true,
                    allowEarlyExercise: false,
                    allowLenderCall: false
                })
            );
        } else {
            vm.prank(bob);
            harness.postBorrowerRatioTrancheOffer(
                EqualLendDirectFixedOfferFacet.BorrowerRatioTrancheOfferParams({
                    borrowerPositionId: borrowerPositionId,
                    lenderPoolId: 1,
                    collateralPoolId: 2,
                    borrowAsset: address(borrowToken),
                    collateralAsset: address(collateralToken),
                    collateralCap: secondLock,
                    priceNumerator: 1,
                    priceDenominator: 2,
                    minCollateralPerFill: secondLock,
                    aprBps: 700,
                    durationSeconds: 14 days,
                    allowEarlyRepay: true,
                    allowEarlyExercise: false,
                    allowLenderCall: false
                })
            );
        }

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 2);
        assertLe(borrowerLocked, borrowerDeposit, "borrower locked capital exceeds deposit");
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

contract EqualLendDirectRollingFuzzTest is Test {
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

    function testFuzz_RollingLenderPrincipalDepartureAndReturnIsSymmetric(
        uint96 lenderDepositSeed,
        uint96 principalSeed,
        uint32 warpSeed
    ) external {
        uint256 lenderDeposit = bound(uint256(lenderDepositSeed), 100 ether, 1_000 ether);
        uint256 principal = bound(uint256(principalSeed), 10 ether, lenderDeposit / 2);

        uint256 lenderPositionId = _mintAndDeposit(alice, 1, lenderDeposit, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, principal * 3, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: principal,
                collateralLocked: principal * 3 / 2,
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

        uint256 agreementId;
        vm.prank(bob);
        agreementId = harness.acceptRollingLenderOffer(offerId, borrowerPositionId, 0, principal);

        assertEq(harness.principalOf(1, lenderKey), lenderDeposit - principal, "lender principal after origination");

        uint256 warpDelta = bound(uint256(warpSeed), 8 days, 25 days);
        vm.warp(block.timestamp + warpDelta);
        (uint256 interestDue, uint256 closeoutTotal) = _closeoutTotals(agreementId);

        borrowToken.mint(bob, closeoutTotal);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), closeoutTotal);
        harness.repayRollingInFull(agreementId, closeoutTotal, type(uint256).max);
        vm.stopPrank();

        assertEq(harness.principalOf(1, lenderKey), lenderDeposit + interestDue, "lender principal after closeout");
    }

    function testFuzz_RollingPaymentActionsCannotBypassLenderPoolRestoration(
        uint32 warpSeed,
        uint96 paymentSeed
    ) external {
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

        vm.prank(alice);
        uint256 agreementId = harness.acceptRollingBorrowerOffer(offerId, lenderPositionId, 0, 40 ether);

        uint256 warpDelta = bound(uint256(warpSeed), 8 days, 20 days);
        vm.warp(block.timestamp + warpDelta);

        (LibEqualLendDirectStorage.RollingAgreement memory beforeAgreement,) = harness.getRollingAgreement(agreementId);
        RollingAccrualExpectation memory accrual = _previewAccrual(beforeAgreement, block.timestamp);
        uint256 interestDue = accrual.arrearsDue + accrual.currentInterestDue;
        uint256 paymentAmount = bound(uint256(paymentSeed), interestDue + 1, beforeAgreement.outstandingPrincipal);
        uint256 lenderPrincipalBefore = harness.principalOf(3, lenderKey);

        sameAssetToken.mint(bob, paymentAmount);
        vm.startPrank(bob);
        sameAssetToken.approve(address(harness), paymentAmount);
        harness.makeRollingPayment(agreementId, paymentAmount, paymentAmount, type(uint256).max);
        vm.stopPrank();

        _assertRollingPaymentRestoration(
            agreementId,
            lenderKey,
            borrowerKey,
            lenderPrincipalBefore,
            paymentAmount,
            interestDue,
            beforeAgreement.outstandingPrincipal
        );
    }

    function testFuzz_RollingOfferAndAgreementIndexesStayCoherent(
        uint96 depositSeed,
        uint96 principalSeed,
        bool cancelPath,
        bool recoverPath
    ) external {
        uint256 lenderDeposit = bound(uint256(depositSeed), 120 ether, 600 ether);
        uint256 principal = bound(uint256(principalSeed), 10 ether, lenderDeposit / 2);

        uint256 lenderPositionId = _mintAndDeposit(alice, 1, lenderDeposit, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, principal * 4, collateralToken);
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
                principal: principal,
                collateralLocked: principal * 2,
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

        if (cancelPath) {
            vm.prank(alice);
            harness.cancelRollingOffer(offerId);

            assertFalse(harness.hasOpenOffers(lenderKey), "open offers after cancel");

            vm.prank(alice);
            positionNft.transferFrom(alice, carol, lenderPositionId);
            assertEq(positionNft.ownerOf(lenderPositionId), carol, "transfer after cancel");
            return;
        }

        vm.prank(bob);
        uint256 agreementId = harness.acceptRollingLenderOffer(offerId, borrowerPositionId, 0, principal);

        assertFalse(harness.hasOpenOffers(lenderKey), "open offers after accept");
        assertEq(harness.borrowerAgreementIds(borrowerKey).length, 1, "borrower agreement ids after accept");
        assertEq(harness.lenderAgreementIds(lenderKey).length, 1, "lender agreement ids after accept");

        vm.prank(bob);
        positionNft.transferFrom(bob, dave, borrowerPositionId);

        if (recoverPath) {
            vm.warp(block.timestamp + 8 days + 1);
            vm.prank(carol);
            vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, carol, borrowerPositionId));
            harness.makeRollingPayment(agreementId, principal, principal, 0);
            vm.prank(carol);
            harness.recoverRolling(agreementId);
        } else {
            vm.warp(block.timestamp + 8 days);
            uint256 paymentDue = _interestDue(agreementId);
            borrowToken.mint(dave, paymentDue);
            vm.startPrank(dave);
            borrowToken.approve(address(harness), paymentDue);
            harness.makeRollingPayment(agreementId, paymentDue, paymentDue, type(uint256).max);
            vm.stopPrank();

            (, uint256 closeoutTotal) = _closeoutTotals(agreementId);
            borrowToken.mint(dave, closeoutTotal);
            vm.startPrank(dave);
            borrowToken.approve(address(harness), closeoutTotal);
            harness.repayRollingInFull(agreementId, closeoutTotal, type(uint256).max);
            vm.stopPrank();
        }

        assertEq(harness.borrowerAgreementIds(borrowerKey).length, 0, "borrower agreement ids after terminal");
        assertEq(harness.lenderAgreementIds(lenderKey).length, 0, "lender agreement ids after terminal");
        assertEq(harness.rollingBorrowerAgreementCount(borrowerKey), 0, "rolling borrower agreement count after terminal");
        assertEq(harness.rollingLenderAgreementCount(lenderKey), 0, "rolling lender agreement count after terminal");
    }

    function testFuzz_RollingExerciseClearsAgreementIndexesAndSameAssetDebt(uint96 depositSeed, uint32 warpSeed) external {
        uint256 lenderDeposit = bound(uint256(depositSeed), 150 ether, 800 ether);
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, lenderDeposit, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, lenderDeposit * 2, sameAssetToken);
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

        vm.prank(alice);
        uint256 agreementId = harness.acceptRollingBorrowerOffer(offerId, lenderPositionId, 0, 40 ether);

        vm.warp(block.timestamp + bound(uint256(warpSeed), 1 days, 10 days));

        vm.prank(bob);
        harness.exerciseRolling(agreementId);

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Exercised), "rolling exercise status");
        assertEq(harness.borrowerAgreementIds(borrowerKey).length, 0, "borrower agreement ids after rolling exercise");
        assertEq(harness.lenderAgreementIds(lenderKey).length, 0, "lender agreement ids after rolling exercise");
        assertEq(harness.rollingBorrowerAgreementCount(borrowerKey), 0, "rolling borrower agreement count after rolling exercise");
        assertEq(harness.rollingLenderAgreementCount(lenderKey), 0, "rolling lender agreement count after rolling exercise");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 0, "same-asset debt after rolling exercise");
    }

    function testFuzz_RollingOfferEscrowNeverExceedsAvailablePrincipal(
        uint96 depositSeed,
        uint96 firstOfferSeed,
        uint96 secondOfferSeed
    ) external {
        uint256 lenderDeposit = bound(uint256(depositSeed), 100 ether, 800 ether);
        uint256 firstOffer = bound(uint256(firstOfferSeed), 1 ether, lenderDeposit);
        uint256 secondOffer = bound(uint256(secondOfferSeed), 1 ether, lenderDeposit);

        uint256 lenderPositionId = _mintAndDeposit(alice, 1, lenderDeposit, borrowToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(alice);
        harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: firstOffer,
                collateralLocked: firstOffer * 2,
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

        if (firstOffer + secondOffer > lenderDeposit) {
            vm.prank(alice);
            vm.expectRevert();
            harness.postRollingLenderOffer(
                EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                    lenderPositionId: lenderPositionId,
                    lenderPoolId: 1,
                    collateralPoolId: 2,
                    borrowAsset: address(borrowToken),
                    collateralAsset: address(collateralToken),
                    principal: secondOffer,
                    collateralLocked: secondOffer * 2,
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
        } else {
            vm.prank(alice);
            harness.postRollingLenderOffer(
                EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                    lenderPositionId: lenderPositionId,
                    lenderPoolId: 1,
                    collateralPoolId: 2,
                    borrowAsset: address(borrowToken),
                    collateralAsset: address(collateralToken),
                    principal: secondOffer,
                    collateralLocked: secondOffer * 2,
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
        }

        (,, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 1);
        assertLe(lenderEscrow, lenderDeposit, "rolling lender escrow exceeds deposit");
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

    function _assertRollingPaymentRestoration(
        uint256 agreementId,
        bytes32 lenderKey,
        bytes32 borrowerKey,
        uint256 lenderPrincipalBefore,
        uint256 paymentAmount,
        uint256 interestDue,
        uint256 outstandingPrincipalBefore
    ) internal view {
        (LibEqualLendDirectStorage.RollingAgreement memory afterAgreement,) = harness.getRollingAgreement(agreementId);
        uint256 expectedPrincipalReduction = paymentAmount - interestDue;
        uint256 expectedOutstanding = outstandingPrincipalBefore - expectedPrincipalReduction;

        assertEq(lenderPrincipalBefore + paymentAmount, harness.principalOf(3, lenderKey), "lender principal credit");
        assertEq(expectedOutstanding, afterAgreement.outstandingPrincipal, "outstanding principal reduction");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), expectedOutstanding, "borrowed principal reduction");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), expectedOutstanding, "same-asset debt reduction");
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