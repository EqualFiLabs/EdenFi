// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { InsufficientPoolLiquidity } from "./Errors.sol";
import { LibAppStorage } from "./LibAppStorage.sol";
import { LibEncumbrance } from "./LibEncumbrance.sol";
import { LibMaintenance } from "./LibMaintenance.sol";
import { Types } from "./Types.sol";

/// @notice Fee index accounting over internal principal ledgers.
/// @dev This EdenFi extraction keeps the EqualFi fee-index shape while removing
/// direct-lending dependencies so the shared substrate stays modular.
library LibFeeIndex {
    uint256 internal constant INDEX_SCALE = 1e18;

    event FeeIndexAccrued(uint256 indexed pid, uint256 amount, uint256 delta, uint256 newIndex, bytes32 source);
    event YieldSettled(
        uint256 indexed pid,
        bytes32 indexed user,
        uint256 prevIndex,
        uint256 newIndex,
        uint256 addedYield,
        uint256 totalAccruedYield
    );

    function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) internal {
        if (amount == 0) return;

        LibMaintenance.enforce(pid);
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 totalDeposits = p.totalDeposits;
        if (totalDeposits == 0) return;

        uint256 reserved = p.totalDeposits + p.yieldReserve;
        uint256 backing = p.trackedBalance + p.activeCreditPrincipalTotal;
        uint256 available = backing > reserved ? backing - reserved : 0;
        if (amount > available) {
            revert InsufficientPoolLiquidity(amount, available);
        }

        p.yieldReserve += amount;
        _accrueReservedAmount(p, pid, amount, source, totalDeposits);
    }

    function accrueReservedWithSource(uint256 pid, uint256 amount, bytes32 source) internal {
        if (amount == 0) return;
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 totalDeposits = p.totalDeposits;
        if (totalDeposits == 0) return;
        _accrueReservedAmount(p, pid, amount, source, totalDeposits);
    }

    function _accrueReservedAmount(
        Types.PoolData storage p,
        uint256 pid,
        uint256 amount,
        bytes32 source,
        uint256 totalDeposits
    ) private {
        uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
        uint256 dividend = scaledAmount + p.feeIndexRemainder;
        uint256 delta = dividend / totalDeposits;
        if (delta == 0) {
            p.feeIndexRemainder = dividend;
            return;
        }

        p.feeIndexRemainder = dividend - (delta * totalDeposits);
        uint256 newIndex = p.feeIndex + delta;
        p.feeIndex = newIndex;
        emit FeeIndexAccrued(pid, amount, delta, newIndex, source);
    }

    function accrueWithSourceUsingBacking(uint256 pid, uint256 amount, bytes32 source, uint256 extraBacking) internal {
        if (amount == 0) return;

        LibMaintenance.enforce(pid);
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 totalDeposits = p.totalDeposits;
        if (totalDeposits == 0) return;

        uint256 reserved = p.totalDeposits + p.yieldReserve;
        uint256 backing = p.trackedBalance + p.activeCreditPrincipalTotal + extraBacking;
        uint256 available = backing > reserved ? backing - reserved : extraBacking;
        if (amount > available) {
            revert InsufficientPoolLiquidity(amount, available);
        }

        p.yieldReserve += amount;
        _accrueReservedAmount(p, pid, amount, source, totalDeposits);
    }

    function settle(uint256 pid, bytes32 user) internal {
        LibMaintenance.enforce(pid);
        Types.PoolData storage p = LibAppStorage.s().pools[pid];

        uint256 principal = p.userPrincipal[user];
        if (principal == 0) {
            p.userFeeIndex[user] = p.feeIndex;
            p.userMaintenanceIndex[user] = p.maintenanceIndex;
            return;
        }

        uint256 globalMaintenanceIndex = p.maintenanceIndex;
        uint256 prevMaintenanceIndex = p.userMaintenanceIndex[user];
        if (globalMaintenanceIndex > prevMaintenanceIndex) {
            uint256 maintenanceDelta = globalMaintenanceIndex - prevMaintenanceIndex;
            uint256 chargeablePrincipal = _chargeablePrincipal(user, pid, principal);
            uint256 maintenanceFee = Math.mulDiv(chargeablePrincipal, maintenanceDelta, INDEX_SCALE);
            if (maintenanceFee > 0) {
                if (maintenanceFee >= principal) {
                    principal = 0;
                    p.userPrincipal[user] = 0;
                } else {
                    principal -= maintenanceFee;
                    p.userPrincipal[user] = principal;
                }
            }
            p.userMaintenanceIndex[user] = globalMaintenanceIndex;
        }

        uint256 globalIndex = p.feeIndex;
        uint256 prevIndex = p.userFeeIndex[user];
        uint256 added;
        if (globalIndex > prevIndex && principal > 0) {
            uint256 feeBase = _feeBase(p, user, principal);
            if (feeBase > 0) {
                added = Math.mulDiv(feeBase, globalIndex - prevIndex, INDEX_SCALE);
                if (added > 0) {
                    p.userAccruedYield[user] += added;
                    p.userClaimableFeeYield[user] += added;
                }
            }
        }
        p.userFeeIndex[user] = globalIndex;

        emit YieldSettled(pid, user, prevIndex, globalIndex, added, p.userAccruedYield[user]);
    }

    function pendingYield(uint256 pid, bytes32 user) internal view returns (uint256 amount) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        amount = p.userClaimableFeeYield[user];

        uint256 principal = previewSettledPrincipal(pid, user);
        if (principal == 0) return amount;

        uint256 globalIndex = p.feeIndex;
        uint256 userIndex = p.userFeeIndex[user];
        if (globalIndex > userIndex && principal > 0) {
            uint256 feeBase = _feeBase(p, user, principal);
            if (feeBase > 0) {
                amount += Math.mulDiv(feeBase, globalIndex - userIndex, INDEX_SCALE);
            }
        }
    }

    function previewSettledPrincipal(uint256 pid, bytes32 user) internal view returns (uint256 principal) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        principal = p.userPrincipal[user];
        if (principal == 0) return 0;

        (, uint256 globalMaintenanceIndex) = LibMaintenance.previewState(pid);
        uint256 userMaintenanceIndex = p.userMaintenanceIndex[user];
        if (globalMaintenanceIndex <= userMaintenanceIndex) {
            return principal;
        }

        uint256 maintenanceDelta = globalMaintenanceIndex - userMaintenanceIndex;
        uint256 chargeablePrincipal = _chargeablePrincipal(user, pid, principal);
        uint256 maintenanceFee = Math.mulDiv(chargeablePrincipal, maintenanceDelta, INDEX_SCALE);
        if (maintenanceFee >= principal) {
            return 0;
        }
        return principal - maintenanceFee;
    }

    function _chargeablePrincipal(bytes32 user, uint256 pid, uint256 principal) private view returns (uint256) {
        uint256 indexEncumbered = LibEncumbrance.getIndexEncumbered(user, pid);
        if (indexEncumbered >= principal) {
            return 0;
        }
        return principal - indexEncumbered;
    }

    function _feeBase(Types.PoolData storage p, bytes32 user, uint256 principal) private view returns (uint256) {
        uint256 sameAssetDebt = p.userSameAssetDebt[user];
        if (sameAssetDebt >= principal) {
            return 0;
        }
        return principal - sameAssetDebt;
    }
}
