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
