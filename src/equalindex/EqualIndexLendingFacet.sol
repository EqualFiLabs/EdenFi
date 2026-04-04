// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualIndexBaseV3} from "./EqualIndexBaseV3.sol";
import {IndexToken} from "./IndexToken.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEqualIndexRewards} from "../libraries/LibEqualIndexRewards.sol";
import {LibEqualIndexLending} from "../libraries/LibEqualIndexLending.sol";
import {LibIndexEncumbrance} from "../libraries/LibIndexEncumbrance.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

/// @notice Position-based borrowing against index-token pool principal.
/// @dev Borrowing is index-based: collateral index units unlock proportional underlying principal.
contract EqualIndexLendingFacet is EqualIndexBaseV3, ReentrancyGuardModifiers {
    uint256 internal constant INDEX_SCALE = 1e18;

    struct BorrowPreparation {
        uint256 lockedAfter;
        address[] assets;
        uint256[] principals;
    }

    function configureLending(
        uint256 indexId,
        uint16 ltvBps,
        uint40 minDuration,
        uint40 maxDuration
    ) external onlyTimelock indexExists(indexId) {
        if (ltvBps != 10_000) revert InvalidParameterRange("ltvBps");
        if (minDuration > maxDuration) revert InvalidParameterRange("duration");

        LibEqualIndexLending.s().lendingConfigs[indexId] = LibEqualIndexLending.LendingConfig({
            ltvBps: ltvBps, minDuration: minDuration, maxDuration: maxDuration
        });

        emit LibEqualIndexLending.LendingConfigured(indexId, ltvBps, minDuration, maxDuration);
    }

    function configureBorrowFeeTiers(
        uint256 indexId,
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external onlyTimelock indexExists(indexId) {
        uint256 len = minCollateralUnits.length;
        if (len == 0 || len != flatFeeNative.length) revert InvalidArrayLength();

        uint256 prevMin;
        for (uint256 i = 0; i < len; i++) {
            uint256 minUnits = minCollateralUnits[i];
            if (minUnits == 0 || minUnits % INDEX_SCALE != 0) {
                revert InvalidParameterRange("tierCollateralUnitsWhole");
            }
            if (i > 0 && minUnits <= prevMin) revert InvalidParameterRange("tierOrder");
            prevMin = minUnits;
        }

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        delete ls.borrowFeeTiers[indexId];
        for (uint256 i = 0; i < len; i++) {
            ls.borrowFeeTiers[indexId].push(
                LibEqualIndexLending.BorrowFeeTier({
                    minCollateralUnits: minCollateralUnits[i], flatFeeNative: flatFeeNative[i]
                })
            );
        }

        emit LibEqualIndexLending.BorrowFeeTiersConfigured(indexId, minCollateralUnits, flatFeeNative);
    }

    function borrowFromPosition(uint256 positionId, uint256 indexId, uint256 collateralUnits, uint40 duration)
        external
        payable
        nonReentrant
        indexExists(indexId)
        returns (uint256 loanId)
    {
        if (collateralUnits == 0) revert InvalidParameterRange("collateralUnits");
        if (collateralUnits % INDEX_SCALE != 0) revert InvalidParameterRange("collateralUnitsWhole");

        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        uint16 ltvBps = _validatedBorrowLtv(indexId, duration);
        uint256 flatFeeNative = _borrowFlatFee(indexId, collateralUnits);
        _collectFlatNativeFee(flatFeeNative);

        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);

        uint256 indexPoolId = s().indexToPoolId[indexId];
        if (indexPoolId == 0) revert PoolNotInitialized(indexPoolId);
        LibPoolMembership._ensurePoolMembership(positionKey, indexPoolId, false);

        Types.PoolData storage indexPool = LibAppStorage.s().pools[indexPoolId];
        _assertAvailableCollateral(indexPool, positionKey, indexPoolId, collateralUnits);
        BorrowPreparation memory prep = _prepareBorrow(idx, indexId, collateralUnits, ltvBps);
        loanId = _createLoan(indexId, positionKey, collateralUnits, ltvBps, duration, prep.lockedAfter);
        _encumberWithAci(indexPool, positionKey, indexPoolId, indexId, collateralUnits);
        _disburseBorrowedAssets(loanId, indexId, prep.assets, prep.principals);

        _emitLoanCreated(loanId, positionKey, indexId, collateralUnits, ltvBps);
        emit LibEqualIndexLending.BorrowFlatFeePaid(loanId, indexId, collateralUnits, flatFeeNative);
    }

    function repayFromPosition(uint256 positionId, uint256 loanId) external payable nonReentrant {
        LibEqualIndexLending.IndexLoan storage loan = _requireLoan(loanId);
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        if (loan.positionKey != positionKey) {
            revert LibEqualIndexLending.PositionMismatch(loan.positionKey, positionKey);
        }

        Index storage idx = s().indexes[loan.indexId];
        (address[] memory assets, uint256[] memory principals) = _loanPrincipals(idx, loan.collateralUnits, loan.ltvBps);
        uint256 nativeDue = _sumForNative(assets, principals);

        LibCurrency.assertMsgValue(address(0), nativeDue);
        if (nativeDue > 0) {
            LibCurrency.pullAtLeast(address(0), msg.sender, nativeDue, nativeDue);
        }

        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            if (!LibCurrency.isNative(asset)) {
                LibCurrency.pullAtLeast(asset, msg.sender, principal, principal);
            }
            s().vaultBalances[loan.indexId][asset] += principal;
            ls.outstandingPrincipal[loan.indexId][asset] -= principal;
            emit LibEqualIndexLending.LoanAssetDelta(loanId, asset, principal, 0, false);
        }

        ls.lockedCollateralUnits[loan.indexId] -= loan.collateralUnits;

        uint256 indexPoolId = s().indexToPoolId[loan.indexId];
        _unencumberWithAci(LibAppStorage.s().pools[indexPoolId], positionKey, indexPoolId, loan.indexId, loan.collateralUnits);

        uint256 repaidIndexId = loan.indexId;
        delete ls.loans[loanId];
        emit LibEqualIndexLending.LoanRepaid(loanId, repaidIndexId);
    }

    function extendFromPosition(uint256 positionId, uint256 loanId, uint40 addedDuration)
        external
        payable
        nonReentrant
    {
        LibEqualIndexLending.IndexLoan storage loan = _requireLoan(loanId);
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        if (loan.positionKey != positionKey) {
            revert LibEqualIndexLending.PositionMismatch(loan.positionKey, positionKey);
        }
        if (block.timestamp > loan.maturity) {
            revert LibEqualIndexLending.LoanExpired(loanId, loan.maturity);
        }

        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(loan.indexId);
        uint256 newMaturity = uint256(loan.maturity) + addedDuration;
        uint256 maxAllowed = block.timestamp + cfg.maxDuration;
        if (newMaturity > maxAllowed) {
            revert LibEqualIndexLending.MaxDurationExceeded(uint40(newMaturity), uint40(maxAllowed));
        }

        uint256 flatFeeNative = _borrowFlatFee(loan.indexId, loan.collateralUnits);
        _collectFlatNativeFee(flatFeeNative);

        loan.maturity = uint40(newMaturity);
        emit LibEqualIndexLending.LoanExtended(loanId, loan.maturity, flatFeeNative);
        emit LibEqualIndexLending.LoanExtendFlatFeePaid(
            loanId, loan.indexId, loan.collateralUnits, addedDuration, flatFeeNative
        );
    }

    function recoverExpiredIndexLoan(uint256 loanId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();

        LibEqualIndexLending.IndexLoan memory loan = _loanSnapshot(loanId);
        if (block.timestamp <= loan.maturity) {
            revert LibEqualIndexLending.LoanNotExpired(loanId, loan.maturity);
        }

        uint256 writtenOffPrincipalTotal = _writeOffOutstanding(loanId, loan);
        _releaseRecoveredCollateral(loan);

        delete LibEqualIndexLending.s().loans[loanId];
        emit LibEqualIndexLending.LoanRecovered(loanId, loan.indexId, loan.collateralUnits, writtenOffPrincipalTotal);
    }

    function getLoan(uint256 loanId) external view returns (LibEqualIndexLending.IndexLoan memory) {
        return LibEqualIndexLending.s().loans[loanId];
    }

    function getOutstandingPrincipal(uint256 indexId, address asset)
        external
        view
        indexExists(indexId)
        returns (uint256)
    {
        return LibEqualIndexLending.s().outstandingPrincipal[indexId][asset];
    }

    function getLockedCollateralUnits(uint256 indexId) external view indexExists(indexId) returns (uint256) {
        return LibEqualIndexLending.s().lockedCollateralUnits[indexId];
    }

    function getLendingConfig(uint256 indexId)
        external
        view
        indexExists(indexId)
        returns (LibEqualIndexLending.LendingConfig memory)
    {
        return LibEqualIndexLending.s().lendingConfigs[indexId];
    }

    function economicBalance(uint256 indexId, address asset) external view indexExists(indexId) returns (uint256) {
        return LibEqualIndexLending.getEconomicBalance(indexId, asset, s().vaultBalances[indexId][asset]);
    }

    function maxBorrowable(uint256 indexId, address asset, uint256 collateralUnits)
        external
        view
        indexExists(indexId)
        returns (uint256)
    {
        if (collateralUnits == 0) return 0;
        if (collateralUnits % INDEX_SCALE != 0) revert InvalidParameterRange("collateralUnitsWhole");
        Index storage idx = s().indexes[indexId];
        (bool found, uint256 bundleAmount) = _bundleAmountForAsset(idx, asset);
        if (!found) revert LibEqualIndexLending.InvalidAsset(asset);

        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(indexId);
        uint256 collateralValue = Math.mulDiv(collateralUnits, bundleAmount, INDEX_SCALE);
        return Math.mulDiv(collateralValue, cfg.ltvBps, 10_000);
    }

    function quoteBorrowBasket(uint256 indexId, uint256 collateralUnits)
        external
        view
        indexExists(indexId)
        returns (address[] memory assets, uint256[] memory principals)
    {
        if (collateralUnits == 0) return (new address[](0), new uint256[](0));
        if (collateralUnits % INDEX_SCALE != 0) revert InvalidParameterRange("collateralUnitsWhole");
        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(indexId);
        return _loanPrincipals(s().indexes[indexId], collateralUnits, cfg.ltvBps);
    }

    function quoteBorrowFee(uint256 indexId, uint256 collateralUnits)
        external
        view
        indexExists(indexId)
        returns (uint256)
    {
        if (collateralUnits == 0) return 0;
        if (collateralUnits % INDEX_SCALE != 0) revert InvalidParameterRange("collateralUnitsWhole");
        return _borrowFlatFee(indexId, collateralUnits);
    }

    function getBorrowFeeTiers(uint256 indexId)
        external
        view
        indexExists(indexId)
        returns (uint256[] memory minCollateralUnits, uint256[] memory flatFeeNative)
    {
        LibEqualIndexLending.BorrowFeeTier[] storage tiers = LibEqualIndexLending.s().borrowFeeTiers[indexId];
        uint256 len = tiers.length;
        minCollateralUnits = new uint256[](len);
        flatFeeNative = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            minCollateralUnits[i] = tiers[i].minCollateralUnits;
            flatFeeNative[i] = tiers[i].flatFeeNative;
        }
    }

    function _bundleAmountForAsset(Index storage idx, address asset) private view returns (bool found, uint256 amount) {
        uint256 len = idx.assets.length;
        for (uint256 i = 0; i < len; i++) {
            if (idx.assets[i] == asset) {
                return (true, idx.bundleAmounts[i]);
            }
        }
        return (false, 0);
    }

    function _configuredLending(uint256 indexId) private view returns (LibEqualIndexLending.LendingConfig memory cfg) {
        cfg = LibEqualIndexLending.s().lendingConfigs[indexId];
        if (cfg.ltvBps == 0) {
            revert LibEqualIndexLending.LendingNotConfigured(indexId);
        }
    }

    function _validatedBorrowLtv(uint256 indexId, uint40 duration) private view returns (uint16 ltvBps) {
        LibEqualIndexLending.LendingConfig memory cfg = _configuredLending(indexId);
        if (duration < cfg.minDuration || duration > cfg.maxDuration) {
            revert LibEqualIndexLending.InvalidDuration(duration, cfg.minDuration, cfg.maxDuration);
        }
        return cfg.ltvBps;
    }

    function _requireLoan(uint256 loanId) private view returns (LibEqualIndexLending.IndexLoan storage loan) {
        loan = LibEqualIndexLending.s().loans[loanId];
        if (loan.collateralUnits == 0) revert LibEqualIndexLending.LoanNotFound(loanId);
    }

    function _loanSnapshot(uint256 loanId) private view returns (LibEqualIndexLending.IndexLoan memory loan) {
        LibEqualIndexLending.IndexLoan storage storedLoan = _requireLoan(loanId);
        loan = storedLoan;
    }

    function _loanPrincipals(Index storage idx, uint256 collateralUnits, uint16 ltvBps)
        private
        view
        returns (address[] memory assets, uint256[] memory principals)
    {
        assets = idx.assets;
        uint256 len = assets.length;
        principals = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 collateralValue = Math.mulDiv(collateralUnits, idx.bundleAmounts[i], INDEX_SCALE);
            principals[i] = Math.mulDiv(collateralValue, ltvBps, 10_000);
        }
    }

    function _borrowFlatFee(uint256 indexId, uint256 collateralUnits) private view returns (uint256 feeNative) {
        LibEqualIndexLending.BorrowFeeTier[] storage tiers = LibEqualIndexLending.s().borrowFeeTiers[indexId];
        uint256 len = tiers.length;
        if (len == 0) return 0;
        if (collateralUnits < tiers[0].minCollateralUnits) {
            revert InvalidParameterRange("collateralUnitsBelowFeeTier");
        }
        for (uint256 i = len; i > 0; i--) {
            LibEqualIndexLending.BorrowFeeTier storage tier = tiers[i - 1];
            if (collateralUnits >= tier.minCollateralUnits) {
                return tier.flatFeeNative;
            }
        }
        return 0;
    }

    function _collectFlatNativeFee(uint256 feeNative) private {
        if (feeNative == 0) {
            LibCurrency.assertZeroMsgValue();
            return;
        }
        if (msg.value != feeNative) {
            revert LibEqualIndexLending.FlatFeePaymentMismatch(feeNative, msg.value);
        }
        address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
        if (treasury == address(0)) revert LibEqualIndexLending.FlatFeeTreasuryNotSet();
        LibCurrency.transfer(address(0), treasury, feeNative);
    }

    function _sumForNative(address[] memory assets, uint256[] memory amounts) private pure returns (uint256 sum) {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            if (LibCurrency.isNative(assets[i])) {
                sum += amounts[i];
            }
        }
    }

    function _assertAvailableCollateral(
        Types.PoolData storage indexPool,
        bytes32 positionKey,
        uint256 indexPoolId,
        uint256 collateralUnits
    ) private view {
        uint256 availableCollateral = LibPositionHelpers.availablePrincipal(indexPool, positionKey, indexPoolId);
        if (availableCollateral < collateralUnits) {
            revert InsufficientUnencumberedPrincipal(collateralUnits, availableCollateral);
        }
    }

    function _prepareBorrow(Index storage idx, uint256 indexId, uint256 collateralUnits, uint16 ltvBps)
        private
        view
        returns (BorrowPreparation memory prep)
    {
        prep.lockedAfter = LibEqualIndexLending.s().lockedCollateralUnits[indexId] + collateralUnits;
        if (idx.totalUnits < prep.lockedAfter) {
            revert LibEqualIndexLending.RedeemabilityViolation(address(0), prep.lockedAfter, idx.totalUnits);
        }

        uint256 redeemableUnits = idx.totalUnits - prep.lockedAfter;
        (prep.assets, prep.principals) = _loanPrincipals(idx, collateralUnits, ltvBps);
        uint256 len = prep.assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = prep.assets[i];
            uint256 principal = prep.principals[i];
            uint256 vaultBalance = s().vaultBalances[indexId][asset];
            if (vaultBalance < principal) revert InsufficientPoolLiquidity(principal, vaultBalance);

            uint256 requiredVaultAfter = Math.mulDiv(redeemableUnits, idx.bundleAmounts[i], INDEX_SCALE);
            uint256 vaultAfter = vaultBalance - principal;
            if (vaultAfter < requiredVaultAfter) {
                revert LibEqualIndexLending.RedeemabilityViolation(asset, requiredVaultAfter, vaultAfter);
            }
        }
    }

    function _createLoan(
        uint256 indexId,
        bytes32 positionKey,
        uint256 collateralUnits,
        uint16 ltvBps,
        uint40 duration,
        uint256 lockedAfter
    ) private returns (uint256 loanId) {
        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        loanId = ls.nextLoanId;
        ls.nextLoanId = loanId + 1;
        ls.lockedCollateralUnits[indexId] = lockedAfter;
        ls.loans[loanId] = LibEqualIndexLending.IndexLoan({
            positionKey: positionKey,
            indexId: indexId,
            collateralUnits: collateralUnits,
            ltvBps: ltvBps,
            maturity: uint40(block.timestamp + duration)
        });
    }

    function _emitLoanCreated(
        uint256 loanId,
        bytes32 positionKey,
        uint256 indexId,
        uint256 collateralUnits,
        uint16 ltvBps
    ) private {
        emit LibEqualIndexLending.LoanCreated(
            loanId, positionKey, indexId, collateralUnits, ltvBps, LibEqualIndexLending.s().loans[loanId].maturity
        );
    }

    function _disburseBorrowedAssets(
        uint256 loanId,
        uint256 indexId,
        address[] memory assets,
        uint256[] memory principals
    ) private {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            if (app.assetToPoolId[asset] == 0) revert NoPoolForAsset(asset);

            ls.outstandingPrincipal[indexId][asset] += principal;
            s().vaultBalances[indexId][asset] -= principal;

            if (principal > 0) {
                if (LibCurrency.isNative(asset)) {
                    app.nativeTrackedTotal -= principal;
                }
                LibCurrency.transfer(asset, msg.sender, principal);
            }
            emit LibEqualIndexLending.LoanAssetDelta(loanId, asset, principal, 0, true);
        }
    }

    function _writeOffOutstanding(uint256 loanId, LibEqualIndexLending.IndexLoan memory loan)
        private
        returns (uint256 writtenOffPrincipalTotal)
    {
        Index storage idx = s().indexes[loan.indexId];
        (address[] memory assets, uint256[] memory principals) = _loanPrincipals(idx, loan.collateralUnits, loan.ltvBps);
        LibEqualIndexLending.LendingStorage storage ls = LibEqualIndexLending.s();
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 principal = principals[i];
            ls.outstandingPrincipal[loan.indexId][assets[i]] -= principal;
            writtenOffPrincipalTotal += principal;
            emit LibEqualIndexLending.LoanAssetDelta(loanId, assets[i], principal, 0, false);
        }
        ls.lockedCollateralUnits[loan.indexId] -= loan.collateralUnits;
    }

    function _releaseRecoveredCollateral(LibEqualIndexLending.IndexLoan memory loan) private {
        Index storage idx = s().indexes[loan.indexId];
        idx.totalUnits -= loan.collateralUnits;
        IndexToken(idx.token).burnIndexUnits(address(this), loan.collateralUnits);

        uint256 indexPoolId = s().indexToPoolId[loan.indexId];
        Types.PoolData storage indexPool = LibAppStorage.s().pools[indexPoolId];
        uint256 principalBefore =
            LibEqualIndexRewards.settleBeforeEligibleBalanceChange(loan.indexId, indexPoolId, loan.positionKey);
        if (principalBefore < loan.collateralUnits) {
            revert InsufficientPrincipal(loan.collateralUnits, principalBefore);
        }
        uint256 principalAfter = principalBefore - loan.collateralUnits;
        indexPool.userPrincipal[loan.positionKey] = principalAfter;
        indexPool.totalDeposits -= loan.collateralUnits;
        if (indexPool.trackedBalance < loan.collateralUnits) {
            revert InsufficientPrincipal(loan.collateralUnits, indexPool.trackedBalance);
        }
        indexPool.trackedBalance -= loan.collateralUnits;
        if (principalBefore > 0 && principalAfter == 0 && indexPool.userCount > 0) {
            indexPool.userCount -= 1;
        }
        indexPool.userFeeIndex[loan.positionKey] = indexPool.feeIndex;
        indexPool.userMaintenanceIndex[loan.positionKey] = indexPool.maintenanceIndex;
        LibEqualIndexRewards.syncEligibleBalanceChange(loan.indexId);

        _unencumberWithAci(indexPool, loan.positionKey, indexPoolId, loan.indexId, loan.collateralUnits);
    }

    function _encumberWithAci(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 poolId,
        uint256 indexId,
        uint256 amount
    )
        private
    {
        LibIndexEncumbrance.encumber(positionKey, poolId, indexId, amount);
        if (amount == 0) {
            return;
        }
        LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
    }

    function _unencumberWithAci(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 poolId,
        uint256 indexId,
        uint256 amount
    )
        private
    {
        LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, amount);
        LibActiveCreditIndex.applyEncumbranceDecrease(pool, poolId, positionKey, amount);
    }
}
