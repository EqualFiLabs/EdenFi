// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "src/equallend/EqualLendDirectRollingOfferFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {
    DirectError_InvalidConfiguration,
    RollingError_ExcessivePremium,
    RollingError_InvalidAPY,
    RollingError_InvalidGracePeriod,
    RollingError_InvalidInterval,
    RollingError_InvalidPaymentCount
} from "src/libraries/Errors.sol";

contract MockERC20RollingOffer is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualLendDirectRollingOfferHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectFixedOfferFacet,
    EqualLendDirectRollingOfferFacet
{
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function setRollingConfig(
        uint256 minPaymentIntervalSeconds,
        uint256 maxPaymentCount,
        uint256 maxUpfrontPremiumBps,
        uint256 minRollingApyBps,
        uint256 maxRollingApyBps,
        uint256 defaultPenaltyBps,
        uint256 minPaymentBps
    ) external {
        if (
            minPaymentIntervalSeconds > type(uint32).max || maxPaymentCount > type(uint16).max
                || maxUpfrontPremiumBps > type(uint16).max || minRollingApyBps > type(uint16).max
                || maxRollingApyBps > type(uint16).max || defaultPenaltyBps > type(uint16).max
                || minPaymentBps > type(uint16).max
        ) revert();
        LibEqualLendDirectStorage.DirectRollingConfig memory cfg = LibEqualLendDirectStorage.DirectRollingConfig({
            minPaymentIntervalSeconds: uint32(minPaymentIntervalSeconds),
            maxPaymentCount: uint16(maxPaymentCount),
            maxUpfrontPremiumBps: uint16(maxUpfrontPremiumBps),
            minRollingApyBps: uint16(minRollingApyBps),
            maxRollingApyBps: uint16(maxRollingApyBps),
            defaultPenaltyBps: uint16(defaultPenaltyBps),
            minPaymentBps: uint16(minPaymentBps)
        });
        LibEqualLendDirectStorage.validateRollingConfig(cfg);
        LibEqualLendDirectStorage.s().rollingConfig = cfg;
    }

    function setRawRollingConfig(
        uint256 minPaymentIntervalSeconds,
        uint256 maxPaymentCount,
        uint256 maxUpfrontPremiumBps,
        uint256 minRollingApyBps,
        uint256 maxRollingApyBps,
        uint256 defaultPenaltyBps,
        uint256 minPaymentBps
    ) external {
        if (
            minPaymentIntervalSeconds > type(uint32).max || maxPaymentCount > type(uint16).max
                || maxUpfrontPremiumBps > type(uint16).max || minRollingApyBps > type(uint16).max
                || maxRollingApyBps > type(uint16).max || defaultPenaltyBps > type(uint16).max
                || minPaymentBps > type(uint16).max
        ) revert();
        LibEqualLendDirectStorage.s().rollingConfig = LibEqualLendDirectStorage.DirectRollingConfig({
            minPaymentIntervalSeconds: uint32(minPaymentIntervalSeconds),
            maxPaymentCount: uint16(maxPaymentCount),
            maxUpfrontPremiumBps: uint16(maxUpfrontPremiumBps),
            minRollingApyBps: uint16(minRollingApyBps),
            maxRollingApyBps: uint16(maxRollingApyBps),
            defaultPenaltyBps: uint16(defaultPenaltyBps),
            minPaymentBps: uint16(minPaymentBps)
        });
    }

    function getRollingLenderOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.RollingLenderOffer memory offer, LibEqualLendDirectStorage.OfferKind kind)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return (store.rollingLenderOffers[offerId], store.offerKindById[offerId]);
    }

    function getRollingBorrowerOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.RollingBorrowerOffer memory offer, LibEqualLendDirectStorage.OfferKind kind)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return (store.rollingBorrowerOffers[offerId], store.offerKindById[offerId]);
    }

    function encumbranceOf(bytes32 positionKey, uint256 poolId)
        external
        view
        returns (uint256 lockedCapital, uint256 encumberedCapital, uint256 offerEscrowedCapital)
    {
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, poolId);
        return (enc.lockedCapital, enc.encumberedCapital, enc.offerEscrowedCapital);
    }
}

