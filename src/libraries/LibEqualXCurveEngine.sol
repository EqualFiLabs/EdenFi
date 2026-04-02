// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurveProfile} from "../interfaces/ICurveProfile.sol";
import {LibActiveCreditIndex} from "./LibActiveCreditIndex.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibCurrency} from "./LibCurrency.sol";
import {LibEncumbrance} from "./LibEncumbrance.sol";
import {LibEqualXCurveStorage} from "./LibEqualXCurveStorage.sol";
import {LibEqualXDiscoveryStorage} from "./LibEqualXDiscoveryStorage.sol";
import {LibEqualXTypes} from "./LibEqualXTypes.sol";
import {LibFeeIndex} from "./LibFeeIndex.sol";
import {LibFeeRouter} from "./LibFeeRouter.sol";
import {LibPoolMembership} from "./LibPoolMembership.sol";
import {LibPositionHelpers} from "./LibPositionHelpers.sol";
import {Types} from "./Types.sol";
import {InsufficientPrincipal, InvalidParameterRange, PoolMembershipRequired} from "./Errors.sol";

library LibEqualXCurveEngine {
    bytes32 internal constant CURVE_FEE_SOURCE = keccak256("EQUALX_CURVE_FILL");
    bytes32 internal constant CURVE_DOMAIN_SEPARATOR = keccak256("EQUALX_CURVE_V1");
    uint16 internal constant BUILTIN_LINEAR_PROFILE_ID = 1;
    uint256 internal constant MAX_PAST_START = 30 minutes;
    uint256 internal constant WAD = 1e18;

    error EqualXCurve_InvalidAmount(uint256 amount);
    error EqualXCurve_InvalidCurve(uint256 curveId);
    error EqualXCurve_InvalidDescriptor();
    error EqualXCurve_InvalidTimeWindow(uint64 startTime, uint64 duration);
    error EqualXCurve_NotActive(uint256 curveId);
    error EqualXCurve_Expired(uint256 curveId);
    error EqualXCurve_NotExpired(uint256 curveId);
    error EqualXCurve_InsufficientVolume(uint256 requested, uint256 available);
    error EqualXCurve_Slippage(uint256 minOut, uint256 actualOut);
    error EqualXCurve_GenerationMismatch(uint32 expected, uint32 actual);
    error EqualXCurve_CommitmentMismatch(bytes32 expected, bytes32 actual);
    error EqualXCurve_InvalidProfileId(uint16 profileId);
    error EqualXCurve_NotBuiltInLinearProfile(uint16 profileId);
    error EqualXCurve_ProfileNotApproved(uint16 profileId);

    event EqualXCurveCreated(
        uint256 indexed curveId,
        bytes32 indexed makerPositionKey,
        uint256 indexed makerPositionId,
        bool baseIsA,
        uint128 maxVolume,
        uint256 poolIdA,
        uint256 poolIdB
    );
    event EqualXCurveUpdated(uint256 indexed curveId, bytes32 indexed makerPositionKey, uint32 generation);
    event EqualXCurveCancelled(uint256 indexed curveId, bytes32 indexed makerPositionKey, uint256 remainingVolume);
    event EqualXCurveExpired(uint256 indexed curveId, bytes32 indexed makerPositionKey, uint256 remainingVolume);
    event EqualXCurveFilled(
        uint256 indexed curveId,
        address indexed taker,
        address indexed recipient,
        uint256 amountIn,
        uint256 actualIn,
        uint256 amountOut,
        uint256 feeAmount,
        uint256 remainingVolume
    );

    struct CurveDescriptor {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        bool side;
        bool priceIsQuotePerBase;
        uint128 maxVolume;
        uint128 startPrice;
        uint128 endPrice;
        uint64 startTime;
        uint64 duration;
        uint32 generation;
        uint16 feeRateBps;
        LibEqualXTypes.FeeAsset feeAsset;
        uint96 salt;
        uint16 profileId;
        bytes32 profileParams;
    }

    struct CurveUpdateParams {
        uint128 startPrice;
        uint128 endPrice;
        uint64 startTime;
        uint64 duration;
        bool updateProfile;
        uint16 profileId;
        bool updateProfileParams;
        bytes32 profileParams;
    }

    struct CurveExecutionPreview {
        uint256 price;
        uint256 amountOut;
        uint256 feeAmount;
        uint256 totalQuote;
        uint256 remainingAfter;
        uint256 basePoolId;
        uint256 quotePoolId;
        address baseToken;
        address quoteToken;
        bool baseIsA;
    }

    struct CurveExecutionRequest {
        uint256 curveId;
        uint256 amountIn;
        uint256 maxQuote;
        uint256 minOut;
        uint64 deadline;
        address recipient;
        uint32 expectedGeneration;
        bytes32 expectedCommitment;
    }

    function createCurve(CurveDescriptor calldata desc) internal returns (uint256 curveId) {
        bytes32 positionKey = LibPositionHelpers.positionKey(desc.makerPositionId);
        LibPositionHelpers.requireOwnership(desc.makerPositionId);
        if (desc.makerPositionKey != positionKey) revert EqualXCurve_InvalidDescriptor();

        (bool baseIsA, uint256 endTime) = _validateDescriptor(desc, positionKey);
        uint256 basePoolId = baseIsA ? desc.poolIdA : desc.poolIdB;
        _lockCollateral(positionKey, basePoolId, desc.maxVolume);

        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        curveId = LibEqualXCurveStorage.allocateCurveId(store);
        _storeCreatedCurve(store, curveId, desc, positionKey, baseIsA, endTime);

        LibEqualXDiscoveryStorage.registerMarket(
            LibEqualXDiscoveryStorage.s(),
            positionKey,
            desc.tokenA,
            desc.tokenB,
            LibEqualXTypes.MarketType.CURVE_LIQUIDITY,
            curveId
        );

        _emitCurveCreated(curveId, positionKey, desc, baseIsA);
    }

    function updateCurve(uint256 curveId, CurveUpdateParams calldata params) internal {
        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        LibEqualXCurveStorage.CurveMarket storage market = store.markets[curveId];
        _requireActiveCurve(curveId, market);

        if (params.startPrice == 0 || params.endPrice == 0) revert EqualXCurve_InvalidDescriptor();
        if (params.duration == 0) revert EqualXCurve_InvalidTimeWindow(params.startTime, params.duration);
        if (params.startTime < block.timestamp) revert EqualXCurve_InvalidTimeWindow(params.startTime, params.duration);

        uint256 endTime = uint256(params.startTime) + uint256(params.duration);
        if (endTime > type(uint64).max) revert EqualXCurve_InvalidTimeWindow(params.startTime, params.duration);

        LibEqualXCurveStorage.CurveData storage data = store.curveData[curveId];
        bytes32 positionKey = LibPositionHelpers.positionKey(data.makerPositionId);
        LibPositionHelpers.requireOwnership(data.makerPositionId);
        if (positionKey != data.makerPositionKey) revert EqualXCurve_InvalidDescriptor();

        LibEqualXCurveStorage.CurveProfileData storage profileData = store.curveProfileData[curveId];

        uint16 nextProfileId = profileData.profileId;
        bytes32 nextProfileParams = profileData.profileParams;
        if (params.updateProfile) {
            _enforceProfileApprovedForMutation(params.profileId);
            nextProfileId = params.profileId;
        }
        if (params.updateProfileParams) {
            nextProfileParams = params.profileParams;
        }

        uint32 newGeneration = _applyCurveUpdate(store, curveId, params, nextProfileId, nextProfileParams, endTime);
        profileData.profileId = nextProfileId;
        profileData.profileParams = nextProfileParams;

        emit EqualXCurveUpdated(curveId, data.makerPositionKey, newGeneration);
    }

    function cancelCurve(uint256 curveId) internal {
        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        LibEqualXCurveStorage.CurveMarket storage market = store.markets[curveId];
        _requireActiveCurve(curveId, market);

        LibEqualXCurveStorage.CurveData storage data = store.curveData[curveId];
        bytes32 positionKey = LibPositionHelpers.positionKey(data.makerPositionId);
        LibPositionHelpers.requireOwnership(data.makerPositionId);
        if (positionKey != data.makerPositionKey) revert EqualXCurve_InvalidDescriptor();

        uint256 remaining = market.remainingVolume;
        if (remaining > 0) {
            uint256 basePoolId = store.curveBaseIsA[curveId] ? data.poolIdA : data.poolIdB;
            _unlockCollateral(data.makerPositionKey, basePoolId, remaining);
        }

        market.active = false;
        market.remainingVolume = 0;
        market.commitment = bytes32(0);
        LibEqualXDiscoveryStorage.removeActiveMarket(
            LibEqualXDiscoveryStorage.s(), LibEqualXTypes.MarketType.CURVE_LIQUIDITY, curveId
        );

        emit EqualXCurveCancelled(curveId, data.makerPositionKey, remaining);
    }

    function expireCurve(uint256 curveId) internal {
        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        LibEqualXCurveStorage.CurveMarket storage market = store.markets[curveId];
        _requireActiveCurve(curveId, market);
        if (block.timestamp <= market.endTime) revert EqualXCurve_NotExpired(curveId);

        LibEqualXCurveStorage.CurveData storage data = store.curveData[curveId];
        uint256 remaining = market.remainingVolume;
        if (remaining > 0) {
            uint256 basePoolId = store.curveBaseIsA[curveId] ? data.poolIdA : data.poolIdB;
            _unlockCollateral(data.makerPositionKey, basePoolId, remaining);
        }

        market.active = false;
        market.remainingVolume = 0;
        market.commitment = bytes32(0);
        LibEqualXDiscoveryStorage.removeActiveMarket(
            LibEqualXDiscoveryStorage.s(), LibEqualXTypes.MarketType.CURVE_LIQUIDITY, curveId
        );

        emit EqualXCurveExpired(curveId, data.makerPositionKey, remaining);
    }

    function previewCurveQuote(uint256 curveId, uint256 amountIn)
        internal
        view
        returns (CurveExecutionPreview memory preview)
    {
        if (amountIn == 0) revert EqualXCurve_InvalidAmount(amountIn);
        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        LibEqualXCurveStorage.CurveMarket storage market = store.markets[curveId];
        _requireActiveCurve(curveId, market);
        return _previewCurveQuote(curveId, amountIn, market);
    }

    function executeCurveSwap(CurveExecutionRequest memory request) internal returns (uint256 amountOut) {
        if (request.amountIn == 0) revert EqualXCurve_InvalidAmount(request.amountIn);
        if (request.recipient == address(0)) revert InvalidParameterRange("recipient=0");
        if (block.timestamp > request.deadline) revert EqualXCurve_Expired(request.curveId);

        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        LibEqualXCurveStorage.CurveMarket storage market = store.markets[request.curveId];
        _requireActiveCurve(request.curveId, market);
        if (market.generation != request.expectedGeneration) {
            revert EqualXCurve_GenerationMismatch(request.expectedGeneration, market.generation);
        }
        if (market.commitment != request.expectedCommitment) {
            revert EqualXCurve_CommitmentMismatch(request.expectedCommitment, market.commitment);
        }

        CurveExecutionPreview memory preview = _previewCurveQuote(request.curveId, request.amountIn, market);
        if (preview.amountOut < request.minOut) revert EqualXCurve_Slippage(request.minOut, preview.amountOut);

        LibCurrency.assertMsgValue(preview.quoteToken, request.maxQuote);
        uint256 received =
            LibCurrency.pullAtLeast(preview.quoteToken, msg.sender, preview.totalQuote, request.maxQuote);
        uint256 excess = received - preview.totalQuote;

        bytes32 makerPositionKey = _applyQuoteSide(request.curveId, preview, request.amountIn);
        _applyBaseSide(makerPositionKey, preview);
        _finalizeFill(request.curveId, market, preview.remainingAfter);

        if (excess > 0) {
            if (LibCurrency.isNative(preview.quoteToken)) {
                LibAppStorage.s().nativeTrackedTotal -= excess;
            }
            LibCurrency.transfer(preview.quoteToken, msg.sender, excess);
        }
        if (LibCurrency.isNative(preview.baseToken)) {
            LibAppStorage.s().nativeTrackedTotal -= preview.amountOut;
        }
        LibCurrency.transferWithMin(preview.baseToken, request.recipient, preview.amountOut, request.minOut);

        emit EqualXCurveFilled(
            request.curveId,
            msg.sender,
            request.recipient,
            request.amountIn,
            preview.totalQuote,
            preview.amountOut,
            preview.feeAmount,
            preview.remainingAfter
        );
        return preview.amountOut;
    }

    function currentCommitment(uint256 curveId) internal view returns (uint32 generation, bytes32 commitment) {
        LibEqualXCurveStorage.CurveMarket storage market = LibEqualXCurveStorage.s().markets[curveId];
        generation = market.generation;
        commitment = market.commitment;
    }

    function builtInLinearProfileId() internal pure returns (uint16) {
        return BUILTIN_LINEAR_PROFILE_ID;
    }

    function setCurveProfile(uint16 profileId, address impl, uint32 flags, bool approved) internal {
        if (profileId == 0) revert EqualXCurve_InvalidProfileId(profileId);
        if (profileId == BUILTIN_LINEAR_PROFILE_ID) {
            if (impl != address(0)) revert EqualXCurve_InvalidProfileId(profileId);
            return;
        }
        if (approved && impl == address(0)) revert EqualXCurve_InvalidProfileId(profileId);
        LibEqualXCurveStorage.s().curveProfiles[profileId] =
            LibEqualXCurveStorage.CurveProfileRegistryEntry({impl: impl, flags: flags, approved: approved});
    }

    function getCurveProfile(uint16 profileId)
        internal
        view
        returns (LibEqualXCurveStorage.CurveProfileRegistryEntry memory entry, bool builtIn)
    {
        builtIn = profileId == BUILTIN_LINEAR_PROFILE_ID;
        if (builtIn) {
            entry = LibEqualXCurveStorage.CurveProfileRegistryEntry({impl: address(0), flags: 0, approved: true});
            return (entry, true);
        }
        entry = LibEqualXCurveStorage.s().curveProfiles[profileId];
    }

    function isCurveProfileApproved(uint16 profileId) internal view returns (bool approved) {
        if (profileId == BUILTIN_LINEAR_PROFILE_ID) return true;
        approved = LibEqualXCurveStorage.s().curveProfiles[profileId].approved;
    }

    function curveHash(CurveDescriptor memory desc) internal pure returns (bytes32) {
        return keccak256(abi.encode(CURVE_DOMAIN_SEPARATOR, desc));
    }

    function immutableHash(CurveDescriptor memory desc) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                desc.makerPositionKey,
                desc.makerPositionId,
                desc.poolIdA,
                desc.poolIdB,
                desc.tokenA,
                desc.tokenB,
                desc.side,
                desc.priceIsQuotePerBase,
                desc.maxVolume,
                desc.feeRateBps,
                desc.feeAsset,
                desc.salt
            )
        );
    }

    function computePrice(
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 duration,
        uint256 t
    ) internal pure returns (uint256 price) {
        if (t <= startTime) return startPrice;
        uint256 endTime = startTime + duration;
        if (t >= endTime) return endPrice;
        uint256 elapsed = t - startTime;
        uint256 delta = endPrice > startPrice ? endPrice - startPrice : startPrice - endPrice;
        uint256 adjustment = Math.mulDiv(delta, elapsed, duration);
        return endPrice >= startPrice ? startPrice + adjustment : startPrice - adjustment;
    }

    function amountInForFill(uint256 baseFill, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(baseFill, price, WAD);
    }

    function amountOutForFill(uint256 amountIn, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(amountIn, WAD, price);
    }

    function computeFeeBps(uint256 amount, uint256 feeRateBps) internal pure returns (uint256) {
        return Math.mulDiv(amount, feeRateBps, 10_000);
    }

    function _validateDescriptor(CurveDescriptor calldata desc, bytes32 positionKey)
        private
        returns (bool baseIsA, uint256 endTime)
    {
        _enforceProfileApprovedForMutation(desc.profileId);
        if (desc.maxVolume == 0) revert EqualXCurve_InvalidAmount(desc.maxVolume);
        if (desc.startPrice == 0 || desc.endPrice == 0) revert EqualXCurve_InvalidDescriptor();
        if (desc.duration == 0) revert EqualXCurve_InvalidTimeWindow(desc.startTime, desc.duration);
        if (block.timestamp > uint256(desc.startTime) + MAX_PAST_START) {
            revert EqualXCurve_InvalidTimeWindow(desc.startTime, desc.duration);
        }
        if (!desc.priceIsQuotePerBase) revert EqualXCurve_InvalidDescriptor();
        if (desc.feeAsset != LibEqualXTypes.FeeAsset.TokenIn) revert EqualXCurve_InvalidDescriptor();
        if (desc.generation != 1) revert EqualXCurve_InvalidDescriptor();
        if (desc.poolIdA == desc.poolIdB) revert EqualXCurve_InvalidDescriptor();
        if (desc.tokenA == desc.tokenB) {
            revert EqualXCurve_InvalidDescriptor();
        }

        Types.PoolData storage poolA = LibPositionHelpers.pool(desc.poolIdA);
        Types.PoolData storage poolB = LibPositionHelpers.pool(desc.poolIdB);
        if (poolA.underlying != desc.tokenA || poolB.underlying != desc.tokenB) {
            revert EqualXCurve_InvalidDescriptor();
        }
        if (!LibPoolMembership.isMember(positionKey, desc.poolIdA)) {
            revert PoolMembershipRequired(positionKey, desc.poolIdA);
        }
        if (!LibPoolMembership.isMember(positionKey, desc.poolIdB)) {
            revert PoolMembershipRequired(positionKey, desc.poolIdB);
        }

        _settlePositionState(desc.poolIdA, positionKey);
        _settlePositionState(desc.poolIdB, positionKey);

        endTime = uint256(desc.startTime) + uint256(desc.duration);
        if (endTime > type(uint64).max) revert EqualXCurve_InvalidTimeWindow(desc.startTime, desc.duration);
        baseIsA = !desc.side;
    }

    function _settlePositionState(uint256 poolId, bytes32 positionKey) private {
        LibFeeIndex.settle(poolId, positionKey);
        LibActiveCreditIndex.settle(poolId, positionKey);
    }

    function _requireBuiltInProfile(uint16 profileId) private pure {
        if (profileId == 0) revert EqualXCurve_InvalidProfileId(profileId);
        if (profileId != BUILTIN_LINEAR_PROFILE_ID) revert EqualXCurve_NotBuiltInLinearProfile(profileId);
    }

    function _enforceProfileApprovedForMutation(uint16 profileId) private view {
        if (profileId == 0) revert EqualXCurve_InvalidProfileId(profileId);
        if (profileId == BUILTIN_LINEAR_PROFILE_ID) return;
        LibEqualXCurveStorage.CurveProfileRegistryEntry storage entry = LibEqualXCurveStorage.s().curveProfiles[profileId];
        if (!entry.approved) revert EqualXCurve_ProfileNotApproved(profileId);
        if (entry.impl == address(0)) revert EqualXCurve_InvalidProfileId(profileId);
    }

    function _requireActiveCurve(uint256 curveId, LibEqualXCurveStorage.CurveMarket storage market) private view {
        if (market.generation == 0) revert EqualXCurve_InvalidCurve(curveId);
        if (!market.active) revert EqualXCurve_NotActive(curveId);
    }

    function _lockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) private {
        Types.PoolData storage pool = LibPositionHelpers.pool(poolId);
        uint256 available = LibPositionHelpers.settledAvailablePrincipal(pool, positionKey, poolId);
        if (available < amount) revert InsufficientPrincipal(amount, available);
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        enc.lockedCapital += amount;
        LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
    }

    function _unlockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) private {
        LibPositionHelpers.settlePosition(poolId, positionKey);
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 currentLockedCapital = enc.lockedCapital;
        if (currentLockedCapital < amount) revert InsufficientPrincipal(amount, currentLockedCapital);
        enc.lockedCapital = currentLockedCapital - amount;
        LibActiveCreditIndex.applyEncumbranceDecrease(LibPositionHelpers.pool(poolId), poolId, positionKey, amount);
    }

    function _computePrice(
        uint256 curveId,
        LibEqualXCurveStorage.CurvePricing storage pricing,
        LibEqualXCurveStorage.CurveProfileData storage profile
    ) private view returns (uint256 price) {
        uint256 endTime = uint256(pricing.startTime) + uint256(pricing.duration);
        if (block.timestamp < pricing.startTime || block.timestamp > endTime) revert EqualXCurve_Expired(curveId);
        if (profile.profileId == BUILTIN_LINEAR_PROFILE_ID) {
            return computePrice(pricing.startPrice, pricing.endPrice, pricing.startTime, pricing.duration, block.timestamp);
        }

        LibEqualXCurveStorage.CurveProfileRegistryEntry storage entry = LibEqualXCurveStorage.s().curveProfiles[profile.profileId];
        if (!entry.approved) revert EqualXCurve_ProfileNotApproved(profile.profileId);
        if (entry.impl == address(0)) revert EqualXCurve_InvalidProfileId(profile.profileId);

        (bool success, bytes memory ret) = entry.impl.staticcall(
            abi.encodeCall(
                ICurveProfile.computePrice,
                (
                    pricing.startPrice,
                    pricing.endPrice,
                    pricing.startTime,
                    pricing.duration,
                    block.timestamp,
                    profile.profileParams
                )
            )
        );
        if (!success) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        price = abi.decode(ret, (uint256));
    }

    function _previewCurveQuote(
        uint256 curveId,
        uint256 amountIn,
        LibEqualXCurveStorage.CurveMarket storage market
    ) private view returns (CurveExecutionPreview memory preview) {
        LibEqualXCurveStorage.CurveStorage storage store = LibEqualXCurveStorage.s();
        LibEqualXCurveStorage.CurveData storage data = store.curveData[curveId];
        LibEqualXCurveStorage.CurveImmutables storage imm = store.curveImmutables[curveId];
        LibEqualXCurveStorage.CurvePricing storage pricing = store.curvePricing[curveId];
        LibEqualXCurveStorage.CurveProfileData storage profile = store.curveProfileData[curveId];

        preview.baseIsA = store.curveBaseIsA[curveId];
        preview.basePoolId = preview.baseIsA ? data.poolIdA : data.poolIdB;
        preview.quotePoolId = preview.baseIsA ? data.poolIdB : data.poolIdA;
        preview.baseToken = preview.baseIsA ? imm.tokenA : imm.tokenB;
        preview.quoteToken = preview.baseIsA ? imm.tokenB : imm.tokenA;
        preview.price = _computePrice(curveId, pricing, profile);
        preview.amountOut = amountOutForFill(amountIn, preview.price);
        if (preview.amountOut == 0) revert EqualXCurve_InvalidAmount(preview.amountOut);
        if (preview.amountOut > market.remainingVolume) {
            revert EqualXCurve_InsufficientVolume(preview.amountOut, market.remainingVolume);
        }
        preview.feeAmount = imm.feeRateBps == 0 ? 0 : computeFeeBps(amountIn, imm.feeRateBps);
        preview.totalQuote = amountIn + preview.feeAmount;
        preview.remainingAfter = market.remainingVolume - preview.amountOut;
    }

    function _applyQuoteSide(uint256 curveId, CurveExecutionPreview memory preview, uint256 amountIn)
        private
        returns (bytes32 makerPositionKey)
    {
        makerPositionKey = LibEqualXCurveStorage.s().curveData[curveId].makerPositionKey;
        _settlePositionState(preview.basePoolId, makerPositionKey);
        _settlePositionState(preview.quotePoolId, makerPositionKey);

        Types.PoolData storage quotePool = LibPositionHelpers.pool(preview.quotePoolId);
        quotePool.trackedBalance += preview.totalQuote;

        uint256 makerFee = (preview.feeAmount * 7000) / 10_000;
        uint256 protocolFee = preview.feeAmount - makerFee;
        uint256 makerIncrease = amountIn + makerFee;
        quotePool.userPrincipal[makerPositionKey] += makerIncrease;
        quotePool.totalDeposits += makerIncrease;
        quotePool.userFeeIndex[makerPositionKey] = quotePool.feeIndex;
        quotePool.userMaintenanceIndex[makerPositionKey] = quotePool.maintenanceIndex;

        if (protocolFee > 0) {
            LibFeeRouter.routeSamePool(preview.quotePoolId, protocolFee, CURVE_FEE_SOURCE, true, 0);
        }
    }

    function _applyBaseSide(bytes32 makerPositionKey, CurveExecutionPreview memory preview) private {
        Types.PoolData storage basePool = LibPositionHelpers.pool(preview.basePoolId);
        _unlockCollateral(makerPositionKey, preview.basePoolId, preview.amountOut);
        uint256 makerBase = basePool.userPrincipal[makerPositionKey];
        if (makerBase < preview.amountOut) revert InsufficientPrincipal(preview.amountOut, makerBase);
        if (basePool.trackedBalance < preview.amountOut) {
            revert InsufficientPrincipal(preview.amountOut, basePool.trackedBalance);
        }
        basePool.userPrincipal[makerPositionKey] = makerBase - preview.amountOut;
        basePool.totalDeposits -= preview.amountOut;
        basePool.trackedBalance -= preview.amountOut;
        basePool.userFeeIndex[makerPositionKey] = basePool.feeIndex;
        basePool.userMaintenanceIndex[makerPositionKey] = basePool.maintenanceIndex;
    }

    function _finalizeFill(
        uint256 curveId,
        LibEqualXCurveStorage.CurveMarket storage market,
        uint256 remainingAfter
    ) private {
        market.remainingVolume = uint128(remainingAfter);
        if (remainingAfter == 0) {
            market.active = false;
            LibEqualXDiscoveryStorage.removeActiveMarket(
                LibEqualXDiscoveryStorage.s(), LibEqualXTypes.MarketType.CURVE_LIQUIDITY, curveId
            );
        }
    }

    function _applyCurveUpdate(
        LibEqualXCurveStorage.CurveStorage storage store,
        uint256 curveId,
        CurveUpdateParams calldata params,
        uint16 nextProfileId,
        bytes32 nextProfileParams,
        uint256 endTime
    ) private returns (uint32 newGeneration) {
        LibEqualXCurveStorage.CurveMarket storage market = store.markets[curveId];
        LibEqualXCurveStorage.CurveData storage data = store.curveData[curveId];
        LibEqualXCurveStorage.CurveImmutables storage imm = store.curveImmutables[curveId];

        newGeneration = market.generation + 1;
        CurveDescriptor memory desc = CurveDescriptor({
            makerPositionKey: data.makerPositionKey,
            makerPositionId: data.makerPositionId,
            poolIdA: data.poolIdA,
            poolIdB: data.poolIdB,
            tokenA: imm.tokenA,
            tokenB: imm.tokenB,
            side: !store.curveBaseIsA[curveId],
            priceIsQuotePerBase: imm.priceIsQuotePerBase,
            maxVolume: imm.maxVolume,
            startPrice: params.startPrice,
            endPrice: params.endPrice,
            startTime: params.startTime,
            duration: params.duration,
            generation: newGeneration,
            feeRateBps: imm.feeRateBps,
            feeAsset: imm.feeAsset,
            salt: imm.salt,
            profileId: nextProfileId,
            profileParams: nextProfileParams
        });

        market.commitment = curveHash(desc);
        market.endTime = uint64(endTime);
        market.generation = newGeneration;
        store.curvePricing[curveId] = LibEqualXCurveStorage.CurvePricing({
            startPrice: params.startPrice,
            endPrice: params.endPrice,
            startTime: params.startTime,
            duration: params.duration
        });
    }

    function _storeCreatedCurve(
        LibEqualXCurveStorage.CurveStorage storage store,
        uint256 curveId,
        CurveDescriptor calldata desc,
        bytes32 positionKey,
        bool baseIsA,
        uint256 endTime
    ) private {
        store.markets[curveId] = LibEqualXCurveStorage.CurveMarket({
            commitment: curveHash(desc),
            remainingVolume: desc.maxVolume,
            endTime: uint64(endTime),
            generation: desc.generation,
            active: true
        });
        store.curveData[curveId] = LibEqualXCurveStorage.CurveData({
            makerPositionKey: positionKey,
            makerPositionId: desc.makerPositionId,
            poolIdA: desc.poolIdA,
            poolIdB: desc.poolIdB
        });
        store.curveImmutables[curveId] = LibEqualXCurveStorage.CurveImmutables({
            tokenA: desc.tokenA,
            tokenB: desc.tokenB,
            maxVolume: desc.maxVolume,
            salt: desc.salt,
            feeRateBps: desc.feeRateBps,
            priceIsQuotePerBase: desc.priceIsQuotePerBase,
            feeAsset: desc.feeAsset
        });
        store.curvePricing[curveId] = LibEqualXCurveStorage.CurvePricing({
            startPrice: desc.startPrice,
            endPrice: desc.endPrice,
            startTime: desc.startTime,
            duration: desc.duration
        });
        store.curveProfileData[curveId] = LibEqualXCurveStorage.CurveProfileData({
            profileId: desc.profileId,
            profileParams: desc.profileParams
        });
        store.curveImmutableHash[curveId] = immutableHash(desc);
        store.curveBaseIsA[curveId] = baseIsA;
    }

    function _emitCurveCreated(uint256 curveId, bytes32 positionKey, CurveDescriptor calldata desc, bool baseIsA) private {
        emit EqualXCurveCreated(
            curveId,
            positionKey,
            desc.makerPositionId,
            baseIsA,
            desc.maxVolume,
            desc.poolIdA,
            desc.poolIdB
        );
    }
}
