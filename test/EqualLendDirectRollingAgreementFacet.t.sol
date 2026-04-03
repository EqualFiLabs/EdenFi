// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectRollingAgreementFacet} from "src/equallend/EqualLendDirectRollingAgreementFacet.sol";
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
import {SolvencyViolation} from "src/libraries/Errors.sol";

contract MockERC20RollingAgreement is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualLendDirectRollingAgreementHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectFixedOfferFacet,
    EqualLendDirectRollingOfferFacet,
    EqualLendDirectRollingAgreementFacet
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

    function getRollingAgreement(uint256 agreementId)
        external
        view
        returns (LibEqualLendDirectStorage.RollingAgreement memory agreement, LibEqualLendDirectStorage.AgreementKind kind)
    {
        LibEqualLendDirectStorage.DirectStorage storage store = LibEqualLendDirectStorage.s();
        return (store.rollingAgreements[agreementId], store.agreementKindById[agreementId]);
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

    function totalDepositsOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function borrowedPrincipalOf(bytes32 positionKey, uint256 lenderPoolId) external view returns (uint256) {
        return LibEqualLendDirectStorage.s().borrowedPrincipalByPool[positionKey][lenderPoolId];
    }

    function sameAssetDebtOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userSameAssetDebt[positionKey];
    }

    function sameAssetDebtByAsset(bytes32 positionKey, address asset) external view returns (uint256) {
        return LibEqualLendDirectStorage.s().sameAssetDebtByAsset[positionKey][asset];
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

    function borrowerAgreementCount(bytes32 positionKey) external view returns (uint256) {
        return LibEqualLendDirectStorage.count(LibEqualLendDirectStorage.s().borrowerAgreementIndex, positionKey);
    }

    function lenderAgreementCount(bytes32 positionKey) external view returns (uint256) {
        return LibEqualLendDirectStorage.count(LibEqualLendDirectStorage.s().lenderAgreementIndex, positionKey);
    }

    function rollingBorrowerAgreementCount(bytes32 positionKey) external view returns (uint256) {
        return LibEqualLendDirectStorage.count(LibEqualLendDirectStorage.s().rollingBorrowerAgreementIndex, positionKey);
    }

    function rollingLenderAgreementCount(bytes32 positionKey) external view returns (uint256) {
        return LibEqualLendDirectStorage.count(LibEqualLendDirectStorage.s().rollingLenderAgreementIndex, positionKey);
    }
}

