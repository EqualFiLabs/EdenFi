// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualLendDirectFixedAgreementFacet} from "src/equallend/EqualLendDirectFixedAgreementFacet.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectLifecycleFacet} from "src/equallend/EqualLendDirectLifecycleFacet.sol";
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
    DirectError_EarlyExerciseNotAllowed,
    DirectError_EarlyRepayNotAllowed,
    DirectError_GracePeriodActive
} from "src/libraries/Errors.sol";
import {NotNFTOwner} from "src/libraries/Errors.sol";

contract MockERC20DirectLifecycle is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualLendDirectLifecycleHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectFixedOfferFacet,
    EqualLendDirectFixedAgreementFacet,
    EqualLendDirectLifecycleFacet
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

    function getFixedAgreement(uint256 agreementId)
        external
        view
        returns (LibEqualLendDirectStorage.FixedAgreement memory agreement, LibEqualLendDirectStorage.AgreementKind kind)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return (store.fixedAgreements[agreementId], store.agreementKindById[agreementId]);
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

    function borrowerAgreementCount(bytes32 positionKey) external view returns (uint256) {
        return LibEqualLendDirectStorage.count(LibEqualLendDirectStorage.s().borrowerAgreementIndex, positionKey);
    }

    function lenderAgreementCount(bytes32 positionKey) external view returns (uint256) {
        return LibEqualLendDirectStorage.count(LibEqualLendDirectStorage.s().lenderAgreementIndex, positionKey);
    }

    function borrowerAgreementIds(bytes32 positionKey) external view returns (uint256[] memory ids) {
        return _copyIds(LibEqualLendDirectStorage.ids(LibEqualLendDirectStorage.s().borrowerAgreementIndex, positionKey));
    }

    function lenderAgreementIds(bytes32 positionKey) external view returns (uint256[] memory ids) {
        return _copyIds(LibEqualLendDirectStorage.ids(LibEqualLendDirectStorage.s().lenderAgreementIndex, positionKey));
    }

    function _copyIds(uint256[] storage source) internal view returns (uint256[] memory ids) {
        ids = new uint256[](source.length);
        for (uint256 i = 0; i < source.length; ++i) {
            ids[i] = source[i];
        }
    }
}