contract EqualLendDirectRollingOfferFacetTest is Test {
    EqualLendDirectRollingOfferHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20RollingOffer internal borrowToken;
    MockERC20RollingOffer internal collateralToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        harness = new EqualLendDirectRollingOfferHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        borrowToken = new MockERC20RollingOffer("Borrow", "BRW");
        collateralToken = new MockERC20RollingOffer("Collateral", "COL");

        _initPool(1, address(borrowToken));
        _initPool(2, address(collateralToken));
        harness.setRollingConfig(1 days, 24, 2_500, 300, 2_000, 500, 500);
    }

    function test_lenderPostedRollingOffer_escrowsCapacityAndBlocksTransferUntilCancel() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);

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
                upfrontPremium: 5 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        (LibEqualLendDirectStorage.RollingLenderOffer memory offer, LibEqualLendDirectStorage.OfferKind kind) =
            harness.getRollingLenderOffer(offerId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.OfferKind.RollingLender), "rolling lender offer kind");
        assertEq(offer.principal, 60 ether, "rolling lender principal");
        assertEq(offer.paymentIntervalSeconds, 7 days, "rolling lender interval");

        (,, uint256 offerEscrowedCapital) = harness.encumbranceOf(lenderKey, 1);
        assertEq(offerEscrowedCapital, 60 ether, "rolling lender escrow");
        assertTrue(harness.hasOpenOffers(lenderKey), "rolling lender offer not tracked");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, lenderKey));
        positionNft.transferFrom(alice, bob, lenderPositionId);

        vm.prank(alice);
        harness.cancelRollingOffer(offerId);

        (offer,) = harness.getRollingLenderOffer(offerId);
        assertTrue(offer.cancelled, "rolling lender offer not cancelled");
        (,, offerEscrowedCapital) = harness.encumbranceOf(lenderKey, 1);
        assertEq(offerEscrowedCapital, 0, "rolling lender escrow after cancel");
        assertFalse(harness.hasOpenOffers(lenderKey), "rolling lender open offers after cancel");

        vm.prank(alice);
        positionNft.transferFrom(alice, bob, lenderPositionId);
        assertEq(positionNft.ownerOf(lenderPositionId), bob, "rolling lender transfer after cancel");
    }

    function test_borrowerPostedRollingOffer_locksCollateralAndBlocksTransferUntilCancel() external {
        uint256 borrowerPositionId = _mintAndDeposit(alice, 2, 120 ether, collateralToken);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 50 ether,
                collateralLocked: 80 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 850,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 10,
                upfrontPremium: 4 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );

        (LibEqualLendDirectStorage.RollingBorrowerOffer memory offer, LibEqualLendDirectStorage.OfferKind kind) =
            harness.getRollingBorrowerOffer(offerId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.OfferKind.RollingBorrower), "rolling borrower kind");
        assertEq(offer.collateralLocked, 80 ether, "rolling borrower collateral");
        assertEq(offer.maxPaymentCount, 10, "rolling borrower payment count");

        (uint256 lockedCapital,,) = harness.encumbranceOf(borrowerKey, 2);
        assertEq(lockedCapital, 80 ether, "rolling borrower locked capital");
        assertTrue(harness.hasOpenOffers(borrowerKey), "rolling borrower offer not tracked");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, borrowerKey));
        positionNft.transferFrom(alice, bob, borrowerPositionId);

        vm.prank(alice);
        harness.cancelRollingOffer(offerId);

        (offer,) = harness.getRollingBorrowerOffer(offerId);
        assertTrue(offer.cancelled, "rolling borrower offer not cancelled");
        (lockedCapital,,) = harness.encumbranceOf(borrowerKey, 2);
        assertEq(lockedCapital, 0, "rolling borrower locked after cancel");
        assertFalse(harness.hasOpenOffers(borrowerKey), "rolling borrower open offers after cancel");

        vm.prank(alice);
        positionNft.transferFrom(alice, bob, borrowerPositionId);
        assertEq(positionNft.ownerOf(borrowerPositionId), bob, "rolling borrower transfer after cancel");
    }

    function test_rollingPostingValidation_usesConfigBoundsAndPremiumLimits() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 100 ether, collateralToken);

        harness.setRawRollingConfig(0, 0, 0, 0, 0, 0, 0);

        vm.prank(alice);
        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 10 ether,
                collateralLocked: 20 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 8,
                upfrontPremium: 1 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        harness.setRollingConfig(1 days, 24, 2_500, 300, 2_000, 500, 500);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RollingError_InvalidInterval.selector, 3600, 1 days));
        harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 10 ether,
                collateralLocked: 20 ether,
                paymentIntervalSeconds: 3600,
                rollingApyBps: 900,
                gracePeriodSeconds: 1800,
                maxPaymentCount: 8,
                upfrontPremium: 1 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RollingError_InvalidPaymentCount.selector, 25, 24));
        harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 10 ether,
                collateralLocked: 20 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 25,
                upfrontPremium: 1 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RollingError_InvalidGracePeriod.selector, 7 days, 7 days));
        harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 10 ether,
                collateralLocked: 20 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 7 days,
                maxPaymentCount: 8,
                upfrontPremium: 1 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RollingError_InvalidAPY.selector, 2_500, 300, 2_000));
        harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 10 ether,
                collateralLocked: 20 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 2_500,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 8,
                upfrontPremium: 1 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RollingError_ExcessivePremium.selector, 3 ether, 2.5 ether));
        harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 10 ether,
                collateralLocked: 20 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 8,
                upfrontPremium: 3 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );
    }

    function test_cancelOffersForPosition_cleansRollingOffersFromSharedHook() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(alice);
        harness.postRollingLenderOffer(
            EqualLendDirectRollingOfferFacet.RollingLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 40 ether,
                collateralLocked: 60 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 900,
                gracePeriodSeconds: 1 days,
                maxPaymentCount: 8,
                upfrontPremium: 2 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        assertTrue(harness.hasOpenOffers(lenderKey), "rolling open offers before hook cleanup");
        vm.prank(address(positionNft));
        harness.cancelOffersForPosition(lenderKey);
        assertFalse(harness.hasOpenOffers(lenderKey), "rolling open offers after hook cleanup");

        (,, uint256 offerEscrowedCapital) = harness.encumbranceOf(lenderKey, 1);
        assertEq(offerEscrowedCapital, 0, "rolling escrow after hook cleanup");
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount, MockERC20RollingOffer token)
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
