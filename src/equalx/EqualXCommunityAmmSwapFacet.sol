// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEqualXCommunityAmmStorage} from "../libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCommunityFeeIndex} from "../libraries/LibEqualXCommunityFeeIndex.sol";
import {LibEqualXDiscoveryStorage} from "../libraries/LibEqualXDiscoveryStorage.sol";
import {LibEqualXSwapMath} from "../libraries/LibEqualXSwapMath.sol";
import {LibEqualXTypes} from "../libraries/LibEqualXTypes.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import {InsufficientPrincipal, InvalidParameterRange} from "../libraries/Errors.sol";
import {EqualXCommunityAmmTypes} from "./EqualXCommunityAmmTypes.sol";

/// @notice EqualX community AMM swap surface.
contract EqualXCommunityAmmSwapFacet is ReentrancyGuardModifiers, EqualXCommunityAmmTypes {
    function previewEqualXCommunityAmmSwapExactIn(
        uint256 marketId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (CommunityAmmSwapPreview memory preview) {
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = LibEqualXCommunityAmmStorage.s().markets[marketId];
        _requireSwapMarketExists(marketId, market);
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
                LibEqualXSwapMath.splitFeeWithRouter(preview.feeAmount, LibEqualXSwapMath.equalXMakerShareBps());
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
            LibEqualXSwapMath.splitFeeWithRouter(feeAmount, LibEqualXSwapMath.equalXMakerShareBps());
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
            uint256 extraBacking = _feeSideReserve(market, ctx.feePoolId);
            (uint256 toTreasury, uint256 toActive, uint256 toIndex) =
                LibFeeRouter.routeSamePoolPreSplit(
                    ctx.feePoolId,
                    split.treasuryFee,
                    split.activeCreditFee,
                    split.feeIndexFee,
                    COMMUNITY_AMM_FEE_SOURCE,
                    false,
                    extraBacking
                );

            toTreasury;
            if (toActive > 0 || toIndex > 0) {
                Types.PoolData storage feePool =
                    ctx.feePoolId == market.poolIdA ? LibPositionHelpers.pool(market.poolIdA) : LibPositionHelpers.pool(market.poolIdB);
                feePool.trackedBalance += toActive + toIndex;
                if (LibCurrency.isNative(feePool.underlying)) {
                    LibAppStorage.s().nativeTrackedTotal += toActive + toIndex;
                }
                if (ctx.feePoolId == market.poolIdA) {
                    market.feeIndexFeeAAccrued += toActive + toIndex;
                } else {
                    market.feeIndexFeeBAccrued += toActive + toIndex;
                }
            }
        }

        LibCurrency.transferWithMin(ctx.tokenOut, recipient, outputToRecipient, minOut);

        emit EqualXCommunityAmmSwap(marketId, msg.sender, tokenIn, ctx.actualIn, outputToRecipient, feeAmount, recipient);
    }

    function _requireSwapMarketExists(
        uint256 marketId,
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market
    ) internal view {
        if (marketId == 0 || market.creatorPositionId == 0) {
            revert EqualXCommunityAmm_InvalidMarket(marketId);
        }
    }

    function _requireSwapActive(
        uint256 marketId,
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market
    ) internal view {
        _requireSwapMarketExists(marketId, market);
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
    ) internal view returns (SwapContext memory ctx) {
        ctx.inIsA = _isTokenA(tokenIn, market);
        ctx.reserveIn = ctx.inIsA ? market.reserveA : market.reserveB;
        ctx.reserveOut = ctx.inIsA ? market.reserveB : market.reserveA;
        ctx.decimalsIn = ctx.inIsA ? market.tokenADecimals : market.tokenBDecimals;
        ctx.decimalsOut = ctx.inIsA ? market.tokenBDecimals : market.tokenADecimals;
        ctx.tokenOut = ctx.inIsA ? market.tokenB : market.tokenA;
        if (market.feeAsset == LibEqualXTypes.FeeAsset.TokenIn) {
            ctx.feePoolId = ctx.inIsA ? market.poolIdA : market.poolIdB;
            ctx.feeToken = tokenIn;
        } else {
            ctx.feePoolId = ctx.inIsA ? market.poolIdB : market.poolIdA;
            ctx.feeToken = ctx.tokenOut;
        }
    }

    function _feeSideReserve(
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market,
        uint256 feePoolId
    ) internal view returns (uint256) {
        return feePoolId == market.poolIdA ? market.reserveA : market.reserveB;
    }
}
