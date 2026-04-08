// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibMaintenance} from "./LibMaintenance.sol";
import {LibSelfSecuredCreditStorage} from "./LibSelfSecuredCreditStorage.sol";
import {Types} from "./Types.sol";

/// @notice Active Credit index accounting with 24h time-gated eligibility
library LibActiveCreditIndex {
    uint256 public constant INDEX_SCALE = 1e18;
    uint256 public constant TIME_GATE = 24 hours;
    uint256 internal constant BUCKET_SIZE = 1 hours;
    uint8 internal constant BUCKET_COUNT = 24;

    event ActiveCreditIndexAccrued(uint256 indexed pid, uint256 amount, uint256 delta, uint256 newIndex, bytes32 source);
    event ActiveCreditSettled(
        uint256 indexed pid,
        bytes32 indexed user,
        uint256 prevIndex,
        uint256 newIndex,
        uint256 addedYield,
        uint256 totalAccruedYield
    );

    event ActiveCreditTimingUpdated(
        uint256 indexed pid,
        bytes32 indexed user,
        bool isDebtState,
        uint40 startTime,
        uint256 principal,
        bool isMature
    );

    /// @notice Compute time credit toward maturity (capped at TIME_GATE).
    function timeCredit(Types.ActiveCreditState storage state) internal view returns (uint256) {
        if (state.principal == 0 || block.timestamp <= state.startTime) return 0;
        uint256 elapsed = block.timestamp - state.startTime;
        return elapsed > TIME_GATE ? TIME_GATE : elapsed;
    }

    /// @notice Calculate active weight for a state (0 until mature).
    function activeWeight(Types.ActiveCreditState storage state) internal view returns (uint256) {
        return timeCredit(state) < TIME_GATE ? 0 : state.principal;
    }

    /// @notice Apply weighted dilution on principal increase and update startTime.
    function applyWeightedIncrease(Types.ActiveCreditState storage state, uint256 addedPrincipal) internal {
        if (addedPrincipal == 0) return;
        uint256 oldPrincipal = state.principal;
        if (oldPrincipal == 0) {
            state.principal = addedPrincipal;
            state.startTime = uint40(block.timestamp);
            return;
        }
        uint256 oldCredit = timeCredit(state);
        uint256 total = oldPrincipal + addedPrincipal;
        uint256 newCredit = Math.mulDiv(oldPrincipal, oldCredit, total);
        if (newCredit > TIME_GATE) newCredit = TIME_GATE;
        state.principal = total;
        state.startTime = uint40(block.timestamp - newCredit);
    }

    /// @notice Apply weighted dilution and emit timing gate status for the updated state.
    function applyWeightedIncreaseWithGate(
        Types.PoolData storage p,
        Types.ActiveCreditState storage state,
        uint256 addedPrincipal,
        uint256 pid,
        bytes32 user,
        bool isDebtState
    ) internal {
        _rollMatured(p);
        _removeFromBase(p, state, state.principal);
        applyWeightedIncrease(state, addedPrincipal);
        _scheduleState(p, state);
        emit ActiveCreditTimingUpdated(pid, user, isDebtState, state.startTime, state.principal, _isMature(state));
    }

    /// @notice Reset state when principal is zero.
    function resetIfZero(Types.ActiveCreditState storage state) internal {
        if (state.principal == 0) {
            state.startTime = 0;
            state.indexSnapshot = 0;
        }
    }

    /// @notice Reset state when principal is zero and emit timing gate status.
    function resetIfZeroWithGate(
        Types.ActiveCreditState storage state,
        uint256 pid,
        bytes32 user,
        bool isDebtState
    ) internal {
        if (state.principal == 0) {
            state.startTime = 0;
            state.indexSnapshot = 0;
            emit ActiveCreditTimingUpdated(pid, user, isDebtState, 0, 0, false);
            return;
        }
        uint256 principalBefore = state.principal;
        resetIfZero(state);
        if (principalBefore != 0 && state.principal == 0) {
            emit ActiveCreditTimingUpdated(pid, user, isDebtState, state.startTime, state.principal, false);
        }
    }

    function applyPrincipalDecrease(
        Types.PoolData storage p,
        Types.ActiveCreditState storage state,
        uint256 decrease
    ) internal {
        if (decrease == 0) return;
        _rollMatured(p);
        _removeFromBase(p, state, decrease);
        if (state.principal <= decrease) {
            state.principal = 0;
        } else {
            state.principal -= decrease;
        }
    }

    function applyEncumbranceDelta(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 user,
        uint256 beforeEncumbrance,
        uint256 afterEncumbrance
    ) internal {
        if (beforeEncumbrance == afterEncumbrance) return;
        if (afterEncumbrance > beforeEncumbrance) {
            _increaseEncumbrance(p, pid, user, afterEncumbrance - beforeEncumbrance);
        } else {
            _decreaseEncumbrance(p, pid, user, beforeEncumbrance - afterEncumbrance);
        }
    }

    function applyEncumbranceIncrease(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 user,
        uint256 amount
    ) internal {
        _increaseEncumbrance(p, pid, user, amount);
    }

    function applyEncumbranceDecrease(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 user,
        uint256 amount
    ) internal {
        _decreaseEncumbrance(p, pid, user, amount);
    }

    function _increaseEncumbrance(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 user,
        uint256 amount
    ) private {
        if (amount == 0) return;
        Types.ActiveCreditState storage enc = p.userActiveCreditStateEncumbrance[user];
        _settleState(p, enc, pid, user);
        p.activeCreditPrincipalTotal += amount;
        applyWeightedIncreaseWithGate(p, enc, amount, pid, user, false);
        enc.indexSnapshot = p.activeCreditIndex;
    }

    function _decreaseEncumbrance(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 user,
        uint256 amount
    ) private {
        if (amount == 0) return;
        Types.ActiveCreditState storage enc = p.userActiveCreditStateEncumbrance[user];
        _settleState(p, enc, pid, user);
        uint256 principalBefore = enc.principal;
        uint256 decrease = principalBefore >= amount ? amount : principalBefore;
        if (p.activeCreditPrincipalTotal >= decrease) {
            p.activeCreditPrincipalTotal -= decrease;
        } else {
            p.activeCreditPrincipalTotal = 0;
        }
        applyPrincipalDecrease(p, enc, decrease);
        if (principalBefore <= amount || enc.principal == 0) {
            resetIfZeroWithGate(enc, pid, user, false);
        } else {
            enc.indexSnapshot = p.activeCreditIndex;
        }
    }

    function trackState(Types.PoolData storage p, Types.ActiveCreditState storage state) internal {
        if (state.principal == 0) return;
        _rollMatured(p);
        _scheduleState(p, state);
    }

    /// @notice Accrue an underlying-denominated fee into the active credit index with a source tag.
    /// @dev Mirrors LibFeeIndex accrual using per-pool remainder tracking.
    function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) internal {
        if (amount == 0) return;
        LibMaintenance.enforce(pid);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];
        _accrueReservedWithSource(p, pid, amount, source);
    }

    function accrueReservedWithSource(uint256 pid, uint256 amount, bytes32 source) internal {
        if (amount == 0) return;
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        _accrueReservedWithSource(p, pid, amount, source);
    }

    function _accrueReservedWithSource(Types.PoolData storage p, uint256 pid, uint256 amount, bytes32 source)
        private
    {
        _rollMatured(p);
        uint256 activeBase = p.activeCreditMaturedTotal;
        if (activeBase == 0) return;

        uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
        uint256 dividend = scaledAmount + p.activeCreditIndexRemainder;
        uint256 delta = dividend / activeBase;
        if (delta == 0) {
            p.activeCreditIndexRemainder = dividend;
            return;
        }

        p.activeCreditIndexRemainder = dividend - (delta * activeBase);
        uint256 newIndex = p.activeCreditIndex + delta;
        p.activeCreditIndex = newIndex;
        emit ActiveCreditIndexAccrued(pid, amount, delta, newIndex, source);
    }

    function hasMaturedBase(uint256 pid) internal returns (bool) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        _rollMatured(p);
        return p.activeCreditMaturedTotal != 0;
    }

    /// @notice Settle pending active credit yield for a user into accrued ledger and checkpoint index.
    function settle(uint256 pid, bytes32 user) internal {
        LibMaintenance.enforce(pid);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];
        _rollMatured(p);

        _settleState(p, p.userActiveCreditStateEncumbrance[user], pid, user);
        _settleDebtState(p, p.userActiveCreditStateDebt[user], pid, user);
    }

    /// @notice View helper returning accrued + pending active credit yield for a user.
    function pendingYield(uint256 pid, bytes32 user) internal view returns (uint256) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];

        uint256 accrued = p.userAccruedYield[user];
        uint256 feeAccrued = p.userClaimableFeeYield[user];
        uint256 amount = accrued > feeAccrued ? accrued - feeAccrued : 0;
        amount += _pendingForState(p, p.userActiveCreditStateEncumbrance[user]);
        amount += _pendingDebtYieldExcludingSsc(p, pid, user);
        return amount;
    }

    /// @notice View helper returning claimable SSC-routed ACI yield.
    function pendingSscClaimableYield(uint256 pid, bytes32 user) internal view returns (uint256 amount) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(user, pid);
        if (lineState.aciMode == Types.SscAciMode.SelfPay) {
            uint256 protectedClaimable = LibSelfSecuredCreditStorage.protectedClaimableAciYieldOf(user, pid);
            uint256 storedClaimable = LibSelfSecuredCreditStorage.claimableAciYieldOf(user, pid);
            return protectedClaimable > storedClaimable ? storedClaimable : protectedClaimable;
        }

        amount = LibSelfSecuredCreditStorage.claimableAciYieldOf(user, pid);
        amount += _pendingSscDebtYield(p, pid, user);
    }

    /// @notice View helper returning pending SSC debt-side ACI before self-pay routing is applied.
    function pendingSscDebtYield(uint256 pid, bytes32 user) internal view returns (uint256 amount) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        amount = _pendingSscDebtYield(p, pid, user);
    }

    /// @notice View helper returning stored claimable SSC ACI after hypothetical settlement.
    function previewStoredSscClaimableYield(uint256 pid, bytes32 user) internal view returns (uint256 amount) {
        amount = LibSelfSecuredCreditStorage.claimableAciYieldOf(user, pid);
        amount += pendingSscDebtYield(pid, user);
    }

    /// @notice View helper returning the amount of SSC ACI that would self-pay debt on the next service.
    function previewSelfPayAciApplied(uint256 pid, bytes32 user) internal view returns (uint256 amount) {
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(user, pid);
        if (lineState.aciMode != Types.SscAciMode.SelfPay || lineState.outstandingDebt == 0) {
            return 0;
        }

        uint256 claimableBefore = previewStoredSscClaimableYield(pid, user);
        uint256 protectedClaimable = LibSelfSecuredCreditStorage.protectedClaimableAciYieldOf(user, pid);
        if (protectedClaimable > claimableBefore) {
            protectedClaimable = claimableBefore;
        }

        uint256 serviceableAciYield =
            claimableBefore > protectedClaimable ? claimableBefore - protectedClaimable : 0;
        return serviceableAciYield > lineState.outstandingDebt ? lineState.outstandingDebt : serviceableAciYield;
    }

    /// @notice View helper returning only active credit pending yield (excludes already accrued ledger).
    function pendingActiveCredit(uint256 pid, bytes32 user) internal view returns (uint256) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];
        uint256 amount;
        amount += _pendingForState(p, p.userActiveCreditStateEncumbrance[user]);
        amount += _pendingForState(p, p.userActiveCreditStateDebt[user]);
        return amount;
    }

    function _pendingForState(Types.PoolData storage p, Types.ActiveCreditState storage state)
        private
        view
        returns (uint256)
    {
        if (!_isMature(state)) return 0;
        uint256 globalIndex = p.activeCreditIndex;
        uint256 prevIndex = state.indexSnapshot;
        if (globalIndex <= prevIndex || state.principal == 0) return 0;
        uint256 delta = globalIndex - prevIndex;
        return Math.mulDiv(state.principal, delta, INDEX_SCALE);
    }

    function _settleState(
        Types.PoolData storage p,
        Types.ActiveCreditState storage state,
        uint256 pid,
        bytes32 user
    ) private {
        uint256 globalIndex = p.activeCreditIndex;
        uint256 prevIndex = state.indexSnapshot;

        if (state.principal == 0) {
            state.indexSnapshot = globalIndex;
            state.startTime = 0;
            return;
        }

        if (!_isMature(state)) {
            state.indexSnapshot = globalIndex;
            return;
        }

        if (globalIndex > prevIndex) {
            uint256 delta = globalIndex - prevIndex;
            uint256 added = Math.mulDiv(state.principal, delta, INDEX_SCALE);
            if (added > 0) {
                p.userAccruedYield[user] += added;
                emit ActiveCreditSettled(pid, user, prevIndex, globalIndex, added, p.userAccruedYield[user]);
            }
        }
        state.indexSnapshot = globalIndex;
    }

    function _settleDebtState(
        Types.PoolData storage p,
        Types.ActiveCreditState storage state,
        uint256 pid,
        bytes32 user
    ) private {
        uint256 globalIndex = p.activeCreditIndex;
        uint256 prevIndex = state.indexSnapshot;

        if (state.principal == 0) {
            state.indexSnapshot = globalIndex;
            state.startTime = 0;
            return;
        }

        if (!_isMature(state)) {
            state.indexSnapshot = globalIndex;
            return;
        }

        if (globalIndex > prevIndex) {
            uint256 delta = globalIndex - prevIndex;
            uint256 totalAdded = Math.mulDiv(state.principal, delta, INDEX_SCALE);
            if (totalAdded > 0) {
                _routeDebtSettlement(p, pid, user, prevIndex, globalIndex, state.principal, totalAdded);
            }
        }
        state.indexSnapshot = globalIndex;
    }

    function _routeDebtSettlement(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 user,
        uint256 prevIndex,
        uint256 globalIndex,
        uint256 debtPrincipal,
        uint256 totalAdded
    ) private {
        uint256 sscPrincipal = _sscDebtPrincipal(pid, user, debtPrincipal);
        uint256 sscAdded;
        if (sscPrincipal != 0) {
            sscAdded = sscPrincipal >= debtPrincipal
                ? totalAdded
                : Math.mulDiv(totalAdded, sscPrincipal, debtPrincipal);
            if (sscAdded != 0) {
                LibSelfSecuredCreditStorage.increaseClaimableAciYield(user, pid, sscAdded);
            }
        }

        uint256 claimableAdded = totalAdded - sscAdded;
        if (claimableAdded == 0) {
            return;
        }

        uint256 newAccruedYield = p.userAccruedYield[user] + claimableAdded;
        p.userAccruedYield[user] = newAccruedYield;
        emit ActiveCreditSettled(pid, user, prevIndex, globalIndex, claimableAdded, newAccruedYield);
    }

    function _pendingDebtYieldExcludingSsc(Types.PoolData storage p, uint256 pid, bytes32 user)
        private
        view
        returns (uint256 amount)
    {
        uint256 totalPending = _pendingForState(p, p.userActiveCreditStateDebt[user]);
        if (totalPending == 0) {
            return 0;
        }

        uint256 sscPending = _pendingSscDebtYield(p, pid, user);
        return totalPending > sscPending ? totalPending - sscPending : 0;
    }

    function _pendingSscDebtYield(Types.PoolData storage p, uint256 pid, bytes32 user) private view returns (uint256 amount) {
        Types.ActiveCreditState storage debtState = p.userActiveCreditStateDebt[user];
        uint256 totalPending = _pendingForState(p, debtState);
        if (totalPending == 0 || debtState.principal == 0) {
            return 0;
        }

        uint256 sscPrincipal = _sscDebtPrincipal(pid, user, debtState.principal);
        if (sscPrincipal == 0) {
            return 0;
        }

        return sscPrincipal >= debtState.principal
            ? totalPending
            : Math.mulDiv(totalPending, sscPrincipal, debtState.principal);
    }

    function _sscDebtPrincipal(uint256 pid, bytes32 user, uint256 debtStatePrincipal)
        private
        view
        returns (uint256 sscPrincipal)
    {
        Types.SscLine memory lineState = LibSelfSecuredCreditStorage.lineView(user, pid);
        if (!lineState.active) {
            return 0;
        }

        sscPrincipal = lineState.outstandingDebt;
        if (sscPrincipal > debtStatePrincipal) {
            sscPrincipal = debtStatePrincipal;
        }
    }

    function _rollMatured(Types.PoolData storage p) private {
        uint64 currentHour = _currentHour();
        uint64 storedStart = p.activeCreditPendingStartHour;
        if (storedStart == 0) {
            p.activeCreditPendingStartHour = currentHour + 1;
            p.activeCreditPendingCursor = 0;
            return;
        }
        uint64 startHour = storedStart - 1;
        if (currentHour <= startHour) return;

        uint64 elapsed = currentHour - startHour;
        if (elapsed >= BUCKET_COUNT) {
            for (uint8 i = 0; i < BUCKET_COUNT; i++) {
                uint256 pending = p.activeCreditPendingBuckets[i];
                if (pending > 0) {
                    p.activeCreditMaturedTotal += pending;
                    p.activeCreditPendingBuckets[i] = 0;
                }
            }
            p.activeCreditPendingStartHour = currentHour + 1;
            p.activeCreditPendingCursor = 0;
            return;
        }

        uint8 cursor = p.activeCreditPendingCursor;
        for (uint64 i = 0; i < elapsed; i++) {
            uint256 pending = p.activeCreditPendingBuckets[cursor];
            if (pending > 0) {
                p.activeCreditMaturedTotal += pending;
                p.activeCreditPendingBuckets[cursor] = 0;
            }
            cursor = uint8((cursor + 1) % BUCKET_COUNT);
        }
        p.activeCreditPendingCursor = cursor;
        p.activeCreditPendingStartHour = startHour + elapsed + 1;
    }

    function _scheduleState(Types.PoolData storage p, Types.ActiveCreditState storage state) private {
        uint256 principal = state.principal;
        if (principal == 0) return;
        _rollMatured(p);
        if (_isMature(state)) {
            p.activeCreditMaturedTotal += principal;
            return;
        }
        uint64 maturityHour = _maturityHour(state.startTime);
        uint64 startHour = p.activeCreditPendingStartHour - 1;
        if (maturityHour <= startHour) {
            p.activeCreditMaturedTotal += principal;
            return;
        }
        uint64 offset = maturityHour - startHour - 1;
        if (offset >= BUCKET_COUNT) {
            uint8 last = uint8((p.activeCreditPendingCursor + (BUCKET_COUNT - 1)) % BUCKET_COUNT);
            p.activeCreditPendingBuckets[last] += principal;
            return;
        }
        uint8 index = uint8((p.activeCreditPendingCursor + uint8(offset)) % BUCKET_COUNT);
        p.activeCreditPendingBuckets[index] += principal;
    }

    function _removeFromBase(Types.PoolData storage p, Types.ActiveCreditState storage state, uint256 amount) private {
        if (amount == 0) return;
        _rollMatured(p);
        if (_isMature(state)) {
            p.activeCreditMaturedTotal -= amount;
            return;
        }
        uint64 maturityHour = _maturityHour(state.startTime);
        uint64 startHour = p.activeCreditPendingStartHour - 1;
        if (maturityHour <= startHour) {
            p.activeCreditMaturedTotal -= amount;
            return;
        }
        uint64 offset = maturityHour - startHour - 1;
        if (offset >= BUCKET_COUNT) {
            uint8 last = uint8((p.activeCreditPendingCursor + (BUCKET_COUNT - 1)) % BUCKET_COUNT);
            p.activeCreditPendingBuckets[last] -= amount;
            return;
        }
        uint8 index = uint8((p.activeCreditPendingCursor + uint8(offset)) % BUCKET_COUNT);
        p.activeCreditPendingBuckets[index] -= amount;
    }

    function _currentHour() private view returns (uint64) {
        return uint64(block.timestamp / BUCKET_SIZE);
    }

    function _maturityHour(uint40 startTime) private pure returns (uint64) {
        return uint64((uint256(startTime) + TIME_GATE) / BUCKET_SIZE);
    }

    function _isMature(Types.ActiveCreditState storage state) private view returns (bool) {
        if (state.principal == 0) return false;
        if (block.timestamp <= state.startTime) return false;
        uint256 elapsed = block.timestamp - state.startTime;
        return elapsed >= TIME_GATE;
    }
}
