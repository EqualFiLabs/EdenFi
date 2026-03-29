// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {BasketToken} from "../tokens/BasketToken.sol";
import {EdenLendingLogic} from "./EdenLendingLogic.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibEdenLendingStorage} from "../libraries/LibEdenLendingStorage.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibModuleEncumbrance} from "../libraries/LibModuleEncumbrance.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

contract EdenLendingFacet is EdenLendingLogic, ReentrancyGuardModifiers {
    error InvalidDuration(uint256 provided, uint256 minDuration, uint256 maxDuration);
    error InvalidTierConfiguration();
    error UnexpectedNativeFee(uint256 expected, uint256 actual);
    error InsufficientVaultBalance(address asset, uint256 expected, uint256 actual);
    error RedeemabilityInvariantBroken(address asset, uint256 required, uint256 remaining);
    error LoanNotFound(uint256 loanId);
    error LoanExpired(uint256 loanId, uint40 maturity);
    error LoanNotExpired(uint256 loanId, uint40 maturity);
    error BelowMinimumTier(uint256 collateralUnits);
    error PositionMismatch(bytes32 expected, bytes32 actual);

    event LendingConfigUpdated(
        uint256 indexed productId,
        uint40 minDuration,
        uint40 maxDuration,
        uint16 ltvBps
    );
    event BorrowFeeTiersUpdated(
        uint256 indexed productId,
        uint256[] minCollateralUnits,
        uint256[] flatFeeNative
    );
    event LoanCreated(
        uint256 indexed loanId,
        uint256 indexed productId,
        bytes32 indexed borrowerPositionKey,
        uint256 collateralUnits,
        address[] assets,
        uint256[] principals,
        uint16 ltvBps,
        uint40 maturity
    );
    event LoanRepaid(uint256 indexed loanId, bytes32 indexed borrowerPositionKey);
    event LoanExtended(uint256 indexed loanId, uint40 newMaturity, uint256 feeNative);
    event LoanRecovered(
        uint256 indexed loanId,
        bytes32 indexed borrowerPositionKey,
        uint256 collateralUnits,
        address[] assets,
        uint256[] principals
    );

    function borrow(
        uint256 positionId,
        uint256 collateralUnits,
        uint40 duration
    ) external payable nonReentrant basketExists(LibEdenBasketStorage.PRODUCT_ID) returns (uint256 loanId) {
        if (collateralUnits == 0 || collateralUnits % UNIT_SCALE != 0) revert InvalidUnits();

        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        uint256 nativeFee = _checkBorrowRequest(positionKey, collateralUnits, duration);
        _requireNativeFee(nativeFee);

        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, collateralUnits, LibEdenLendingStorage.DEFAULT_LTV_BPS);
        _enforceBorrowInvariantForNewLoan(collateralUnits, assets, principals);

        uint40 maturity = uint40(block.timestamp + duration);
        lending.lockedCollateralUnits += collateralUnits;

        loanId = lending.nextLoanId;
        lending.nextLoanId = loanId + 1;
        lending.loans[loanId] = LibEdenLendingStorage.Loan({
            borrowerPositionKey: positionKey,
            collateralUnits: collateralUnits,
            ltvBps: LibEdenLendingStorage.DEFAULT_LTV_BPS,
            maturity: maturity
        });
        lending.borrowerLoanIds[positionKey].push(loanId);
        lending.loanCreatedAt[loanId] = block.timestamp;

        LibPoolMembership._ensurePoolMembership(positionKey, basket.poolId, true);
        LibModuleEncumbrance.encumber(positionKey, basket.poolId, _loanModuleId(loanId), collateralUnits);

        _executeBorrowPayouts(assets, principals, msg.sender);
        _forwardNativeFee(nativeFee);

        emit LoanCreated(
            loanId,
            LibEdenBasketStorage.PRODUCT_ID,
            positionKey,
            collateralUnits,
            assets,
            principals,
            LibEdenLendingStorage.DEFAULT_LTV_BPS,
            maturity
        );
    }

    function repay(uint256 positionId, uint256 loanId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrowerPositionKey == bytes32(0) || lending.loanClosed[loanId]) revert LoanNotFound(loanId);
        if (loan.borrowerPositionKey != positionKey) revert PositionMismatch(loan.borrowerPositionKey, positionKey);

        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        LibEdenBasketStorage.ProductConfig storage basket = store.product;
        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, loan.collateralUnits, loan.ltvBps);

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 principal = principals[i];
            uint256 received = LibCurrency.pullAtLeast(asset, msg.sender, principal, principal);
            store.accounting.vaultBalances[asset] += received;
            lending.outstandingPrincipal[asset] -= principal;
        }

        lending.lockedCollateralUnits -= loan.collateralUnits;
        LibModuleEncumbrance.unencumber(positionKey, basket.poolId, _loanModuleId(loanId), loan.collateralUnits);

        lending.loanClosed[loanId] = true;
        lending.loanClosedAt[loanId] = block.timestamp;
        lending.loanCloseReason[loanId] = 1;

        emit LoanRepaid(loanId, positionKey);
    }

    function extend(uint256 positionId, uint256 loanId, uint40 addedDuration) external payable nonReentrant {
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        (uint40 newMaturity, uint256 feeNative) =
            _validateAndQuoteExtension(lending, loanId, addedDuration, positionKey);
        _requireNativeFee(feeNative);

        lending.loans[loanId].maturity = newMaturity;
        _forwardNativeFee(feeNative);

        emit LoanExtended(loanId, newMaturity, feeNative);
    }

    function recoverExpired(uint256 loanId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();

        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrowerPositionKey == bytes32(0) || lending.loanClosed[loanId]) revert LoanNotFound(loanId);
        if (block.timestamp <= loan.maturity) revert LoanNotExpired(loanId, loan.maturity);

        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        LibEdenBasketStorage.ProductConfig storage basket = store.product;
        Types.PoolData storage basketPool = LibAppStorage.s().pools[basket.poolId];
        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, loan.collateralUnits, loan.ltvBps);

        LibPoolMembership._ensurePoolMembership(loan.borrowerPositionKey, basket.poolId, true);
        LibActiveCreditIndex.settle(basket.poolId, loan.borrowerPositionKey);
        LibFeeIndex.settle(basket.poolId, loan.borrowerPositionKey);
        _settleRecoveredStEVE(loan.borrowerPositionKey, loan.collateralUnits);

        uint256 currentPrincipal = basketPool.userPrincipal[loan.borrowerPositionKey];
        if (loan.collateralUnits > currentPrincipal) {
            revert InsufficientPrincipal(loan.collateralUnits, currentPrincipal);
        }

        lending.lockedCollateralUnits -= loan.collateralUnits;
        LibModuleEncumbrance.unencumber(
            loan.borrowerPositionKey, basket.poolId, _loanModuleId(loanId), loan.collateralUnits
        );

        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            lending.outstandingPrincipal[assets[i]] -= principals[i];
        }

        uint256 newPrincipal = currentPrincipal - loan.collateralUnits;
        basketPool.userPrincipal[loan.borrowerPositionKey] = newPrincipal;
        basketPool.totalDeposits -= loan.collateralUnits;
        basketPool.trackedBalance -= loan.collateralUnits;
        if (currentPrincipal > 0 && newPrincipal == 0 && basketPool.userCount > 0) {
            basketPool.userCount -= 1;
        }
        basketPool.userFeeIndex[loan.borrowerPositionKey] = basketPool.feeIndex;
        basketPool.userMaintenanceIndex[loan.borrowerPositionKey] = basketPool.maintenanceIndex;

        basket.totalUnits -= loan.collateralUnits;
        BasketToken(basket.token).burnIndexUnits(address(this), loan.collateralUnits);

        _enforcePostRecoveryInvariant(basket, lending.lockedCollateralUnits, basket.totalUnits);

        lending.loanClosed[loanId] = true;
        lending.loanClosedAt[loanId] = block.timestamp;
        lending.loanCloseReason[loanId] = 2;

        emit LoanRecovered(loanId, loan.borrowerPositionKey, loan.collateralUnits, assets, principals);
    }

    function configureLending(uint40 minDuration, uint40 maxDuration)
        external
        nonReentrant
        basketExists(LibEdenBasketStorage.PRODUCT_ID)
    {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();
        if (minDuration == 0 || maxDuration < minDuration) {
            revert InvalidDuration(0, minDuration, maxDuration);
        }

        LibEdenLendingStorage.s().lendingConfig =
            LibEdenLendingStorage.LendingConfig({minDuration: minDuration, maxDuration: maxDuration});
        emit LendingConfigUpdated(
            LibEdenBasketStorage.PRODUCT_ID, minDuration, maxDuration, LibEdenLendingStorage.DEFAULT_LTV_BPS
        );
    }

    function configureBorrowFeeTiers(
        uint256[] calldata minCollateralUnits,
        uint256[] calldata flatFeeNative
    ) external nonReentrant basketExists(LibEdenBasketStorage.PRODUCT_ID) {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        uint256 len = minCollateralUnits.length;
        if (len == 0 || len != flatFeeNative.length) revert InvalidArrayLength();

        LibEdenLendingStorage.BorrowFeeTier[] storage tiers = LibEdenLendingStorage.s().borrowFeeTiers;
        while (tiers.length > 0) {
            tiers.pop();
        }

        uint256 previousMin = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 currentMin = minCollateralUnits[i];
            if (currentMin == 0 || (i > 0 && currentMin <= previousMin)) revert InvalidTierConfiguration();
            tiers.push(
                LibEdenLendingStorage.BorrowFeeTier({
                    minCollateralUnits: currentMin,
                    flatFeeNative: flatFeeNative[i]
                })
            );
            previousMin = currentMin;
        }

        emit BorrowFeeTiersUpdated(LibEdenBasketStorage.PRODUCT_ID, minCollateralUnits, flatFeeNative);
    }

    function loanCount() external view returns (uint256) {
        return LibEdenLendingStorage.s().nextLoanId;
    }

    function borrowerLoanCount(uint256 positionId) external view returns (uint256) {
        return LibEdenLendingStorage.s().borrowerLoanIds[LibPositionHelpers.positionKey(positionId)].length;
    }

    function getLoanView(uint256 loanId) public view returns (LoanView memory) {
        return _getLoanView(loanId);
    }

    function getLoanIdsByBorrower(uint256 positionId) public view returns (uint256[] memory) {
        return _loanIdsByBorrower(positionId);
    }

    function getActiveLoanIdsByBorrower(uint256 positionId) public view returns (uint256[] memory) {
        return _activeLoanIdsByBorrower(positionId);
    }

    function getLoansByBorrower(uint256 positionId) external view returns (LoanView[] memory loans) {
        uint256[] memory loanIds = _loanIdsByBorrower(positionId);
        uint256 len = loanIds.length;
        loans = new LoanView[](len);
        for (uint256 i = 0; i < len; i++) {
            loans[i] = _getLoanView(loanIds[i]);
        }
    }

    function getActiveLoansByBorrower(uint256 positionId) external view returns (LoanView[] memory loans) {
        uint256[] memory loanIds = _activeLoanIdsByBorrower(positionId);
        uint256 len = loanIds.length;
        loans = new LoanView[](len);
        for (uint256 i = 0; i < len; i++) {
            loans[i] = _getLoanView(loanIds[i]);
        }
    }

    function getLoanIdsByBorrowerPaginated(uint256 positionId, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory)
    {
        return _sliceLoanIds(
            LibEdenLendingStorage.s().borrowerLoanIds[LibPositionHelpers.positionKey(positionId)], start, limit
        );
    }

    function getActiveLoanIdsByBorrowerPaginated(uint256 positionId, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory)
    {
        return _activeLoanIdsByBorrowerPaginated(positionId, start, limit);
    }

    function previewBorrow(uint256 positionId, uint256 collateralUnits, uint40 duration)
        external
        view
        basketExists(LibEdenBasketStorage.PRODUCT_ID)
        returns (BorrowPreview memory preview)
    {
        if (collateralUnits == 0 || collateralUnits % UNIT_SCALE != 0) revert InvalidUnits();

        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        _validateDuration(lending.lendingConfig, duration);

        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, collateralUnits, LibEdenLendingStorage.DEFAULT_LTV_BPS);
        uint256 availableCollateral = _availableCollateral(positionKey, basket.poolId);
        uint256 resultingLockedCollateral = lending.lockedCollateralUnits + collateralUnits;

        preview.productId = LibEdenBasketStorage.PRODUCT_ID;
        preview.collateralUnits = collateralUnits;
        preview.duration = duration;
        preview.assets = assets;
        preview.principals = principals;
        preview.feeNative = _selectBorrowFeeTier(lending.borrowFeeTiers, collateralUnits).flatFeeNative;
        preview.maturity = uint40(block.timestamp + duration);
        preview.availableCollateral = availableCollateral;
        preview.resultingLockedCollateral = resultingLockedCollateral;
        preview.invariantSatisfied = collateralUnits <= availableCollateral
            && _redeemabilityInvariantSatisfied(basket, assets, principals, resultingLockedCollateral, basket.totalUnits);
    }

    function previewRepay(uint256 positionId, uint256 loanId) external view returns (RepayPreview memory preview) {
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrowerPositionKey == bytes32(0) || lending.loanClosed[loanId]) revert LoanNotFound(loanId);

        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        if (loan.borrowerPositionKey != positionKey) revert PositionMismatch(loan.borrowerPositionKey, positionKey);

        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(LibEdenBasketStorage.s().product, loan.collateralUnits, loan.ltvBps);
        preview = RepayPreview({
            loanId: loanId,
            assets: assets,
            principals: principals,
            unlockedCollateralUnits: loan.collateralUnits
        });
    }

    function previewExtend(uint256 positionId, uint256 loanId, uint40 addedDuration)
        external
        view
        returns (ExtendPreview memory preview)
    {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        (uint40 newMaturity, uint256 feeNative) =
            _validateAndQuoteExtension(LibEdenLendingStorage.s(), loanId, addedDuration, positionKey);

        preview = ExtendPreview({
            loanId: loanId,
            addedDuration: addedDuration,
            newMaturity: newMaturity,
            feeNative: feeNative
        });
    }

    function getOutstandingPrincipal(address asset) external view returns (uint256) {
        return LibEdenLendingStorage.s().outstandingPrincipal[asset];
    }

    function getLockedCollateralUnits() external view returns (uint256) {
        return LibEdenLendingStorage.s().lockedCollateralUnits;
    }
}
