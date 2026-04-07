// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";
import {LibActiveCreditIndexHarness} from "test/utils/LibActiveCreditIndexHarness.sol";

contract LibActiveCreditIndexTest is Test {
    uint256 internal constant POOL_ID = 7;
    uint256 internal constant INDEX_SCALE = 1e18;
    uint256 internal constant PRINCIPAL = 100 ether;
    uint256 internal constant YIELD_AMOUNT = 10 ether;

    bytes32 internal constant USER = keccak256("aci-user");

    LibActiveCreditIndexHarness internal harness;

    function setUp() public {
        vm.warp(30 days);
        harness = new LibActiveCreditIndexHarness();
    }

    function test_BugCondition_BucketOverflowRemoval_ShouldRemoveFromLastPendingBucket() external {
        uint40 futureStart = _primeOverflowOffsetState(PRINCIPAL);
        uint8 lastBucket = _lastBucketIndex();

        (,, uint256 maturedBefore,,) = harness.poolState(POOL_ID);
        uint256 pendingBefore = harness.pendingBucket(POOL_ID, lastBucket);
        assertEq(pendingBefore, PRINCIPAL, "scheduled into last pending bucket");

        harness.decreaseTrackedEncumbrancePrincipal(POOL_ID, USER, PRINCIPAL);

        uint256 pendingAfter = harness.pendingBucket(POOL_ID, lastBucket);
        (, uint40 storedStartTime,) = harness.encumbranceState(POOL_ID, USER);
        (,, uint256 maturedAfter,,) = harness.poolState(POOL_ID);

        assertEq(storedStartTime, futureStart, "start time unchanged during bookkeeping remove");
        assertEq(pendingAfter, 0, "pending bucket should be decremented");
        assertEq(maturedAfter, maturedBefore, "matured total should stay unchanged");
    }

    function test_BugCondition_BucketOverflowRemoval_ShouldNotPhantomInflateAfterRoll() external {
        _primeOverflowOffsetState(PRINCIPAL);

        harness.decreaseTrackedEncumbrancePrincipal(POOL_ID, USER, PRINCIPAL);

        vm.warp(block.timestamp + 72 hours);
        harness.roll(POOL_ID);

        (,, uint256 maturedTotal,,) = harness.poolState(POOL_ID);
        assertEq(maturedTotal, 0, "removed overflow bucket should not roll into matured total");
    }

    function test_BugCondition_EncumbranceIncrease_ShouldSettlePendingYieldBeforeSnapshotOverwrite() external {
        uint256 expectedYield = _primeMatureEncumbranceWithYield(PRINCIPAL, YIELD_AMOUNT);

        harness.applyEncumbranceIncrease(POOL_ID, USER, 50 ether);

        assertEq(harness.userAccruedYield(POOL_ID, USER), expectedYield, "pending yield should settle on increase");
    }

    function test_BugCondition_EncumbranceDecrease_ShouldSettlePendingYieldBeforeSnapshotOverwrite() external {
        uint256 expectedYield = _primeMatureEncumbranceWithYield(PRINCIPAL, YIELD_AMOUNT);

        harness.applyEncumbranceDecrease(POOL_ID, USER, 40 ether);

        assertEq(harness.userAccruedYield(POOL_ID, USER), expectedYield, "pending yield should settle on decrease");
    }

    function test_NormalBucketPlacement_RemovesFromPendingBucketForInWindowOffsets() external {
        harness.initPool(POOL_ID, 0);
        harness.setEncumbranceState(POOL_ID, USER, PRINCIPAL, uint40(block.timestamp), 0);
        harness.trackEncumbranceState(POOL_ID, USER);

        uint8 lastBucket = _lastBucketIndex();
        assertEq(harness.pendingBucket(POOL_ID, lastBucket), PRINCIPAL, "principal scheduled into in-window bucket");

        harness.decreaseTrackedEncumbrancePrincipal(POOL_ID, USER, 40 ether);

        assertEq(harness.pendingBucket(POOL_ID, lastBucket), 60 ether, "pending bucket decremented by removed amount");
        (,, uint256 maturedTotal,,) = harness.poolState(POOL_ID);
        assertEq(maturedTotal, 0, "matured total unchanged before maturity");
    }

    function test_MatureStateRemoval_DecrementsMaturedTotal() external {
        harness.initPool(POOL_ID, 0);
        harness.setEncumbranceState(POOL_ID, USER, PRINCIPAL, uint40(block.timestamp - 25 hours), 0);
        harness.trackEncumbranceState(POOL_ID, USER);

        (,, uint256 maturedBefore,,) = harness.poolState(POOL_ID);
        assertEq(maturedBefore, PRINCIPAL, "matured principal tracked");

        harness.decreaseTrackedEncumbrancePrincipal(POOL_ID, USER, 40 ether);

        (uint256 principalAfter,,) = harness.encumbranceState(POOL_ID, USER);
        (,, uint256 maturedAfter,,) = harness.poolState(POOL_ID);
        assertEq(principalAfter, 60 ether, "principal reduced");
        assertEq(maturedAfter, 60 ether, "matured total reduced in lockstep");
    }

    function test_RollMatured_MovesPendingPrincipalIntoMaturedTotal() external {
        harness.initPool(POOL_ID, 0);
        harness.setEncumbranceState(POOL_ID, USER, PRINCIPAL, uint40(block.timestamp), 0);
        harness.trackEncumbranceState(POOL_ID, USER);

        vm.warp(block.timestamp + 25 hours);
        harness.roll(POOL_ID);

        uint8 lastBucket = _lastBucketIndex();
        (,, uint256 maturedTotal,,) = harness.poolState(POOL_ID);
        assertEq(harness.pendingBucket(POOL_ID, lastBucket), 0, "pending bucket drained on roll");
        assertEq(maturedTotal, PRINCIPAL, "matured total accumulates pending principal");
    }

    function test_EncumbranceIncrease_ZeroAmountReturnsEarlyWithoutStateChange() external {
        harness.initPool(POOL_ID, 0);
        harness.applyEncumbranceIncrease(POOL_ID, USER, 75 ether);

        (, uint256 principalTotalBefore, uint256 maturedBefore,,) = harness.poolState(POOL_ID);
        (uint256 principalBefore, uint40 startTimeBefore, uint256 snapshotBefore) = harness.encumbranceState(POOL_ID, USER);
        uint256 accruedBefore = harness.userAccruedYield(POOL_ID, USER);

        harness.applyEncumbranceIncrease(POOL_ID, USER, 0);

        (uint256 indexAfter, uint256 principalTotalAfter, uint256 maturedAfter,,) = harness.poolState(POOL_ID);
        (uint256 principalAfter, uint40 startTimeAfter, uint256 snapshotAfter) = harness.encumbranceState(POOL_ID, USER);

        assertEq(indexAfter, 0, "index unchanged");
        assertEq(principalTotalAfter, principalTotalBefore, "principal total unchanged");
        assertEq(maturedAfter, maturedBefore, "matured total unchanged");
        assertEq(principalAfter, principalBefore, "principal unchanged");
        assertEq(startTimeAfter, startTimeBefore, "start time unchanged");
        assertEq(snapshotAfter, snapshotBefore, "snapshot unchanged");
        assertEq(harness.userAccruedYield(POOL_ID, USER), accruedBefore, "no yield side effects");
    }

    function test_EncumbranceDecrease_FullZeroClearsState() external {
        harness.initPool(POOL_ID, 0);
        harness.applyEncumbranceIncrease(POOL_ID, USER, PRINCIPAL);

        harness.applyEncumbranceDecrease(POOL_ID, USER, PRINCIPAL);

        (uint256 principalAfter, uint40 startTimeAfter, uint256 snapshotAfter) = harness.encumbranceState(POOL_ID, USER);
        (, uint256 principalTotalAfter, uint256 maturedAfter,,) = harness.poolState(POOL_ID);
        assertEq(principalAfter, 0, "principal cleared");
        assertEq(startTimeAfter, 0, "start time reset");
        assertEq(snapshotAfter, 0, "snapshot reset");
        assertEq(principalTotalAfter, 0, "active credit principal total cleared");
        assertEq(maturedAfter, 0, "no matured base remains");
    }

    function test_EncumbranceChange_NoPendingYieldLeavesAccruedYieldUntouched() external {
        harness.initPool(POOL_ID, 2 * INDEX_SCALE);
        harness.applyEncumbranceIncrease(POOL_ID, USER, PRINCIPAL);

        uint256 accruedBefore = harness.userAccruedYield(POOL_ID, USER);
        harness.applyEncumbranceIncrease(POOL_ID, USER, 25 ether);

        (uint256 principalAfter,, uint256 snapshotAfter) = harness.encumbranceState(POOL_ID, USER);
        (uint256 indexAfter, uint256 principalTotalAfter,,,) = harness.poolState(POOL_ID);
        assertEq(accruedBefore, 0, "no accrued yield before change");
        assertEq(harness.userAccruedYield(POOL_ID, USER), 0, "no yield settled when snapshot matches index");
        assertEq(principalAfter, 125 ether, "principal increases normally");
        assertEq(principalTotalAfter, 125 ether, "pool principal total increases normally");
        assertEq(snapshotAfter, indexAfter, "snapshot tracks current index");
    }

    function _primeOverflowOffsetState(uint256 principal) internal returns (uint40 futureStart) {
        harness.initPool(POOL_ID, 0);
        futureStart = uint40(block.timestamp + 25 hours);
        harness.setEncumbranceState(POOL_ID, USER, principal, futureStart, 0);
        harness.trackEncumbranceState(POOL_ID, USER);
    }

    function _primeMatureEncumbranceWithYield(uint256 principal, uint256 amountToAccrue)
        internal
        returns (uint256 expectedYield)
    {
        harness.initPool(POOL_ID, 0);
        harness.setEncumbranceState(POOL_ID, USER, principal, uint40(block.timestamp - 25 hours), 0);
        harness.trackEncumbranceState(POOL_ID, USER);
        harness.accrue(POOL_ID, amountToAccrue);

        (uint256 activeCreditIndex,, uint256 maturedTotal,,) = harness.poolState(POOL_ID);
        assertEq(maturedTotal, principal, "matured base seeded");
        expectedYield = (principal * activeCreditIndex) / INDEX_SCALE;
        assertGt(expectedYield, 0, "yield should accrue before encumbrance mutation");
    }

    function _lastBucketIndex() internal view returns (uint8) {
        (,,, , uint8 cursor) = harness.poolState(POOL_ID);
        return uint8((cursor + 23) % 24);
    }
}
