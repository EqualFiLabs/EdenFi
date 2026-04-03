// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualLendDirectFixedAgreementFacet} from "src/equallend/EqualLendDirectFixedAgreementFacet.sol";
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
import {SolvencyViolation} from "src/libraries/Errors.sol";

contract MockERC20DirectAgreement is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualLendDirectFixedAgreementHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectFixedOfferFacet,
    EqualLendDirectFixedAgreementFacet
{
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

    function setDirectConfig(
        uint256 platformFeeBps,
        uint256 interestLenderBps,
        uint256 platformFeeLenderBps,
        uint256 defaultLenderBps,
        uint256 minInterestDuration
    ) external {
        if (
            platformFeeBps > type(uint16).max || interestLenderBps > type(uint16).max
                || platformFeeLenderBps > type(uint16).max || defaultLenderBps > type(uint16).max
                || minInterestDuration > type(uint40).max
        ) revert();

        LibEqualLendDirectStorage.DirectConfig memory cfg = LibEqualLendDirectStorage.DirectConfig({
            platformFeeBps: uint16(platformFeeBps),
            interestLenderBps: uint16(interestLenderBps),
            platformFeeLenderBps: uint16(platformFeeLenderBps),
            defaultLenderBps: uint16(defaultLenderBps),
            minInterestDuration: uint40(minInterestDuration)
        });
        LibEqualLendDirectStorage.validateDirectConfig(cfg);
        LibEqualLendDirectStorage.s().config = cfg;
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

    function getFixedAgreement(uint256 agreementId)
        external
        view
        returns (LibEqualLendDirectStorage.FixedAgreement memory agreement, LibEqualLendDirectStorage.AgreementKind kind)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return (store.fixedAgreements[agreementId], store.agreementKindById[agreementId]);
    }

    function getLenderRatioOffer(uint256 offerId)
        external
        view
        returns (LibEqualLendDirectStorage.LenderRatioTrancheOffer memory offer, LibEqualLendDirectStorage.OfferKind kind)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return (store.lenderRatioOffers[offerId], store.offerKindById[offerId]);
    }

    function encumbranceOf(bytes32 positionKey, uint256 poolId)
        external
        view
        returns (uint256 lockedCapital, uint256 encumberedCapital, uint256 offerEscrowedCapital)
    {
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, poolId);
        return (enc.lockedCapital, enc.encumberedCapital, enc.offerEscrowedCapital);
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function trackedBalanceOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDepositsOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function yieldReserveOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].yieldReserve;
    }

    function accruedYieldOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function sameAssetDebtOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userSameAssetDebt[positionKey];
    }

    function sameAssetDebtByAsset(bytes32 positionKey, address asset) external view returns (uint256) {
        return LibEqualLendDirectStorage.s().sameAssetDebtByAsset[positionKey][asset];
    }

    function borrowedPrincipalOf(bytes32 positionKey, uint256 lenderPoolId) external view returns (uint256) {
        return LibEqualLendDirectStorage.s().borrowedPrincipalByPool[positionKey][lenderPoolId];
    }

    function activeCreditPrincipalTotalOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function activeCreditDebtStateOf(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 principal, uint40 startTime, uint256 indexSnapshot)
    {
        Types.ActiveCreditState storage state = LibAppStorage.s().pools[pid].userActiveCreditStateDebt[positionKey];
        return (state.principal, state.startTime, state.indexSnapshot);
    }
}

