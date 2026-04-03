// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {EqualLendDirectConfigFacet} from "src/equallend/EqualLendDirectConfigFacet.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectFixedAgreementFacet} from "src/equallend/EqualLendDirectFixedAgreementFacet.sol";
import {EqualLendDirectLifecycleFacet} from "src/equallend/EqualLendDirectLifecycleFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "src/equallend/EqualLendDirectRollingOfferFacet.sol";
import {EqualLendDirectRollingAgreementFacet} from "src/equallend/EqualLendDirectRollingAgreementFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "src/equallend/EqualLendDirectRollingPaymentFacet.sol";
import {EqualLendDirectRollingLifecycleFacet} from "src/equallend/EqualLendDirectRollingLifecycleFacet.sol";
import {EqualLendDirectViewFacet} from "src/equallend/EqualLendDirectViewFacet.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";

import {LaunchFixture, MockERC20Launch} from "test/utils/LaunchFixture.t.sol";

contract EqualLendDirectLaunchDiamondTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _configureDirect();
    }

    function test_LiveLaunch_EqualLendDirect_FixedLifecycleRepaysAndRestoresLenderLiquidity() external {
        uint256 lenderPositionId = _mintPositionWithDeposit(alice, 1, 100 ether, eve);
        uint256 borrowerPositionId = _mintPositionWithDeposit(bob, 2, 150 ether, alt);

        vm.prank(alice);
        uint256 offerId = EqualLendDirectFixedOfferFacet(diamond).postFixedLenderOffer(
            EqualLendDirectFixedOfferFacet.FixedLenderOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                borrowAsset: address(eve),
                collateralAsset: address(alt),
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
        uint256 agreementId = EqualLendDirectFixedAgreementFacet(diamond).acceptFixedLenderOffer(
            offerId, borrowerPositionId, _borrowerNetFor(80 ether, 800, 21 days)
        );

        eve.mint(bob, 80 ether);
        vm.startPrank(bob);
        eve.approve(diamond, 80 ether);
        EqualLendDirectLifecycleFacet(diamond).repay(agreementId, 80 ether);
        vm.stopPrank();

        LibEqualLendDirectStorage.FixedAgreement memory agreement =
            EqualLendDirectViewFacet(diamond).getFixedAgreement(agreementId);
        EqualLendDirectViewFacet.PositionAgreementIds memory borrowerAgreements =
            EqualLendDirectViewFacet(diamond).getBorrowerAgreementIds(borrowerPositionId);
        EqualLendDirectViewFacet.PositionAgreementIds memory lenderAgreements =
            EqualLendDirectViewFacet(diamond).getLenderAgreementIds(lenderPositionId);

        assertEq(uint256(agreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Repaid));
        assertEq(agreement.lender, alice);
        assertEq(agreement.borrower, bob);
        assertEq(borrowerAgreements.allAgreementIds.length, 0);
        assertEq(lenderAgreements.allAgreementIds.length, 0);

        uint256 aliceBefore = eve.balanceOf(alice);
        vm.prank(alice);
        PositionManagementFacet(diamond).withdrawFromPosition(lenderPositionId, 1, 100 ether, 100 ether);
        assertEq(eve.balanceOf(alice) - aliceBefore, 100 ether);
    }

    function test_LiveLaunch_EqualLendDirect_InstallsRollingAndTrancheSurface() external view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        assertTrue(loupe.facetAddress(EqualLendDirectFixedOfferFacet.postLenderRatioTrancheOffer.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectFixedOfferFacet.postBorrowerRatioTrancheOffer.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectFixedAgreementFacet.acceptLenderRatioTrancheOffer.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectFixedAgreementFacet.acceptBorrowerRatioTrancheOffer.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectRollingOfferFacet.postRollingLenderOffer.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectRollingOfferFacet.postRollingBorrowerOffer.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectRollingAgreementFacet.acceptRollingLenderOffer.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectRollingAgreementFacet.acceptRollingBorrowerOffer.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectRollingPaymentFacet.makeRollingPayment.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectRollingLifecycleFacet.exerciseRolling.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectRollingLifecycleFacet.recoverRolling.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectRollingLifecycleFacet.repayRollingInFull.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectViewFacet.getRollingStatus.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectViewFacet.getLenderRatioTrancheStatus.selector) != address(0));
        assertTrue(loupe.facetAddress(EqualLendDirectViewFacet.getBorrowerRatioTrancheStatus.selector) != address(0));

        LibEqualLendDirectStorage.DirectConfig memory directConfig = EqualLendDirectViewFacet(diamond).getDirectConfig();
        LibEqualLendDirectStorage.DirectRollingConfig memory rollingConfig =
            EqualLendDirectViewFacet(diamond).getDirectRollingConfig();

        assertEq(uint256(directConfig.platformFeeBps), 100);
        assertEq(uint256(directConfig.minInterestDuration), 1 days);
        assertEq(uint256(rollingConfig.maxPaymentCount), 24);
        assertEq(uint256(rollingConfig.minPaymentIntervalSeconds), 1 days);
    }

    function _configureDirect() internal {
        LibEqualLendDirectStorage.DirectConfig memory directConfig = LibEqualLendDirectStorage.DirectConfig({
            platformFeeBps: 100,
            interestLenderBps: 6_000,
            platformFeeLenderBps: 2_500,
            defaultLenderBps: 8_000,
            minInterestDuration: 1 days
        });
        LibEqualLendDirectStorage.DirectRollingConfig memory rollingConfig =
            LibEqualLendDirectStorage.DirectRollingConfig({
                minPaymentIntervalSeconds: 1 days,
                maxPaymentCount: 24,
                maxUpfrontPremiumBps: 2_500,
                minRollingApyBps: 300,
                maxRollingApyBps: 2_000,
                defaultPenaltyBps: 500,
                minPaymentBps: 1
            });

        _timelockCall(
            diamond, abi.encodeWithSelector(EqualLendDirectConfigFacet.setDirectConfig.selector, directConfig)
        );
        _timelockCall(
            diamond, abi.encodeWithSelector(EqualLendDirectConfigFacet.setRollingConfig.selector, rollingConfig)
        );
    }

    function _mintPositionWithDeposit(address owner, uint256 poolId, uint256 amount, MockERC20Launch token)
        internal
        returns (uint256 positionId)
    {
        token.mint(owner, amount);

        vm.startPrank(owner);
        positionId = PositionManagementFacet(diamond).mintPosition(poolId);
        token.approve(diamond, amount);
        PositionManagementFacet(diamond).depositToPosition(positionId, poolId, amount, amount);
        vm.stopPrank();
    }

    function _borrowerNetFor(uint256 principal, uint16 aprBps, uint64 duration) internal pure returns (uint256) {
        uint256 platformFee = (principal * 100) / 10_000;
        uint256 effectiveDuration = duration < 1 days ? 1 days : duration;
        uint256 interestAmount = (principal * uint256(aprBps) * effectiveDuration) / (365 days * 10_000);
        return principal - platformFee - interestAmount;
    }
}