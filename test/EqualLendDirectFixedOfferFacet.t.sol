// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
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
    DirectError_InvalidAsset,
    DirectError_InvalidConfiguration,
    InsufficientPrincipal,
    NotNFTOwner
} from "src/libraries/Errors.sol";

contract MockERC20Direct is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualLendDirectFixedOfferHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectFixedOfferFacet
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

    function seedSameAssetDebt(uint256 pid, bytes32 positionKey, uint256 amount) external {
        LibAppStorage.s().pools[pid].userSameAssetDebt[positionKey] = amount;
    }

    function getFixedLenderOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.FixedLenderOffer memory offer, LibEqualLendDirectStorage.OfferKind kind)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return (store.fixedLenderOffers[offerId], store.offerKindById[offerId]);
    }

    function getFixedBorrowerOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.FixedBorrowerOffer memory offer, LibEqualLendDirectStorage.OfferKind kind)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return (store.fixedBorrowerOffers[offerId], store.offerKindById[offerId]);
    }

    function encumbranceOf(bytes32 positionKey, uint256 poolId)
        external
        view
        returns (uint256 lockedCapital, uint256 encumberedCapital, uint256 offerEscrowedCapital)
    {
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        return (enc.lockedCapital, enc.encumberedCapital, enc.offerEscrowedCapital);
    }
}

contract EqualLendDirectFixedOfferFacetTest is Test {
    EqualLendDirectFixedOfferHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20Direct internal borrowToken;
    MockERC20Direct internal collateralToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        harness = new EqualLendDirectFixedOfferHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        borrowToken = new MockERC20Direct("Borrow", "BRW");
        collateralToken = new MockERC20Direct("Collateral", "COL");

        _initPool(1, address(borrowToken));
        _initPool(2, address(collateralToken));
    }

    function test_lenderPostedFixedOffer_escrowsCapacityAndBlocksTransferUntilCancel() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 60 ether,
                collateralLocked: 90 ether,
                aprBps: 700,
                durationSeconds: 30 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        (LibEqualLendDirectStorage.FixedLenderOffer memory offer, LibEqualLendDirectStorage.OfferKind kind) =
            harness.getFixedLenderOffer(offerId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.OfferKind.FixedLender), "lender offer kind");
        assertEq(offer.principal, 60 ether, "lender offer principal");
        assertEq(offer.lenderPositionId, lenderPositionId, "lender offer position");

        (,, uint256 offerEscrowedCapital) = harness.encumbranceOf(lenderKey, 1);
        assertEq(offerEscrowedCapital, 60 ether, "lender offer escrow");
        assertTrue(harness.hasOpenOffers(lenderKey), "open lender offer not tracked");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, lenderKey));
        positionNft.transferFrom(alice, bob, lenderPositionId);

        vm.prank(alice);
        harness.cancelFixedOffer(offerId);

        (offer, kind) = harness.getFixedLenderOffer(offerId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.OfferKind.FixedLender), "lender kind after cancel");
        assertTrue(offer.cancelled, "lender offer not cancelled");
        (,, offerEscrowedCapital) = harness.encumbranceOf(lenderKey, 1);
        assertEq(offerEscrowedCapital, 0, "lender offer escrow after cancel");
        assertFalse(harness.hasOpenOffers(lenderKey), "open lender offer after cancel");

        vm.prank(alice);
        positionNft.transferFrom(alice, bob, lenderPositionId);
        assertEq(positionNft.ownerOf(lenderPositionId), bob, "transfer after cancel");
    }

    function test_borrowerPostedFixedOffer_locksCollateralAndBlocksTransferUntilCancel() external {
        uint256 borrowerPositionId = _mintAndDeposit(alice, 2, 120 ether, collateralToken);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 50 ether,
                collateralLocked: 80 ether,
                aprBps: 650,
                durationSeconds: 21 days,
                allowEarlyRepay: true,
                allowEarlyExercise: true,
                allowLenderCall: false
            })
        );

        (LibEqualLendDirectStorage.FixedBorrowerOffer memory offer, LibEqualLendDirectStorage.OfferKind kind) =
            harness.getFixedBorrowerOffer(offerId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.OfferKind.FixedBorrower), "borrower offer kind");
        assertEq(offer.collateralLocked, 80 ether, "borrower collateral locked");
        assertEq(offer.borrowerPositionId, borrowerPositionId, "borrower position id");

        (uint256 lockedCapital,,) = harness.encumbranceOf(borrowerKey, 2);
        assertEq(lockedCapital, 80 ether, "borrower locked capital");
        assertTrue(harness.hasOpenOffers(borrowerKey), "open borrower offer not tracked");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFT.PositionNFTHasOpenOffers.selector, borrowerKey));
        positionNft.transferFrom(alice, bob, borrowerPositionId);

        vm.prank(alice);
        harness.cancelFixedOffer(offerId);

        (offer,) = harness.getFixedBorrowerOffer(offerId);
        assertTrue(offer.cancelled, "borrower offer not cancelled");
        (lockedCapital,,) = harness.encumbranceOf(borrowerKey, 2);
        assertEq(lockedCapital, 0, "borrower locked capital after cancel");
        assertFalse(harness.hasOpenOffers(borrowerKey), "open borrower offer after cancel");

        vm.prank(alice);
        positionNft.transferFrom(alice, bob, borrowerPositionId);
        assertEq(positionNft.ownerOf(borrowerPositionId), bob, "borrower transfer after cancel");
    }

    function test_postingValidations_recheckPoolAssetAlignmentDurationAndAvailablePrincipal() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);

        vm.prank(alice);
        vm.expectRevert(DirectError_InvalidAsset.selector);
        harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(collateralToken),
                collateralAsset: address(collateralToken),
                principal: 10 ether,
                collateralLocked: 20 ether,
                aprBps: 500,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        vm.expectRevert(DirectError_InvalidConfiguration.selector);
        harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 10 ether,
                collateralLocked: 20 ether,
                aprBps: 500,
                durationSeconds: 0,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 80 ether,
                collateralLocked: 120 ether,
                aprBps: 500,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 30 ether, 20 ether));
        harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 30 ether,
                collateralLocked: 40 ether,
                aprBps: 500,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
    }

    function test_postingValidation_countsSameAssetDebtAgainstBorrowerAvailableCollateral() external {
        uint256 borrowerPositionId = _mintAndDeposit(alice, 2, 100 ether, collateralToken);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);
        harness.seedSameAssetDebt(2, borrowerKey, 70 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 40 ether, 30 ether));
        harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 25 ether,
                collateralLocked: 40 ether,
                aprBps: 500,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );
    }

    function test_onlyCurrentOwnerCanCancelFixedOffer() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);

        vm.prank(alice);
        uint256 offerId = harness.postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                principal: 40 ether,
                collateralLocked: 55 ether,
                aprBps: 500,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, bob, lenderPositionId));
        harness.cancelFixedOffer(offerId);
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount, MockERC20Direct token)
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
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 30;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 1000;
    }

    function _actionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        return actionFees;
    }
}
