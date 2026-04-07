// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {Types} from "src/libraries/Types.sol";

contract LibActiveCreditIndexHarness {
    bytes32 internal constant SOURCE = keccak256("aci-harness");

    function initPool(uint256 pid, uint256 activeCreditIndex_) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.initialized = true;
        pool.activeCreditIndex = activeCreditIndex_;
    }

    function setEncumbranceState(
        uint256 pid,
        bytes32 user,
        uint256 principal,
        uint40 startTime,
        uint256 indexSnapshot
    ) external {
        Types.ActiveCreditState storage state = LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[user];
        state.principal = principal;
        state.startTime = startTime;
        state.indexSnapshot = indexSnapshot;
    }

    function trackEncumbranceState(uint256 pid, bytes32 user) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        LibActiveCreditIndex.trackState(pool, pool.userActiveCreditStateEncumbrance[user]);
    }

    function decreaseTrackedEncumbrancePrincipal(uint256 pid, bytes32 user, uint256 amount) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        LibActiveCreditIndex.applyPrincipalDecrease(pool, pool.userActiveCreditStateEncumbrance[user], amount);
    }

    function applyEncumbranceIncrease(uint256 pid, bytes32 user, uint256 amount) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        LibActiveCreditIndex.applyEncumbranceIncrease(pool, pid, user, amount);
    }

    function applyEncumbranceDecrease(uint256 pid, bytes32 user, uint256 amount) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        LibActiveCreditIndex.applyEncumbranceDecrease(pool, pid, user, amount);
    }

    function accrue(uint256 pid, uint256 amount) external {
        LibActiveCreditIndex.accrueWithSource(pid, amount, SOURCE);
    }

    function roll(uint256 pid) external returns (bool) {
        return LibActiveCreditIndex.hasMaturedBase(pid);
    }

    function pendingBucket(uint256 pid, uint256 index) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPendingBuckets[index];
    }

    function userAccruedYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[user];
    }

    function encumbranceState(uint256 pid, bytes32 user)
        external
        view
        returns (uint256 principal, uint40 startTime, uint256 indexSnapshot)
    {
        Types.ActiveCreditState storage state = LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[user];
        return (state.principal, state.startTime, state.indexSnapshot);
    }

    function poolState(uint256 pid)
        external
        view
        returns (
            uint256 activeCreditIndex,
            uint256 activeCreditPrincipalTotal,
            uint256 activeCreditMaturedTotal,
            uint64 activeCreditPendingStartHour,
            uint8 activeCreditPendingCursor
        )
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        return (
            pool.activeCreditIndex,
            pool.activeCreditPrincipalTotal,
            pool.activeCreditMaturedTotal,
            pool.activeCreditPendingStartHour,
            pool.activeCreditPendingCursor
        );
    }
}
