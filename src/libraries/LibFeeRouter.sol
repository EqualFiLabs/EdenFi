// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibFeeIndex} from "./LibFeeIndex.sol";
import {LibActiveCreditIndex} from "./LibActiveCreditIndex.sol";
import {LibCurrency} from "./LibCurrency.sol";
import {LibMaintenance} from "./LibMaintenance.sol";
import {Types} from "./Types.sol";
import {InsufficientPoolLiquidity, InsufficientPrincipal} from "./Errors.sol";

/// @notice Central fee router for ACI/FI/Treasury splits.
library LibFeeRouter {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    struct RoutedSplit {
        uint256 treasury;
        uint256 active;
        uint256 fee;
    }

    event ManagedPoolSystemShareRouted(
        uint256 indexed managedPid,
        uint256 indexed basePid,
        uint256 amount,
        bytes32 source
    );

    function previewSplit(uint256 amount)
        internal
        view
        returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex)
    {
        if (amount == 0) return (0, 0, 0);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint16 treasuryBps = LibAppStorage.treasurySplitBps(store);
        uint16 activeBps = LibAppStorage.activeCreditSplitBps(store);
        require(treasuryBps + activeBps <= BPS_DENOMINATOR, "FeeRouter: splits>100%");

        address treasury = LibAppStorage.treasuryAddress(store);
        toTreasury = treasury != address(0) ? (amount * treasuryBps) / BPS_DENOMINATOR : 0;
        toActiveCredit = (amount * activeBps) / BPS_DENOMINATOR;
        toFeeIndex = amount - toTreasury - toActiveCredit;
    }

    /// @notice Route a fee amount into ACI/FI/Treasury for a single pool.
    /// @dev Use extraBacking when fee assets are encumbered (e.g., auction reserves).
    function routeSamePool(
        uint256 pid,
        uint256 amount,
        bytes32 source,
        bool pullFromTracked,
        uint256 extraBacking
    ) internal returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) {
        if (amount == 0) return (0, 0, 0);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage pool = store.pools[pid];

        (toTreasury, toActiveCredit, toFeeIndex) = previewSplit(amount);

        if (toTreasury > 0) {
            _transferTreasury(pool, toTreasury, pullFromTracked);
        }
        if (toActiveCredit > 0) {
            bool accruedToActiveCredit = _accrueActiveCredit(pool, pid, toActiveCredit, source, extraBacking);
            if (!accruedToActiveCredit) {
                toFeeIndex += toActiveCredit;
                toActiveCredit = 0;
            }
        }
        if (toFeeIndex > 0) {
            if (extraBacking > 0) {
                LibFeeIndex.accrueWithSourceUsingBacking(pid, toFeeIndex, source, extraBacking);
            } else {
                LibFeeIndex.accrueWithSource(pid, toFeeIndex, source);
            }
        }
    }

    function routeSamePoolPreSplit(
        uint256 pid,
        uint256 toTreasury,
        uint256 toActiveCredit,
        uint256 toFeeIndex,
        bytes32 source,
        bool pullFromTracked,
        uint256 extraBacking
    ) internal returns (uint256 routedTreasury, uint256 routedActiveCredit, uint256 routedFeeIndex) {
        if (toTreasury == 0 && toActiveCredit == 0 && toFeeIndex == 0) {
            return (0, 0, 0);
        }

        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage pool = store.pools[pid];

        routedTreasury = toTreasury;
        routedActiveCredit = toActiveCredit;
        routedFeeIndex = toFeeIndex;

        if (routedTreasury > 0) {
            _transferTreasury(pool, routedTreasury, pullFromTracked);
        }

        if (routedActiveCredit > 0 && !LibActiveCreditIndex.hasMaturedBase(pid)) {
            routedFeeIndex += routedActiveCredit;
            routedActiveCredit = 0;
        }

        uint256 reservedYield = routedActiveCredit + routedFeeIndex;
        if (reservedYield > 0) {
            _reserveYield(pool, pid, reservedYield, extraBacking);
            if (routedActiveCredit > 0) {
                LibActiveCreditIndex.accrueReservedWithSource(pid, routedActiveCredit, source);
            }
            if (routedFeeIndex > 0) {
                LibFeeIndex.accrueReservedWithSource(pid, routedFeeIndex, source);
            }
        }
    }

    /// @notice Route a fee amount with managed pool system share logic.
    /// @dev When pool is unmanaged, this is equivalent to routeSamePool.
    function routeManagedShare(
        uint256 pid,
        uint256 amount,
        bytes32 source,
        bool pullFromTracked,
        uint256 extraBacking
    ) internal returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) {
        if (amount == 0) return (0, 0, 0);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage pool = store.pools[pid];

        if (!pool.isManagedPool) {
            return routeSamePool(pid, amount, source, pullFromTracked, extraBacking);
        }

        uint16 systemShareBps = LibAppStorage.managedPoolSystemShareBps(store);
        if (systemShareBps == 0) {
            return routeSamePool(pid, amount, source, pullFromTracked, extraBacking);
        }

        return _routeManagedShareConfigured(pid, amount, source, pullFromTracked, extraBacking, systemShareBps);
    }

    function _routeManagedShareConfigured(
        uint256 pid,
        uint256 amount,
        bytes32 source,
        bool pullFromTracked,
        uint256 extraBacking,
        uint16 systemShareBps
    ) private returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) {
        uint256 systemShare = (amount * systemShareBps) / BPS_DENOMINATOR;
        uint256 managedShare = amount - systemShare;

        uint256 systemExtraBacking = (extraBacking * systemShareBps) / BPS_DENOMINATOR;
        uint256 managedExtraBacking = extraBacking - systemExtraBacking;

        if (systemShare > 0) {
            RoutedSplit memory systemSplit =
                _routeSystemShare(pid, systemShare, source, pullFromTracked, systemExtraBacking);
            toTreasury += systemSplit.treasury;
            toActiveCredit += systemSplit.active;
            toFeeIndex += systemSplit.fee;
        }

        if (managedShare > 0) {
            RoutedSplit memory managedSplit =
                _routeManagedPoolShare(pid, managedShare, source, pullFromTracked, managedExtraBacking);
            toTreasury += managedSplit.treasury;
            toActiveCredit += managedSplit.active;
            toFeeIndex += managedSplit.fee;
        }
    }

    /// @notice Accrue active credit yield with yieldReserve backing.
    function accrueActiveCredit(uint256 pid, uint256 amount, bytes32 source, uint256 extraBacking) internal {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        _accrueActiveCredit(pool, pid, amount, source, extraBacking);
    }

    function _routeSystemShare(
        uint256 managedPid,
        uint256 amount,
        bytes32 source,
        bool pullFromTracked,
        uint256 extraBacking
    ) private returns (RoutedSplit memory split) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage managedPool = store.pools[managedPid];
        uint256 basePid = store.assetToPoolId[managedPool.underlying];
        Types.PoolData storage basePool = store.pools[basePid];
        if (basePid == 0 || !basePool.initialized || basePool.totalDeposits == 0) {
            _routeSystemShareToTreasury(managedPool, amount, pullFromTracked);
            emit ManagedPoolSystemShareRouted(managedPid, 0, amount, source);
            split.treasury = amount;
            return split;
        }

        _transferBacking(managedPool, basePool, amount);
        (split.treasury, split.active, split.fee) = routeSamePool(basePid, amount, source, true, extraBacking);
        emit ManagedPoolSystemShareRouted(managedPid, basePid, amount, source);
    }

    function _routeManagedPoolShare(
        uint256 pid,
        uint256 amount,
        bytes32 source,
        bool pullFromTracked,
        uint256 extraBacking
    ) private returns (RoutedSplit memory split) {
        (split.treasury, split.active, split.fee) = routeSamePool(pid, amount, source, pullFromTracked, extraBacking);
    }

    function _transferBacking(Types.PoolData storage fromPool, Types.PoolData storage toPool, uint256 amount)
        private
    {
        if (amount == 0) return;
        uint256 tracked = fromPool.trackedBalance;
        if (tracked < amount) {
            revert InsufficientPrincipal(amount, tracked);
        }
        fromPool.trackedBalance = tracked - amount;
        toPool.trackedBalance += amount;
    }

    function _routeSystemShareToTreasury(Types.PoolData storage pool, uint256 amount, bool pullFromTracked)
        private
    {
        _transferTreasury(pool, amount, pullFromTracked);
    }

    function _transferTreasury(Types.PoolData storage pool, uint256 amount, bool pullFromTracked) private {
        address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
        if (treasury == address(0) || amount == 0) return;
        uint256 balanceBefore = LibCurrency.balanceOfSelf(pool.underlying);
        if (balanceBefore < amount) {
            revert InsufficientPrincipal(amount, balanceBefore);
        }

        uint256 trackedBefore;
        if (pullFromTracked) {
            trackedBefore = pool.trackedBalance;
            if (trackedBefore < amount) {
                revert InsufficientPrincipal(amount, trackedBefore);
            }
        }

        LibCurrency.transfer(pool.underlying, treasury, amount);

        if (pullFromTracked) {
            // Treasury debits follow actual pool outflow so sender-tax tokens do not
            // leave trackedBalance overstated relative to backing.
            uint256 poolOutflow = balanceBefore - LibCurrency.balanceOfSelf(pool.underlying);
            pool.trackedBalance = trackedBefore - poolOutflow;
        }
    }

    function _accrueActiveCredit(
        Types.PoolData storage pool,
        uint256 pid,
        uint256 amount,
        bytes32 source,
        uint256 extraBacking
    ) private returns (bool accrued) {
        if (amount == 0) return false;
        if (!LibActiveCreditIndex.hasMaturedBase(pid)) {
            return false;
        }
        _reserveYield(pool, pid, amount, extraBacking);
        LibActiveCreditIndex.accrueWithSource(pid, amount, source);
        return true;
    }

    function _reserveYield(
        Types.PoolData storage pool,
        uint256 pid,
        uint256 amount,
        uint256 extraBacking
    ) private {
        if (amount == 0) return;
        LibMaintenance.enforce(pid);
        uint256 reserved = pool.totalDeposits + pool.yieldReserve;
        uint256 backing = pool.trackedBalance + pool.activeCreditPrincipalTotal + extraBacking;
        uint256 available = backing > reserved ? backing - reserved : extraBacking;
        if (amount > available) {
            revert InsufficientPoolLiquidity(amount, available);
        }
        pool.yieldReserve += amount;
    }
}
