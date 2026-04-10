// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEqualXTypes} from "../libraries/LibEqualXTypes.sol";

abstract contract EqualXCommunityAmmTypes {
    bytes32 internal constant COMMUNITY_AMM_FEE_SOURCE = keccak256("EQUALX_COMMUNITY_AMM_FEE");

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
}
