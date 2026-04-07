// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibMaintenance} from "src/libraries/LibMaintenance.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {LibSelfSecuredCreditAccounting} from "src/libraries/LibSelfSecuredCreditAccounting.sol";
import {LibSelfSecuredCreditStorage} from "src/libraries/LibSelfSecuredCreditStorage.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Shared read helpers for the Self-Secured Credit lifecycle.
library LibSelfSecuredCreditViews {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    struct ServiceState {
        uint256 settledPrincipal;
        uint256 totalSameAssetDebtBeforeService;
        uint256 totalSameAssetDebtAfterService;
        uint256 outstandingDebtBeforeService;
        uint256 outstandingDebtAfterService;
        uint256 requiredLockedCapitalBeforeService;
        uint256 requiredLockedCapitalAfterService;
        uint256 otherEncumbrance;
        uint256 claimableFeeYield;
        uint256 claimableAciYieldAfterService;
        uint256 pendingSelfPayAciToDebt;
        uint256 trackedBalanceAfterMaintenance;
        uint256 trackedBalanceAfterService;
        Types.SscAciMode aciMode;
        bool activeBeforeService;
        bool activeAfterService;
    }

    function lineView(uint256 tokenId, uint256 pid) internal view returns (Types.SscLineView memory view_) {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(positionKey, pid);
        ServiceState memory serviceState = _previewServiceState(positionKey, pid, pool, lineState);

        view_.tokenId = tokenId;
        view_.poolId = pid;
        view_.underlying = pool.underlying;
        view_.principal = serviceState.settledPrincipal;
        view_.outstandingDebt = lineState.outstandingDebt;
        view_.requiredLockedCapital = lineState.requiredLockedCapital;
        view_.freeEquity = _freeEquity(
            serviceState.settledPrincipal,
            pool.userSameAssetDebt[positionKey],
            _otherEncumbrance(positionKey, pid, lineState.requiredLockedCapital),
            lineState.requiredLockedCapital
        );
        view_.maxAdditionalDraw = _maxAdditionalDraw(serviceState, pool.poolConfig.depositorLTVBps);
        view_.claimableFeeYield = serviceState.claimableFeeYield;
        view_.claimableAciYield = LibActiveCreditIndex.pendingSscClaimableYield(pid, positionKey);
        view_.pendingSelfPayAciToDebt = serviceState.pendingSelfPayAciToDebt;
        view_.totalAciAppliedToDebt = LibSelfSecuredCreditStorage.totalAciAppliedToDebtOf(positionKey, pid);
        view_.aciMode = lineState.aciMode;
        view_.active = lineState.active;
    }

    function maintenancePreview(uint256 tokenId, uint256 pid)
        internal
        view
        returns (Types.SscMaintenancePreview memory preview)
    {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(positionKey, pid);

        preview.tokenId = tokenId;
        preview.poolId = pid;
        preview.settledPrincipal = LibFeeIndex.previewSettledPrincipal(pid, positionKey);
        preview.totalSameAssetDebt = pool.userSameAssetDebt[positionKey];
        preview.outstandingDebt = lineState.outstandingDebt;
        preview.requiredLockedCapital =
            LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(lineState.outstandingDebt, pool.poolConfig.depositorLTVBps);

        uint256 totalEncumbered =
            _totalEncumberedWithUpdatedLock(positionKey, pid, lineState.requiredLockedCapital, preview.requiredLockedCapital);
        preview.freeEquity =
            _freeEquity(preview.settledPrincipal, preview.totalSameAssetDebt, totalEncumbered - preview.requiredLockedCapital, preview.requiredLockedCapital);

        uint256 trackedAfterMaintenance = _previewTrackedBalanceAfterMaintenance(pool, pid);
        preview.remainingBorrowRunway = _maxAdditionalDrawFromInputs(
            preview.settledPrincipal,
            preview.totalSameAssetDebt,
            lineState.outstandingDebt,
            totalEncumbered > preview.requiredLockedCapital ? totalEncumbered - preview.requiredLockedCapital : 0,
            trackedAfterMaintenance,
            pool.poolConfig.depositorLTVBps
        );
        preview.unsafeAfterMaintenance = _isUnsafe(
            preview.settledPrincipal,
            preview.totalSameAssetDebt,
            totalEncumbered > preview.requiredLockedCapital ? totalEncumbered - preview.requiredLockedCapital : 0,
            preview.requiredLockedCapital,
            pool.poolConfig.depositorLTVBps
        );
    }

    function drawPreview(uint256 tokenId, uint256 pid, uint256 amount)
        internal
        view
        returns (Types.SscDrawPreview memory preview)
    {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(positionKey, pid);
        ServiceState memory serviceState = _previewServiceState(positionKey, pid, pool, lineState);

        preview.requestedAmount = amount;
        preview.settledPrincipal = serviceState.settledPrincipal;
        preview.outstandingDebtBefore = serviceState.outstandingDebtAfterService;
        preview.requiredLockedCapitalBefore = serviceState.requiredLockedCapitalAfterService;
        preview.availableTrackedLiquidity = serviceState.trackedBalanceAfterService;
        preview.maxAdditionalDraw = _maxAdditionalDraw(serviceState, pool.poolConfig.depositorLTVBps);
        preview.appliedDrawAmount = amount > preview.maxAdditionalDraw ? preview.maxAdditionalDraw : amount;
        preview.requestExceedsMaxDraw = amount > preview.maxAdditionalDraw;
        preview.outstandingDebtAfter = serviceState.outstandingDebtAfterService + preview.appliedDrawAmount;
        preview.requiredLockedCapitalAfter = LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(
            preview.outstandingDebtAfter, pool.poolConfig.depositorLTVBps
        );
        preview.additionalLockRequired =
            preview.requiredLockedCapitalAfter > preview.requiredLockedCapitalBefore
                ? preview.requiredLockedCapitalAfter - preview.requiredLockedCapitalBefore
                : 0;
        preview.freeEquityAfter = _freeEquity(
            serviceState.settledPrincipal,
            serviceState.totalSameAssetDebtAfterService + preview.appliedDrawAmount,
            serviceState.otherEncumbrance,
            preview.requiredLockedCapitalAfter
        );
        preview.aciMode = serviceState.aciMode;
        preview.lineActiveAfter = preview.outstandingDebtAfter != 0;
    }

    function repayPreview(uint256 tokenId, uint256 pid, uint256 amount)
        internal
        view
        returns (Types.SscRepayPreview memory preview)
    {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(positionKey, pid);
        ServiceState memory serviceState = _previewServiceState(positionKey, pid, pool, lineState);

        preview.requestedRepayAmount = amount;
        preview.appliedRepayAmount =
            amount > serviceState.outstandingDebtAfterService ? serviceState.outstandingDebtAfterService : amount;
        preview.outstandingDebtBefore = serviceState.outstandingDebtAfterService;
        preview.outstandingDebtAfter = serviceState.outstandingDebtAfterService - preview.appliedRepayAmount;
        preview.requiredLockedCapitalBefore = serviceState.requiredLockedCapitalAfterService;
        preview.requiredLockedCapitalAfter = LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(
            preview.outstandingDebtAfter, pool.poolConfig.depositorLTVBps
        );
        preview.lockReleased =
            preview.requiredLockedCapitalBefore > preview.requiredLockedCapitalAfter
                ? preview.requiredLockedCapitalBefore - preview.requiredLockedCapitalAfter
                : 0;
        preview.claimableAciYield = serviceState.claimableAciYieldAfterService;
        preview.aciMode = serviceState.aciMode;
        preview.lineCloses = preview.outstandingDebtAfter == 0;
    }

    function servicePreview(uint256 tokenId, uint256 pid)
        internal
        view
        returns (Types.SscServicePreview memory preview)
    {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(positionKey, pid);
        ServiceState memory serviceState = _previewServiceState(positionKey, pid, pool, lineState);

        preview.settledPrincipal = serviceState.settledPrincipal;
        preview.outstandingDebtBefore = serviceState.outstandingDebtBeforeService;
        preview.outstandingDebtAfter = serviceState.outstandingDebtAfterService;
        preview.requiredLockedCapitalBefore = serviceState.requiredLockedCapitalBeforeService;
        preview.requiredLockedCapitalAfter = serviceState.requiredLockedCapitalAfterService;
        preview.claimableFeeYield = serviceState.claimableFeeYield;
        preview.claimableAciYield = serviceState.claimableAciYieldAfterService;
        preview.aciAppliedToDebt = serviceState.pendingSelfPayAciToDebt;
        preview.freeEquityAfter = _freeEquity(
            serviceState.settledPrincipal,
            serviceState.totalSameAssetDebtAfterService,
            serviceState.otherEncumbrance,
            serviceState.requiredLockedCapitalAfterService
        );
        preview.aciMode = serviceState.aciMode;
        preview.unsafeAfterService = _isUnsafe(
            serviceState.settledPrincipal,
            serviceState.totalSameAssetDebtAfterService,
            serviceState.otherEncumbrance,
            serviceState.requiredLockedCapitalAfterService,
            pool.poolConfig.depositorLTVBps
        );
    }

    function terminalSettlementPreview(uint256 tokenId, uint256 pid)
        internal
        view
        returns (Types.SscTerminalSettlementPreview memory preview)
    {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(positionKey, pid);
        ServiceState memory serviceState = _previewServiceState(positionKey, pid, pool, lineState);

        preview.principalBefore = serviceState.settledPrincipal;
        preview.outstandingDebtBefore = serviceState.outstandingDebtAfterService;
        preview.requiredLockedCapitalBefore = serviceState.requiredLockedCapitalAfterService;
        preview.principalAfter = preview.principalBefore;
        preview.outstandingDebtAfter = preview.outstandingDebtBefore;
        preview.requiredLockedCapitalAfter = preview.requiredLockedCapitalBefore;
        preview.lineClosed = preview.outstandingDebtAfter == 0;

        if (
            preview.outstandingDebtBefore == 0
                || !_isUnsafe(
                    preview.principalBefore,
                    serviceState.totalSameAssetDebtAfterService,
                    serviceState.otherEncumbrance,
                    preview.requiredLockedCapitalBefore,
                    pool.poolConfig.depositorLTVBps
                )
        ) {
            return preview;
        }

        preview.settlementRequired = true;

        uint256 availableSscBacking =
            preview.principalBefore > serviceState.otherEncumbrance
                ? preview.principalBefore - serviceState.otherEncumbrance
                : 0;
        (bool canHealWithBackingOnly, uint256 principalConsumed) = _minimumPrincipalConsumptionForSafety(
            preview.outstandingDebtBefore, availableSscBacking, pool.poolConfig.depositorLTVBps
        );

        if (canHealWithBackingOnly) {
            preview.principalConsumed = principalConsumed;
            preview.debtRepaid = principalConsumed;
        } else {
            preview.principalConsumed =
                availableSscBacking < preview.outstandingDebtBefore ? availableSscBacking : preview.outstandingDebtBefore;

            uint256 debtAfterBacking = preview.outstandingDebtBefore - preview.principalConsumed;
            uint256 remainingBacking = availableSscBacking - preview.principalConsumed;
            uint256 safeResidualDebt = _maxSafeDebtForBacking(remainingBacking, pool.poolConfig.depositorLTVBps);
            if (safeResidualDebt > debtAfterBacking) {
                safeResidualDebt = debtAfterBacking;
            }
            preview.debtRepaid = preview.outstandingDebtBefore - safeResidualDebt;
        }

        preview.principalAfter = preview.principalBefore - preview.principalConsumed;
        preview.outstandingDebtAfter = preview.outstandingDebtBefore - preview.debtRepaid;
        preview.requiredLockedCapitalAfter = LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(
            preview.outstandingDebtAfter, pool.poolConfig.depositorLTVBps
        );
        preview.lineClosed = preview.outstandingDebtAfter == 0;
    }

    function claimableFeeYield(uint256 tokenId, uint256 pid) internal view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, LibPositionHelpers.positionKey(tokenId));
    }

    function claimableAciYield(uint256 tokenId, uint256 pid) internal view returns (uint256) {
        return LibActiveCreditIndex.pendingSscClaimableYield(pid, LibPositionHelpers.positionKey(tokenId));
    }

    function aciMode(uint256 tokenId, uint256 pid) internal view returns (Types.SscAciMode) {
        return LibSelfSecuredCreditStorage.lineView(LibPositionHelpers.positionKey(tokenId), pid).aciMode;
    }

    function pendingSelfPayEffect(uint256 tokenId, uint256 pid) internal view returns (uint256) {
        return LibActiveCreditIndex.previewSelfPayAciApplied(pid, LibPositionHelpers.positionKey(tokenId));
    }

    function maxAdditionalDraw(uint256 tokenId, uint256 pid) internal view returns (uint256) {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(positionKey, pid);
        ServiceState memory serviceState = _previewServiceState(positionKey, pid, pool, lineState);
        return _maxAdditionalDraw(serviceState, pool.poolConfig.depositorLTVBps);
    }

    function _previewServiceState(
        bytes32 positionKey,
        uint256 pid,
        Types.PoolData storage pool,
        Types.SscLine memory lineState
    ) private view returns (ServiceState memory state) {
        state.settledPrincipal = LibFeeIndex.previewSettledPrincipal(pid, positionKey);
        state.totalSameAssetDebtBeforeService = pool.userSameAssetDebt[positionKey];
        state.outstandingDebtBeforeService = lineState.outstandingDebt;
        state.requiredLockedCapitalBeforeService = lineState.requiredLockedCapital;
        state.otherEncumbrance = _otherEncumbrance(positionKey, pid, lineState.requiredLockedCapital);
        state.claimableFeeYield = LibFeeIndex.pendingYield(pid, positionKey);
        state.pendingSelfPayAciToDebt = LibActiveCreditIndex.previewSelfPayAciApplied(pid, positionKey);
        state.outstandingDebtAfterService = lineState.outstandingDebt - state.pendingSelfPayAciToDebt;
        state.requiredLockedCapitalAfterService = LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(
            state.outstandingDebtAfterService, pool.poolConfig.depositorLTVBps
        );
        state.totalSameAssetDebtAfterService = state.totalSameAssetDebtBeforeService - state.pendingSelfPayAciToDebt;
        state.trackedBalanceAfterMaintenance = _previewTrackedBalanceAfterMaintenance(pool, pid);
        state.trackedBalanceAfterService = state.trackedBalanceAfterMaintenance + state.pendingSelfPayAciToDebt;
        state.aciMode = lineState.aciMode;
        state.activeBeforeService = lineState.active;
        state.activeAfterService = state.outstandingDebtAfterService != 0;

        uint256 storedClaimableAciAfterSettlement = LibActiveCreditIndex.previewStoredSscClaimableYield(pid, positionKey);
        state.claimableAciYieldAfterService = storedClaimableAciAfterSettlement - state.pendingSelfPayAciToDebt;
    }

    function _freeEquity(
        uint256 principal,
        uint256 totalSameAssetDebt,
        uint256 otherEncumbrance,
        uint256 requiredLockedCapital
    ) private pure returns (uint256 freeEquity_) {
        uint256 totalEncumbered = otherEncumbrance + requiredLockedCapital;
        uint256 withdrawalBlocker = totalSameAssetDebt > totalEncumbered ? totalSameAssetDebt : totalEncumbered;
        if (principal > withdrawalBlocker) {
            freeEquity_ = principal - withdrawalBlocker;
        }
    }

    function _maxAdditionalDraw(ServiceState memory state, uint16 ltvBps) private pure returns (uint256) {
        return _maxAdditionalDrawFromInputs(
            state.settledPrincipal,
            state.totalSameAssetDebtAfterService,
            state.outstandingDebtAfterService,
            state.otherEncumbrance,
            state.trackedBalanceAfterService,
            ltvBps
        );
    }

    function _maxAdditionalDrawFromInputs(
        uint256 settledPrincipal,
        uint256 totalSameAssetDebt,
        uint256 outstandingDebt,
        uint256 otherEncumbrance,
        uint256 trackedBalance,
        uint16 ltvBps
    ) private pure returns (uint256) {
        if (trackedBalance == 0 || ltvBps == 0 || ltvBps > BPS_DENOMINATOR) {
            return 0;
        }

        uint256 low;
        uint256 high = trackedBalance;
        while (low < high) {
            uint256 mid = low + (high - low + 1) / 2;
            if (_canDraw(settledPrincipal, totalSameAssetDebt, outstandingDebt, otherEncumbrance, trackedBalance, ltvBps, mid)) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return low;
    }

    function _canDraw(
        uint256 settledPrincipal,
        uint256 totalSameAssetDebt,
        uint256 outstandingDebt,
        uint256 otherEncumbrance,
        uint256 trackedBalance,
        uint16 ltvBps,
        uint256 additionalDebt
    ) private pure returns (bool) {
        if (additionalDebt > trackedBalance) {
            return false;
        }

        uint256 newTotalSameAssetDebt = totalSameAssetDebt + additionalDebt;
        uint256 maxDebt = Math.mulDiv(settledPrincipal, ltvBps, BPS_DENOMINATOR);
        if (newTotalSameAssetDebt > maxDebt) {
            return false;
        }

        uint256 requiredLock =
            LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(outstandingDebt + additionalDebt, ltvBps);
        return otherEncumbrance + requiredLock <= settledPrincipal;
    }

    function _totalEncumberedWithUpdatedLock(
        bytes32 positionKey,
        uint256 pid,
        uint256 currentRequiredLockedCapital,
        uint256 requiredLockedCapital
    ) private view returns (uint256 totalEncumbered) {
        uint256 currentTotal = LibEncumbrance.total(positionKey, pid);
        if (currentTotal > currentRequiredLockedCapital) {
            totalEncumbered = currentTotal - currentRequiredLockedCapital + requiredLockedCapital;
        } else {
            totalEncumbered = requiredLockedCapital;
        }
    }

    function _previewTrackedBalanceAfterMaintenance(Types.PoolData storage pool, uint256 pid)
        private
        view
        returns (uint256 trackedAfterMaintenance)
    {
        trackedAfterMaintenance = pool.trackedBalance;

        if (LibAppStorage.s().foundationReceiver == address(0) || !pool.initialized) {
            return trackedAfterMaintenance;
        }

        (uint256 totalDepositsAfterAccrual,) = LibMaintenance.previewState(pid);
        uint256 accrued = pool.totalDeposits > totalDepositsAfterAccrual ? pool.totalDeposits - totalDepositsAfterAccrual : 0;
        uint256 outstandingMaintenance = pool.pendingMaintenance + accrued;
        if (outstandingMaintenance == 0) {
            return trackedAfterMaintenance;
        }

        uint256 paid = outstandingMaintenance;
        if (paid > trackedAfterMaintenance) {
            paid = trackedAfterMaintenance;
        }

        uint256 contractBalance = LibCurrency.balanceOfSelf(pool.underlying);
        if (paid > contractBalance) {
            paid = contractBalance;
        }

        return trackedAfterMaintenance - paid;
    }

    function _otherEncumbrance(bytes32 positionKey, uint256 pid, uint256 currentRequiredLockedCapital)
        private
        view
        returns (uint256 otherEncumbrance)
    {
        uint256 totalEncumbered = LibEncumbrance.total(positionKey, pid);
        otherEncumbrance =
            totalEncumbered > currentRequiredLockedCapital ? totalEncumbered - currentRequiredLockedCapital : 0;
    }

    function _isUnsafe(
        uint256 principal,
        uint256 totalSameAssetDebt,
        uint256 otherEncumbrance,
        uint256 requiredLockedCapital,
        uint16 ltvBps
    ) private pure returns (bool) {
        if (principal == 0) {
            return totalSameAssetDebt != 0 || otherEncumbrance != 0;
        }

        uint256 maxDebt = Math.mulDiv(principal, ltvBps, BPS_DENOMINATOR);
        uint256 totalEncumbered = otherEncumbrance + requiredLockedCapital;
        return totalSameAssetDebt > maxDebt || totalEncumbered > principal;
    }

    function _minimumPrincipalConsumptionForSafety(uint256 outstandingDebt, uint256 availableBacking, uint16 ltvBps)
        private
        pure
        returns (bool feasible, uint256 principalConsumed)
    {
        uint256 maxConsumable = outstandingDebt < availableBacking ? outstandingDebt : availableBacking;
        if (_isSafeAfterPrincipalConsumption(outstandingDebt, availableBacking, ltvBps, 0)) {
            return (true, 0);
        }
        if (!_isSafeAfterPrincipalConsumption(outstandingDebt, availableBacking, ltvBps, maxConsumable)) {
            return (false, maxConsumable);
        }

        uint256 low;
        uint256 high = maxConsumable;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (_isSafeAfterPrincipalConsumption(outstandingDebt, availableBacking, ltvBps, mid)) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return (true, low);
    }

    function _isSafeAfterPrincipalConsumption(uint256 outstandingDebt, uint256 availableBacking, uint16 ltvBps, uint256 x)
        private
        pure
        returns (bool)
    {
        uint256 residualDebt = outstandingDebt - x;
        uint256 residualBacking = availableBacking - x;
        return residualDebt <= _maxSafeDebtForBacking(residualBacking, ltvBps);
    }

    function _maxSafeDebtForBacking(uint256 backing, uint16 ltvBps) private pure returns (uint256) {
        return Math.mulDiv(backing, ltvBps, BPS_DENOMINATOR);
    }
}
