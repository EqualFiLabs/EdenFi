// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEqualXCurveEngine} from "../libraries/LibEqualXCurveEngine.sol";
import {LibEqualXCurveStorage} from "../libraries/LibEqualXCurveStorage.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";

/// @notice Execution surface for EqualX curve liquidity.
contract EqualXCurveExecutionFacet is ReentrancyGuardModifiers {
    function previewEqualXCurveQuote(uint256 curveId, uint256 amountIn)
        external
        view
        returns (LibEqualXCurveEngine.CurveExecutionPreview memory preview)
    {
        preview = LibEqualXCurveEngine.previewCurveQuote(curveId, amountIn);
    }

    function getEqualXCurveCommitment(uint256 curveId) external view returns (uint32 generation, bytes32 commitment) {
        LibEqualXCurveStorage.CurveMarket storage market = LibEqualXCurveStorage.s().markets[curveId];
        generation = market.generation;
        commitment = market.commitment;
    }

    function executeEqualXCurveSwap(
        uint256 curveId,
        uint256 amountIn,
        uint256 maxQuote,
        uint256 minOut,
        uint64 deadline,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        (uint32 generation, bytes32 commitment) = LibEqualXCurveEngine.currentCommitment(curveId);
        amountOut = LibEqualXCurveEngine.executeCurveSwap(
            LibEqualXCurveEngine.CurveExecutionRequest({
                curveId: curveId,
                amountIn: amountIn,
                maxQuote: maxQuote,
                minOut: minOut,
                deadline: deadline,
                recipient: recipient,
                expectedGeneration: generation,
                expectedCommitment: commitment
            })
        );
    }

    function executeEqualXCurveSwap(
        uint256 curveId,
        uint256 amountIn,
        uint256 maxQuote,
        uint256 minOut,
        uint64 deadline,
        address recipient,
        uint32 expectedGeneration,
        bytes32 expectedCommitment
    ) external payable nonReentrant returns (uint256 amountOut) {
        amountOut = LibEqualXCurveEngine.executeCurveSwap(
            LibEqualXCurveEngine.CurveExecutionRequest({
                curveId: curveId,
                amountIn: amountIn,
                maxQuote: maxQuote,
                minOut: minOut,
                deadline: deadline,
                recipient: recipient,
                expectedGeneration: expectedGeneration,
                expectedCommitment: expectedCommitment
            })
        );
    }
}
