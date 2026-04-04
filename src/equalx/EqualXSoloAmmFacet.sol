// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibEqualXDiscoveryStorage} from "../libraries/LibEqualXDiscoveryStorage.sol";
import {LibEqualXSoloAmmStorage} from "../libraries/LibEqualXSoloAmmStorage.sol";
import {LibEqualXSwapMath} from "../libraries/LibEqualXSwapMath.sol";
import {LibEqualXTypes} from "../libraries/LibEqualXTypes.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {TransientSwapCache} from "../libraries/TransientSwapCache.sol";
import {Types} from "../libraries/Types.sol";
import {InsufficientPrincipal, InvalidParameterRange, PoolMembershipRequired} from "../libraries/Errors.sol";

/// @notice Greenfield solo AMM execution surface for EqualX.
contract EqualXSoloAmmFacet is ReentrancyGuardModifiers {
    bytes32 internal constant SOLO_AMM_FEE_SOURCE = keccak256("EQUALX_SOLO_AMM_FEE");
    uint16 internal constant SOLO_AMM_MAKER_SHARE_BPS = 7000;
    uint256 internal constant SOLO_AMM_REBALANCE_MAX_DELTA_DIVISOR = 10;

    error EqualXSoloAmm_InvalidMarket(uint256 marketId);
    error EqualXSoloAmm_InvalidToken(address token);
    error EqualXSoloAmm_InvalidPoolPair(uint256 poolIdA, uint256 poolIdB);
    error EqualXSoloAmm_InvalidFee(uint16 feeBps);
    error EqualXSoloAmm_InvalidTimeWindow(uint64 startTime, uint64 endTime);
    error EqualXSoloAmm_NotStarted(uint256 marketId);
    error EqualXSoloAmm_NotExpired(uint256 marketId);
    error EqualXSoloAmm_Expired(uint256 marketId);
    error EqualXSoloAmm_AlreadyFinalized(uint256 marketId);
    error EqualXSoloAmm_PendingRebalanceExists(uint256 marketId);
    error EqualXSoloAmm_NoPendingRebalance(uint256 marketId);
    error EqualXSoloAmm_RebalanceNotReady(uint256 marketId, uint64 executeAfter);
    error EqualXSoloAmm_StableZeroOutput();
    error EqualXSoloAmm_Slippage(uint256 minOut, uint256 actualOut);

    event EqualXSoloAmmMarketCreated(
        uint256 indexed marketId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        uint256 reserveA,
        uint256 reserveB
    );
    event EqualXSoloAmmSwap(
        uint256 indexed marketId,
        address indexed swapper,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        address recipient
    );
    event EqualXSoloAmmMarketFinalized(uint256 indexed marketId, bytes32 indexed makerPositionKey, bool cancelled);
    event EqualXSoloAmmMinRebalanceTimelockSet(uint64 minRebalanceTimelock);
    event EqualXSoloAmmRebalanceScheduled(
        uint256 indexed marketId,
        bytes32 indexed makerPositionKey,
        uint256 snapshotReserveA,
        uint256 snapshotReserveB,
        uint256 targetReserveA,
        uint256 targetReserveB,
        uint64 executeAfter
    );
    event EqualXSoloAmmRebalanceCancelled(uint256 indexed marketId, bytes32 indexed makerPositionKey);
    event EqualXSoloAmmRebalanceExecuted(
        uint256 indexed marketId,
        bytes32 indexed makerPositionKey,
        address indexed executor,
        uint256 previousReserveA,
        uint256 previousReserveB,
        uint256 targetReserveA,
        uint256 targetReserveB
    );

    struct SoloAmmSwapPreview {
        uint256 rawOut;
        uint256 amountOut;
        uint256 feeAmount;
        uint256 makerFee;
        uint256 treasuryFee;
        uint256 activeCreditFee;
        uint256 feeIndexFee;
        address feeToken;
        uint256 feePoolId;
    }

    struct SoloAmmSwapContext {
        bool inIsA;
        uint256 reserveIn;
        uint256 reserveOut;
        uint8 decimalsIn;
        uint8 decimalsOut;
        uint256 actualIn;
        uint256 newReserveIn;
        uint256 newReserveOut;
        uint256 feePoolId;
        address feeToken;
    }

    struct SoloAmmSwapOutcome {
        uint256 amountOut;
        uint256 feeAmount;
        uint256 toTreasury;
        uint256 toActive;
        uint256 toFeeIndex;
        LibEqualXSwapMath.FeeSplit split;
    }

    struct SoloAmmSwapRequest {
        address tokenIn;
        uint256 amountIn;
        uint256 maxIn;
        uint256 minOut;
    }

    struct SoloAmmCreateContext {
        bytes32 makerPositionKey;
        address tokenA;
        address tokenB;
        uint8 tokenADecimals;
        uint8 tokenBDecimals;
    }

    struct SoloAmmCreateRequest {
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        uint256 reserveA;
        uint256 reserveB;
        uint64 startTime;
        uint64 endTime;
        uint64 rebalanceTimelock;
        uint16 feeBps;
        LibEqualXTypes.FeeAsset feeAsset;
        LibEqualXTypes.InvariantMode invariantMode;
    }

    function createEqualXSoloAmmMarket(
        uint256 makerPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        uint256 reserveA,
        uint256 reserveB,
        uint64 startTime,
        uint64 endTime,
        uint64 rebalanceTimelock,
        uint16 feeBps,
        LibEqualXTypes.FeeAsset feeAsset,
        LibEqualXTypes.InvariantMode invariantMode
    ) external nonReentrant returns (uint256 marketId) {
        LibEqualXSoloAmmStorage.SoloAmmStorage storage store = LibEqualXSoloAmmStorage.s();
        if (reserveA == 0 || reserveB == 0) {
            revert InvalidParameterRange("reserve=0");
        }
        if (poolIdA == poolIdB) {
            revert EqualXSoloAmm_InvalidPoolPair(poolIdA, poolIdB);
        }
        if (feeBps >= 10_000) {
            revert EqualXSoloAmm_InvalidFee(feeBps);
        }
        if (endTime <= startTime || endTime <= block.timestamp) {
            revert EqualXSoloAmm_InvalidTimeWindow(startTime, endTime);
        }
        if (rebalanceTimelock < LibEqualXSoloAmmStorage.minRebalanceTimelock(store)) {
            revert InvalidParameterRange("rebalanceTimelock");
        }

        SoloAmmCreateRequest memory request = SoloAmmCreateRequest({
            makerPositionId: makerPositionId,
            poolIdA: poolIdA,
            poolIdB: poolIdB,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: startTime,
            endTime: endTime,
            rebalanceTimelock: rebalanceTimelock,
            feeBps: feeBps,
            feeAsset: feeAsset,
            invariantMode: invariantMode
        });
        SoloAmmCreateContext memory ctx =
            _prepareCreateContext(request.makerPositionId, request.poolIdA, request.poolIdB, request.reserveA, request.reserveB, request.invariantMode);
        marketId = _initializeSoloAmmMarket(ctx, request);
    }

    function setEqualXSoloAmmMinRebalanceTimelock(uint64 newMinRebalanceTimelock) external {
        LibAccess.enforceOwnerOrTimelock();
        if (newMinRebalanceTimelock == 0) {
            revert InvalidParameterRange("minRebalanceTimelock");
        }
        LibEqualXSoloAmmStorage.s().minRebalanceTimelock = newMinRebalanceTimelock;
        emit EqualXSoloAmmMinRebalanceTimelockSet(newMinRebalanceTimelock);
    }

    function scheduleEqualXSoloAmmRebalance(
        uint256 marketId,
        uint256 targetReserveA,
        uint256 targetReserveB
    ) external nonReentrant returns (uint64 executeAfter) {
        LibEqualXSoloAmmStorage.SoloAmmStorage storage store = LibEqualXSoloAmmStorage.s();
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = store.markets[marketId];
        _requireMarketExists(marketId, market);
        LibPositionHelpers.requireOwnership(market.makerPositionId);
        _requireActiveExecution(marketId, market);

        if (targetReserveA == 0) {
            revert InvalidParameterRange("targetReserveA");
        }
        if (targetReserveB == 0) {
            revert InvalidParameterRange("targetReserveB");
        }

        uint256 snapshotReserveA = market.reserveA;
        uint256 snapshotReserveB = market.reserveB;
        _requireRebalanceTargetWithinBound(snapshotReserveA, targetReserveA, "targetReserveA");
        _requireRebalanceTargetWithinBound(snapshotReserveB, targetReserveB, "targetReserveB");

        if (store.pendingRebalances[marketId].exists) {
            revert EqualXSoloAmm_PendingRebalanceExists(marketId);
        }

        executeAfter = _computeRebalanceExecuteAfter(market.lastRebalanceExecutionAt, market.rebalanceTimelock);
        store.pendingRebalances[marketId] = LibEqualXSoloAmmStorage.SoloAmmPendingRebalance({
            snapshotReserveA: snapshotReserveA,
            snapshotReserveB: snapshotReserveB,
            targetReserveA: targetReserveA,
            targetReserveB: targetReserveB,
            executeAfter: executeAfter,
            exists: true
        });

        emit EqualXSoloAmmRebalanceScheduled(
            marketId, market.makerPositionKey, snapshotReserveA, snapshotReserveB, targetReserveA, targetReserveB, executeAfter
        );
    }

    function cancelEqualXSoloAmmRebalance(uint256 marketId) external nonReentrant {
        LibEqualXSoloAmmStorage.SoloAmmStorage storage store = LibEqualXSoloAmmStorage.s();
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = store.markets[marketId];
        _requireMarketExists(marketId, market);
        LibPositionHelpers.requireOwnership(market.makerPositionId);
        if (!store.pendingRebalances[marketId].exists) {
            revert EqualXSoloAmm_NoPendingRebalance(marketId);
        }

        delete store.pendingRebalances[marketId];
        emit EqualXSoloAmmRebalanceCancelled(marketId, market.makerPositionKey);
    }

    function executeEqualXSoloAmmRebalance(uint256 marketId) external nonReentrant {
        LibEqualXSoloAmmStorage.SoloAmmStorage storage store = LibEqualXSoloAmmStorage.s();
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = store.markets[marketId];
        _requireMarketExists(marketId, market);
        _requireActiveExecution(marketId, market);

        LibEqualXSoloAmmStorage.SoloAmmPendingRebalance memory pending = store.pendingRebalances[marketId];
        if (!pending.exists) {
            revert EqualXSoloAmm_NoPendingRebalance(marketId);
        }
        if (block.timestamp < pending.executeAfter) {
            revert EqualXSoloAmm_RebalanceNotReady(marketId, pending.executeAfter);
        }

        bytes32 makerPositionKey = market.makerPositionKey;
        Types.PoolData storage poolA = LibPositionHelpers.pool(market.poolIdA);
        Types.PoolData storage poolB = LibPositionHelpers.pool(market.poolIdB);
        uint256 previousReserveA = market.reserveA;
        uint256 previousReserveB = market.reserveB;

        _applyExecutedRebalanceDelta(
            poolA, market.poolIdA, makerPositionKey, previousReserveA, market.baselineReserveA, pending.targetReserveA
        );
        _applyExecutedRebalanceDelta(
            poolB, market.poolIdB, makerPositionKey, previousReserveB, market.baselineReserveB, pending.targetReserveB
        );

        market.reserveA = pending.targetReserveA;
        market.reserveB = pending.targetReserveB;
        market.baselineReserveA = pending.targetReserveA;
        market.baselineReserveB = pending.targetReserveB;
        market.lastRebalanceExecutionAt = uint64(block.timestamp);
        delete store.pendingRebalances[marketId];

        emit EqualXSoloAmmRebalanceExecuted(
            marketId,
            makerPositionKey,
            msg.sender,
            previousReserveA,
            previousReserveB,
            pending.targetReserveA,
            pending.targetReserveB
        );
    }

    function previewEqualXSoloAmmSwapExactIn(
        uint256 marketId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (SoloAmmSwapPreview memory preview) {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        _requireMarketExists(marketId, market);
        bool inIsA = _isTokenA(tokenIn, market);

        uint256 reserveIn = inIsA ? market.reserveA : market.reserveB;
        uint256 reserveOut = inIsA ? market.reserveB : market.reserveA;
        uint8 decimalsIn = inIsA ? market.tokenADecimals : market.tokenBDecimals;
        uint8 decimalsOut = inIsA ? market.tokenBDecimals : market.tokenADecimals;

        (preview.rawOut, preview.feeAmount, preview.amountOut) = LibEqualXSwapMath.computeSwapByInvariant(
            market.invariantMode,
            market.feeAsset,
            reserveIn,
            reserveOut,
            amountIn,
            market.feeBps,
            decimalsIn,
            decimalsOut
        );

        if (preview.feeAmount > 0) {
            LibEqualXSwapMath.FeeSplit memory split =
                LibEqualXSwapMath.splitFeeWithRouter(preview.feeAmount, SOLO_AMM_MAKER_SHARE_BPS);
            preview.makerFee = split.makerFee;
            preview.treasuryFee = split.treasuryFee;
            preview.activeCreditFee = split.activeCreditFee;
            preview.feeIndexFee = split.feeIndexFee;
        }
        if (market.feeAsset == LibEqualXTypes.FeeAsset.TokenIn) {
            preview.feeToken = tokenIn;
            preview.feePoolId = inIsA ? market.poolIdA : market.poolIdB;
        } else {
            preview.feeToken = inIsA ? market.tokenB : market.tokenA;
            preview.feePoolId = inIsA ? market.poolIdB : market.poolIdA;
        }
    }

    function swapEqualXSoloAmmExactIn(
        uint256 marketId,
        address tokenIn,
        uint256 amountIn,
        uint256 maxIn,
        uint256 minOut,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) {
            revert InvalidParameterRange("amountIn=0");
        }
        if (recipient == address(0)) {
            revert InvalidParameterRange("recipient=0");
        }

        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        _requireActiveExecution(marketId, market);

        SoloAmmSwapContext memory ctx = _prepareSwapContext(market, tokenIn);
        SoloAmmSwapOutcome memory outcome;
        SoloAmmSwapRequest memory request =
            SoloAmmSwapRequest({tokenIn: tokenIn, amountIn: amountIn, maxIn: maxIn, minOut: minOut});
        (ctx, outcome) = _fundAndQuoteSwap(market, request, ctx);

        _commitSwapReserves(market, ctx);
        _accrueMakerFee(market, ctx.feeToken, outcome.split.makerFee);

        if (outcome.split.protocolFee > 0) {
            uint256 extraBacking = _feeSideReserve(market, ctx.feePoolId);
            TransientSwapCache.cacheFeePool(ctx.feePoolId);
            uint256 cachedFeePoolId = TransientSwapCache.loadFeePool();
            if (cachedFeePoolId != 0) {
                ctx.feePoolId = cachedFeePoolId;
            }
            (outcome.toTreasury, outcome.toActive, outcome.toFeeIndex) =
                LibFeeRouter.routeSamePool(ctx.feePoolId, outcome.split.protocolFee, SOLO_AMM_FEE_SOURCE, false, extraBacking);
            _accrueProtocolFees(market, ctx.feeToken, outcome.toTreasury, outcome.toActive, outcome.toFeeIndex);
        }

        _payoutSwapRecipient(ctx.inIsA ? market.tokenB : market.tokenA, recipient, outcome.amountOut, minOut);
        amountOut = outcome.amountOut;
        _emitSoloAmmSwap(marketId, tokenIn, ctx.actualIn, amountOut, outcome.feeAmount, recipient);
    }

    function finalizeEqualXSoloAmmMarket(uint256 marketId) external nonReentrant {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        _requireMarketExists(marketId, market);
        if (!market.active) {
            revert EqualXSoloAmm_InvalidMarket(marketId);
        }
        if (block.timestamp < market.endTime) {
            revert EqualXSoloAmm_NotExpired(marketId);
        }
        _closeMarket(marketId, market, false);
    }

    function cancelEqualXSoloAmmMarket(uint256 marketId) external nonReentrant {
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = LibEqualXSoloAmmStorage.s().markets[marketId];
        _requireMarketExists(marketId, market);
        LibPositionHelpers.requireOwnership(market.makerPositionId);
        _closeMarket(marketId, market, true);
    }

    function _closeMarket(uint256 marketId, LibEqualXSoloAmmStorage.SoloAmmMarket storage market, bool cancelled)
        internal
    {
        if (!market.active) {
            revert EqualXSoloAmm_InvalidMarket(marketId);
        }

        bytes32 makerPositionKey = market.makerPositionKey;
        Types.PoolData storage poolA = LibPositionHelpers.pool(market.poolIdA);
        Types.PoolData storage poolB = LibPositionHelpers.pool(market.poolIdB);

        LibActiveCreditIndex.settle(market.poolIdA, makerPositionKey);
        LibActiveCreditIndex.settle(market.poolIdB, makerPositionKey);
        _unlockReserveBacking(makerPositionKey, market.poolIdA, market.reserveA);
        _unlockReserveBacking(makerPositionKey, market.poolIdB, market.reserveB);
        LibActiveCreditIndex.applyEncumbranceDecrease(poolA, market.poolIdA, makerPositionKey, market.baselineReserveA);
        LibActiveCreditIndex.applyEncumbranceDecrease(poolB, market.poolIdB, makerPositionKey, market.baselineReserveB);

        uint256 reserveAForPrincipal = market.reserveA;
        uint256 reserveBForPrincipal = market.reserveB;

        uint256 protocolYieldA = market.feeIndexFeeAAccrued + market.activeCreditFeeAAccrued;
        if (protocolYieldA > 0) {
            poolA.trackedBalance += protocolYieldA;
            if (LibCurrency.isNative(poolA.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += protocolYieldA;
            }
        }
        uint256 protocolYieldB = market.feeIndexFeeBAccrued + market.activeCreditFeeBAccrued;
        if (protocolYieldB > 0) {
            poolB.trackedBalance += protocolYieldB;
            if (LibCurrency.isNative(poolB.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += protocolYieldB;
            }
        }

        if (market.feeIndexFeeAAccrued > 0 && reserveAForPrincipal >= market.feeIndexFeeAAccrued) {
            reserveAForPrincipal -= market.feeIndexFeeAAccrued;
        }
        if (market.activeCreditFeeAAccrued > 0 && reserveAForPrincipal >= market.activeCreditFeeAAccrued) {
            reserveAForPrincipal -= market.activeCreditFeeAAccrued;
        }
        if (market.feeIndexFeeBAccrued > 0 && reserveBForPrincipal >= market.feeIndexFeeBAccrued) {
            reserveBForPrincipal -= market.feeIndexFeeBAccrued;
        }
        if (market.activeCreditFeeBAccrued > 0 && reserveBForPrincipal >= market.activeCreditFeeBAccrued) {
            reserveBForPrincipal -= market.activeCreditFeeBAccrued;
        }

        _applyPrincipalDelta(poolA, market.poolIdA, makerPositionKey, reserveAForPrincipal, market.baselineReserveA);
        _applyPrincipalDelta(poolB, market.poolIdB, makerPositionKey, reserveBForPrincipal, market.baselineReserveB);

        delete LibEqualXSoloAmmStorage.s().pendingRebalances[marketId];
        market.active = false;
        market.finalized = true;
        LibEqualXDiscoveryStorage.removeActiveMarket(
            LibEqualXDiscoveryStorage.s(), LibEqualXTypes.MarketType.SOLO_AMM, marketId
        );

        emit EqualXSoloAmmMarketFinalized(marketId, makerPositionKey, cancelled);
    }

    function _requireMarketExists(uint256 marketId, LibEqualXSoloAmmStorage.SoloAmmMarket storage market) internal view {
        if (marketId == 0 || market.makerPositionId == 0) {
            revert EqualXSoloAmm_InvalidMarket(marketId);
        }
    }

    function _requireActiveExecution(uint256 marketId, LibEqualXSoloAmmStorage.SoloAmmMarket storage market)
        internal
        view
    {
        _requireMarketExists(marketId, market);
        if (market.finalized) {
            revert EqualXSoloAmm_AlreadyFinalized(marketId);
        }
        if (!market.active) {
            revert EqualXSoloAmm_InvalidMarket(marketId);
        }
        if (block.timestamp < market.startTime) {
            revert EqualXSoloAmm_NotStarted(marketId);
        }
        if (block.timestamp >= market.endTime) {
            revert EqualXSoloAmm_Expired(marketId);
        }
    }

    function _isTokenA(address tokenIn, LibEqualXSoloAmmStorage.SoloAmmMarket storage market)
        internal
        view
        returns (bool inIsA)
    {
        if (tokenIn == market.tokenA) {
            return true;
        }
        if (tokenIn == market.tokenB) {
            return false;
        }
        revert EqualXSoloAmm_InvalidToken(tokenIn);
    }

    function _prepareCreateContext(
        uint256 makerPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        uint256 reserveA,
        uint256 reserveB,
        LibEqualXTypes.InvariantMode invariantMode
    ) internal returns (SoloAmmCreateContext memory ctx) {
        ctx.makerPositionKey = LibPositionHelpers.positionKey(makerPositionId);
        LibPositionHelpers.requireOwnership(makerPositionId);

        Types.PoolData storage poolA = LibPositionHelpers.pool(poolIdA);
        Types.PoolData storage poolB = LibPositionHelpers.pool(poolIdB);
        ctx.tokenA = poolA.underlying;
        ctx.tokenB = poolB.underlying;
        if (ctx.tokenA == ctx.tokenB) {
            revert EqualXSoloAmm_InvalidPoolPair(poolIdA, poolIdB);
        }
        if (!LibPoolMembership.isMember(ctx.makerPositionKey, poolIdA)) {
            revert PoolMembershipRequired(ctx.makerPositionKey, poolIdA);
        }
        if (!LibPoolMembership.isMember(ctx.makerPositionKey, poolIdB)) {
            revert PoolMembershipRequired(ctx.makerPositionKey, poolIdB);
        }

        if (invariantMode == LibEqualXTypes.InvariantMode.Stable) {
            ctx.tokenADecimals = LibCurrency.decimalsOrRevert(ctx.tokenA);
            ctx.tokenBDecimals = LibCurrency.decimalsOrRevert(ctx.tokenB);
            LibEqualXSwapMath.validateStableDecimals(ctx.tokenADecimals, ctx.tokenBDecimals);
        } else {
            ctx.tokenADecimals = LibCurrency.decimals(ctx.tokenA);
            ctx.tokenBDecimals = LibCurrency.decimals(ctx.tokenB);
        }

        _requireAvailableBacking(poolA, ctx.makerPositionKey, poolIdA, reserveA);
        _requireAvailableBacking(poolB, ctx.makerPositionKey, poolIdB, reserveB);
    }

    function _initializeSoloAmmMarket(
        SoloAmmCreateContext memory ctx,
        SoloAmmCreateRequest memory request
    ) internal returns (uint256 marketId) {
        LibEqualXSoloAmmStorage.SoloAmmStorage storage store = LibEqualXSoloAmmStorage.s();
        marketId = LibEqualXSoloAmmStorage.allocateMarketId(store);
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market = store.markets[marketId];
        market.makerPositionKey = ctx.makerPositionKey;
        market.makerPositionId = request.makerPositionId;
        market.poolIdA = request.poolIdA;
        market.poolIdB = request.poolIdB;
        market.tokenA = ctx.tokenA;
        market.tokenB = ctx.tokenB;
        market.reserveA = request.reserveA;
        market.reserveB = request.reserveB;
        market.baselineReserveA = request.reserveA;
        market.baselineReserveB = request.reserveB;
        market.startTime = request.startTime;
        market.endTime = request.endTime;
        market.rebalanceTimelock = request.rebalanceTimelock;
        market.feeBps = request.feeBps;
        market.feeAsset = request.feeAsset;
        market.invariantMode = request.invariantMode;
        market.tokenADecimals = ctx.tokenADecimals;
        market.tokenBDecimals = ctx.tokenBDecimals;
        market.active = true;

        _lockReserveBacking(LibPositionHelpers.pool(request.poolIdA), ctx.makerPositionKey, request.poolIdA, request.reserveA);
        _lockReserveBacking(LibPositionHelpers.pool(request.poolIdB), ctx.makerPositionKey, request.poolIdB, request.reserveB);

        LibEqualXDiscoveryStorage.registerMarket(
            LibEqualXDiscoveryStorage.s(),
            ctx.makerPositionKey,
            market.tokenA,
            market.tokenB,
            LibEqualXTypes.MarketType.SOLO_AMM,
            marketId
        );

        _emitSoloAmmMarketCreated(marketId, ctx, request);
    }

    function _prepareSwapContext(
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market,
        address tokenIn
    ) internal returns (SoloAmmSwapContext memory ctx) {
        ctx.inIsA = _isTokenA(tokenIn, market);
        ctx.reserveIn = ctx.inIsA ? market.reserveA : market.reserveB;
        ctx.reserveOut = ctx.inIsA ? market.reserveB : market.reserveA;
        ctx.decimalsIn = ctx.inIsA ? market.tokenADecimals : market.tokenBDecimals;
        ctx.decimalsOut = ctx.inIsA ? market.tokenBDecimals : market.tokenADecimals;
        TransientSwapCache.cacheReserves(ctx.reserveIn, ctx.reserveOut);
        if (market.feeAsset == LibEqualXTypes.FeeAsset.TokenIn) {
            ctx.feePoolId = ctx.inIsA ? market.poolIdA : market.poolIdB;
            ctx.feeToken = tokenIn;
        } else {
            ctx.feePoolId = ctx.inIsA ? market.poolIdB : market.poolIdA;
            ctx.feeToken = ctx.inIsA ? market.tokenB : market.tokenA;
        }
    }

    function _fundAndQuoteSwap(
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market,
        SoloAmmSwapRequest memory request,
        SoloAmmSwapContext memory ctx
    ) internal returns (SoloAmmSwapContext memory updatedCtx, SoloAmmSwapOutcome memory outcome) {
        LibCurrency.assertMsgValue(request.tokenIn, request.amountIn);
        ctx.actualIn = LibCurrency.pullAtLeast(request.tokenIn, msg.sender, request.amountIn, request.maxIn);

        (uint256 rawOut, uint256 feeAmount, uint256 outputToRecipient) = LibEqualXSwapMath.computeSwapByInvariant(
            market.invariantMode,
            market.feeAsset,
            ctx.reserveIn,
            ctx.reserveOut,
            ctx.actualIn,
            market.feeBps,
            ctx.decimalsIn,
            ctx.decimalsOut
        );
        rawOut;
        if (market.invariantMode == LibEqualXTypes.InvariantMode.Stable && outputToRecipient == 0) {
            revert EqualXSoloAmm_StableZeroOutput();
        }
        if (outputToRecipient < request.minOut) {
            revert EqualXSoloAmm_Slippage(request.minOut, outputToRecipient);
        }

        outcome.amountOut = outputToRecipient;
        outcome.feeAmount = feeAmount;
        outcome.split = LibEqualXSwapMath.splitFeeWithRouter(feeAmount, SOLO_AMM_MAKER_SHARE_BPS);
        ctx.newReserveIn = ctx.reserveIn + ctx.actualIn;
        ctx.newReserveOut = ctx.reserveOut - outputToRecipient;
        if (outcome.split.treasuryFee > 0) {
            bool ok;
            (ctx.newReserveIn, ctx.newReserveOut, ok) = LibEqualXSwapMath.applyProtocolFee(
                market.feeAsset, ctx.newReserveIn, ctx.newReserveOut, outcome.split.treasuryFee
            );
            if (!ok) {
                uint256 available =
                    market.feeAsset == LibEqualXTypes.FeeAsset.TokenIn ? ctx.newReserveIn : ctx.newReserveOut;
                revert InsufficientPrincipal(outcome.split.treasuryFee, available);
            }
        }
        updatedCtx = ctx;
    }

    function _computeRebalanceExecuteAfter(uint64 lastRebalanceExecutionAt, uint64 rebalanceTimelock)
        internal
        view
        returns (uint64 executeAfter)
    {
        uint256 executeAfter_ = block.timestamp + uint256(rebalanceTimelock);
        uint256 cooldownReady = uint256(lastRebalanceExecutionAt) + uint256(rebalanceTimelock);
        if (cooldownReady > executeAfter_) {
            executeAfter_ = cooldownReady;
        }
        if (executeAfter_ > type(uint64).max) {
            revert InvalidParameterRange("rebalanceExecuteAfter");
        }
        executeAfter = uint64(executeAfter_);
    }

    function _requireRebalanceTargetWithinBound(
        uint256 snapshotReserve,
        uint256 targetReserve,
        string memory parameterName
    ) internal pure {
        uint256 maxDelta = snapshotReserve / SOLO_AMM_REBALANCE_MAX_DELTA_DIVISOR;
        if (targetReserve > snapshotReserve) {
            if (targetReserve - snapshotReserve > maxDelta) {
                revert InvalidParameterRange(parameterName);
            }
            return;
        }
        if (snapshotReserve - targetReserve > maxDelta) {
            revert InvalidParameterRange(parameterName);
        }
    }

    function _requireAvailableBacking(
        Types.PoolData storage pool,
        bytes32 makerPositionKey,
        uint256 poolId,
        uint256 amount
    ) internal {
        uint256 available = LibPositionHelpers.settledAvailablePrincipal(pool, makerPositionKey, poolId);
        if (amount > available) {
            revert InsufficientPrincipal(amount, available);
        }
    }

    function _lockReserveBacking(
        Types.PoolData storage pool,
        bytes32 makerPositionKey,
        uint256 poolId,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        LibPositionHelpers.settlePosition(poolId, makerPositionKey);
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(makerPositionKey, poolId);
        enc.encumberedCapital += amount;
        LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, makerPositionKey, amount);
    }

    function _unlockReserveBacking(bytes32 makerPositionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) return;
        LibPositionHelpers.settlePosition(poolId, makerPositionKey);
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(makerPositionKey, poolId);
        uint256 currentEncumberedCapital = enc.encumberedCapital;
        if (currentEncumberedCapital < amount) {
            revert InsufficientPrincipal(amount, currentEncumberedCapital);
        }
        enc.encumberedCapital = currentEncumberedCapital - amount;
    }

    function _commitSwapReserves(
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market,
        SoloAmmSwapContext memory ctx
    ) internal {
        if (ctx.inIsA) {
            _applyReserveDelta(market.makerPositionKey, market.poolIdA, market.reserveA, ctx.newReserveIn);
            _applyReserveDelta(market.makerPositionKey, market.poolIdB, market.reserveB, ctx.newReserveOut);
            market.reserveA = ctx.newReserveIn;
            market.reserveB = ctx.newReserveOut;
            return;
        }

        _applyReserveDelta(market.makerPositionKey, market.poolIdB, market.reserveB, ctx.newReserveIn);
        _applyReserveDelta(market.makerPositionKey, market.poolIdA, market.reserveA, ctx.newReserveOut);
        market.reserveB = ctx.newReserveIn;
        market.reserveA = ctx.newReserveOut;
    }

    function _applyReserveDelta(
        bytes32 makerPositionKey,
        uint256 poolId,
        uint256 previousReserve,
        uint256 newReserve
    ) internal {
        if (previousReserve == newReserve) {
            return;
        }
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(makerPositionKey, poolId);
        if (newReserve > previousReserve) {
            enc.encumberedCapital += newReserve - previousReserve;
        } else {
            uint256 delta = previousReserve - newReserve;
            uint256 currentEncumberedCapital = enc.encumberedCapital;
            if (currentEncumberedCapital < delta) {
                revert InsufficientPrincipal(delta, currentEncumberedCapital);
            }
            enc.encumberedCapital = currentEncumberedCapital - delta;
        }
    }

    function _applyExecutedRebalanceDelta(
        Types.PoolData storage pool,
        uint256 poolId,
        bytes32 makerPositionKey,
        uint256 previousReserve,
        uint256 previousBaseline,
        uint256 targetReserve
    ) internal {
        LibPositionHelpers.settlePosition(poolId, makerPositionKey);
        _applyRebalanceReserveEncumbranceDelta(pool, poolId, makerPositionKey, previousReserve, targetReserve);
        _applyRebalanceBaselineActiveCreditDelta(pool, poolId, makerPositionKey, previousBaseline, targetReserve);
    }

    function _applyRebalanceReserveEncumbranceDelta(
        Types.PoolData storage pool,
        uint256 poolId,
        bytes32 makerPositionKey,
        uint256 previousReserve,
        uint256 targetReserve
    ) internal {
        if (previousReserve == targetReserve) {
            return;
        }

        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(makerPositionKey, poolId);
        if (targetReserve > previousReserve) {
            uint256 deltaIncrease = targetReserve - previousReserve;
            uint256 available = LibPositionHelpers.availablePrincipal(pool, makerPositionKey, poolId);
            if (deltaIncrease > available) {
                revert InsufficientPrincipal(deltaIncrease, available);
            }
            enc.encumberedCapital += deltaIncrease;
            return;
        }

        uint256 deltaDecrease = previousReserve - targetReserve;
        uint256 currentEncumberedCapital = enc.encumberedCapital;
        if (currentEncumberedCapital < deltaDecrease) {
            revert InsufficientPrincipal(deltaDecrease, currentEncumberedCapital);
        }
        enc.encumberedCapital = currentEncumberedCapital - deltaDecrease;
    }

    function _applyRebalanceBaselineActiveCreditDelta(
        Types.PoolData storage pool,
        uint256 poolId,
        bytes32 makerPositionKey,
        uint256 previousBaseline,
        uint256 targetReserve
    ) internal {
        if (previousBaseline == targetReserve) {
            return;
        }

        if (targetReserve > previousBaseline) {
            LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, makerPositionKey, targetReserve - previousBaseline);
            return;
        }

        LibActiveCreditIndex.applyEncumbranceDecrease(pool, poolId, makerPositionKey, previousBaseline - targetReserve);
    }

    function _applyPrincipalDelta(
        Types.PoolData storage pool,
        uint256 pid,
        bytes32 makerPositionKey,
        uint256 currentReserve,
        uint256 initialReserve
    ) internal {
        if (currentReserve == initialReserve) {
            return;
        }

        LibFeeIndex.settle(pid, makerPositionKey);

        if (currentReserve > initialReserve) {
            uint256 deltaIncrease = currentReserve - initialReserve;
            pool.userPrincipal[makerPositionKey] += deltaIncrease;
            pool.totalDeposits += deltaIncrease;
            pool.trackedBalance += deltaIncrease;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += deltaIncrease;
            }
            return;
        }

        uint256 deltaDecrease = initialReserve - currentReserve;
        uint256 principal = pool.userPrincipal[makerPositionKey];
        if (principal < deltaDecrease) {
            revert InsufficientPrincipal(deltaDecrease, principal);
        }
        pool.userPrincipal[makerPositionKey] = principal - deltaDecrease;
        pool.totalDeposits -= deltaDecrease;
        if (pool.trackedBalance < deltaDecrease) {
            revert InsufficientPrincipal(deltaDecrease, pool.trackedBalance);
        }
        pool.trackedBalance -= deltaDecrease;
        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= deltaDecrease;
        }
    }

    function _accrueMakerFee(
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market,
        address feeToken,
        uint256 makerFee
    ) internal {
        if (makerFee == 0) {
            return;
        }
        if (feeToken == market.tokenA) {
            market.makerFeeAAccrued += makerFee;
        } else {
            market.makerFeeBAccrued += makerFee;
        }
    }

    function _accrueProtocolFees(
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market,
        address feeToken,
        uint256 toTreasury,
        uint256 toActive,
        uint256 toFeeIndex
    ) internal {
        if (feeToken == market.tokenA) {
            market.treasuryFeeAAccrued += toTreasury;
            market.activeCreditFeeAAccrued += toActive;
            market.feeIndexFeeAAccrued += toFeeIndex;
        } else {
            market.treasuryFeeBAccrued += toTreasury;
            market.activeCreditFeeBAccrued += toActive;
            market.feeIndexFeeBAccrued += toFeeIndex;
        }
    }

    function _feeSideReserve(
        LibEqualXSoloAmmStorage.SoloAmmMarket storage market,
        uint256 feePoolId
    ) internal view returns (uint256) {
        return feePoolId == market.poolIdA ? market.reserveA : market.reserveB;
    }

    function _payoutSwapRecipient(address tokenOut, address recipient, uint256 amountOut, uint256 minOut) internal {
        LibCurrency.transferWithMin(tokenOut, recipient, amountOut, minOut);
        if (LibCurrency.isNative(tokenOut)) {
            LibAppStorage.s().nativeTrackedTotal -= amountOut;
        }
    }

    function _emitSoloAmmSwap(
        uint256 marketId,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        address recipient
    ) internal {
        emit EqualXSoloAmmSwap(marketId, msg.sender, tokenIn, amountIn, amountOut, feeAmount, recipient);
    }

    function _emitSoloAmmMarketCreated(
        uint256 marketId,
        SoloAmmCreateContext memory ctx,
        SoloAmmCreateRequest memory request
    ) internal {
        emit EqualXSoloAmmMarketCreated(
            marketId,
            ctx.makerPositionKey,
            request.makerPositionId,
            request.poolIdA,
            request.poolIdB,
            request.reserveA,
            request.reserveB
        );
    }
}
