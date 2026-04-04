// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    InsufficientPoolLiquidity,
    InsufficientPrincipal,
    InvalidLTVRatio,
    InvalidParameterRange,
    LoanBelowMinimum,
    SolvencyViolation
} from "src/libraries/Errors.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibMaintenance} from "src/libraries/LibMaintenance.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "src/libraries/LibReentrancyGuard.sol";
import {LibSelfSecuredCreditAccounting} from "src/libraries/LibSelfSecuredCreditAccounting.sol";
import {LibSelfSecuredCreditStorage} from "src/libraries/LibSelfSecuredCreditStorage.sol";
import {Types} from "src/libraries/Types.sol";

/// @title SelfSecuredCreditFacet
/// @notice Public lifecycle entrypoints for the clean Self-Secured Credit rebuild.
contract SelfSecuredCreditFacet is ReentrancyGuardModifiers {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    event SelfSecuredCreditDrawn(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 borrowedAmount,
        uint256 outstandingDebt,
        uint256 requiredLockedCapital
    );
    event SelfSecuredCreditRepaid(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        uint256 repaidAmount,
        uint256 outstandingDebt,
        uint256 requiredLockedCapital
    );
    event SelfSecuredCreditClosed(
        uint256 indexed tokenId, address indexed owner, uint256 indexed poolId, uint256 totalDebtRepaid
    );
    event SelfSecuredCreditAciModeUpdated(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 indexed poolId,
        Types.SscAciMode previousMode,
        Types.SscAciMode newMode
    );

    function previewSelfSecuredCreditMaintenance(uint256 tokenId, uint256 pid)
        external
        view
        returns (Types.SscMaintenancePreview memory preview)
    {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        preview = _previewMaintenanceState(tokenId, positionKey, pid, pool);
    }

    function getSelfSecuredCreditLineView(uint256 tokenId, uint256 pid)
        external
        view
        returns (Types.SscLineView memory view_)
    {
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, pid);

        view_.tokenId = tokenId;
        view_.poolId = pid;
        view_.underlying = pool.underlying;
        view_.principal = LibFeeIndex.previewSettledPrincipal(pid, positionKey);
        view_.outstandingDebt = lineState.outstandingDebt;
        view_.requiredLockedCapital = lineState.requiredLockedCapital;
        view_.claimableFeeYield = LibFeeIndex.pendingYield(pid, positionKey);
        view_.claimableAciYield = LibActiveCreditIndex.pendingSscClaimableYield(pid, positionKey);
        view_.totalAciAppliedToDebt = LibSelfSecuredCreditStorage.totalAciAppliedToDebtOf(positionKey, pid);
        view_.aciMode = lineState.aciMode;
        view_.active = lineState.active;

        uint256 totalEncumbered =
            _totalEncumberedWithUpdatedLock(positionKey, pid, lineState, view_.requiredLockedCapital);
        uint256 withdrawalBlocker = pool.userSameAssetDebt[positionKey] > totalEncumbered
            ? pool.userSameAssetDebt[positionKey]
            : totalEncumbered;
        if (view_.principal > withdrawalBlocker) {
            view_.freeEquity = view_.principal - withdrawalBlocker;
        }
    }

    function drawSelfSecuredCredit(uint256 tokenId, uint256 pid, uint256 amount, uint256 minReceived)
        external
        payable
        nonReentrant
        returns (uint256 received)
    {
        LibCurrency.assertZeroMsgValue();
        if (amount == 0) {
            revert InvalidParameterRange("amount=0");
        }

        LibPositionHelpers.requireOwnership(tokenId);
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        LibPositionHelpers.ensurePoolMembership(positionKey, pid, true);
        LibPositionHelpers.settlePosition(pid, positionKey);

        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, pid);
        _enforceDrawThreshold(pool, lineState, amount);
        if (amount > pool.trackedBalance) {
            revert InsufficientPoolLiquidity(amount, pool.trackedBalance);
        }

        _enforceDrawSolvency(pool, positionKey, pid, lineState, amount);

        LibSelfSecuredCreditAccounting.DebtAdjustment memory adjustment =
            LibSelfSecuredCreditAccounting.increaseDebt(positionKey, tokenId, pid, amount);

        pool.trackedBalance -= adjustment.appliedAmount;
        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= adjustment.appliedAmount;
        }

        received = LibCurrency.transferWithMin(pool.underlying, msg.sender, adjustment.appliedAmount, minReceived);

        emit SelfSecuredCreditDrawn(
            tokenId,
            msg.sender,
            pid,
            adjustment.appliedAmount,
            adjustment.outstandingDebtAfter,
            adjustment.requiredLockedCapitalAfter
        );
    }

    function repaySelfSecuredCredit(uint256 tokenId, uint256 pid, uint256 amount, uint256 maxPayment)
        external
        payable
        nonReentrant
        returns (uint256 repaid)
    {
        repaid = _repaySelfSecuredCredit(tokenId, pid, amount, maxPayment);
    }

    function closeSelfSecuredCredit(uint256 tokenId, uint256 pid, uint256 maxPayment)
        external
        payable
        nonReentrant
        returns (uint256 repaid)
    {
        repaid = _repaySelfSecuredCredit(tokenId, pid, type(uint256).max, maxPayment);
    }

    function setSelfSecuredCreditAciMode(uint256 tokenId, uint256 pid, Types.SscAciMode newMode)
        external
        payable
        nonReentrant
    {
        LibCurrency.assertZeroMsgValue();
        LibPositionHelpers.requireOwnership(tokenId);

        LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        LibPositionHelpers.ensurePoolMembership(positionKey, pid, true);
        LibPositionHelpers.settlePosition(pid, positionKey);

        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, pid);
        if (!lineState.active) {
            revert InvalidParameterRange("no debt");
        }

        Types.SscAciMode previousMode = lineState.aciMode;
        if (previousMode == newMode) {
            return;
        }

        lineState.aciMode = newMode;
        emit SelfSecuredCreditAciModeUpdated(tokenId, msg.sender, pid, previousMode, newMode);
    }

    function _repaySelfSecuredCredit(uint256 tokenId, uint256 pid, uint256 requestedAmount, uint256 maxPayment)
        internal
        returns (uint256 repaid)
    {
        if (requestedAmount == 0) {
            revert InvalidParameterRange("amount=0");
        }

        LibPositionHelpers.requireOwnership(tokenId);
        Types.PoolData storage pool = LibPositionHelpers.pool(pid);
        bytes32 positionKey = LibPositionHelpers.positionKey(tokenId);
        LibPositionHelpers.ensurePoolMembership(positionKey, pid, true);
        LibPositionHelpers.settlePosition(pid, positionKey);

        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, pid);
        uint256 outstandingDebt = lineState.outstandingDebt;
        if (outstandingDebt == 0) {
            revert InvalidParameterRange("no debt");
        }

        uint256 minPayment = requestedAmount > outstandingDebt ? outstandingDebt : requestedAmount;
        uint256 received = LibCurrency.pullAtLeast(pool.underlying, msg.sender, minPayment, maxPayment);
        repaid = received > outstandingDebt ? outstandingDebt : received;

        LibSelfSecuredCreditAccounting.DebtAdjustment memory adjustment =
            LibSelfSecuredCreditAccounting.decreaseDebt(positionKey, tokenId, pid, repaid);

        pool.trackedBalance += repaid;

        uint256 surplus = received - repaid;
        if (surplus != 0) {
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal -= surplus;
            }
            LibCurrency.transfer(pool.underlying, msg.sender, surplus);
        }

        emit SelfSecuredCreditRepaid(
            tokenId,
            msg.sender,
            pid,
            repaid,
            adjustment.outstandingDebtAfter,
            adjustment.requiredLockedCapitalAfter
        );

        if (adjustment.outstandingDebtAfter == 0) {
            emit SelfSecuredCreditClosed(tokenId, msg.sender, pid, repaid);
        }
    }

    function _enforceDrawThreshold(Types.PoolData storage pool, Types.SscLine storage lineState, uint256 amount)
        internal
        view
    {
        uint256 minimum = lineState.active ? pool.poolConfig.minTopupAmount : pool.poolConfig.minLoanAmount;
        if (amount < minimum) {
            revert LoanBelowMinimum(amount, minimum);
        }
    }

    function _enforceDrawSolvency(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 poolId,
        Types.SscLine storage lineState,
        uint256 additionalDebt
    ) internal view {
        uint256 principal = pool.userPrincipal[positionKey];
        uint256 currentSameAssetDebt = pool.userSameAssetDebt[positionKey];
        uint256 newDebt = currentSameAssetDebt + additionalDebt;
        uint16 ltvBps = pool.poolConfig.depositorLTVBps;

        if (ltvBps == 0 || ltvBps > BPS_DENOMINATOR) {
            revert InvalidLTVRatio();
        }

        uint256 maxDebt = Math.mulDiv(principal, ltvBps, BPS_DENOMINATOR);
        if (newDebt > maxDebt) {
            revert SolvencyViolation(principal, newDebt, ltvBps);
        }

        uint256 totalEncumbered = LibEncumbrance.total(positionKey, poolId);
        uint256 otherEncumbrance =
            totalEncumbered > lineState.requiredLockedCapital ? totalEncumbered - lineState.requiredLockedCapital : 0;
        uint256 requiredLock = LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(newDebt, ltvBps);
        uint256 requiredPrincipal = otherEncumbrance + requiredLock;
        if (requiredPrincipal > principal) {
            revert InsufficientPrincipal(requiredPrincipal, principal);
        }
    }

    function _previewMaintenanceState(
        uint256 tokenId,
        bytes32 positionKey,
        uint256 pid,
        Types.PoolData storage pool
    ) internal view returns (Types.SscMaintenancePreview memory preview) {
        preview.tokenId = tokenId;
        preview.poolId = pid;
        preview.settledPrincipal = LibFeeIndex.previewSettledPrincipal(pid, positionKey);
        preview.totalSameAssetDebt = pool.userSameAssetDebt[positionKey];

        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, pid);
        preview.outstandingDebt = lineState.outstandingDebt;
        preview.requiredLockedCapital =
            LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(lineState.outstandingDebt, pool.poolConfig.depositorLTVBps);

        uint256 totalEncumbered = _totalEncumberedWithUpdatedLock(positionKey, pid, lineState, preview.requiredLockedCapital);
        uint256 withdrawalBlocker = preview.totalSameAssetDebt > totalEncumbered ? preview.totalSameAssetDebt : totalEncumbered;
        if (preview.settledPrincipal > withdrawalBlocker) {
            preview.freeEquity = preview.settledPrincipal - withdrawalBlocker;
        }

        uint256 maxDebt = Math.mulDiv(preview.settledPrincipal, pool.poolConfig.depositorLTVBps, BPS_DENOMINATOR);
        if (maxDebt > preview.totalSameAssetDebt) {
            preview.remainingBorrowRunway = maxDebt - preview.totalSameAssetDebt;
        }

        uint256 trackedAfterMaintenance = _previewTrackedBalanceAfterMaintenance(pool, pid);
        if (preview.remainingBorrowRunway > trackedAfterMaintenance) {
            preview.remainingBorrowRunway = trackedAfterMaintenance;
        }

        preview.unsafeAfterMaintenance =
            preview.totalSameAssetDebt > maxDebt || totalEncumbered > preview.settledPrincipal;
    }

    function _totalEncumberedWithUpdatedLock(
        bytes32 positionKey,
        uint256 pid,
        Types.SscLine storage lineState,
        uint256 requiredLockedCapital
    ) internal view returns (uint256 totalEncumbered) {
        uint256 currentTotal = LibEncumbrance.total(positionKey, pid);
        if (currentTotal > lineState.requiredLockedCapital) {
            totalEncumbered = currentTotal - lineState.requiredLockedCapital + requiredLockedCapital;
        } else {
            totalEncumbered = requiredLockedCapital;
        }
    }

    function _previewTrackedBalanceAfterMaintenance(Types.PoolData storage pool, uint256 pid)
        internal
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
}
