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
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
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
        uint256 newDebt = lineState.outstandingDebt + additionalDebt;
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
}
