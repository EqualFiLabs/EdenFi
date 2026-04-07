// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";
import {LibAccess} from "src/libraries/LibAccess.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibOptionTokenStorage} from "src/libraries/LibOptionTokenStorage.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {ReentrancyGuardModifiers} from "src/libraries/LibReentrancyGuard.sol";
import {Types} from "src/libraries/Types.sol";
import {
    InsufficientPrincipal,
    InvalidParameterRange,
    PoolMembershipRequired,
    Unauthorized
} from "src/libraries/Errors.sol";

/// @notice Greenfield covered-options lifecycle built on the current EqualFi substrate.
contract OptionsFacet is ReentrancyGuardModifiers {
    error Options_Paused();
    error Options_InvalidAmount(uint256 amount);
    error Options_InvalidContractSize(uint256 contractSize);
    error Options_InvalidPrice(uint256 strikePrice);
    error Options_InvalidExpiry(uint64 expiry);
    error Options_InvalidPool(uint256 poolId);
    error Options_InvalidAssetPair(address underlying, address strike);
    error Options_InvalidSeries(uint256 seriesId);
    error Options_ExerciseWindowClosed(uint256 seriesId);
    error Options_Reclaimed(uint256 seriesId);
    error Options_NotReclaimed(uint256 seriesId);
    error Options_NotTokenHolder(address caller, uint256 seriesId);
    error Options_InvalidRecipient(address recipient);
    error Options_InsufficientBalance(address holder, uint256 required, uint256 available);
    error Options_TokenNotSet();

    event OptionSeriesCreated(
        uint256 indexed seriesId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
        uint256 underlyingPoolId,
        uint256 strikePoolId,
        address underlyingAsset,
        address strikeAsset,
        uint256 strikePrice,
        uint64 expiry,
        uint256 totalSize,
        uint256 contractSize,
        uint256 collateralLocked,
        bool isCall,
        bool isAmerican
    );
    event OptionsExercised(
        uint256 indexed seriesId,
        address indexed holder,
        address indexed recipient,
        uint256 amount,
        uint256 paymentAmount,
        uint256 collateralDelivered
    );
    event OptionsReclaimed(
        uint256 indexed seriesId, bytes32 indexed makerPositionKey, uint256 remainingSize, uint256 collateralUnlocked
    );
    event ReclaimedOptionClaimsBurned(uint256 indexed seriesId, address indexed holder, uint256 amount);
    event OptionsPausedUpdated(bool paused);
    event EuropeanToleranceUpdated(uint64 toleranceSeconds);

    function createOptionSeries(LibOptionsStorage.CreateOptionSeriesParams calldata params)
        external
        nonReentrant
        returns (uint256 seriesId)
    {
        LibCurrency.assertZeroMsgValue();
        LibOptionsStorage.OptionsStorage storage store = LibOptionsStorage.s();
        if (store.paused) revert Options_Paused();
        if (params.totalSize == 0) revert Options_InvalidAmount(params.totalSize);
        if (params.contractSize == 0) revert Options_InvalidContractSize(params.contractSize);
        if (params.strikePrice == 0) revert Options_InvalidPrice(params.strikePrice);
        if (params.expiry <= block.timestamp) revert Options_InvalidExpiry(params.expiry);
        if (params.underlyingPoolId == params.strikePoolId) revert Options_InvalidPool(params.underlyingPoolId);

        address makerOwner = LibPositionHelpers.requireOwnership(params.positionId);
        bytes32 makerPositionKey = LibPositionHelpers.positionKey(params.positionId);

        Types.PoolData storage underlyingPool = LibPositionHelpers.pool(params.underlyingPoolId);
        Types.PoolData storage strikePool = LibPositionHelpers.pool(params.strikePoolId);
        address underlyingAsset = underlyingPool.underlying;
        address strikeAsset = strikePool.underlying;
        if (underlyingAsset == strikeAsset) {
            revert Options_InvalidAssetPair(underlyingAsset, strikeAsset);
        }
        if (!LibPoolMembership.isMember(makerPositionKey, params.underlyingPoolId)) {
            revert PoolMembershipRequired(makerPositionKey, params.underlyingPoolId);
        }
        if (!LibPoolMembership.isMember(makerPositionKey, params.strikePoolId)) {
            revert PoolMembershipRequired(makerPositionKey, params.strikePoolId);
        }

        LibPositionHelpers.settlePosition(params.underlyingPoolId, makerPositionKey);
        LibPositionHelpers.settlePosition(params.strikePoolId, makerPositionKey);

        uint256 underlyingNotional = params.totalSize * params.contractSize;
        uint256 collateralLocked = params.isCall
            ? underlyingNotional
            : _normalizeStrikeAmount(underlyingNotional, params.strikePrice, underlyingAsset, strikeAsset);
        if (collateralLocked == 0) revert Options_InvalidAmount(collateralLocked);

        uint256 collateralPoolId = params.isCall ? params.underlyingPoolId : params.strikePoolId;
        _lockCollateral(makerPositionKey, collateralPoolId, collateralLocked);

        seriesId = ++store.nextOptionSeriesId;
        _writeSeries(store, seriesId, makerPositionKey, params, underlyingAsset, strikeAsset, collateralLocked);

        LibOptionsStorage.addSeriesForPosition(store, makerPositionKey, seriesId);
        _optionToken().mint(makerOwner, seriesId, params.totalSize, "");
        _emitSeriesCreated(seriesId);
    }

    function exerciseOptions(
        uint256 seriesId,
        uint256 amount,
        address recipient,
        uint256 maxPayment,
        uint256 minReceived
    ) external payable nonReentrant returns (uint256 paymentAmount) {
        paymentAmount = _exerciseOptions(seriesId, amount, msg.sender, recipient, maxPayment, minReceived);
    }

    function exerciseOptionsFor(
        uint256 seriesId,
        uint256 amount,
        address holder,
        address recipient,
        uint256 maxPayment,
        uint256 minReceived
    ) external payable nonReentrant returns (uint256 paymentAmount) {
        paymentAmount = _exerciseOptions(seriesId, amount, holder, recipient, maxPayment, minReceived);
    }

    function reclaimOptions(uint256 seriesId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibOptionsStorage.OptionSeries storage series = _series(seriesId);
        if (block.timestamp <= series.expiry) revert Options_ExerciseWindowClosed(seriesId);
        if (series.reclaimed) revert Options_Reclaimed(seriesId);

        LibPositionHelpers.requireOwnership(series.makerPositionId);

        uint256 remainingSize = series.remainingSize;
        uint256 collateralUnlocked;
        if (remainingSize > 0) {
            uint256 underlyingAmount = remainingSize * series.contractSize;
            collateralUnlocked = series.isCall
                ? underlyingAmount
                : _normalizeStrikeAmount(underlyingAmount, series.strikePrice, series.underlyingAsset, series.strikeAsset);
            if (collateralUnlocked == 0) revert Options_InvalidAmount(collateralUnlocked);

            uint256 collateralPoolId = series.isCall ? series.underlyingPoolId : series.strikePoolId;
            _unlockCollateral(series.makerPositionKey, collateralPoolId, collateralUnlocked);
            series.collateralLocked -= collateralUnlocked;
            series.remainingSize = 0;
        }

        series.reclaimed = true;
        LibOptionsStorage.removeSeriesForPosition(LibOptionsStorage.s(), series.makerPositionKey, seriesId);

        emit OptionsReclaimed(seriesId, series.makerPositionKey, remainingSize, collateralUnlocked);
    }

    function burnReclaimedOptionsClaims(address holder, uint256 seriesId, uint256 amount) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        if (amount == 0) revert Options_InvalidAmount(amount);

        LibOptionsStorage.OptionSeries storage series = _series(seriesId);
        if (!series.reclaimed) revert Options_NotReclaimed(seriesId);

        OptionToken token = _optionToken();
        uint256 balance = token.balanceOf(holder, seriesId);
        if (balance < amount) {
            revert Options_InsufficientBalance(holder, amount, balance);
        }

        token.burn(holder, seriesId, amount);
        emit ReclaimedOptionClaimsBurned(seriesId, holder, amount);
    }

    function setOptionsPaused(bool paused) external {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();
        LibOptionsStorage.s().paused = paused;
        emit OptionsPausedUpdated(paused);
    }

    function setEuropeanTolerance(uint64 toleranceSeconds) external {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();
        LibOptionsStorage.s().europeanToleranceSeconds = toleranceSeconds;
        emit EuropeanToleranceUpdated(toleranceSeconds);
    }

    function _exerciseOptions(
        uint256 seriesId,
        uint256 amount,
        address holder,
        address recipient,
        uint256 maxPayment,
        uint256 minReceived
    ) internal returns (uint256 paymentAmount) {
        if (amount == 0) revert Options_InvalidAmount(amount);
        if (holder == address(0)) revert Options_InvalidRecipient(holder);
        if (recipient == address(0)) revert Options_InvalidRecipient(recipient);

        LibOptionsStorage.OptionSeries storage series = _series(seriesId);
        if (series.reclaimed) revert Options_Reclaimed(seriesId);
        if (amount > series.remainingSize) revert Options_InvalidAmount(amount);

        _validateExerciseWindow(seriesId, series);

        OptionToken token = _optionToken();
        _requireTokenHolderOrOperator(token, holder, seriesId, amount);
        token.burn(holder, seriesId, amount);

        LibPositionHelpers.settlePosition(series.underlyingPoolId, series.makerPositionKey);
        LibPositionHelpers.settlePosition(series.strikePoolId, series.makerPositionKey);

        uint256 underlyingAmount = amount * series.contractSize;
        uint256 strikeAmount =
            _normalizeStrikeAmount(underlyingAmount, series.strikePrice, series.underlyingAsset, series.strikeAsset);
        if (strikeAmount == 0) revert Options_InvalidAmount(strikeAmount);

        if (series.isCall) {
            paymentAmount = _exerciseCall(series, holder, recipient, underlyingAmount, strikeAmount, maxPayment, minReceived);
            series.collateralLocked -= underlyingAmount;
        } else {
            paymentAmount = _exercisePut(series, holder, recipient, underlyingAmount, strikeAmount, maxPayment, minReceived);
            series.collateralLocked -= strikeAmount;
        }

        series.remainingSize -= amount;
        emit OptionsExercised(
            seriesId, holder, recipient, amount, paymentAmount, series.isCall ? underlyingAmount : strikeAmount
        );
    }

    function _exerciseCall(
        LibOptionsStorage.OptionSeries storage series,
        address holder,
        address recipient,
        uint256 underlyingAmount,
        uint256 strikeAmount,
        uint256 maxPayment,
        uint256 minReceived
    ) internal returns (uint256 paymentAmount) {
        _unlockCollateral(series.makerPositionKey, series.underlyingPoolId, underlyingAmount);

        Types.PoolData storage underlyingPool = LibPositionHelpers.pool(series.underlyingPoolId);
        Types.PoolData storage strikePool = LibPositionHelpers.pool(series.strikePoolId);

        paymentAmount = _collectExercisePayment(series.strikeAsset, holder, strikeAmount, maxPayment);
        strikePool.trackedBalance += paymentAmount;
        _increasePrincipal(strikePool, series.strikePoolId, series.makerPositionKey, paymentAmount);

        _decreasePrincipalAndTransfer(
            underlyingPool,
            series.underlyingPoolId,
            series.makerPositionKey,
            underlyingAmount,
            recipient,
            minReceived
        );
    }

    function _exercisePut(
        LibOptionsStorage.OptionSeries storage series,
        address holder,
        address recipient,
        uint256 underlyingAmount,
        uint256 strikeAmount,
        uint256 maxPayment,
        uint256 minReceived
    ) internal returns (uint256 paymentAmount) {
        _unlockCollateral(series.makerPositionKey, series.strikePoolId, strikeAmount);

        Types.PoolData storage underlyingPool = LibPositionHelpers.pool(series.underlyingPoolId);
        Types.PoolData storage strikePool = LibPositionHelpers.pool(series.strikePoolId);

        paymentAmount = _collectExercisePayment(series.underlyingAsset, holder, underlyingAmount, maxPayment);
        underlyingPool.trackedBalance += paymentAmount;
        _increasePrincipal(underlyingPool, series.underlyingPoolId, series.makerPositionKey, paymentAmount);

        _decreasePrincipalAndTransfer(
            strikePool, series.strikePoolId, series.makerPositionKey, strikeAmount, recipient, minReceived
        );
    }

    function _collectExercisePayment(address asset, address payer, uint256 paymentAmount, uint256 maxPayment)
        internal
        returns (uint256 received)
    {
        received = LibCurrency.pullAtLeast(asset, payer, paymentAmount, maxPayment);
        if (received > paymentAmount) {
            uint256 excess = received - paymentAmount;
            LibCurrency.transfer(asset, payer, excess);
            received = paymentAmount;
        }
    }

    function _increasePrincipal(Types.PoolData storage pool, uint256 poolId, bytes32 positionKey, uint256 amount) internal {
        uint256 currentPrincipal = pool.userPrincipal[positionKey];
        if (currentPrincipal == 0) {
            uint256 maxUsers = pool.poolConfig.maxUserCount;
            if (maxUsers != 0 && pool.userCount >= maxUsers) {
                revert InvalidParameterRange("maxUserCount");
            }
            pool.userCount += 1;
        }

        uint256 newPrincipal = currentPrincipal + amount;
        if (pool.poolConfig.isCapped && pool.poolConfig.depositCap != 0 && newPrincipal > pool.poolConfig.depositCap) {
            revert InvalidParameterRange("depositCap");
        }

        pool.userPrincipal[positionKey] = newPrincipal;
        pool.totalDeposits += amount;
        pool.userFeeIndex[positionKey] = pool.feeIndex;
        pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
        LibActiveCreditIndex.settle(poolId, positionKey);
    }

    function _decreasePrincipalAndTransfer(
        Types.PoolData storage pool,
        uint256 poolId,
        bytes32 positionKey,
        uint256 amount,
        address recipient,
        uint256 minReceived
    ) internal {
        uint256 principal = pool.userPrincipal[positionKey];
        if (principal < amount) revert InsufficientPrincipal(amount, principal);
        if (pool.trackedBalance < amount) revert InsufficientPrincipal(amount, pool.trackedBalance);

        uint256 newPrincipal = principal - amount;
        pool.userPrincipal[positionKey] = newPrincipal;
        pool.totalDeposits -= amount;
        pool.trackedBalance -= amount;
        pool.userFeeIndex[positionKey] = pool.feeIndex;
        pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
        if (newPrincipal == 0 && pool.userCount > 0) {
            pool.userCount -= 1;
        }
        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }

        LibCurrency.transferWithMin(pool.underlying, recipient, amount, minReceived);
        LibActiveCreditIndex.settle(poolId, positionKey);
    }

    function _lockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        Types.PoolData storage pool = LibPositionHelpers.pool(poolId);
        uint256 available = LibPositionHelpers.settledAvailablePrincipal(pool, positionKey, poolId);
        if (available < amount) revert InsufficientPrincipal(amount, available);

        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        enc.lockedCapital += amount;
        LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
    }

    function _unlockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        LibPositionHelpers.settlePosition(poolId, positionKey);
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 lockedCapital = enc.lockedCapital;
        if (lockedCapital < amount) revert InsufficientPrincipal(amount, lockedCapital);

        enc.lockedCapital = lockedCapital - amount;
        LibActiveCreditIndex.applyEncumbranceDecrease(LibPositionHelpers.pool(poolId), poolId, positionKey, amount);
    }

    function _writeSeries(
        LibOptionsStorage.OptionsStorage storage store,
        uint256 seriesId,
        bytes32 makerPositionKey,
        LibOptionsStorage.CreateOptionSeriesParams calldata params,
        address underlyingAsset,
        address strikeAsset,
        uint256 collateralLocked
    ) internal {
        store.optionSeries[seriesId] = LibOptionsStorage.OptionSeries({
            makerPositionKey: makerPositionKey,
            makerPositionId: params.positionId,
            underlyingPoolId: params.underlyingPoolId,
            strikePoolId: params.strikePoolId,
            underlyingAsset: underlyingAsset,
            strikeAsset: strikeAsset,
            strikePrice: params.strikePrice,
            expiry: params.expiry,
            totalSize: params.totalSize,
            remainingSize: params.totalSize,
            contractSize: params.contractSize,
            collateralLocked: collateralLocked,
            isCall: params.isCall,
            isAmerican: params.isAmerican,
            reclaimed: false
        });
    }

    function _emitSeriesCreated(uint256 seriesId) internal {
        LibOptionsStorage.OptionSeries storage series = LibOptionsStorage.s().optionSeries[seriesId];
        emit OptionSeriesCreated(
            seriesId,
            series.makerPositionKey,
            series.makerPositionId,
            series.underlyingPoolId,
            series.strikePoolId,
            series.underlyingAsset,
            series.strikeAsset,
            series.strikePrice,
            series.expiry,
            series.totalSize,
            series.contractSize,
            series.collateralLocked,
            series.isCall,
            series.isAmerican
        );
    }

    function _series(uint256 seriesId) internal view returns (LibOptionsStorage.OptionSeries storage series) {
        series = LibOptionsStorage.s().optionSeries[seriesId];
        if (series.makerPositionKey == bytes32(0)) revert Options_InvalidSeries(seriesId);
    }

    function _optionToken() internal view returns (OptionToken token) {
        address tokenAddress = LibOptionTokenStorage.s().optionToken;
        if (tokenAddress == address(0)) revert Options_TokenNotSet();
        token = OptionToken(tokenAddress);
    }

    function _requireTokenHolderOrOperator(OptionToken token, address holder, uint256 seriesId, uint256 amount)
        internal
        view
    {
        uint256 balance = token.balanceOf(holder, seriesId);
        if (balance < amount) {
            revert Options_InsufficientBalance(holder, amount, balance);
        }
        if (msg.sender != holder && !token.isApprovedForAll(holder, msg.sender)) {
            revert Options_NotTokenHolder(msg.sender, seriesId);
        }
    }

    function _normalizeStrikeAmount(uint256 underlyingAmount, uint256 strikePrice, address underlying, address strike)
        internal
        view
        returns (uint256 strikeAmount)
    {
        uint256 underlyingScale = 10 ** uint256(LibCurrency.decimals(underlying));
        uint256 strikeScale = 10 ** uint256(LibCurrency.decimals(strike));
        uint256 normalizedUnderlying = Math.mulDiv(underlyingAmount, strikePrice, underlyingScale);
        strikeAmount = Math.mulDiv(normalizedUnderlying, strikeScale, 1e18);
    }

    function _validateExerciseWindow(uint256 seriesId, LibOptionsStorage.OptionSeries storage series) internal view {
        if (series.isAmerican) {
            if (block.timestamp >= series.expiry) revert Options_ExerciseWindowClosed(seriesId);
            return;
        }

        uint64 tolerance = LibOptionsStorage.s().europeanToleranceSeconds;
        uint64 lowerBound = series.expiry > tolerance ? series.expiry - tolerance : 0;
        uint64 upperBound = series.expiry + tolerance;
        if (block.timestamp < lowerBound || block.timestamp > upperBound) {
            revert Options_ExerciseWindowClosed(seriesId);
        }
    }
}
