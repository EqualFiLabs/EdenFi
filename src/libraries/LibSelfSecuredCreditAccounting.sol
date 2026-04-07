// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EncumbranceUnderflow, InsufficientPoolLiquidity, InvalidLTVRatio} from "src/libraries/Errors.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibSelfSecuredCreditStorage} from "src/libraries/LibSelfSecuredCreditStorage.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Shared accounting transitions for the Self-Secured Credit rebuild.
library LibSelfSecuredCreditAccounting {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    struct DebtAdjustment {
        uint256 appliedAmount;
        uint256 outstandingDebtBefore;
        uint256 outstandingDebtAfter;
        uint256 requiredLockedCapitalBefore;
        uint256 requiredLockedCapitalAfter;
        uint256 lockedCapitalDelta;
        bool lineActiveAfter;
    }

    struct AciDebtService {
        uint256 claimableAciYieldBefore;
        uint256 claimableAciYieldAfter;
        uint256 protectedClaimableAciYieldBefore;
        uint256 protectedClaimableAciYieldAfter;
        uint256 aciAppliedToDebt;
        DebtAdjustment debtAdjustment;
    }

    function increaseDebt(bytes32 positionKey, uint256 positionId, uint256 poolId, uint256 amount)
        internal
        returns (DebtAdjustment memory result)
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, poolId);

        result.appliedAmount = amount;
        result.outstandingDebtBefore = lineState.outstandingDebt;
        result.requiredLockedCapitalBefore = lineState.requiredLockedCapital;

        if (amount == 0) {
            result.outstandingDebtAfter = lineState.outstandingDebt;
            result.requiredLockedCapitalAfter = lineState.requiredLockedCapital;
            result.lineActiveAfter = lineState.active;
            return result;
        }

        lineState.outstandingDebt += amount;
        lineState.active = true;

        _increaseSameAssetDebt(pool, positionKey, positionId, poolId, amount);
        result.lockedCapitalDelta = _syncRequiredLock(pool, positionKey, poolId, lineState);

        result.outstandingDebtAfter = lineState.outstandingDebt;
        result.requiredLockedCapitalAfter = lineState.requiredLockedCapital;
        result.lineActiveAfter = lineState.active;
    }

    function decreaseDebt(bytes32 positionKey, uint256 positionId, uint256 poolId, uint256 amount)
        internal
        returns (DebtAdjustment memory result)
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, poolId);

        result.outstandingDebtBefore = lineState.outstandingDebt;
        result.requiredLockedCapitalBefore = lineState.requiredLockedCapital;

        uint256 currentDebt = lineState.outstandingDebt;
        uint256 appliedAmount = amount > currentDebt ? currentDebt : amount;
        result.appliedAmount = appliedAmount;

        if (appliedAmount == 0) {
            result.outstandingDebtAfter = lineState.outstandingDebt;
            result.requiredLockedCapitalAfter = lineState.requiredLockedCapital;
            result.lineActiveAfter = lineState.active;
            return result;
        }

        lineState.outstandingDebt = currentDebt - appliedAmount;
        lineState.active = lineState.outstandingDebt != 0;

        _decreaseSameAssetDebt(pool, positionKey, positionId, poolId, appliedAmount);
        result.lockedCapitalDelta = _syncRequiredLock(pool, positionKey, poolId, lineState);

        result.outstandingDebtAfter = lineState.outstandingDebt;
        result.requiredLockedCapitalAfter = lineState.requiredLockedCapital;
        result.lineActiveAfter = lineState.active;
    }

    function serviceSelfPayAci(bytes32 positionKey, uint256 positionId, uint256 poolId)
        internal
        returns (AciDebtService memory result)
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, poolId);

        result.claimableAciYieldBefore = LibSelfSecuredCreditStorage.claimableAciYieldOf(positionKey, poolId);
        result.protectedClaimableAciYieldBefore =
            LibSelfSecuredCreditStorage.protectedClaimableAciYieldOf(positionKey, poolId);

        if (lineState.aciMode != Types.SscAciMode.SelfPay || lineState.outstandingDebt == 0) {
            result.claimableAciYieldAfter = result.claimableAciYieldBefore;
            result.protectedClaimableAciYieldAfter = result.protectedClaimableAciYieldBefore;
            return result;
        }

        if (result.protectedClaimableAciYieldBefore > result.claimableAciYieldBefore) {
            result.protectedClaimableAciYieldBefore = result.claimableAciYieldBefore;
        }

        uint256 serviceableAciYield =
            result.claimableAciYieldBefore > result.protectedClaimableAciYieldBefore
                ? result.claimableAciYieldBefore - result.protectedClaimableAciYieldBefore
                : 0;
        if (serviceableAciYield == 0) {
            result.claimableAciYieldAfter = result.claimableAciYieldBefore;
            result.protectedClaimableAciYieldAfter = result.protectedClaimableAciYieldBefore;
            return result;
        }

        result.aciAppliedToDebt =
            serviceableAciYield > lineState.outstandingDebt ? lineState.outstandingDebt : serviceableAciYield;
        if (pool.yieldReserve < result.aciAppliedToDebt) {
            revert InsufficientPoolLiquidity(result.aciAppliedToDebt, pool.yieldReserve);
        }

        LibSelfSecuredCreditStorage.decreaseClaimableAciYield(positionKey, poolId, result.aciAppliedToDebt);
        LibSelfSecuredCreditStorage.increaseTotalAciAppliedToDebt(positionKey, poolId, result.aciAppliedToDebt);

        pool.yieldReserve -= result.aciAppliedToDebt;
        pool.trackedBalance += result.aciAppliedToDebt;

        result.debtAdjustment = decreaseDebt(positionKey, positionId, poolId, result.aciAppliedToDebt);
        result.claimableAciYieldAfter = result.claimableAciYieldBefore - result.aciAppliedToDebt;
        result.protectedClaimableAciYieldAfter = result.claimableAciYieldAfter;

        LibSelfSecuredCreditStorage.setProtectedClaimableAciYield(
            positionKey, poolId, result.protectedClaimableAciYieldAfter
        );
    }

    function requiredLockedCapitalForDebt(uint256 debt, uint16 ltvBps) internal pure returns (uint256 requiredLock) {
        if (debt == 0) return 0;
        if (ltvBps == 0 || ltvBps > BPS_DENOMINATOR) revert InvalidLTVRatio();
        requiredLock = Math.mulDiv(debt, BPS_DENOMINATOR, ltvBps, Math.Rounding.Ceil);
    }

    function increaseLockedCapital(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) return;
        LibEncumbrance.position(positionKey, poolId).lockedCapital += amount;
    }

    function decreaseLockedCapital(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) return;
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 current = enc.lockedCapital;
        if (amount > current) revert EncumbranceUnderflow(amount, current);
        enc.lockedCapital = current - amount;
    }

    function _syncRequiredLock(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 poolId,
        Types.SscLine storage lineState
    ) private returns (uint256 lockDelta) {
        uint256 currentRequired = lineState.requiredLockedCapital;
        uint256 targetRequired = requiredLockedCapitalForDebt(lineState.outstandingDebt, pool.poolConfig.depositorLTVBps);

        if (targetRequired > currentRequired) {
            lockDelta = targetRequired - currentRequired;
            increaseLockedCapital(positionKey, poolId, lockDelta);
        } else if (currentRequired > targetRequired) {
            lockDelta = currentRequired - targetRequired;
            decreaseLockedCapital(positionKey, poolId, lockDelta);
        }

        lineState.requiredLockedCapital = targetRequired;
    }

    function _increaseSameAssetDebt(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 positionId,
        uint256 poolId,
        uint256 amount
    ) private {
        if (amount == 0) return;

        pool.userSameAssetDebt[positionKey] += amount;
        pool.sameAssetDebt[positionId] += amount;
        pool.activeCreditPrincipalTotal += amount;

        LibActiveCreditIndex.applyWeightedIncreaseWithGate(
            pool, pool.userActiveCreditStateDebt[positionKey], amount, poolId, positionKey, true
        );
        pool.userActiveCreditStateDebt[positionKey].indexSnapshot = pool.activeCreditIndex;
    }

    function _decreaseSameAssetDebt(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 positionId,
        uint256 poolId,
        uint256 principalComponent
    ) private {
        if (principalComponent == 0) return;

        uint256 sameAssetDebt = pool.userSameAssetDebt[positionKey];
        pool.userSameAssetDebt[positionKey] = principalComponent >= sameAssetDebt ? 0 : sameAssetDebt - principalComponent;

        uint256 tokenDebt = pool.sameAssetDebt[positionId];
        pool.sameAssetDebt[positionId] = principalComponent >= tokenDebt ? 0 : tokenDebt - principalComponent;

        Types.ActiveCreditState storage debtState = pool.userActiveCreditStateDebt[positionKey];
        uint256 debtPrincipalBefore = debtState.principal;
        uint256 debtDecrease = debtPrincipalBefore > principalComponent ? principalComponent : debtPrincipalBefore;
        LibActiveCreditIndex.applyPrincipalDecrease(pool, debtState, debtDecrease);

        if (debtPrincipalBefore <= principalComponent || debtState.principal == 0) {
            LibActiveCreditIndex.resetIfZeroWithGate(debtState, poolId, positionKey, true);
        } else {
            debtState.indexSnapshot = pool.activeCreditIndex;
        }

        if (pool.activeCreditPrincipalTotal >= debtDecrease) {
            pool.activeCreditPrincipalTotal -= debtDecrease;
        } else {
            pool.activeCreditPrincipalTotal = 0;
        }
    }
}
