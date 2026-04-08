// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {EqualLendDirectRollingPaymentFacetTest} from "test/EqualLendDirectRollingPaymentFacet.t.sol";
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
