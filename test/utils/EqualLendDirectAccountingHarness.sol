// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectAccounting} from "src/libraries/LibEqualLendDirectAccounting.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {Types} from "src/libraries/Types.sol";

contract EqualLendDirectAccountingHarness {
    function setPool(
        uint256 pid,
        address underlying,
        uint256 totalDeposits,
        uint256 trackedBalance,
        uint256 userCount
    ) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.initialized = true;
        pool.underlying = underlying;
        pool.totalDeposits = totalDeposits;
        pool.trackedBalance = trackedBalance;
        pool.userCount = userCount;
    }

    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = principal;
    }

    function setMaxUserCount(uint256 pid, uint256 maxUserCount) external {
        LibAppStorage.s().pools[pid].poolConfig.maxUserCount = maxUserCount;
    }

    function setMaintenanceIndex(uint256 pid, uint256 maintenanceIndex) external {
        LibAppStorage.s().pools[pid].maintenanceIndex = maintenanceIndex;
    }

    function setUserMaintenanceIndex(uint256 pid, bytes32 positionKey, uint256 maintenanceIndex) external {
        LibAppStorage.s().pools[pid].userMaintenanceIndex[positionKey] = maintenanceIndex;
    }

    function setUserFeeIndex(uint256 pid, bytes32 positionKey, uint256 feeIndex) external {
        LibAppStorage.s().pools[pid].userFeeIndex[positionKey] = feeIndex;
    }

    function userFeeIndexOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userFeeIndex[positionKey];
    }

    function userMaintenanceIndexOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userMaintenanceIndex[positionKey];
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function setNativeTrackedTotal(uint256 amount) external {
        LibAppStorage.s().nativeTrackedTotal = amount;
    }

    function increaseOfferEscrow(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.increaseOfferEscrow(lenderPositionKey, lenderPoolId, amount);
    }

    function decreaseOfferEscrow(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.decreaseOfferEscrow(lenderPositionKey, lenderPoolId, amount);
    }

    function increaseLockedCapital(bytes32 borrowerPositionKey, uint256 collateralPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.increaseLockedCapital(borrowerPositionKey, collateralPoolId, amount);
    }

    function decreaseLockedCapital(bytes32 borrowerPositionKey, uint256 collateralPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.decreaseLockedCapital(borrowerPositionKey, collateralPoolId, amount);
    }

    function increaseLiveExposure(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.increaseLiveExposure(lenderPositionKey, lenderPoolId, amount);
    }

    function decreaseLiveExposure(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.decreaseLiveExposure(lenderPositionKey, lenderPoolId, amount);
    }

    function moveOfferEscrowToLiveExposure(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.moveOfferEscrowToLiveExposure(lenderPositionKey, lenderPoolId, amount);
    }

    function departLenderCapital(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.departLenderCapital(lenderPositionKey, lenderPoolId, amount);
    }

    function restoreLenderCapital(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) external {
        LibEqualLendDirectAccounting.restoreLenderCapital(lenderPositionKey, lenderPoolId, amount);
    }

    function settleFeeIndex(uint256 pid, bytes32 positionKey) external {
        LibFeeIndex.settle(pid, positionKey);
    }

    function originateFixed(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principal,
        uint256 collateralToLock
    ) external returns (bool sameAsset) {
        sameAsset = _originate(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            principal,
            collateralToLock
        );
    }

    function originateRolling(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principal,
        uint256 collateralToLock
    ) external returns (bool sameAsset) {
        sameAsset = _originate(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            principal,
            collateralToLock
        );
    }

    function originateRatio(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principal,
        uint256 collateralToLock
    ) external returns (bool sameAsset) {
        sameAsset = _originate(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            principal,
            collateralToLock
        );
    }

    function settleFixedPrincipal(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principalDelta,
        uint256 collateralDelta,
        bool releaseLockedCollateral
    ) external returns (bool sameAsset) {
        sameAsset = _settlePrincipal(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            principalDelta,
            collateralDelta,
            releaseLockedCollateral
        );
    }

    function settleRollingPrincipal(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principalDelta,
        uint256 collateralDelta,
        bool releaseLockedCollateral
    ) external returns (bool sameAsset) {
        sameAsset = _settlePrincipal(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            principalDelta,
            collateralDelta,
            releaseLockedCollateral
        );
    }

    function settleRatioPrincipal(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principalDelta,
        uint256 collateralDelta,
        bool releaseLockedCollateral
    ) external returns (bool sameAsset) {
        sameAsset = _settlePrincipal(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            principalDelta,
            collateralDelta,
            releaseLockedCollateral
        );
    }

    function cleanupFixed(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 borrowedPrincipalToClear,
        uint256 exposureToClear,
        uint256 collateralToUnlock
    ) external returns (bool sameAsset) {
        sameAsset = _cleanup(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            borrowedPrincipalToClear,
            exposureToClear,
            collateralToUnlock
        );
    }

    function cleanupRolling(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 borrowedPrincipalToClear,
        uint256 exposureToClear,
        uint256 collateralToUnlock
    ) external returns (bool sameAsset) {
        sameAsset = _cleanup(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            borrowedPrincipalToClear,
            exposureToClear,
            collateralToUnlock
        );
    }

    function cleanupRatio(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 borrowedPrincipalToClear,
        uint256 exposureToClear,
        uint256 collateralToUnlock
    ) external returns (bool sameAsset) {
        sameAsset = _cleanup(
            lenderPositionKey,
            borrowerPositionKey,
            borrowerPositionId,
            lenderPoolId,
            collateralPoolId,
            borrowAsset,
            collateralAsset,
            borrowedPrincipalToClear,
            exposureToClear,
            collateralToUnlock
        );
    }

    function borrowedPrincipalOf(bytes32 borrowerPositionKey, uint256 lenderPoolId) external view returns (uint256) {
        return LibEqualLendDirectStorage.s().borrowedPrincipalByPool[borrowerPositionKey][lenderPoolId];
    }

    function sameAssetDebtOf(bytes32 borrowerPositionKey, address asset) external view returns (uint256) {
        return LibEqualLendDirectStorage.s().sameAssetDebtByAsset[borrowerPositionKey][asset];
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function encumbranceOf(bytes32 positionKey, uint256 poolId)
        external
        view
        returns (uint256 lockedCapital, uint256 encumberedCapital, uint256 offerEscrowedCapital)
    {
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        return (enc.lockedCapital, enc.encumberedCapital, enc.offerEscrowedCapital);
    }

    function poolState(uint256 pid, bytes32 positionKey, uint256 borrowerPositionId)
        external
        view
        returns (
            uint256 principal,
            uint256 totalDeposits,
            uint256 trackedBalance,
            uint256 userCount,
            uint256 activeCreditPrincipalTotal,
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 debtStatePrincipal
        )
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        principal = pool.userPrincipal[positionKey];
        totalDeposits = pool.totalDeposits;
        trackedBalance = pool.trackedBalance;
        userCount = pool.userCount;
        activeCreditPrincipalTotal = pool.activeCreditPrincipalTotal;
        userSameAssetDebt = pool.userSameAssetDebt[positionKey];
        tokenSameAssetDebt = pool.sameAssetDebt[borrowerPositionId];
        debtStatePrincipal = pool.userActiveCreditStateDebt[positionKey].principal;
    }

    function pendingActiveCreditBase(uint256 pid) external returns (uint256 principalTotal, uint256 maturedTotal) {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        LibActiveCreditIndex.hasMaturedBase(pid);
        return (pool.activeCreditPrincipalTotal, pool.activeCreditMaturedTotal);
    }

    function _originate(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principal,
        uint256 collateralToLock
    ) private returns (bool sameAsset) {
        sameAsset = LibEqualLendDirectAccounting.originate(
            LibEqualLendDirectStorage.s(),
            LibEqualLendDirectAccounting.OriginationParams({
                lenderPositionKey: lenderPositionKey,
                borrowerPositionKey: borrowerPositionKey,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: lenderPoolId,
                collateralPoolId: collateralPoolId,
                borrowAsset: borrowAsset,
                collateralAsset: collateralAsset,
                principal: principal,
                collateralToLock: collateralToLock,
                convertOfferEscrow: true,
                lockCollateralNow: true
            })
        );
    }

    function _settlePrincipal(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principalDelta,
        uint256 collateralDelta,
        bool releaseLockedCollateral
    ) private returns (bool sameAsset) {
        sameAsset = LibEqualLendDirectAccounting.settlePrincipal(
            LibEqualLendDirectStorage.s(),
            LibEqualLendDirectAccounting.PrincipalSettlementParams({
                lenderPositionKey: lenderPositionKey,
                borrowerPositionKey: borrowerPositionKey,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: lenderPoolId,
                collateralPoolId: collateralPoolId,
                borrowAsset: borrowAsset,
                collateralAsset: collateralAsset,
                principalDelta: principalDelta,
                collateralDelta: collateralDelta,
                releaseLockedCollateral: releaseLockedCollateral
            })
        );
    }

    function _cleanup(
        bytes32 lenderPositionKey,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 borrowedPrincipalToClear,
        uint256 exposureToClear,
        uint256 collateralToUnlock
    ) private returns (bool sameAsset) {
        sameAsset = LibEqualLendDirectAccounting.cleanupTerminal(
            LibEqualLendDirectStorage.s(),
            LibEqualLendDirectAccounting.TerminalCleanupParams({
                lenderPositionKey: lenderPositionKey,
                borrowerPositionKey: borrowerPositionKey,
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: lenderPoolId,
                collateralPoolId: collateralPoolId,
                borrowAsset: borrowAsset,
                collateralAsset: collateralAsset,
                borrowedPrincipalToClear: borrowedPrincipalToClear,
                exposureToClear: exposureToClear,
                collateralToUnlock: collateralToUnlock
            })
        );
    }
}
