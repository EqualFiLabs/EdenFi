// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {EqualLendDirectRollingPaymentFacetTest} from "test/EqualLendDirectRollingPaymentFacet.t.sol";
import {DirectError_EarlyRepayNotAllowed} from "src/libraries/Errors.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";

contract EqualLendDirectRollingLifecycleBugConditionTest is EqualLendDirectRollingPaymentFacetTest {
    function test_BugCondition_RecoverRolling_PenaltyShouldBeCappedBySeizedDebtValue() external {
        (uint256 agreementId,,, uint64 acceptTs) = _setupCrossAssetAgreement(false, true);

        vm.warp(acceptTs + (400 * 365 days));

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        RollingAccrualExpectation memory accrual = _previewAccrual(agreement, block.timestamp);
        uint256 totalDebt = agreement.outstandingPrincipal + accrual.arrearsDue + accrual.currentInterestDue;
        uint256 collateralSeized = agreement.collateralLocked;
        uint256 expectedPenaltyCap = (collateralSeized < totalDebt ? collateralSeized : totalDebt) * 500 / 10_000;

        vm.recordLogs();
        vm.prank(alice);
        harness.recoverRolling(agreementId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 eventSig =
            keccak256("RollingAgreementRecovered(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 penaltyPaid;
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 3 || logs[i].topics[0] != eventSig) {
                continue;
            }
            (penaltyPaid,,,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            found = true;
            break;
        }

        assertTrue(found, "expected RollingAgreementRecovered event");
        assertLe(penaltyPaid, expectedPenaltyCap, "penalty should be capped by seized debt value");
    }
}

contract EqualLendDirectRollingLifecyclePreservationTest is EqualLendDirectRollingPaymentFacetTest {
    function test_recoverRolling_farPastDueUsesRealizedValuePenaltyBase() external {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint64 acceptTs) =
            _setupCrossAssetAgreement(false, true);

        vm.warp(acceptTs + (400 * 365 days));

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        RollingAccrualExpectation memory accrual = _previewAccrual(agreement, block.timestamp);
        uint256 totalDebt = agreement.outstandingPrincipal + accrual.arrearsDue + accrual.currentInterestDue;
        TerminalExpectation memory expected = _previewTerminalExpectation(agreement, 150 ether, block.timestamp, true);
        uint256 treasuryBefore = collateralToken.balanceOf(treasury);

        assertGt(totalDebt, expected.collateralSeized, "setup should push total debt above seized collateral");

        vm.recordLogs();
        vm.prank(alice);
        harness.recoverRolling(agreementId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 eventSig =
            keccak256("RollingAgreementRecovered(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 penaltyPaid;
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 3 || logs[i].topics[0] != eventSig) {
                continue;
            }
            (penaltyPaid,,,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            found = true;
            break;
        }

        assertTrue(found, "expected RollingAgreementRecovered event");
        assertEq(penaltyPaid, expected.penaltyPaid, "penalty should use realized-value base");
        assertEq(harness.principalOf(2, lenderKey), expected.lenderShare, "lender recovery share");
        assertEq(
            harness.principalOf(2, borrowerKey),
            150 ether - expected.debtValueApplied - expected.penaltyPaid,
            "borrower refund balance"
        );
        assertEq(
            collateralToken.balanceOf(treasury) - treasuryBefore,
            expected.treasuryShare + expected.penaltyPaid,
            "treasury share plus penalty"
        );
        assertEq(harness.yieldReserveOf(2), expected.feeIndexShare, "fee-index reserve");
    }

    function test_repayRollingInFull_revertsWhenEarlyRepayDisabledBeforePaymentCap() external {
        (uint256 agreementId,,, ) = _setupCrossAssetAgreement(false, false);

        vm.prank(bob);
        vm.expectRevert(DirectError_EarlyRepayNotAllowed.selector);
        harness.repayRollingInFull(agreementId, 1 ether, 0);
    }

    function test_recoverRolling_preservesDefaultSplitRouting() external {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint64 acceptTs) = _setupCrossAssetAgreement(false, true);

        vm.warp(acceptTs + 8 days + 1);

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        TerminalExpectation memory expected = _previewTerminalExpectation(agreement, 150 ether, block.timestamp, true);
        uint256 treasuryBefore = collateralToken.balanceOf(treasury);

        vm.prank(alice);
        harness.recoverRolling(agreementId);

        (LibEqualLendDirectStorage.RollingAgreement memory afterAgreement,) = harness.getRollingAgreement(agreementId);
        assertEq(uint256(afterAgreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Defaulted), "status");
        assertEq(harness.principalOf(2, lenderKey), expected.lenderShare, "lender collateral principal");
        assertEq(
            harness.principalOf(2, borrowerKey),
            150 ether - expected.debtValueApplied - expected.penaltyPaid,
            "borrower refund balance"
        );
        assertEq(
            collateralToken.balanceOf(treasury) - treasuryBefore,
            expected.treasuryShare + expected.penaltyPaid,
            "treasury recovery"
        );
        assertEq(harness.yieldReserveOf(2), expected.feeIndexShare, "fee-index reserve");
    }

    function test_exerciseRolling_preservesNoPenaltyPath() external {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint64 acceptTs) = _setupSameAssetAgreement(true, true);

        vm.warp(acceptTs + 10 days);

        (LibEqualLendDirectStorage.RollingAgreement memory agreement,) = harness.getRollingAgreement(agreementId);
        TerminalExpectation memory expected = _previewTerminalExpectation(agreement, 150 ether, block.timestamp, false);
        uint256 treasuryBefore = sameAssetToken.balanceOf(treasury);

        vm.prank(bob);
        harness.exerciseRolling(agreementId);

        (LibEqualLendDirectStorage.RollingAgreement memory afterAgreement,) = harness.getRollingAgreement(agreementId);
        assertEq(uint256(afterAgreement.status), uint256(LibEqualLendDirectStorage.AgreementStatus.Exercised), "status");
        assertEq(sameAssetToken.balanceOf(treasury) - treasuryBefore, expected.treasuryShare, "treasury share");
        assertEq(harness.principalOf(3, lenderKey), 60 ether + expected.lenderShare, "lender recovered principal");
        assertEq(
            harness.principalOf(3, borrowerKey),
            150 ether - expected.debtValueApplied,
            "borrower refunded principal"
        );
        assertEq(harness.yieldReserveOf(3), expected.feeIndexShare, "fee-index reserve");
    }
}
