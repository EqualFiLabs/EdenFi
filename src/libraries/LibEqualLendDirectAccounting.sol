// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    EncumbranceUnderflow,
    InsufficientPoolLiquidity,
    InsufficientPrincipal,
    DirectError_ZeroAmount,
    MaxUserCountExceeded
} from "src/libraries/Errors.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Shared accounting transitions for EqualLend Direct origination, repayment, and closeout.
library LibEqualLendDirectAccounting {
    struct OriginationParams {
        bytes32 lenderPositionKey;
        bytes32 borrowerPositionKey;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principal;
        uint256 collateralToLock;
        bool convertOfferEscrow;
        bool lockCollateralNow;
    }

    struct PrincipalSettlementParams {
        bytes32 lenderPositionKey;
        bytes32 borrowerPositionKey;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 principalDelta;
        uint256 collateralDelta;
        bool releaseLockedCollateral;
    }

    struct TerminalCleanupParams {
        bytes32 lenderPositionKey;
        bytes32 borrowerPositionKey;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address borrowAsset;
        address collateralAsset;
        uint256 borrowedPrincipalToClear;
        uint256 exposureToClear;
        uint256 collateralToUnlock;
    }

    function increaseOfferEscrow(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) internal {
        if (amount == 0) return;
        LibEncumbrance.position(lenderPositionKey, lenderPoolId).offerEscrowedCapital += amount;
    }

    function decreaseOfferEscrow(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) internal {
        if (amount == 0) return;
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(lenderPositionKey, lenderPoolId);
        uint256 current = enc.offerEscrowedCapital;
        if (amount > current) revert EncumbranceUnderflow(amount, current);
        enc.offerEscrowedCapital = current - amount;
    }

    function increaseLockedCapital(bytes32 borrowerPositionKey, uint256 collateralPoolId, uint256 amount) internal {
        if (amount == 0) return;
        LibEncumbrance.position(borrowerPositionKey, collateralPoolId).lockedCapital += amount;
    }

    function decreaseLockedCapital(bytes32 borrowerPositionKey, uint256 collateralPoolId, uint256 amount) internal {
        if (amount == 0) return;
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(borrowerPositionKey, collateralPoolId);
        uint256 current = enc.lockedCapital;
        if (amount > current) revert EncumbranceUnderflow(amount, current);
        enc.lockedCapital = current - amount;
    }

    function increaseLiveExposure(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) internal {
        if (amount == 0) return;
        LibEncumbrance.position(lenderPositionKey, lenderPoolId).encumberedCapital += amount;
    }

    function decreaseLiveExposure(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) internal {
        if (amount == 0) return;
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(lenderPositionKey, lenderPoolId);
        uint256 current = enc.encumberedCapital;
        if (amount > current) revert EncumbranceUnderflow(amount, current);
        enc.encumberedCapital = current - amount;
    }

    function moveOfferEscrowToLiveExposure(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) internal {
        if (amount == 0) return;
        decreaseOfferEscrow(lenderPositionKey, lenderPoolId, amount);
        increaseLiveExposure(lenderPositionKey, lenderPoolId, amount);
    }

    function departLenderCapital(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) internal {
        if (amount == 0) revert DirectError_ZeroAmount();

        Types.PoolData storage lenderPool = LibAppStorage.s().pools[lenderPoolId];
        uint256 principalBefore = lenderPool.userPrincipal[lenderPositionKey];
        if (principalBefore < amount) revert InsufficientPrincipal(amount, principalBefore);
        if (lenderPool.totalDeposits < amount) revert InsufficientPrincipal(amount, lenderPool.totalDeposits);
        if (lenderPool.trackedBalance < amount) revert InsufficientPoolLiquidity(amount, lenderPool.trackedBalance);

        lenderPool.userPrincipal[lenderPositionKey] = principalBefore - amount;
        lenderPool.totalDeposits -= amount;
        lenderPool.trackedBalance -= amount;

        if (principalBefore == amount && lenderPool.userCount > 0) {
            lenderPool.userCount -= 1;
        }

        if (LibCurrency.isNative(lenderPool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }
    }

    function restoreLenderCapital(bytes32 lenderPositionKey, uint256 lenderPoolId, uint256 amount) internal {
        if (amount == 0) return;

        Types.PoolData storage lenderPool = LibAppStorage.s().pools[lenderPoolId];
        uint256 principalBefore = lenderPool.userPrincipal[lenderPositionKey];
        lenderPool.userPrincipal[lenderPositionKey] = principalBefore + amount;
        lenderPool.totalDeposits += amount;
        lenderPool.trackedBalance += amount;

        if (principalBefore == 0) {
            uint256 maxUsers = lenderPool.poolConfig.maxUserCount;
            if (maxUsers > 0 && lenderPool.userCount >= maxUsers) {
                revert MaxUserCountExceeded(maxUsers);
            }
            lenderPool.userCount += 1;
        }

        if (LibCurrency.isNative(lenderPool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal += amount;
        }
    }

    function originate(
        LibEqualLendDirectStorage.DirectStorage storage store,
        OriginationParams memory params
    ) internal returns (bool sameAsset) {
        if (params.principal == 0) revert DirectError_ZeroAmount();

        departLenderCapital(params.lenderPositionKey, params.lenderPoolId, params.principal);

        if (params.convertOfferEscrow) {
            moveOfferEscrowToLiveExposure(params.lenderPositionKey, params.lenderPoolId, params.principal);
        } else {
            increaseLiveExposure(params.lenderPositionKey, params.lenderPoolId, params.principal);
        }

        if (params.lockCollateralNow) {
            increaseLockedCapital(params.borrowerPositionKey, params.collateralPoolId, params.collateralToLock);
        }
        _increaseBorrowedPrincipal(store, params.borrowerPositionKey, params.lenderPoolId, params.principal);

        sameAsset = params.borrowAsset == params.collateralAsset;
        if (sameAsset) {
            _increaseSameAssetDebt(
                store,
                params.borrowerPositionKey,
                params.borrowerPositionId,
                params.collateralPoolId,
                params.collateralAsset,
                params.principal
            );
        }
    }

    function settlePrincipal(
        LibEqualLendDirectStorage.DirectStorage storage store,
        PrincipalSettlementParams memory params
    ) internal returns (bool sameAsset) {
        if (params.principalDelta == 0) revert DirectError_ZeroAmount();

        restoreLenderCapital(params.lenderPositionKey, params.lenderPoolId, params.principalDelta);
        decreaseLiveExposure(params.lenderPositionKey, params.lenderPoolId, params.principalDelta);
        _decreaseBorrowedPrincipal(store, params.borrowerPositionKey, params.lenderPoolId, params.principalDelta);

        sameAsset = params.borrowAsset == params.collateralAsset;
        if (sameAsset) {
            _decreaseSameAssetDebt(
                store,
                params.borrowerPositionKey,
                params.borrowerPositionId,
                params.collateralPoolId,
                params.collateralAsset,
                params.principalDelta
            );
        }

        if (params.releaseLockedCollateral) {
            decreaseLockedCapital(params.borrowerPositionKey, params.collateralPoolId, params.collateralDelta);
        }
    }

    function cleanupTerminal(
        LibEqualLendDirectStorage.DirectStorage storage store,
        TerminalCleanupParams memory params
    ) internal returns (bool sameAsset) {
        sameAsset = params.borrowAsset == params.collateralAsset;

        if (params.exposureToClear > 0) {
            decreaseLiveExposure(params.lenderPositionKey, params.lenderPoolId, params.exposureToClear);
        }
        if (params.collateralToUnlock > 0) {
            decreaseLockedCapital(params.borrowerPositionKey, params.collateralPoolId, params.collateralToUnlock);
        }
        if (params.borrowedPrincipalToClear > 0) {
            _decreaseBorrowedPrincipal(store, params.borrowerPositionKey, params.lenderPoolId, params.borrowedPrincipalToClear);
            if (sameAsset) {
                _decreaseSameAssetDebt(
                    store,
                    params.borrowerPositionKey,
                    params.borrowerPositionId,
                    params.collateralPoolId,
                    params.collateralAsset,
                    params.borrowedPrincipalToClear
                );
            }
        }
    }

    function _increaseBorrowedPrincipal(
        LibEqualLendDirectStorage.DirectStorage storage store,
        bytes32 borrowerPositionKey,
        uint256 lenderPoolId,
        uint256 amount
    ) private {
        store.borrowedPrincipalByPool[borrowerPositionKey][lenderPoolId] += amount;
    }

    function _decreaseBorrowedPrincipal(
        LibEqualLendDirectStorage.DirectStorage storage store,
        bytes32 borrowerPositionKey,
        uint256 lenderPoolId,
        uint256 amount
    ) private {
        uint256 current = store.borrowedPrincipalByPool[borrowerPositionKey][lenderPoolId];
        store.borrowedPrincipalByPool[borrowerPositionKey][lenderPoolId] = current - amount;
    }

    function _increaseSameAssetDebt(
        LibEqualLendDirectStorage.DirectStorage storage store,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 collateralPoolId,
        address collateralAsset,
        uint256 amount
    ) private {
        store.sameAssetDebtByAsset[borrowerPositionKey][collateralAsset] += amount;

        Types.PoolData storage collateralPool = LibAppStorage.s().pools[collateralPoolId];
        collateralPool.userSameAssetDebt[borrowerPositionKey] += amount;
        collateralPool.sameAssetDebt[borrowerPositionId] += amount;
        collateralPool.activeCreditPrincipalTotal += amount;

        LibActiveCreditIndex.applyWeightedIncreaseWithGate(
            collateralPool,
            collateralPool.userActiveCreditStateDebt[borrowerPositionKey],
            amount,
            collateralPoolId,
            borrowerPositionKey,
            true
        );
        collateralPool.userActiveCreditStateDebt[borrowerPositionKey].indexSnapshot = collateralPool.activeCreditIndex;
    }

    function _decreaseSameAssetDebt(
        LibEqualLendDirectStorage.DirectStorage storage store,
        bytes32 borrowerPositionKey,
        uint256 borrowerPositionId,
        uint256 collateralPoolId,
        address collateralAsset,
        uint256 principalComponent
    ) private {
        uint256 storedDebt = store.sameAssetDebtByAsset[borrowerPositionKey][collateralAsset];
        store.sameAssetDebtByAsset[borrowerPositionKey][collateralAsset] = storedDebt - principalComponent;

        Types.PoolData storage collateralPool = LibAppStorage.s().pools[collateralPoolId];

        uint256 sameAssetDebt = collateralPool.userSameAssetDebt[borrowerPositionKey];
        collateralPool.userSameAssetDebt[borrowerPositionKey] = sameAssetDebt - principalComponent;

        uint256 tokenDebt = collateralPool.sameAssetDebt[borrowerPositionId];
        collateralPool.sameAssetDebt[borrowerPositionId] = tokenDebt - principalComponent;

        Types.ActiveCreditState storage debtState = collateralPool.userActiveCreditStateDebt[borrowerPositionKey];
        uint256 debtPrincipalBefore = debtState.principal;
        uint256 debtDecrease = principalComponent;
        LibActiveCreditIndex.applyPrincipalDecrease(collateralPool, debtState, debtDecrease);

        if (debtPrincipalBefore <= principalComponent || debtState.principal == 0) {
            LibActiveCreditIndex.resetIfZeroWithGate(debtState, collateralPoolId, borrowerPositionKey, true);
        } else {
            debtState.indexSnapshot = collateralPool.activeCreditIndex;
        }

        collateralPool.activeCreditPrincipalTotal -= debtDecrease;
    }
}
