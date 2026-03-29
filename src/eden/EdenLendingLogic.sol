// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EdenBasketBase} from "./EdenBasketBase.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibEdenLendingStorage} from "../libraries/LibEdenLendingStorage.sol";
import {LibEdenRewards} from "../libraries/LibEdenRewards.sol";
import {LibEdenStEVEStorage} from "../libraries/LibEdenStEVEStorage.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

import {IEdenLendingErrors} from "./IEdenLendingErrors.sol";

abstract contract EdenLendingLogic is EdenBasketBase {
    uint256 internal constant BASIS_POINTS = 10_000;

    struct LoanView {
        uint256 loanId;
        bytes32 borrowerPositionKey;
        uint256 productId;
        uint256 collateralUnits;
        uint16 ltvBps;
        uint40 maturity;
        uint256 createdAt;
        uint256 closedAt;
        uint8 closeReason;
        bool active;
        bool expired;
        address[] assets;
        uint256[] principals;
        uint256 extensionFeeNative;
    }

    struct BorrowPreview {
        uint256 productId;
        uint256 collateralUnits;
        uint40 duration;
        address[] assets;
        uint256[] principals;
        uint256 feeNative;
        uint40 maturity;
        uint256 availableCollateral;
        uint256 resultingLockedCollateral;
        bool invariantSatisfied;
    }

    struct RepayPreview {
        uint256 loanId;
        address[] assets;
        uint256[] principals;
        uint256 unlockedCollateralUnits;
    }

    struct ExtendPreview {
        uint256 loanId;
        uint40 addedDuration;
        uint40 newMaturity;
        uint256 feeNative;
    }

    function _getLoanView(uint256 loanId) internal view returns (LoanView memory loanView) {
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrowerPositionKey == bytes32(0)) revert IEdenLendingErrors.LoanNotFound(loanId);

        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, loan.collateralUnits, loan.ltvBps);
        (bool hasTier, uint256 extensionFeeNative) = _findBorrowFeeTier(lending.borrowFeeTiers, loan.collateralUnits);

        bool closed = lending.loanClosed[loanId];
        bool expired = block.timestamp > loan.maturity;
        loanView = LoanView({
            loanId: loanId,
            borrowerPositionKey: loan.borrowerPositionKey,
            productId: LibEdenBasketStorage.PRODUCT_ID,
            collateralUnits: loan.collateralUnits,
            ltvBps: loan.ltvBps,
            maturity: loan.maturity,
            createdAt: lending.loanCreatedAt[loanId],
            closedAt: lending.loanClosedAt[loanId],
            closeReason: lending.loanCloseReason[loanId],
            active: !closed && !expired,
            expired: expired,
            assets: assets,
            principals: principals,
            extensionFeeNative: hasTier ? extensionFeeNative : 0
        });
    }

    function _loanIdsByBorrower(uint256 positionId) internal view returns (uint256[] memory) {
        return _sliceLoanIds(
            LibEdenLendingStorage.s().borrowerLoanIds[LibPositionHelpers.positionKey(positionId)], 0, type(uint256).max
        );
    }

    function _activeLoanIdsByBorrower(uint256 positionId) internal view returns (uint256[] memory loanIds) {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        uint256[] storage allLoanIds = lending.borrowerLoanIds[positionKey];
        uint256 len = allLoanIds.length;
        uint256 activeCount;

        for (uint256 i = 0; i < len; i++) {
            LibEdenLendingStorage.Loan storage loan = lending.loans[allLoanIds[i]];
            if (_isActiveLoan(lending, allLoanIds[i], loan)) {
                activeCount++;
            }
        }

        loanIds = new uint256[](activeCount);
        uint256 index;
        for (uint256 i = 0; i < len; i++) {
            uint256 loanId = allLoanIds[i];
            LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
            if (_isActiveLoan(lending, loanId, loan)) {
                loanIds[index++] = loanId;
            }
        }
    }

    function _activeLoanIdsByBorrowerPaginated(uint256 positionId, uint256 start, uint256 limit)
        internal
        view
        returns (uint256[] memory loanIds)
    {
        if (limit == 0) return new uint256[](0);

        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        uint256[] storage allLoanIds = lending.borrowerLoanIds[positionKey];
        uint256 len = allLoanIds.length;
        uint256 activeCount;

        for (uint256 i = 0; i < len; i++) {
            LibEdenLendingStorage.Loan storage loan = lending.loans[allLoanIds[i]];
            if (_isActiveLoan(lending, allLoanIds[i], loan)) {
                activeCount++;
            }
        }

        if (start >= activeCount) return new uint256[](0);

        uint256 remaining = activeCount - start;
        uint256 resultLen = remaining < limit ? remaining : limit;
        loanIds = new uint256[](resultLen);

        uint256 activeIndex;
        uint256 resultIndex;
        for (uint256 i = 0; i < len && resultIndex < resultLen; i++) {
            uint256 loanId = allLoanIds[i];
            LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
            if (!_isActiveLoan(lending, loanId, loan)) continue;
            if (activeIndex++ < start) continue;
            loanIds[resultIndex++] = loanId;
        }
    }

    function _availableCollateral(bytes32 positionKey, uint256 basketPoolId) internal view returns (uint256 available) {
        Types.PoolData storage basketPool = LibAppStorage.s().pools[basketPoolId];
        uint256 currentPrincipal = basketPool.userPrincipal[positionKey];
        uint256 totalEncumbered = basketPool.userSameAssetDebt[positionKey];
        uint256 encumbrance = LibEncumbrance.total(positionKey, basketPoolId);
        if (encumbrance > totalEncumbered) {
            totalEncumbered = encumbrance;
        }
        if (totalEncumbered > currentPrincipal) return 0;
        return currentPrincipal - totalEncumbered;
    }

    function _checkBorrowRequest(
        bytes32 positionKey,
        uint256 collateralUnits,
        uint40 duration
    ) internal view returns (uint256 nativeFee) {
        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        if (basket.paused) revert IndexPaused(LibEdenBasketStorage.PRODUCT_ID);

        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        _validateDuration(lending.lendingConfig, duration);

        uint256 availableCollateral = _availableCollateral(positionKey, basket.poolId);
        if (collateralUnits > availableCollateral) {
            revert InsufficientPrincipal(collateralUnits, availableCollateral);
        }

        nativeFee = _selectBorrowFeeTier(lending.borrowFeeTiers, collateralUnits).flatFeeNative;
    }

    function _enforceBorrowInvariantForNewLoan(
        uint256 collateralUnits,
        address[] memory assets,
        uint256[] memory principals
    ) internal view {
        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        _enforceRedeemabilityInvariant(
            basket,
            assets,
            principals,
            LibEdenLendingStorage.s().lockedCollateralUnits + collateralUnits,
            basket.totalUnits
        );
    }

    function _validateDuration(LibEdenLendingStorage.LendingConfig memory config, uint40 duration) internal pure {
        if (
            duration == 0 || config.minDuration == 0 || duration < config.minDuration
                || duration > config.maxDuration
        ) {
            revert IEdenLendingErrors.InvalidDuration(duration, config.minDuration, config.maxDuration);
        }
    }

    function _validateAndQuoteExtension(
        LibEdenLendingStorage.LendingStorage storage lending,
        uint256 loanId,
        uint40 addedDuration,
        bytes32 expectedBorrowerPositionKey
    ) internal view returns (uint40 newMaturity, uint256 feeNative) {
        LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrowerPositionKey == bytes32(0) || lending.loanClosed[loanId]) {
            revert IEdenLendingErrors.LoanNotFound(loanId);
        }
        if (loan.borrowerPositionKey != expectedBorrowerPositionKey) {
            revert IEdenLendingErrors.PositionMismatch(loan.borrowerPositionKey, expectedBorrowerPositionKey);
        }
        if (block.timestamp > loan.maturity) revert IEdenLendingErrors.LoanExpired(loanId, loan.maturity);

        LibEdenLendingStorage.LendingConfig memory config = lending.lendingConfig;
        if (addedDuration == 0 || config.maxDuration == 0) {
            revert IEdenLendingErrors.InvalidDuration(addedDuration, config.minDuration, config.maxDuration);
        }

        uint256 extendedMaturity = uint256(loan.maturity) + addedDuration;
        uint256 maxAllowedMaturity = block.timestamp + config.maxDuration;
        if (extendedMaturity > maxAllowedMaturity) {
            revert IEdenLendingErrors.InvalidDuration(addedDuration, config.minDuration, config.maxDuration);
        }

        newMaturity = uint40(extendedMaturity);
        feeNative = _selectBorrowFeeTier(lending.borrowFeeTiers, loan.collateralUnits).flatFeeNative;
    }

    function _executeBorrowPayouts(
        address[] memory assets,
        uint256[] memory principals,
        address recipient
    ) internal {
        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            store.accounting.vaultBalances[asset] -= principal;
            lending.outstandingPrincipal[asset] += principal;
            LibCurrency.transfer(asset, recipient, principal);
        }
    }

    function _selectBorrowFeeTier(
        LibEdenLendingStorage.BorrowFeeTier[] storage tiers,
        uint256 collateralUnits
    ) internal view returns (LibEdenLendingStorage.BorrowFeeTier memory tier) {
        uint256 len = tiers.length;
        if (len == 0) revert IEdenLendingErrors.BelowMinimumTier(collateralUnits);

        bool found;
        for (uint256 i = 0; i < len; i++) {
            if (collateralUnits >= tiers[i].minCollateralUnits) {
                tier = tiers[i];
                found = true;
            } else {
                break;
            }
        }

        if (!found) revert IEdenLendingErrors.BelowMinimumTier(collateralUnits);
    }

    function _findBorrowFeeTier(
        LibEdenLendingStorage.BorrowFeeTier[] storage tiers,
        uint256 collateralUnits
    ) internal view returns (bool found, uint256 flatFeeNative) {
        uint256 len = tiers.length;
        for (uint256 i = 0; i < len; i++) {
            if (collateralUnits >= tiers[i].minCollateralUnits) {
                found = true;
                flatFeeNative = tiers[i].flatFeeNative;
            } else {
                break;
            }
        }
    }

    function _deriveLoanPrincipals(
        LibEdenBasketStorage.ProductConfig storage basket,
        uint256 collateralUnits,
        uint16 ltvBps
    ) internal view returns (address[] memory assets, uint256[] memory principals) {
        uint256 len = basket.assets.length;
        assets = new address[](len);
        principals = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            assets[i] = basket.assets[i];
            principals[i] =
                Math.mulDiv(collateralUnits, basket.bundleAmounts[i] * ltvBps, UNIT_SCALE * BASIS_POINTS);
        }
    }

    function _sliceLoanIds(uint256[] storage source, uint256 start, uint256 limit)
        internal
        view
        returns (uint256[] memory loanIds)
    {
        uint256 len = source.length;
        if (start >= len || limit == 0) return new uint256[](0);

        uint256 remaining = len - start;
        uint256 resultLen = remaining < limit ? remaining : limit;
        loanIds = new uint256[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            loanIds[i] = source[start + i];
        }
    }

    function _isActiveLoan(
        LibEdenLendingStorage.LendingStorage storage lending,
        uint256 loanId,
        LibEdenLendingStorage.Loan storage loan
    ) internal view returns (bool) {
        return loan.borrowerPositionKey != bytes32(0) && !lending.loanClosed[loanId] && block.timestamp <= loan.maturity;
    }

    function _redeemabilityInvariantSatisfied(
        LibEdenBasketStorage.ProductConfig storage basket,
        address[] memory assets,
        uint256[] memory principals,
        uint256 lockedCollateralUnits,
        uint256 totalUnits
    ) internal view returns (bool) {
        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        uint256 redeemableSupply = totalUnits - lockedCollateralUnits;
        uint256 len = assets.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 currentVault = store.accounting.vaultBalances[assets[i]];
            if (currentVault < principals[i]) return false;

            uint256 remainingVault = currentVault - principals[i];
            uint256 requiredVault = Math.mulDiv(redeemableSupply, basket.bundleAmounts[i], UNIT_SCALE);
            if (remainingVault < requiredVault) return false;
        }

        return true;
    }

    function _enforceRedeemabilityInvariant(
        LibEdenBasketStorage.ProductConfig storage basket,
        address[] memory assets,
        uint256[] memory principals,
        uint256 lockedCollateralUnits,
        uint256 totalUnits
    ) internal view {
        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        uint256 redeemableSupply = totalUnits - lockedCollateralUnits;
        uint256 len = assets.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 currentVault = store.accounting.vaultBalances[assets[i]];
            if (currentVault < principals[i]) {
                revert IEdenLendingErrors.InsufficientVaultBalance(assets[i], principals[i], currentVault);
            }

            uint256 remainingVault = currentVault - principals[i];
            uint256 requiredVault = Math.mulDiv(redeemableSupply, basket.bundleAmounts[i], UNIT_SCALE);
            if (remainingVault < requiredVault) {
                revert IEdenLendingErrors.RedeemabilityInvariantBroken(assets[i], requiredVault, remainingVault);
            }
        }
    }

    function _enforcePostRecoveryInvariant(
        LibEdenBasketStorage.ProductConfig storage basket,
        uint256 lockedCollateralUnits,
        uint256 totalUnits
    ) internal view {
        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        uint256 redeemableSupply = totalUnits - lockedCollateralUnits;
        uint256 len = basket.assets.length;

        for (uint256 i = 0; i < len; i++) {
            address asset = basket.assets[i];
            uint256 currentVault = store.accounting.vaultBalances[asset];
            uint256 requiredVault = Math.mulDiv(redeemableSupply, basket.bundleAmounts[i], UNIT_SCALE);
            if (currentVault < requiredVault) {
                revert IEdenLendingErrors.RedeemabilityInvariantBroken(asset, requiredVault, currentVault);
            }
        }
    }

    function _settleRecoveredStEVE(bytes32 positionKey, uint256 amount) internal {
        LibEdenStEVEStorage.StEVEStorage storage steve = LibEdenStEVEStorage.s();
        if (!steve.configured) return;

        uint256 eligible = steve.eligiblePrincipal[positionKey];
        if (amount > eligible) revert InsufficientPrincipal(amount, eligible);

        LibEdenRewards.settlePositionRewards(positionKey);
        steve.eligiblePrincipal[positionKey] = eligible - amount;
        steve.eligibleSupply -= amount;
    }

    function _loanModuleId(uint256 loanId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("EDEN_LOAN", loanId)));
    }

    function _requireNativeFee(uint256 expected) internal view {
        if (msg.value != expected) revert IEdenLendingErrors.UnexpectedNativeFee(expected, msg.value);
    }

    function _forwardNativeFee(uint256 amount) internal {
        if (amount == 0) return;

        address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
        if (treasury == address(0)) revert TreasuryNotSet();
        LibCurrency.transfer(address(0), treasury, amount);
    }
}