contract EqualLendDirectLifecycleFacetTest is Test {
    uint256 internal constant FIXED_GRACE_PERIOD = 1 days;

    EqualLendDirectLifecycleHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20DirectLifecycle internal borrowToken;
    MockERC20DirectLifecycle internal collateralToken;
    MockERC20DirectLifecycle internal sameAssetToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
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

    function test_repay_gatesEarlyRepayAndRestoresLenderPrincipalBeforeWithdraw() external {
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
                allowEarlyRepay: false,
                allowEarlyExercise: true,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        uint256 agreementId = harness.acceptFixedBorrowerOffer(offerId, lenderPositionId, _borrowerNetFor(40 ether, 900, 14 days));

        sameAssetToken.mint(bob, 1 ether);
        vm.prank(bob);
        sameAssetToken.approve(address(harness), 40 ether);

        vm.prank(bob);
        vm.expectRevert(DirectError_EarlyRepayNotAllowed.selector);
        harness.repay(agreementId, 40 ether);

        vm.warp(block.timestamp + 13 days);

        vm.prank(bob);
        harness.repay(agreementId, 40 ether);

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "status after repay");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 0, "borrowed principal cleared");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 0, "same-asset debt cleared");
        assertEq(harness.sameAssetDebtByAsset(borrowerKey, address(sameAssetToken)), 0, "debt by asset cleared");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 0, "active credit principal cleared");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 3);
        (, uint256 lenderEncumbered,) = harness.encumbranceOf(lenderKey, 3);
        assertEq(borrowerLocked, 0, "borrower collateral still locked");
        assertEq(lenderEncumbered, 0, "lender exposure still encumbered");
        assertEq(harness.principalOf(3, lenderKey), 100 ether, "lender principal not restored");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index after repay");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement index after repay");

        uint256 aliceBefore = sameAssetToken.balanceOf(alice);
        vm.prank(alice);
        harness.withdrawFromPosition(lenderPositionId, 3, 100 ether, 100 ether);
        assertEq(sameAssetToken.balanceOf(alice) - aliceBefore, 100 ether, "lender withdraw after repay");
    }

    function test_callDirect_acceleratesWindowAndBorrowerExerciseSettlesCollateral() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);
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

        vm.prank(bob);
        vm.expectRevert(DirectError_EarlyExerciseNotAllowed.selector);
        harness.exerciseDirect(agreementId);

        vm.prank(alice);
        harness.callDirect(agreementId);

        (LibEqualLendDirectStorage.FixedAgreement memory calledAgreement,) = harness.getFixedAgreement(agreementId);
        assertEq(calledAgreement.dueTimestamp, uint64(block.timestamp), "call did not accelerate due timestamp");

        vm.prank(bob);
        harness.exerciseDirect(agreementId);

        (LibEqualLendDirectStorage.FixedAgreement memory exercisedAgreement,) = harness.getFixedAgreement(agreementId);
        assertEq(uint256(exercisedAgreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Exercised), "status after exercise");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 0, "borrowed principal after exercise");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 2);
        assertEq(borrowerLocked, 0, "borrower lock after exercise");
        assertEq(harness.principalOf(2, positionNft.getPositionKey(lenderPositionId)), 80 ether, "lender collateral principal");

        uint256 aliceBefore = collateralToken.balanceOf(alice);
        vm.prank(alice);
        harness.withdrawFromPosition(lenderPositionId, 2, 80 ether, 80 ether);
        assertEq(collateralToken.balanceOf(alice) - aliceBefore, 80 ether, "lender collateral withdraw");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index after exercise");
        assertEq(harness.lenderAgreementCount(positionNft.getPositionKey(lenderPositionId)), 0, "lender agreement index after exercise");
    }

    function test_recover_afterGracePeriod_permissionlessClearsStateAndDistributesCollateral() external {
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
                principal: 60 ether,
                collateralLocked: 100 ether,
                aprBps: 700,
                durationSeconds: 10 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(bob);
        uint256 agreementId = harness.acceptFixedLenderOffer(offerId, borrowerPositionId, _borrowerNetFor(60 ether, 700, 10 days));

        vm.prank(carol);
        vm.expectRevert(DirectError_GracePeriodActive.selector);
        harness.recover(agreementId);

        vm.warp(block.timestamp + 11 days);

        uint256 treasuryBefore = collateralToken.balanceOf(treasury);
        vm.prank(carol);
        harness.recover(agreementId);

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Defaulted), "status after recover");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 0, "borrowed principal after recover");
        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 2);
        (, uint256 lenderEncumbered,) = harness.encumbranceOf(lenderKey, 1);
        assertEq(borrowerLocked, 0, "borrower lock after recover");
        assertEq(lenderEncumbered, 0, "lender exposure after recover");

        assertEq(harness.principalOf(2, lenderKey), 80 ether, "lender collateral principal after recover");
        assertEq(collateralToken.balanceOf(treasury) - treasuryBefore, 2 ether, "treasury default share");
        assertEq(harness.yieldReserveOf(2), 18 ether, "fee-index reserve from recover");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index after recover");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement index after recover");

        uint256 aliceBefore = collateralToken.balanceOf(alice);
        vm.prank(alice);
        harness.withdrawFromPosition(lenderPositionId, 2, 80 ether, 80 ether);
        assertEq(collateralToken.balanceOf(alice) - aliceBefore, 80 ether, "lender collateral withdraw after recover");
    }

    function test_callDirect_followsTransferredLenderOwnership() external {
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

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, alice, lenderPositionId));
        harness.callDirect(agreementId);

        vm.prank(carol);
        harness.callDirect(agreementId);

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        assertEq(agreement.dueTimestamp, uint64(block.timestamp), "transferred lender did not control call");
    }

    function test_repay_ratioOriginatedAgreement_clearsGenericAgreementIndexes() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 200 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 300 ether, collateralToken);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = positionNft.getPositionKey(borrowerPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postBorrowerRatioTrancheOffer(
            EqualLendDirectFixedOfferFacet.BorrowerRatioTrancheOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(borrowToken),
                collateralAsset: address(collateralToken),
                collateralCap: 120 ether,
                priceNumerator: 1,
                priceDenominator: 2,
                minCollateralPerFill: 40 ether,
                aprBps: 900,
                durationSeconds: 14 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        uint256 agreementId = harness.acceptBorrowerRatioTrancheOffer(
            offerId, lenderPositionId, 60 ether, _borrowerNetFor(30 ether, 900, 14 days)
        );

        uint256[] memory borrowerAgreementIdsBefore = harness.borrowerAgreementIds(borrowerKey);
        uint256[] memory lenderAgreementIdsBefore = harness.lenderAgreementIds(lenderKey);

        assertEq(harness.borrowerAgreementCount(borrowerKey), 1, "borrower agreement count before ratio repay");
        assertEq(harness.lenderAgreementCount(lenderKey), 1, "lender agreement count before ratio repay");
        assertEq(borrowerAgreementIdsBefore.length, 1, "borrower agreement ids before ratio repay");
        assertEq(lenderAgreementIdsBefore.length, 1, "lender agreement ids before ratio repay");
        assertEq(borrowerAgreementIdsBefore[0], agreementId, "borrower agreement id before ratio repay");
        assertEq(lenderAgreementIdsBefore[0], agreementId, "lender agreement id before ratio repay");

        borrowToken.mint(bob, 30 ether);
        vm.prank(bob);
        borrowToken.approve(address(harness), 30 ether);

        vm.prank(bob);
        harness.repay(agreementId, 30 ether);

        (LibEqualLendDirectStorage.FixedAgreement memory agreement,) = harness.getFixedAgreement(agreementId);
        uint256[] memory borrowerAgreementIdsAfter = harness.borrowerAgreementIds(borrowerKey);
        uint256[] memory lenderAgreementIdsAfter = harness.lenderAgreementIds(lenderKey);
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "ratio agreement status");
        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement count after ratio repay");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement count after ratio repay");
        assertEq(borrowerAgreementIdsAfter.length, 0, "borrower agreement ids after ratio repay");
        assertEq(lenderAgreementIdsAfter.length, 0, "lender agreement ids after ratio repay");
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
