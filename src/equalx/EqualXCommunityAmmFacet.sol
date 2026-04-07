// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibEqualXCommunityAmmStorage} from "../libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCommunityFeeIndex} from "../libraries/LibEqualXCommunityFeeIndex.sol";
import {LibEqualXDiscoveryStorage} from "../libraries/LibEqualXDiscoveryStorage.sol";
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

/// @notice Greenfield community AMM execution surface for EqualX.
contract EqualXCommunityAmmFacet is ReentrancyGuardModifiers {
    bytes32 internal constant COMMUNITY_AMM_FEE_SOURCE = keccak256("EQUALX_COMMUNITY_AMM_FEE");
    uint16 internal constant COMMUNITY_AMM_MAKER_SHARE_BPS = 7000;

    error EqualXCommunityAmm_InvalidMarket(uint256 marketId);
    error EqualXCommunityAmm_InvalidPoolPair(uint256 poolIdA, uint256 poolIdB);
    error EqualXCommunityAmm_InvalidFee(uint16 feeBps);
    error EqualXCommunityAmm_InvalidTimeWindow(uint64 startTime, uint64 endTime);
    error EqualXCommunityAmm_InvalidToken(address token);
    error EqualXCommunityAmm_InvalidRatio(uint256 expected, uint256 actual);
    error EqualXCommunityAmm_NotStarted(uint256 marketId);
    error EqualXCommunityAmm_NotExpired(uint256 marketId);
    error EqualXCommunityAmm_Expired(uint256 marketId);
    error EqualXCommunityAmm_AlreadyFinalized(uint256 marketId);
    error EqualXCommunityAmm_NotParticipant(bytes32 positionKey);
    error EqualXCommunityAmm_StableZeroOutput();
    error EqualXCommunityAmm_Slippage(uint256 minOut, uint256 actualOut);

    event EqualXCommunityAmmMarketCreated(
        uint256 indexed marketId,
        bytes32 indexed creatorPositionKey,
        uint256 indexed creatorPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        uint256 reserveA,
        uint256 reserveB
    );
    event EqualXCommunityAmmMakerJoined(
        uint256 indexed marketId,
        bytes32 indexed positionKey,
        uint256 indexed positionId,
        uint256 amountA,
        uint256 amountB,
        uint256 share
    );
    event EqualXCommunityAmmMakerLeft(
        uint256 indexed marketId,
        bytes32 indexed positionKey,
        uint256 indexed positionId,
        uint256 withdrawnA,
        uint256 withdrawnB,
        uint256 feesA,
        uint256 feesB
    );
    event EqualXCommunityAmmFeesClaimed(
        uint256 indexed marketId,
        bytes32 indexed positionKey,
        uint256 feesA,
        uint256 feesB
    );
    event EqualXCommunityAmmSwap(
        uint256 indexed marketId,
        address indexed swapper,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        address recipient
    );
    event EqualXCommunityAmmMarketFinalized(uint256 indexed marketId, bytes32 indexed creatorPositionKey);
    event EqualXCommunityAmmMarketCancelled(uint256 indexed marketId, bytes32 indexed creatorPositionKey);

    struct CommunityAmmSwapPreview {
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

    struct CreateMarketRequest {
        uint256 creatorPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        uint256 reserveA;
        uint256 reserveB;
        uint64 startTime;
        uint64 endTime;
        uint16 feeBps;
        LibEqualXTypes.FeeAsset feeAsset;
        LibEqualXTypes.InvariantMode invariantMode;
    }

    struct CreateMarketContext {
        bytes32 creatorPositionKey;
        address tokenA;
        address tokenB;
        uint8 tokenADecimals;
        uint8 tokenBDecimals;
    }

    struct SwapContext {
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
        address tokenOut;
    }

    struct LeaveSettlement {
        uint256 withdrawnA;
        uint256 withdrawnB;
        uint256 initialA;
        uint256 initialB;
    }

    function createEqualXCommunityAmmMarket(
        uint256 creatorPositionId,
        uint256 poolIdA,
        uint256 poolIdB,
        uint256 reserveA,
        uint256 reserveB,
        uint64 startTime,
        uint64 endTime,
        uint16 feeBps,
        LibEqualXTypes.FeeAsset feeAsset,
        LibEqualXTypes.InvariantMode invariantMode
    ) external nonReentrant returns (uint256 marketId) {
        CreateMarketRequest memory request = CreateMarketRequest({
            creatorPositionId: creatorPositionId,
            poolIdA: poolIdA,
            poolIdB: poolIdB,
            reserveA: reserveA,
            reserveB: reserveB,
            startTime: startTime,
            endTime: endTime,
            feeBps: feeBps,
            feeAsset: feeAsset,
            invariantMode: invariantMode
        });
        CreateMarketContext memory ctx = _prepareCreateContext(request);
        marketId = _initializeCommunityMarket(request, ctx);
    }

    function _prepareCreateContext(CreateMarketRequest memory request)
        internal
        returns (CreateMarketContext memory ctx)
    {
        if (request.reserveA == 0 || request.reserveB == 0) revert InvalidParameterRange("reserve=0");
        if (request.poolIdA == request.poolIdB) {
            revert EqualXCommunityAmm_InvalidPoolPair(request.poolIdA, request.poolIdB);
        }
        if (request.feeBps >= 10_000) revert EqualXCommunityAmm_InvalidFee(request.feeBps);
        if (request.endTime <= request.startTime || request.endTime <= block.timestamp) {
            revert EqualXCommunityAmm_InvalidTimeWindow(request.startTime, request.endTime);
        }

        ctx.creatorPositionKey = LibPositionHelpers.positionKey(request.creatorPositionId);
        LibPositionHelpers.requireOwnership(request.creatorPositionId);

        Types.PoolData storage poolA = LibPositionHelpers.pool(request.poolIdA);
        Types.PoolData storage poolB = LibPositionHelpers.pool(request.poolIdB);
        ctx.tokenA = poolA.underlying;
        ctx.tokenB = poolB.underlying;
        if (ctx.tokenA == ctx.tokenB) {
            revert EqualXCommunityAmm_InvalidPoolPair(request.poolIdA, request.poolIdB);
        }
        if (!LibPoolMembership.isMember(ctx.creatorPositionKey, request.poolIdA)) {
            revert PoolMembershipRequired(ctx.creatorPositionKey, request.poolIdA);
        }
        if (!LibPoolMembership.isMember(ctx.creatorPositionKey, request.poolIdB)) {
            revert PoolMembershipRequired(ctx.creatorPositionKey, request.poolIdB);
        }

        _settlePositionState(request.poolIdA, ctx.creatorPositionKey);
        _settlePositionState(request.poolIdB, ctx.creatorPositionKey);
        _requireAvailableBacking(poolA, ctx.creatorPositionKey, request.poolIdA, request.reserveA);
        _requireAvailableBacking(poolB, ctx.creatorPositionKey, request.poolIdB, request.reserveB);

        if (request.invariantMode == LibEqualXTypes.InvariantMode.Stable) {
            ctx.tokenADecimals = LibCurrency.decimalsOrRevert(ctx.tokenA);
            ctx.tokenBDecimals = LibCurrency.decimalsOrRevert(ctx.tokenB);
            LibEqualXSwapMath.validateStableDecimals(ctx.tokenADecimals, ctx.tokenBDecimals);
        } else {
            ctx.tokenADecimals = LibCurrency.decimals(ctx.tokenA);
            ctx.tokenBDecimals = LibCurrency.decimals(ctx.tokenB);
        }

        _lockReserveBacking(poolA, ctx.creatorPositionKey, request.poolIdA, request.reserveA);
        _lockReserveBacking(poolB, ctx.creatorPositionKey, request.poolIdB, request.reserveB);
    }

    function _initializeCommunityMarket(CreateMarketRequest memory request, CreateMarketContext memory ctx)
        internal
        returns (uint256 marketId)
    {
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        marketId = LibEqualXCommunityAmmStorage.allocateMarketId(store);
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        market.creatorPositionKey = ctx.creatorPositionKey;
        market.creatorPositionId = request.creatorPositionId;
        market.poolIdA = request.poolIdA;
        market.poolIdB = request.poolIdB;
        market.tokenA = ctx.tokenA;
        market.tokenB = ctx.tokenB;
        market.reserveA = request.reserveA;
        market.reserveB = request.reserveB;
        market.totalShares = Math.sqrt(Math.mulDiv(request.reserveA, request.reserveB, 1));
        market.makerCount = 1;
        market.startTime = request.startTime;
        market.endTime = request.endTime;
        market.feeBps = request.feeBps;
        market.feeAsset = request.feeAsset;
        market.invariantMode = request.invariantMode;
        market.tokenADecimals = ctx.tokenADecimals;
        market.tokenBDecimals = ctx.tokenBDecimals;
        market.active = true;

        LibEqualXCommunityAmmStorage.CommunityMakerPosition storage maker = store.makers[marketId][ctx.creatorPositionKey];
        maker.share = market.totalShares;
        maker.initialContributionA = request.reserveA;
        maker.initialContributionB = request.reserveB;
        maker.isParticipant = true;

        LibEqualXDiscoveryStorage.registerMarket(
            LibEqualXDiscoveryStorage.s(),
            ctx.creatorPositionKey,
            market.tokenA,
            market.tokenB,
            LibEqualXTypes.MarketType.COMMUNITY_AMM,
            marketId
        );

        emit EqualXCommunityAmmMarketCreated(
            marketId,
            ctx.creatorPositionKey,
            request.creatorPositionId,
            request.poolIdA,
            request.poolIdB,
            request.reserveA,
            request.reserveB
        );
    }

    function joinEqualXCommunityAmmMarket(uint256 marketId, uint256 positionId, uint256 amountA, uint256 amountB)
        external
        nonReentrant
    {
        if (amountA == 0 || amountB == 0) revert InvalidParameterRange("join=0");
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        _requireJoinActive(marketId, market);

        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibPositionHelpers.requireOwnership(positionId);

        if (!LibPoolMembership.isMember(positionKey, market.poolIdA)) {
            revert PoolMembershipRequired(positionKey, market.poolIdA);
        }
        if (!LibPoolMembership.isMember(positionKey, market.poolIdB)) {
            revert PoolMembershipRequired(positionKey, market.poolIdB);
        }

        LibEqualXCommunityAmmStorage.CommunityMakerPosition storage maker = store.makers[marketId][positionKey];
        bool newParticipant = !maker.isParticipant;

        _validateJoinRatio(market, amountA, amountB);

        if (!newParticipant) {
            LibEqualXCommunityFeeIndex.settleMaker(marketId, positionKey);
        }

        _settlePositionState(market.poolIdA, positionKey);
        _settlePositionState(market.poolIdB, positionKey);
        Types.PoolData storage poolA = LibPositionHelpers.pool(market.poolIdA);
        Types.PoolData storage poolB = LibPositionHelpers.pool(market.poolIdB);
        _requireAvailableBacking(poolA, positionKey, market.poolIdA, amountA);
        _requireAvailableBacking(poolB, positionKey, market.poolIdB, amountB);
        _lockReserveBacking(poolA, positionKey, market.poolIdA, amountA);
        _lockReserveBacking(poolB, positionKey, market.poolIdB, amountB);

        uint256 share;
        if (market.totalShares == 0) {
            share = Math.sqrt(Math.mulDiv(amountA, amountB, 1));
        } else {
            uint256 shareA = Math.mulDiv(amountA, market.totalShares, market.reserveA);
            uint256 shareB = Math.mulDiv(amountB, market.totalShares, market.reserveB);
            share = shareA < shareB ? shareA : shareB;
        }
        maker.share += share;
        maker.initialContributionA += amountA;
        maker.initialContributionB += amountB;
        maker.isParticipant = true;

        market.totalShares += share;
        if (newParticipant) {
            market.makerCount += 1;
            LibEqualXDiscoveryStorage.addPositionMarket(
                LibEqualXDiscoveryStorage.s(), positionKey, LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId
            );
        }
        market.reserveA += amountA;
        market.reserveB += amountB;

        LibEqualXCommunityFeeIndex.snapshotIndexes(marketId, positionKey);

        emit EqualXCommunityAmmMakerJoined(marketId, positionKey, positionId, amountA, amountB, share);
    }

    function claimEqualXCommunityAmmFees(uint256 marketId, uint256 positionId)
        external
        nonReentrant
        returns (uint256 feesA, uint256 feesB)
    {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibPositionHelpers.requireOwnership(positionId);

        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityMakerPosition storage maker = store.makers[marketId][positionKey];
        if (!maker.isParticipant || maker.share == 0) {
            revert EqualXCommunityAmm_NotParticipant(positionKey);
        }

        (feesA, feesB) = LibEqualXCommunityFeeIndex.settleMaker(marketId, positionKey);
        if (feesA > 0 || feesB > 0) {
            LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
            _backSettledMakerFees(
                market,
                LibPositionHelpers.pool(market.poolIdA),
                LibPositionHelpers.pool(market.poolIdB),
                feesA,
                feesB
            );
        }

        emit EqualXCommunityAmmFeesClaimed(marketId, positionKey, feesA, feesB);
    }

    function leaveEqualXCommunityAmmMarket(uint256 marketId, uint256 positionId)
        external
        nonReentrant
        returns (uint256 withdrawnA, uint256 withdrawnB, uint256 feesA, uint256 feesB)
    {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibPositionHelpers.requireOwnership(positionId);

        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        if (market.finalized && market.totalShares == 0) {
            revert EqualXCommunityAmm_AlreadyFinalized(marketId);
        }

        LibEqualXCommunityAmmStorage.CommunityMakerPosition storage maker = store.makers[marketId][positionKey];
        if (!maker.isParticipant || maker.share == 0) {
            revert EqualXCommunityAmm_NotParticipant(positionKey);
        }

        Types.PoolData storage poolA = LibPositionHelpers.pool(market.poolIdA);
        Types.PoolData storage poolB = LibPositionHelpers.pool(market.poolIdB);
        LeaveSettlement memory settlement;
        (settlement, feesA, feesB) = _prepareLeaveSettlement(marketId, market, maker, positionKey, poolA, poolB);
        _applyLeaveSettlement(market, positionKey, poolA, poolB, settlement);

        withdrawnA = settlement.withdrawnA;
        withdrawnB = settlement.withdrawnB;
        market.totalShares = market.totalShares - maker.share;
        market.makerCount -= 1;

        maker.share = 0;
        maker.initialContributionA = 0;
        maker.initialContributionB = 0;
        maker.isParticipant = false;

        _finalizeIfEmpty(marketId, market);

        emit EqualXCommunityAmmMakerLeft(marketId, positionKey, positionId, withdrawnA, withdrawnB, feesA, feesB);
    }

    function previewEqualXCommunityAmmSwapExactIn(
        uint256 marketId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (CommunityAmmSwapPreview memory preview) {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
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
                LibEqualXSwapMath.splitFeeWithRouter(preview.feeAmount, COMMUNITY_AMM_MAKER_SHARE_BPS);
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

    function swapEqualXCommunityAmmExactIn(
        uint256 marketId,
        address tokenIn,
        uint256 amountIn,
        uint256 maxIn,
        uint256 minOut,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidParameterRange("amountIn=0");
        if (recipient == address(0)) revert InvalidParameterRange("recipient=0");

        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        _requireSwapActive(marketId, market);

        SwapContext memory ctx = _prepareSwapContext(market, tokenIn);
        LibCurrency.assertMsgValue(tokenIn, amountIn);
        ctx.actualIn = LibCurrency.pullAtLeast(tokenIn, msg.sender, amountIn, maxIn);
        if (ctx.actualIn == 0) revert InvalidParameterRange("actualIn=0");

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
            revert EqualXCommunityAmm_StableZeroOutput();
        }
        if (outputToRecipient < minOut) {
            revert EqualXCommunityAmm_Slippage(minOut, outputToRecipient);
        }
        amountOut = outputToRecipient;

        LibEqualXSwapMath.FeeSplit memory split =
            LibEqualXSwapMath.splitFeeWithRouter(feeAmount, COMMUNITY_AMM_MAKER_SHARE_BPS);
        ctx.newReserveIn = ctx.reserveIn + ctx.actualIn;
        ctx.newReserveOut = ctx.reserveOut - outputToRecipient;
        if (split.treasuryFee > 0) {
            bool ok;
            (ctx.newReserveIn, ctx.newReserveOut, ok) =
                LibEqualXSwapMath.applyProtocolFee(market.feeAsset, ctx.newReserveIn, ctx.newReserveOut, split.treasuryFee);
            if (!ok) revert InsufficientPrincipal(split.treasuryFee, ctx.newReserveOut);
        }

        if (ctx.inIsA) {
            market.reserveA = ctx.newReserveIn;
            market.reserveB = ctx.newReserveOut;
        } else {
            market.reserveB = ctx.newReserveIn;
            market.reserveA = ctx.newReserveOut;
        }

        if (split.makerFee > 0) {
            if (ctx.feeToken == market.tokenA) {
                LibEqualXCommunityFeeIndex.accrueTokenAFee(marketId, split.makerFee);
            } else {
                LibEqualXCommunityFeeIndex.accrueTokenBFee(marketId, split.makerFee);
            }
        }

        if (split.protocolFee > 0) {
            TransientSwapCache.cacheFeePool(ctx.feePoolId);
            uint256 cachedFeePoolId = TransientSwapCache.loadFeePool();
            if (cachedFeePoolId != 0) {
                ctx.feePoolId = cachedFeePoolId;
            }
            uint256 extraBacking = _feeSideReserve(market, ctx.feePoolId);
            (uint256 toTreasury, uint256 toActive, uint256 toIndex) =
                LibFeeRouter.routeSamePool(ctx.feePoolId, split.protocolFee, COMMUNITY_AMM_FEE_SOURCE, false, extraBacking);

            if (toTreasury > 0) {
                if (ctx.feeToken == market.tokenA) {
                    market.treasuryFeeAAccrued += toTreasury;
                } else {
                    market.treasuryFeeBAccrued += toTreasury;
                }
            }
            if (toActive > 0 || toIndex > 0) {
                Types.PoolData storage feePool =
                    ctx.feePoolId == market.poolIdA ? LibPositionHelpers.pool(market.poolIdA) : LibPositionHelpers.pool(market.poolIdB);
                feePool.trackedBalance += toActive + toIndex;
                if (LibCurrency.isNative(feePool.underlying)) {
                    LibAppStorage.s().nativeTrackedTotal += toActive + toIndex;
                }
                if (ctx.feePoolId == market.poolIdA) {
                    market.activeCreditFeeAAccrued += toActive;
                    market.feeIndexFeeAAccrued += toIndex;
                } else {
                    market.activeCreditFeeBAccrued += toActive;
                    market.feeIndexFeeBAccrued += toIndex;
                }
            }
        }

        LibCurrency.transferWithMin(ctx.tokenOut, recipient, outputToRecipient, minOut);

        emit EqualXCommunityAmmSwap(marketId, msg.sender, tokenIn, ctx.actualIn, outputToRecipient, feeAmount, recipient);
    }

    function finalizeEqualXCommunityAmmMarket(uint256 marketId) external nonReentrant {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        _requireMarketExists(marketId, market);
        if (!market.active) revert EqualXCommunityAmm_InvalidMarket(marketId);
        if (market.finalized) revert EqualXCommunityAmm_AlreadyFinalized(marketId);
        if (block.timestamp < market.endTime) revert EqualXCommunityAmm_NotExpired(marketId);

        market.active = false;
        market.finalized = true;
        LibEqualXDiscoveryStorage.removeActiveMarket(
            LibEqualXDiscoveryStorage.s(), LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId
        );

        emit EqualXCommunityAmmMarketFinalized(marketId, market.creatorPositionKey);
    }

    function cancelEqualXCommunityAmmMarket(uint256 marketId) external nonReentrant {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        _requireMarketExists(marketId, market);
        if (!market.active) revert EqualXCommunityAmm_InvalidMarket(marketId);
        if (market.finalized) revert EqualXCommunityAmm_AlreadyFinalized(marketId);
        if (block.timestamp >= market.startTime) revert EqualXCommunityAmm_NotStarted(marketId);
        LibPositionHelpers.requireOwnership(market.creatorPositionId);

        market.active = false;
        market.finalized = true;
        LibEqualXDiscoveryStorage.removeActiveMarket(
            LibEqualXDiscoveryStorage.s(), LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId
        );

        emit EqualXCommunityAmmMarketCancelled(marketId, market.creatorPositionKey);
    }

    function _requireMarketExists(
        uint256 marketId,
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market
    ) internal view {
        if (marketId == 0 || market.creatorPositionId == 0) {
            revert EqualXCommunityAmm_InvalidMarket(marketId);
        }
    }

    function _requireJoinActive(
        uint256 marketId,
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market
    ) internal view {
        _requireMarketExists(marketId, market);
        if (!market.active) revert EqualXCommunityAmm_InvalidMarket(marketId);
        if (market.finalized) revert EqualXCommunityAmm_AlreadyFinalized(marketId);
        if (block.timestamp >= market.endTime) revert EqualXCommunityAmm_Expired(marketId);
    }

    function _requireSwapActive(
        uint256 marketId,
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market
    ) internal view {
        _requireMarketExists(marketId, market);
        if (!market.active) revert EqualXCommunityAmm_InvalidMarket(marketId);
        if (market.finalized) revert EqualXCommunityAmm_AlreadyFinalized(marketId);
        if (market.totalShares == 0) revert EqualXCommunityAmm_InvalidMarket(marketId);
        if (block.timestamp < market.startTime) revert EqualXCommunityAmm_NotStarted(marketId);
        if (block.timestamp >= market.endTime) revert EqualXCommunityAmm_Expired(marketId);
    }

    function _isTokenA(address tokenIn, LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market)
        internal
        view
        returns (bool)
    {
        if (tokenIn == market.tokenA) return true;
        if (tokenIn == market.tokenB) return false;
        revert EqualXCommunityAmm_InvalidToken(tokenIn);
    }

    function _prepareSwapContext(
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market,
        address tokenIn
    ) internal returns (SwapContext memory ctx) {
        ctx.inIsA = _isTokenA(tokenIn, market);
        ctx.reserveIn = ctx.inIsA ? market.reserveA : market.reserveB;
        ctx.reserveOut = ctx.inIsA ? market.reserveB : market.reserveA;
        ctx.decimalsIn = ctx.inIsA ? market.tokenADecimals : market.tokenBDecimals;
        ctx.decimalsOut = ctx.inIsA ? market.tokenBDecimals : market.tokenADecimals;
        ctx.tokenOut = ctx.inIsA ? market.tokenB : market.tokenA;
        TransientSwapCache.cacheReserves(ctx.reserveIn, ctx.reserveOut);
        if (market.feeAsset == LibEqualXTypes.FeeAsset.TokenIn) {
            ctx.feePoolId = ctx.inIsA ? market.poolIdA : market.poolIdB;
            ctx.feeToken = tokenIn;
        } else {
            ctx.feePoolId = ctx.inIsA ? market.poolIdB : market.poolIdA;
            ctx.feeToken = ctx.tokenOut;
        }
    }

    function _settlePositionState(uint256 pid, bytes32 positionKey) internal {
        LibFeeIndex.settle(pid, positionKey);
        LibActiveCreditIndex.settle(pid, positionKey);
    }

    function _prepareLeaveSettlement(
        uint256 marketId,
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market,
        LibEqualXCommunityAmmStorage.CommunityMakerPosition storage maker,
        bytes32 positionKey,
        Types.PoolData storage poolA,
        Types.PoolData storage poolB
    ) internal returns (LeaveSettlement memory settlement, uint256 feesA, uint256 feesB) {
        LibActiveCreditIndex.settle(market.poolIdA, positionKey);
        LibActiveCreditIndex.settle(market.poolIdB, positionKey);

        (feesA, feesB) = LibEqualXCommunityFeeIndex.settleMaker(marketId, positionKey);
        _backSettledMakerFees(market, poolA, poolB, feesA, feesB);

        uint256 totalShares = market.totalShares;
        if (totalShares > 0) {
            uint256 reservedA = market.feeIndexFeeAAccrued + market.activeCreditFeeAAccrued;
            uint256 reservedB = market.feeIndexFeeBAccrued + market.activeCreditFeeBAccrued;
            uint256 withdrawableReserveA = market.reserveA > reservedA ? market.reserveA - reservedA : 0;
            uint256 withdrawableReserveB = market.reserveB > reservedB ? market.reserveB - reservedB : 0;
            settlement.withdrawnA = Math.mulDiv(withdrawableReserveA, maker.share, totalShares);
            settlement.withdrawnB = Math.mulDiv(withdrawableReserveB, maker.share, totalShares);
        }
        settlement.initialA = maker.initialContributionA;
        settlement.initialB = maker.initialContributionB;
    }

    function _applyLeaveSettlement(
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market,
        bytes32 positionKey,
        Types.PoolData storage poolA,
        Types.PoolData storage poolB,
        LeaveSettlement memory settlement
    ) internal {
        _applyPrincipalDelta(poolA, market.poolIdA, positionKey, settlement.withdrawnA, settlement.initialA);
        _applyPrincipalDelta(poolB, market.poolIdB, positionKey, settlement.withdrawnB, settlement.initialB);

        if (settlement.initialA > 0) {
            _unlockReserveBacking(positionKey, market.poolIdA, settlement.initialA);
            LibActiveCreditIndex.applyEncumbranceDecrease(
                poolA, market.poolIdA, positionKey, settlement.initialA
            );
        }
        if (settlement.initialB > 0) {
            _unlockReserveBacking(positionKey, market.poolIdB, settlement.initialB);
            LibActiveCreditIndex.applyEncumbranceDecrease(
                poolB, market.poolIdB, positionKey, settlement.initialB
            );
        }

        market.reserveA -= settlement.withdrawnA;
        market.reserveB -= settlement.withdrawnB;
    }

    function _finalizeIfEmpty(
        uint256 marketId,
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market
    ) internal {
        if (market.totalShares != 0) return;

        bool wasActive = market.active;
        market.active = false;
        market.finalized = true;

        uint256 reservedA = market.feeIndexFeeAAccrued + market.activeCreditFeeAAccrued;
        uint256 reservedB = market.feeIndexFeeBAccrued + market.activeCreditFeeBAccrued;
        if (reservedA > 0) {
            market.reserveA -= reservedA;
            market.feeIndexFeeAAccrued = 0;
            market.activeCreditFeeAAccrued = 0;
        }
        if (reservedB > 0) {
            market.reserveB -= reservedB;
            market.feeIndexFeeBAccrued = 0;
            market.activeCreditFeeBAccrued = 0;
        }
        if (wasActive) {
            LibEqualXDiscoveryStorage.removeActiveMarket(
                LibEqualXDiscoveryStorage.s(), LibEqualXTypes.MarketType.COMMUNITY_AMM, marketId
            );
        }
    }

    function _requireAvailableBacking(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 poolId,
        uint256 amount
    ) internal {
        uint256 available = LibPositionHelpers.settledAvailablePrincipal(pool, positionKey, poolId);
        if (amount > available) revert InsufficientPrincipal(amount, available);
    }

    function _lockReserveBacking(
        Types.PoolData storage pool,
        bytes32 positionKey,
        uint256 poolId,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        LibPositionHelpers.settlePosition(poolId, positionKey);
        LibEncumbrance.position(positionKey, poolId).encumberedCapital += amount;
        LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
    }

    function _unlockReserveBacking(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) return;
        LibPositionHelpers.settlePosition(poolId, positionKey);
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 currentEncumberedCapital = enc.encumberedCapital;
        if (currentEncumberedCapital < amount) revert InsufficientPrincipal(amount, currentEncumberedCapital);
        enc.encumberedCapital = currentEncumberedCapital - amount;
    }

    function _validateJoinRatio(
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market,
        uint256 amountA,
        uint256 amountB
    ) internal view {
        if (market.reserveA == 0 || market.reserveB == 0) {
            revert InvalidParameterRange("marketReserve=0");
        }
        uint256 expectedB = Math.mulDiv(amountA, market.reserveB, market.reserveA);
        uint256 tolerance = expectedB / 1000;
        uint256 lower = expectedB > tolerance ? expectedB - tolerance : 0;
        if (amountB < lower || amountB > expectedB + tolerance) {
            revert EqualXCommunityAmm_InvalidRatio(expectedB, amountB);
        }
    }

    function _applyPrincipalDelta(
        Types.PoolData storage pool,
        uint256 pid,
        bytes32 positionKey,
        uint256 currentReserve,
        uint256 initialReserve
    ) internal {
        if (currentReserve == initialReserve) return;

        LibFeeIndex.settle(pid, positionKey);
        if (currentReserve > initialReserve) {
            uint256 deltaIncrease = currentReserve - initialReserve;
            pool.userPrincipal[positionKey] += deltaIncrease;
            pool.totalDeposits += deltaIncrease;
            pool.trackedBalance += deltaIncrease;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += deltaIncrease;
            }
            return;
        }

        uint256 deltaDecrease = initialReserve - currentReserve;
        uint256 principal = pool.userPrincipal[positionKey];
        if (principal < deltaDecrease) revert InsufficientPrincipal(deltaDecrease, principal);
        pool.userPrincipal[positionKey] = principal - deltaDecrease;
        pool.totalDeposits -= deltaDecrease;
        if (pool.trackedBalance < deltaDecrease) revert InsufficientPrincipal(deltaDecrease, pool.trackedBalance);
        pool.trackedBalance -= deltaDecrease;
        if (LibCurrency.isNative(pool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= deltaDecrease;
        }
    }

    function _backSettledMakerFees(
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market,
        Types.PoolData storage poolA,
        Types.PoolData storage poolB,
        uint256 feesA,
        uint256 feesB
    ) internal {
        if (feesA > 0) {
            if (market.reserveA < feesA) revert InsufficientPrincipal(feesA, market.reserveA);
            market.reserveA -= feesA;
            poolA.yieldReserve += feesA;
            poolA.trackedBalance += feesA;
            if (LibCurrency.isNative(poolA.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += feesA;
            }
        }
        if (feesB > 0) {
            if (market.reserveB < feesB) revert InsufficientPrincipal(feesB, market.reserveB);
            market.reserveB -= feesB;
            poolB.yieldReserve += feesB;
            poolB.trackedBalance += feesB;
            if (LibCurrency.isNative(poolB.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += feesB;
            }
        }
    }

    function _feeSideReserve(
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market,
        uint256 feePoolId
    ) internal view returns (uint256) {
        return feePoolId == market.poolIdA ? market.reserveA : market.reserveB;
    }
}