contract EqualLendDirectRollingAgreementFacetTest is Test {
    EqualLendDirectRollingAgreementHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20RollingAgreement internal borrowToken;
    MockERC20RollingAgreement internal collateralToken;
    MockERC20RollingAgreement internal sameAssetToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        harness = new EqualLendDirectRollingAgreementHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        borrowToken = new MockERC20RollingAgreement("Borrow", "BRW");
        collateralToken = new MockERC20RollingAgreement("Collateral", "COL");
        sameAssetToken = new MockERC20RollingAgreement("Same Asset", "SAM");

        _initPool(1, address(borrowToken));
        _initPool(2, address(collateralToken));
        _initPool(3, address(sameAssetToken));
        harness.setRollingConfig(1 days, 24, 2_500, 300, 2_000, 500, 500);
    }

    function test_acceptRollingLenderOffer_crossAssetMatchesFixedOriginationLedgers() external {
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
                upfrontPremium: 2 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: false
            })
        );

        vm.warp(10 days);
        uint256 acceptTs = block.timestamp;

        vm.prank(bob);
        uint256 agreementId = harness.acceptRollingLenderOffer(offerId, borrowerPositionId, 2 ether, 58 ether);

        (LibEqualLendDirectStorage.RollingAgreement memory agreement, LibEqualLendDirectStorage.AgreementKind kind) =
            harness.getRollingAgreement(agreementId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.AgreementKind.Rolling), "agreement kind");
        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Active), "agreement status");
        assertEq(agreement.lenderPositionId, lenderPositionId, "lender position");
        assertEq(agreement.borrowerPositionId, borrowerPositionId, "borrower position");
        assertEq(agreement.principal, 60 ether, "principal");
        assertEq(agreement.outstandingPrincipal, 60 ether, "outstanding principal");
        assertEq(agreement.collateralLocked, 90 ether, "collateral");
        assertEq(agreement.upfrontPremium, 2 ether, "premium");
        assertEq(agreement.nextDue, acceptTs + 7 days, "next due");
        assertEq(agreement.lastAccrualTimestamp, acceptTs, "last accrual");
        assertEq(agreement.arrears, 0, "arrears");
        assertEq(agreement.paymentCount, 0, "payment count");
        assertEq(agreement.paymentIntervalSeconds, 7 days, "interval");

        (LibEqualLendDirectStorage.RollingLenderOffer memory offer,) = harness.getRollingLenderOffer(offerId);
        assertTrue(offer.filled, "offer not filled");
        assertFalse(harness.hasOpenOffers(lenderKey), "lender still has open offers");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 2);
        (, uint256 lenderEncumbered, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 1);
        assertEq(borrowerLocked, 90 ether, "borrower lock");
        assertEq(lenderEncumbered, 60 ether, "lender exposure");
        assertEq(lenderEscrow, 0, "lender escrow");

        assertEq(harness.principalOf(1, lenderKey), 40 ether, "lender principal");
        assertEq(harness.totalDepositsOf(1), 40 ether, "pool deposits");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 60 ether, "borrowed principal");
        assertEq(harness.sameAssetDebtOf(2, borrowerKey), 0, "same-asset debt");
        assertEq(harness.sameAssetDebtByAsset(borrowerKey, address(collateralToken)), 0, "stored same-asset debt");
        assertEq(harness.activeCreditPrincipalTotalOf(2), 0, "active credit total");

        assertEq(borrowToken.balanceOf(alice), 2 ether, "lender premium");
        assertEq(borrowToken.balanceOf(bob), 58 ether, "borrower proceeds");

        assertEq(harness.borrowerAgreementCount(borrowerKey), 1, "borrower agreement count");
        assertEq(harness.lenderAgreementCount(lenderKey), 1, "lender agreement count");
        assertEq(harness.rollingBorrowerAgreementCount(borrowerKey), 1, "rolling borrower agreement count");
        assertEq(harness.rollingLenderAgreementCount(lenderKey), 1, "rolling lender agreement count");
    }

    function test_acceptRollingBorrowerOffer_sameAssetUsesSharedDebtAndSingleLock() external {
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
                upfrontPremium: 4 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );

        vm.warp(20 days);
        uint256 acceptTs = block.timestamp;

        vm.prank(alice);
        uint256 agreementId = harness.acceptRollingBorrowerOffer(offerId, lenderPositionId, 4 ether, 36 ether);

        (LibEqualLendDirectStorage.RollingAgreement memory agreement, LibEqualLendDirectStorage.AgreementKind kind) =
            harness.getRollingAgreement(agreementId);
        assertEq(uint256(kind), uint256(LibEqualLendDirectStorage.AgreementKind.Rolling), "agreement kind");
        assertEq(agreement.borrowerPositionId, borrowerPositionId, "borrower position");
        assertEq(agreement.lenderPositionId, lenderPositionId, "lender position");
        assertEq(agreement.principal, 40 ether, "principal");
        assertEq(agreement.outstandingPrincipal, 40 ether, "outstanding principal");
        assertEq(agreement.collateralLocked, 80 ether, "collateral");
        assertEq(agreement.nextDue, acceptTs + 7 days, "next due");
        assertEq(agreement.lastAccrualTimestamp, acceptTs, "last accrual");
        assertEq(agreement.arrears, 0, "arrears");
        assertEq(agreement.paymentCount, 0, "payment count");

        (LibEqualLendDirectStorage.RollingBorrowerOffer memory offer,) = harness.getRollingBorrowerOffer(offerId);
        assertTrue(offer.filled, "offer not filled");
        assertFalse(harness.hasOpenOffers(borrowerKey), "borrower still has open offers");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 3);
        (, uint256 lenderEncumbered, uint256 lenderEscrow) = harness.encumbranceOf(lenderKey, 3);
        assertEq(borrowerLocked, 80 ether, "collateral double lock");
        assertEq(lenderEncumbered, 40 ether, "lender exposure");
        assertEq(lenderEscrow, 0, "unexpected lender escrow");

        assertEq(harness.principalOf(3, lenderKey), 60 ether, "lender principal");
        assertEq(harness.totalDepositsOf(3), 210 ether, "pool deposits");
        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 40 ether, "borrowed principal");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 40 ether, "pool same-asset debt");
        assertEq(harness.sameAssetDebtByAsset(borrowerKey, address(sameAssetToken)), 40 ether, "stored same-asset debt");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 40 ether, "active credit total");

        (uint256 debtPrincipal,, uint256 debtIndexSnapshot) = harness.activeCreditDebtStateOf(3, borrowerKey);
        assertEq(debtPrincipal, 40 ether, "debt principal");
        assertEq(debtIndexSnapshot, 0, "debt index snapshot");

        assertEq(sameAssetToken.balanceOf(alice), 4 ether, "lender premium");
        assertEq(sameAssetToken.balanceOf(bob), 36 ether, "borrower proceeds");

        assertEq(harness.borrowerAgreementCount(borrowerKey), 1, "borrower agreement count");
        assertEq(harness.lenderAgreementCount(lenderKey), 1, "lender agreement count");
        assertEq(harness.rollingBorrowerAgreementCount(borrowerKey), 1, "rolling borrower agreement count");
        assertEq(harness.rollingLenderAgreementCount(lenderKey), 1, "rolling lender agreement count");
    }

    function test_acceptRollingBorrowerOffer_rejectsSameAssetBorrowerSolvencyViolation() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 100 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 100 ether, sameAssetToken);

        vm.prank(bob);
        uint256 offerId = harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                principal: 81 ether,
                collateralLocked: 50 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 700,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 10,
                upfrontPremium: 1 ether,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SolvencyViolation.selector, 100 ether, 81 ether, 8_000));
        harness.acceptRollingBorrowerOffer(offerId, lenderPositionId, 1 ether, 80 ether);
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount, MockERC20RollingAgreement token)
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