contract EqualLendDirectFixedAgreementFacetTest is Test {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint16 internal constant PLATFORM_FEE_BPS = 100;
    uint16 internal constant INTEREST_LENDER_BPS = 6_000;
    uint16 internal constant PLATFORM_FEE_LENDER_BPS = 2_500;
    uint40 internal constant MIN_INTEREST_DURATION = 1 days;
    uint16 internal constant TREASURY_BPS = 1_000;

    EqualLendDirectFixedAgreementHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20DirectAgreement internal borrowToken;
    MockERC20DirectAgreement internal collateralToken;
    MockERC20DirectAgreement internal sameAssetToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        harness = new EqualLendDirectFixedAgreementHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(treasury);
        harness.setFeeSplits(TREASURY_BPS, 0);
        harness.setDirectConfig(PLATFORM_FEE_BPS, INTEREST_LENDER_BPS, PLATFORM_FEE_LENDER_BPS, 0, MIN_INTEREST_DURATION);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        borrowToken = new MockERC20DirectAgreement("Borrow", "BRW");
        collateralToken = new MockERC20DirectAgreement("Collateral", "COL");
        sameAssetToken = new MockERC20DirectAgreement("Same Asset", "SAM");

        _initPool(1, address(borrowToken));
        _initPool(2, address(collateralToken));
        _initPool(3, address(sameAssetToken));
    }

    function test_acceptFixedLenderOffer_crossAssetUsesSharedOriginationAndFeeSplit() external {
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
                collateralLocked: 120 ether,
                aprBps: 1_000,
                durationSeconds: 30 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: true
            })
        );

        vm.prank(bob);
        uint256 agreementId = harness.acceptFixedLenderOffer(offerId, borrowerPositionId, _borrowerNetFor(80 ether, 1_000, 30 days));

        _assertCrossAssetAgreement(agreementId, lenderPositionId, borrowerPositionId);
        _assertCrossAssetAccounting(lenderKey, borrowerKey, lenderPositionId, offerId);
        _assertCrossAssetClaimFlow(lenderPositionId);
    }

    function test_acceptFixedBorrowerOffer_sameAssetKeepsSingleCollateralLockAndAppliesDebtState() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 100 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 150 ether, sameAssetToken);
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

        (uint256 lockedBefore,,) = harness.encumbranceOf(borrowerKey, 3);
        assertEq(lockedBefore, 80 ether, "post-time collateral lock");

        vm.prank(alice);
        uint256 agreementId = harness.acceptFixedBorrowerOffer(offerId, lenderPositionId, _borrowerNetFor(40 ether, 900, 14 days));

        _assertSameAssetAgreement(agreementId, lenderPositionId, borrowerPositionId);
        _assertSameAssetAccounting(lenderKey, borrowerKey, offerId);
        assertEq(sameAssetToken.balanceOf(bob), _borrowerNetFor(40 ether, 900, 14 days), "borrower proceeds");
    }

    function test_acceptFixedBorrowerOffer_rejectsSameAssetBorrowerSolvencyViolation() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 100 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 100 ether, sameAssetToken);

        vm.prank(bob);
        uint256 offerId = harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                principal: 81 ether,
                collateralLocked: 50 ether,
                aprBps: 500,
                durationSeconds: 10 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SolvencyViolation.selector, 100 ether, 81 ether, 8_000));
        harness.acceptFixedBorrowerOffer(offerId, lenderPositionId, 1);
    }

    function test_acceptLenderRatioTrancheOffer_partialFillCancelReleasesOnlyUnfilledCapacity() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 200 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 400 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(alice);
        uint256 offerId = harness.postLenderRatioTrancheOffer(
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
                aprBps: 900,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(bob);
        uint256 agreementId =
            harness.acceptLenderRatioTrancheOffer(offerId, borrowerPositionId, 50 ether, _borrowerNetFor(50 ether, 900, 14 days));

        (
            LibEqualLendDirectStorage.LenderRatioTrancheOffer memory offer,
            LibEqualLendDirectStorage.OfferKind kind
        ) = harness.getLenderRatioOffer(offerId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.OfferKind.RatioTrancheLender), "ratio offer kind");
        assertEq(offer.principalRemaining, 70 ether, "remaining principal after partial fill");
        assertFalse(offer.filled, "offer should stay live after partial fill");
        assertTrue(harness.hasOpenOffers(lenderKey), "open ratio offer not tracked after partial fill");

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(agreement.principal, 50 ether, "partial fill agreement principal");
        assertEq(agreement.collateralLocked, 100 ether, "partial fill collateral locked");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 2);
        (, uint256 lenderEncumbered, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 1);
        assertEq(borrowerLocked, 100 ether, "borrower collateral lock after partial fill");
        assertEq(lenderEncumbered, 50 ether, "lender live exposure after partial fill");
        assertEq(lenderEscrow, 70 ether, "remaining offer escrow after partial fill");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 50 ether, "borrowed principal after partial fill");
        assertEq(harness.principalOf(1, lenderKey), 150 ether, "lender principal after partial fill");
        assertEq(borrowToken.balanceOf(bob), _borrowerNetFor(50 ether, 900, 14 days), "borrower proceeds after partial fill");

        vm.prank(alice);
        harness.cancelLenderRatioTrancheOffer(offerId);

        (offer,) = harness.getLenderRatioOffer(offerId);
        assertTrue(offer.cancelled, "ratio offer not cancelled after partial fill");
        assertTrue(offer.filled, "ratio offer not terminal after cancellation");
        assertEq(offer.principalRemaining, 0, "remaining principal after cancellation");
        assertFalse(harness.hasOpenOffers(lenderKey), "ratio offer still tracked after cancellation");

        (borrowerLocked, lenderEncumbered, lenderEscrow) = harness.encumbranceOf(lenderKey, 1);
        borrowerLocked;
        assertEq(lenderEncumbered, 50 ether, "active exposure changed on cancel");
        assertEq(lenderEscrow, 0, "unfilled capacity not released on cancel");
    }

    function test_acceptLenderRatioTrancheOffer_multiFillDepletesOffer() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 300 ether, borrowToken);
        uint256 borrowerOnePositionId = _mintAndDeposit(bob, 2, 500 ether, collateralToken);
        uint256 borrowerTwoPositionId = _mintAndDeposit(makeAddr("carol"), 2, 500 ether, collateralToken);
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
        uint256 firstAgreementId = harness.acceptLenderRatioTrancheOffer(
            offerId, borrowerOnePositionId, 60 ether, _borrowerNetFor(60 ether, 1_000, 21 days)
        );

        address carol = positionNft.ownerOf(borrowerTwoPositionId);
        vm.prank(carol);
        uint256 secondAgreementId = harness.acceptLenderRatioTrancheOffer(
            offerId, borrowerTwoPositionId, 120 ether, _borrowerNetFor(120 ether, 1_000, 21 days)
        );

        _assertLenderRatioMultiFillDepletion(
            offerId, firstAgreementId, secondAgreementId, lenderKey, borrowerOneKey, borrowerTwoKey
        );
    }

    function test_acceptLenderRatioTrancheOffer_sameAssetUsesSharedDebtAndSingleLock() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 200 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 300 ether, sameAssetToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
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
        uint256 agreementId =
            harness.acceptLenderRatioTrancheOffer(offerId, borrowerPositionId, 40 ether, _borrowerNetFor(40 ether, 900, 14 days));

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(agreement.principal, 40 ether, "same-asset ratio principal");
        assertEq(agreement.collateralLocked, 80 ether, "same-asset ratio collateral");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 3);
        (, uint256 lenderEncumbered, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 3);
        assertEq(borrowerLocked, 80 ether, "same-asset borrower collateral lock");
        assertEq(lenderEncumbered, 40 ether, "same-asset lender exposure");
        assertEq(lenderEscrow, 40 ether, "same-asset remaining offer escrow");

        assertEq(harness.principalOf(3, lenderKey), 160 ether, "same-asset lender principal");
        assertEq(harness.totalDepositsOf(3), 460 ether, "same-asset pool deposits");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 40 ether, "same-asset borrowed principal");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 40 ether, "same-asset pool debt");
        assertEq(harness.sameAssetDebtByAsset(borrowerKey, address(sameAssetToken)), 40 ether, "same-asset stored debt");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 40 ether, "same-asset active credit total");

        (uint256 debtPrincipal,, uint256 debtIndexSnapshot) = harness.activeCreditDebtStateOf(3, borrowerKey);
        assertEq(debtPrincipal, 40 ether, "same-asset active credit debt principal");
        assertEq(debtIndexSnapshot, 0, "same-asset active credit index snapshot");
        assertEq(sameAssetToken.balanceOf(bob), _borrowerNetFor(40 ether, 900, 14 days), "same-asset borrower proceeds");
    }

    function _expectedFeeSplit(uint256 principal, uint16 aprBps, uint64 duration)
        internal
        pure
        returns (uint256 platformFee, uint256 interestAmount, uint256 lenderYield, uint256 treasuryAmount, uint256 feeIndexAmount)
    {
        uint256 effectiveDuration = duration < MIN_INTEREST_DURATION ? MIN_INTEREST_DURATION : duration;
        platformFee = Math.mulDiv(principal, PLATFORM_FEE_BPS, BPS_DENOMINATOR);
        interestAmount = Math.mulDiv(principal, uint256(aprBps) * effectiveDuration, YEAR * BPS_DENOMINATOR);

        uint256 lenderInterestShare = Math.mulDiv(interestAmount, INTEREST_LENDER_BPS, BPS_DENOMINATOR);
        uint256 lenderPlatformShare = Math.mulDiv(platformFee, PLATFORM_FEE_LENDER_BPS, BPS_DENOMINATOR);
        lenderYield = lenderInterestShare + lenderPlatformShare;

        uint256 interestRemainder = interestAmount - lenderInterestShare;
        uint256 platformRemainder = platformFee - lenderPlatformShare;
        uint256 treasuryInterest = Math.mulDiv(interestRemainder, TREASURY_BPS, BPS_DENOMINATOR);
        uint256 treasuryPlatform = Math.mulDiv(platformRemainder, TREASURY_BPS, BPS_DENOMINATOR);
        treasuryAmount = treasuryInterest + treasuryPlatform;
        feeIndexAmount = (interestRemainder - treasuryInterest) + (platformRemainder - treasuryPlatform);
    }

    function _borrowerNetFor(uint256 principal, uint16 aprBps, uint64 duration) internal pure returns (uint256) {
        (uint256 platformFee, uint256 interestAmount,,,) = _expectedFeeSplit(principal, aprBps, duration);
        return principal - platformFee - interestAmount;
    }

    function _assertSameAssetAgreement(uint256 agreementId, uint256 lenderPositionId, uint256 borrowerPositionId) internal view {
        (LibEqualLendDirectStorage.FixedAgreement memory agreement, LibEqualLendDirectStorage.AgreementKind kind) =
            harness.getFixedAgreement(agreementId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.AgreementKind.Fixed), "agreement kind");
        assertEq(agreement.borrowerPositionId, borrowerPositionId, "agreement borrower position");
        assertEq(agreement.lenderPositionId, lenderPositionId, "agreement lender position");
        assertEq(agreement.principal, 40 ether, "agreement principal");
    }

    function _assertSameAssetAccounting(bytes32 lenderKey, bytes32 borrowerKey, uint256 offerId) internal view {
        (LibEqualLendDirectStorage.FixedBorrowerOffer memory offer,) = harness.getFixedBorrowerOffer(offerId);
        assertTrue(offer.filled, "borrower offer not filled");
        assertFalse(harness.hasOpenOffers(borrowerKey), "borrower still has open offers");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 3);
        (, uint256 lenderEncumbered, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 3);
        assertEq(borrowerLocked, 80 ether, "collateral double-locked");
        assertEq(lenderEncumbered, 40 ether, "same-asset lender exposure");
        assertEq(lenderEscrow, 0, "unexpected offer escrow");

        assertEq(harness.principalOf(3, lenderKey), 60 ether, "lender principal after same-asset origination");
        assertEq(harness.totalDepositsOf(3), 210 ether, "same-asset pool deposits");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 40 ether, "same-asset borrowed principal");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 40 ether, "pool same-asset debt");
        assertEq(harness.sameAssetDebtByAsset(borrowerKey, address(sameAssetToken)), 40 ether, "stored same-asset debt");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 40 ether, "active credit principal total");

        (uint256 debtPrincipal,, uint256 debtIndexSnapshot) = harness.activeCreditDebtStateOf(3, borrowerKey);
        assertEq(debtPrincipal, 40 ether, "active credit debt principal");
        assertEq(debtIndexSnapshot, 0, "active credit index snapshot");
    }

    function _assertLenderRatioMultiFillDepletion(
        uint256 offerId,
        uint256 firstAgreementId,
        uint256 secondAgreementId,
        bytes32 lenderKey,
        bytes32 borrowerOneKey,
        bytes32 borrowerTwoKey
    ) internal view {
        (
            LibEqualLendDirectStorage.LenderRatioTrancheOffer memory offer,
            LibEqualLendDirectStorage.OfferKind kind
        ) = harness.getLenderRatioOffer(offerId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.OfferKind.RatioTrancheLender), "ratio kind after depletion");
        assertEq(offer.principalRemaining, 0, "ratio offer not depleted");
        assertTrue(offer.filled, "ratio offer not marked filled");
        assertFalse(harness.hasOpenOffers(lenderKey), "depleted ratio offer still tracked");

        (LibEqualLendDirectStorage.FixedAgreement memory firstAgreement,) = harness.getFixedAgreement(firstAgreementId);
        (LibEqualLendDirectStorage.FixedAgreement memory secondAgreement,) = harness.getFixedAgreement(secondAgreementId);
        assertEq(firstAgreement.principal, 60 ether, "first agreement principal");
        assertEq(firstAgreement.collateralLocked, 120 ether, "first agreement collateral");
        assertEq(secondAgreement.principal, 120 ether, "second agreement principal");
        assertEq(secondAgreement.collateralLocked, 240 ether, "second agreement collateral");

        (uint256 borrowerOneLocked,,) = harness.encumbranceOf(borrowerOneKey, 2);
        (uint256 borrowerTwoLocked,,) = harness.encumbranceOf(borrowerTwoKey, 2);
        (, uint256 lenderEncumbered, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 1);
        assertEq(borrowerOneLocked, 120 ether, "first borrower lock");
        assertEq(borrowerTwoLocked, 240 ether, "second borrower lock");
        assertEq(lenderEncumbered, 180 ether, "lender live exposure after depletion");
        assertEq(lenderEscrow, 0, "escrow not cleared after depletion");
        assertEq(harness.principalOf(1, lenderKey), 120 ether, "lender principal after multi-fill");
        assertEq(harness.totalDepositsOf(1), 120 ether, "pool deposits after multi-fill");
        assertEq(harness.borrowedPrincipalOf(borrowerOneKey, 1), 60 ether, "first borrower borrowed principal");
        assertEq(harness.borrowedPrincipalOf(borrowerTwoKey, 1), 120 ether, "second borrower borrowed principal");
    }

    function _assertCrossAssetAgreement(uint256 agreementId, uint256 lenderPositionId, uint256 borrowerPositionId)
        internal
        view
    {
        (LibEqualLendDirectStorage.FixedAgreement memory agreement, LibEqualLendDirectStorage.AgreementKind kind) =
            harness.getFixedAgreement(agreementId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.AgreementKind.Fixed), "agreement kind");
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Active), "agreement status");
        assertEq(agreement.lenderPositionId, lenderPositionId, "agreement lender position");
        assertEq(agreement.borrowerPositionId, borrowerPositionId, "agreement borrower position");
        assertEq(agreement.principal, 80 ether, "agreement principal");
        assertEq(agreement.userInterest, _interestOnly(80 ether, 1_000, 30 days), "agreement user interest");
        assertEq(agreement.collateralLocked, 120 ether, "agreement collateral");
    }

    function _assertCrossAssetAccounting(bytes32 lenderKey, bytes32 borrowerKey, uint256 lenderPositionId, uint256 offerId)
        internal
        view
    {
        (LibEqualLendDirectStorage.FixedLenderOffer memory offer,) = harness.getFixedLenderOffer(offerId);
        assertTrue(offer.filled, "lender offer not filled");
        assertFalse(harness.hasOpenOffers(lenderKey), "lender still has open offers");

        _assertCrossAssetEncumbrance(lenderKey, borrowerKey);
        _assertCrossAssetPoolAndDebt(lenderKey, borrowerKey);
        _assertCrossAssetFeeResults(lenderKey, lenderPositionId);
    }

    function _assertCrossAssetEncumbrance(bytes32 lenderKey, bytes32 borrowerKey) internal view {
        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 2);
        (, uint256 lenderEncumbered, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 1);
        assertEq(borrowerLocked, 120 ether, "borrower collateral not locked");
        assertEq(lenderEncumbered, 80 ether, "lender live exposure");
        assertEq(lenderEscrow, 0, "offer escrow not cleared");
    }

    function _assertCrossAssetPoolAndDebt(bytes32 lenderKey, bytes32 borrowerKey) internal view {
        assertEq(harness.principalOf(1, lenderKey), 20 ether, "lender principal after origination");
        assertEq(harness.totalDepositsOf(1), 20 ether, "pool deposits after origination");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 80 ether, "borrowed principal ledger");
        assertEq(harness.sameAssetDebtOf(2, borrowerKey), 0, "cross-asset same-asset debt");
        assertEq(harness.sameAssetDebtByAsset(borrowerKey, address(collateralToken)), 0, "cross-asset debt by asset");
        assertEq(harness.activeCreditPrincipalTotalOf(2), 0, "cross-asset active credit total");
    }

    function _assertCrossAssetFeeResults(bytes32 lenderKey, uint256 lenderPositionId) internal view {
        (uint256 platformFee, uint256 interestAmount, uint256 lenderYield, uint256 treasuryAmount, uint256 feeIndexAmount) =
            _expectedFeeSplit(80 ether, 1_000, 30 days);
        assertEq(borrowToken.balanceOf(bob), 80 ether - platformFee - interestAmount, "borrower net proceeds");
        assertEq(borrowToken.balanceOf(treasury), treasuryAmount, "treasury fee split");
        assertEq(harness.trackedBalanceOf(1), 20 ether + lenderYield + feeIndexAmount, "tracked balance after fee routing");
        assertEq(harness.yieldReserveOf(1), lenderYield + feeIndexAmount, "yield reserve backing");
        assertEq(harness.accruedYieldOf(1, lenderKey), lenderYield, "lender direct accrued yield");
        uint256 preview = harness.previewPositionYield(lenderPositionId, 1);
        assertGe(preview, lenderYield, "claimable yield covers lender share");
        assertLe(preview, lenderYield + feeIndexAmount, "claimable yield bounded by reserve");
    }

    function _assertCrossAssetClaimFlow(uint256 lenderPositionId) internal {
        uint256 claimable = harness.previewPositionYield(lenderPositionId, 1);
        uint256 reserveBefore = harness.yieldReserveOf(1);
        uint256 trackedBefore = harness.trackedBalanceOf(1);
        uint256 aliceBefore = borrowToken.balanceOf(alice);

        vm.prank(alice);
        uint256 claimed = harness.claimPositionYield(lenderPositionId, 1, alice, claimable);

        assertEq(claimed, claimable, "claimed yield");
        assertEq(borrowToken.balanceOf(alice) - aliceBefore, claimable, "lender wallet claim");
        assertEq(harness.yieldReserveOf(1), reserveBefore - claimable, "yield reserve after claim");
        assertEq(harness.trackedBalanceOf(1), trackedBefore - claimable, "tracked balance after claim");
    }

    function _interestOnly(uint256 principal, uint16 aprBps, uint64 duration) internal pure returns (uint256) {
        (, uint256 interestAmount,,,) = _expectedFeeSplit(principal, aprBps, duration);
        return interestAmount;
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount, MockERC20DirectAgreement token)
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
