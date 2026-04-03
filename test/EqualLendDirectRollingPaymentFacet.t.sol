// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualLendDirectRollingAgreementFacet} from "src/equallend/EqualLendDirectRollingAgreementFacet.sol";
import {EqualLendDirectRollingLifecycleFacet} from "src/equallend/EqualLendDirectRollingLifecycleFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "src/equallend/EqualLendDirectRollingOfferFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "src/equallend/EqualLendDirectRollingPaymentFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {RollingError_AmortizationDisabled} from "src/libraries/Errors.sol";

contract MockERC20RollingPayments is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualLendDirectRollingPaymentHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectRollingOfferFacet,
    EqualLendDirectRollingAgreementFacet,
    EqualLendDirectRollingPaymentFacet,
    EqualLendDirectRollingLifecycleFacet
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

    function trackedBalanceOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
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

contract EqualLendDirectRollingPaymentFacetTest is Test {
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

    function setUp() public {
        harness = new EqualLendDirectRollingPaymentHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
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

    function test_makeRollingPayment_accruesArrearsAndCurrentInterest_withoutPrincipalReduction() external {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint64 acceptTs) =
            _setupCrossAssetAgreement(false, true);

        vm.warp(acceptTs + 10 days);

        (LibEqualLendDirectStorage.RollingAgreement memory beforeAgreement,) = harness.getRollingAgreement(agreementId);
        RollingAccrualExpectation memory accrual = _previewAccrual(beforeAgreement, block.timestamp);
        uint256 totalInterestDue = accrual.arrearsDue + accrual.currentInterestDue;

        borrowToken.mint(bob, totalInterestDue);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), totalInterestDue);
        harness.makeRollingPayment(agreementId, totalInterestDue, totalInterestDue, 0);
        vm.stopPrank();

        (LibEqualLendDirectStorage.RollingAgreement memory afterAgreement,) = harness.getRollingAgreement(agreementId);
        assertEq(afterAgreement.outstandingPrincipal, beforeAgreement.outstandingPrincipal, "principal changed");
        assertEq(afterAgreement.arrears, 0, "arrears not cleared");
        assertEq(afterAgreement.lastAccrualTimestamp, block.timestamp, "last accrual timestamp");
        assertEq(afterAgreement.nextDue, acceptTs + 14 days, "next due");
        assertEq(afterAgreement.paymentCount, 1, "payment count");

        assertEq(harness.borrowedPrincipalOf(borrowerKey, 1), 60 ether, "borrowed principal mutated");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 2);
        (, uint256 lenderEncumbered,) = harness.encumbranceOf(lenderKey, 1);
        assertEq(borrowerLocked, 90 ether, "borrower lock changed");
        assertEq(lenderEncumbered, 60 ether, "lender exposure changed");

        assertEq(harness.principalOf(1, lenderKey), 40 ether + totalInterestDue, "lender principal credit");
        assertEq(harness.trackedBalanceOf(1), 40 ether + totalInterestDue, "tracked balance credit");
        assertEq(harness.totalDepositsOf(1), 40 ether + totalInterestDue, "pool deposits credit");
    }

    function test_makeRollingPayment_revertsWhenAmortizationDisabledWouldReducePrincipal() external {
        (uint256 agreementId,,, uint64 acceptTs) = _setupCrossAssetAgreement(false, true);

        vm.warp(acceptTs + 10 days);

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        RollingAccrualExpectation memory accrual = _previewAccrual(agreement, block.timestamp);
        uint256 totalInterestDue = accrual.arrearsDue + accrual.currentInterestDue;
        uint256 paymentAmount = totalInterestDue + 1;

        borrowToken.mint(bob, paymentAmount);
        vm.startPrank(bob);
        borrowToken.approve(address(harness), paymentAmount);
        vm.expectRevert(RollingError_AmortizationDisabled.selector);
        harness.makeRollingPayment(agreementId, paymentAmount, paymentAmount, 0);
        vm.stopPrank();
    }

    function test_makeRollingPayment_amortizationOnlyTouchesPrincipalLedgersByPrincipalComponent() external {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint64 acceptTs) = _setupSameAssetAgreement(true, true);

        vm.warp(acceptTs + 10 days);

        (LibEqualLendDirectStorage.RollingAgreement memory beforeAgreement,) = harness.getRollingAgreement(agreementId);
        RollingAccrualExpectation memory accrual = _previewAccrual(beforeAgreement, block.timestamp);
        uint256 totalInterestDue = accrual.arrearsDue + accrual.currentInterestDue;
        uint256 paymentAmount = 5 ether;
        uint256 expectedPrincipalReduction = paymentAmount - totalInterestDue;

        sameAssetToken.mint(bob, paymentAmount);
        vm.startPrank(bob);
        sameAssetToken.approve(address(harness), paymentAmount);
        harness.makeRollingPayment(agreementId, paymentAmount, paymentAmount, 0);
        vm.stopPrank();

        (LibEqualLendDirectStorage.RollingAgreement memory afterAgreement,) = harness.getRollingAgreement(agreementId);
        assertEq(
            beforeAgreement.outstandingPrincipal - afterAgreement.outstandingPrincipal,
            expectedPrincipalReduction,
            "principal reduction"
        );
        assertEq(afterAgreement.arrears, 0, "arrears not cleared");
        assertEq(afterAgreement.nextDue, acceptTs + 14 days, "next due");
        assertEq(afterAgreement.paymentCount, 1, "payment count");

        assertEq(
            harness.borrowedPrincipalOf(borrowerKey, 3),
            beforeAgreement.outstandingPrincipal - expectedPrincipalReduction,
            "borrowed principal"
        );
        assertEq(
            harness.sameAssetDebtOf(3, borrowerKey),
            beforeAgreement.outstandingPrincipal - expectedPrincipalReduction,
            "same-asset debt"
        );
        assertEq(
            harness.sameAssetDebtByAsset(borrowerKey, address(sameAssetToken)),
            beforeAgreement.outstandingPrincipal - expectedPrincipalReduction,
            "same-asset debt by asset"
        );
        assertEq(
            harness.activeCreditPrincipalTotalOf(3),
            beforeAgreement.outstandingPrincipal - expectedPrincipalReduction,
            "active credit principal total"
        );

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 3);
        (, uint256 lenderEncumbered,) = harness.encumbranceOf(lenderKey, 3);
        assertEq(borrowerLocked, 80 ether, "borrower collateral changed");
        assertEq(lenderEncumbered, beforeAgreement.outstandingPrincipal - expectedPrincipalReduction, "lender exposure");

        assertEq(harness.principalOf(3, lenderKey), 60 ether + paymentAmount, "lender principal credit");
        assertEq(harness.totalDepositsOf(3), 210 ether + paymentAmount, "pool deposits credit");
        assertEq(harness.trackedBalanceOf(3), 210 ether + paymentAmount, "tracked balance credit");
    }

    function test_repayRollingInFull_clearsRollingAgreementAndUnlocksCollateral() external {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint64 acceptTs) = _setupSameAssetAgreement(true, true);

        vm.warp(acceptTs + 10 days);
        uint256 firstInterestDue = _currentInterestDue(agreementId);
        _makeSameAssetPayment(agreementId, 5 ether);

        vm.warp(block.timestamp + 3 days);
        (uint256 closeoutInterest, uint256 closeoutTotal) = _closeoutTotals(agreementId);
        _closeSameAssetAgreement(agreementId, closeoutTotal);

        _assertCloseoutState(
            agreementId, lenderKey, borrowerKey, 100 ether + firstInterestDue + closeoutInterest, address(sameAssetToken)
        );
    }

    function _setupCrossAssetAgreement(bool allowAmortization, bool allowEarlyRepay)
        internal
        returns (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint64 acceptTs)
    {
        uint256 lenderPositionId = _mintAndDeposit(alice, 1, 100 ether, borrowToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 2, 150 ether, collateralToken);
        lenderKey = positionNft.getPositionKey(lenderPositionId);
        borrowerKey = positionNft.getPositionKey(borrowerPositionId);

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
                allowAmortization: allowAmortization,
                allowEarlyRepay: allowEarlyRepay,
                allowEarlyExercise: false
            })
        );

        acceptTs = uint64(block.timestamp);
        vm.prank(bob);
        agreementId = harness.acceptRollingLenderOffer(offerId, borrowerPositionId, 0, 60 ether);
    }

    function _setupSameAssetAgreement(bool allowAmortization, bool allowEarlyRepay)
        internal
        returns (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint64 acceptTs)
    {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 100 ether, sameAssetToken);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 150 ether, sameAssetToken);
        lenderKey = positionNft.getPositionKey(lenderPositionId);
        borrowerKey = positionNft.getPositionKey(borrowerPositionId);

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
                allowAmortization: allowAmortization,
                allowEarlyRepay: allowEarlyRepay,
                allowEarlyExercise: true
            })
        );

        acceptTs = uint64(block.timestamp);
        vm.prank(alice);
        agreementId = harness.acceptRollingBorrowerOffer(offerId, lenderPositionId, 0, 40 ether);
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
            accrual.currentInterestDue = _rollingInterest(agreement.outstandingPrincipal, agreement.rollingApyBps, asOf - currentStart);
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

    function _currentInterestDue(uint256 agreementId) internal view returns (uint256) {
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

    function _makeSameAssetPayment(uint256 agreementId, uint256 amount) internal {
        sameAssetToken.mint(bob, amount);
        vm.startPrank(bob);
        sameAssetToken.approve(address(harness), type(uint256).max);
        harness.makeRollingPayment(agreementId, amount, amount, 0);
        vm.stopPrank();
    }

    function _closeSameAssetAgreement(uint256 agreementId, uint256 closeoutTotal) internal {
        sameAssetToken.mint(bob, closeoutTotal);
        vm.startPrank(bob);
        harness.repayRollingInFull(agreementId, closeoutTotal, 0);
        vm.stopPrank();
    }

    function _assertCloseoutState(
        uint256 agreementId,
        bytes32 lenderKey,
        bytes32 borrowerKey,
        uint256 expectedLenderPrincipal,
        address sameAsset
    ) internal view {
        (LibEqualLendDirectStorage.RollingAgreement memory afterCloseout,) = harness.getRollingAgreement(agreementId);
        assertEq(uint256(afterCloseout.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid), "status");
        assertEq(afterCloseout.outstandingPrincipal, 0, "outstanding principal");
        assertEq(afterCloseout.arrears, 0, "arrears");

        assertEq(harness.borrowedPrincipalOf(borrowerKey, 3), 0, "borrowed principal");
        assertEq(harness.sameAssetDebtOf(3, borrowerKey), 0, "same-asset debt");
        assertEq(harness.sameAssetDebtByAsset(borrowerKey, sameAsset), 0, "same-asset debt by asset");
        assertEq(harness.activeCreditPrincipalTotalOf(3), 0, "active credit principal total");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(borrowerKey, 3);
        (, uint256 lenderEncumbered,) = harness.encumbranceOf(lenderKey, 3);
        assertEq(borrowerLocked, 0, "borrower lock");
        assertEq(lenderEncumbered, 0, "lender exposure");
        assertEq(harness.principalOf(3, lenderKey), expectedLenderPrincipal, "lender principal restored");

        assertEq(harness.borrowerAgreementCount(borrowerKey), 0, "borrower agreement index");
        assertEq(harness.lenderAgreementCount(lenderKey), 0, "lender agreement index");
        assertEq(harness.rollingBorrowerAgreementCount(borrowerKey), 0, "rolling borrower agreement index");
        assertEq(harness.rollingLenderAgreementCount(lenderKey), 0, "rolling lender agreement index");
    }
}