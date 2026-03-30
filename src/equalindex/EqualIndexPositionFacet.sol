// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualIndexBaseV3} from "./EqualIndexBaseV3.sol";
import {IndexToken} from "./IndexToken.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibEqualIndexRewards} from "../libraries/LibEqualIndexRewards.sol";
import {LibEqualIndexLending} from "../libraries/LibEqualIndexLending.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibIndexEncumbrance} from "../libraries/LibIndexEncumbrance.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

/// @notice Position-based index mint/burn operations.
contract EqualIndexPositionFacet is EqualIndexBaseV3, ReentrancyGuardModifiers {
    uint256 internal constant POSITION_INDEX_SCALE = 1e18;
    bytes32 internal constant POSITION_INDEX_FEE_SOURCE = keccak256("INDEX_FEE");

    struct PositionBurnLeg {
        address asset;
        uint256 bundleOut;
        uint256 potShare;
        uint256 burnFee;
        uint256 payout;
        uint256 potFee;
        uint256 poolShare;
    }

    struct PositionBurnState {
        uint256[] assetsOut;
        uint256[] feeAmounts;
    }

    struct PositionMintLeg {
        address asset;
        uint256 poolId;
        uint256 vaultIn;
        uint256 potBuyIn;
        uint256 grossIn;
        uint256 fee;
        uint256 total;
    }

    struct PositionMintState {
        uint256[] required;
        uint256[] fees;
    }

    function mintFromPosition(uint256 positionId, uint256 indexId, uint256 units)
        external
        nonReentrant
        indexExists(indexId)
        returns (uint256 minted)
    {
        if (units == 0 || units % POSITION_INDEX_SCALE != 0) revert InvalidUnits();

        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);

        uint256 len = idx.assets.length;
        PositionMintState memory state;
        state.required = new uint256[](len);
        state.fees = new uint256[](len);
        uint16 poolFeeShareBps = _poolFeeShareBps();
        uint256 totalSupply = idx.totalUnits;
        _preparePositionMint(indexId, idx, units, totalSupply, positionKey, poolFeeShareBps, state);

        minted = units;
        idx.totalUnits += minted;
        IndexToken(idx.token).mintIndexUnits(address(this), minted);
        IndexToken(idx.token).recordMintDetails(msg.sender, minted, idx.assets, state.required, state.fees, 0);

        uint256 indexPoolId = s().indexToPoolId[indexId];
        if (indexPoolId == 0) revert PoolNotInitialized(indexPoolId);
        Types.PoolData storage indexPool = LibAppStorage.s().pools[indexPoolId];
        LibPoolMembership._ensurePoolMembership(positionKey, indexPoolId, true);
        uint256 currentPrincipal = LibEqualIndexRewards.settleBeforeEligibleBalanceChange(indexId, indexPoolId, positionKey);
        bool isNewUser = currentPrincipal == 0;
        if (isNewUser) {
            uint256 maxUsers = indexPool.poolConfig.maxUserCount;
            if (maxUsers > 0 && indexPool.userCount >= maxUsers) {
                revert MaxUserCountExceeded(maxUsers);
            }
        }

        uint256 newPrincipal = currentPrincipal + minted;
        if (indexPool.poolConfig.isCapped) {
            uint256 cap = indexPool.poolConfig.depositCap;
            if (cap > 0 && newPrincipal > cap) {
                revert DepositCapExceeded(newPrincipal, cap);
            }
        }

        indexPool.userPrincipal[positionKey] = newPrincipal;
        indexPool.totalDeposits += minted;
        indexPool.trackedBalance += minted;
        if (isNewUser && minted > 0) {
            indexPool.userCount += 1;
        }
        indexPool.userFeeIndex[positionKey] = indexPool.feeIndex;
        indexPool.userMaintenanceIndex[positionKey] = indexPool.maintenanceIndex;
        LibEqualIndexRewards.syncEligibleBalanceChange(indexId, currentPrincipal, newPrincipal);
    }

    function burnFromPosition(uint256 positionId, uint256 indexId, uint256 units)
        external
        nonReentrant
        indexExists(indexId)
        returns (uint256[] memory assetsOut)
    {
        if (units == 0 || units % POSITION_INDEX_SCALE != 0) revert InvalidUnits();

        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);

        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);

        uint256 totalSupply = idx.totalUnits;
        if (units > totalSupply) revert InvalidUnits();

        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint256 indexPoolId = s().indexToPoolId[indexId];
        Types.PoolData storage indexPool = store.pools[indexPoolId];
        if (!indexPool.initialized) revert PoolNotInitialized(indexPoolId);

        LibPoolMembership._ensurePoolMembership(positionKey, indexPoolId, true);
        uint256 positionIndexBalance =
            LibEqualIndexRewards.settleBeforeEligibleBalanceChange(indexId, indexPoolId, positionKey);
        if (units > positionIndexBalance) {
            revert InsufficientIndexTokens(units, positionIndexBalance);
        }

        uint256 len = idx.assets.length;
        PositionBurnState memory state;
        state.assetsOut = new uint256[](len);
        state.feeAmounts = new uint256[](len);
        uint16 poolFeeShareBps = _poolFeeShareBps();
        _preparePositionBurn(indexId, idx, units, totalSupply, positionKey, poolFeeShareBps, state);

        idx.totalUnits = totalSupply - units;
        IndexToken(idx.token).burnIndexUnits(address(this), units);
        assetsOut = state.assetsOut;
        IndexToken(idx.token).recordBurnDetails(msg.sender, units, idx.assets, state.assetsOut, state.feeAmounts, 0);

        uint256 newPrincipal = positionIndexBalance - units;
        indexPool.userPrincipal[positionKey] = newPrincipal;
        indexPool.totalDeposits -= units;
        if (indexPool.trackedBalance < units) {
            revert InsufficientPrincipal(units, indexPool.trackedBalance);
        }
        indexPool.trackedBalance -= units;
        if (positionIndexBalance > 0 && newPrincipal == 0 && indexPool.userCount > 0) {
            indexPool.userCount -= 1;
        }
        indexPool.userFeeIndex[positionKey] = indexPool.feeIndex;
        indexPool.userMaintenanceIndex[positionKey] = indexPool.maintenanceIndex;
        LibEqualIndexRewards.syncEligibleBalanceChange(indexId, positionIndexBalance, newPrincipal);
    }

    function _quotePositionMintLeg(
        Index storage idx,
        uint256 indexId,
        uint256 i,
        uint256 units,
        uint256 totalSupply
    ) internal view returns (PositionMintLeg memory leg) {
        leg.asset = idx.assets[i];
        leg.poolId = LibAppStorage.s().assetToPoolId[leg.asset];
        if (leg.poolId == 0) revert NoPoolForAsset(leg.asset);

        if (totalSupply == 0) {
            leg.vaultIn = Math.mulDiv(idx.bundleAmounts[i], units, POSITION_INDEX_SCALE);
        } else {
            uint256 economicBal =
                LibEqualIndexLending.getEconomicBalance(indexId, leg.asset, s().vaultBalances[indexId][leg.asset]);
            leg.vaultIn = Math.mulDiv(economicBal, units, totalSupply, Math.Rounding.Ceil);
            leg.potBuyIn = Math.mulDiv(s().feePots[indexId][leg.asset], units, totalSupply, Math.Rounding.Ceil);
        }

        leg.grossIn = leg.vaultIn + leg.potBuyIn;
        leg.fee = Math.mulDiv(leg.grossIn, idx.mintFeeBps[i], 10_000, Math.Rounding.Ceil);
        leg.total = leg.grossIn + leg.fee;
    }

    function _preparePositionMint(
        uint256 indexId,
        Index storage idx,
        uint256 units,
        uint256 totalSupply,
        bytes32 positionKey,
        uint16 poolFeeShareBps,
        PositionMintState memory state
    ) internal {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint256 len = idx.assets.length;
        for (uint256 i = 0; i < len; i++) {
            PositionMintLeg memory leg = _quotePositionMintLeg(idx, indexId, i, units, totalSupply);
            _applyPositionMintLeg(store, indexId, positionKey, i, leg, poolFeeShareBps, state);
        }
    }

    function _applyPositionMintLeg(
        LibAppStorage.AppStorage storage store,
        uint256 indexId,
        bytes32 positionKey,
        uint256 i,
        PositionMintLeg memory leg,
        uint16 poolFeeShareBps,
        PositionMintState memory state
    ) internal {
        if (!LibPoolMembership.isMember(positionKey, leg.poolId)) {
            revert NotMemberOfRequiredPool(positionKey, leg.poolId);
        }

        Types.PoolData storage pool = store.pools[leg.poolId];
        uint256 available = LibPositionHelpers.availablePrincipal(pool, positionKey, leg.poolId);
        if (available < leg.total) {
            revert InsufficientUnencumberedPrincipal(leg.total, available);
        }

        state.required[i] = leg.grossIn;
        state.fees[i] = leg.fee;

        LibIndexEncumbrance.encumber(positionKey, leg.poolId, indexId, leg.vaultIn);
        s().vaultBalances[indexId][leg.asset] += leg.vaultIn;

        if (leg.potBuyIn > 0 || leg.fee > 0) {
            LibFeeIndex.settle(leg.poolId, positionKey);
            uint256 principal = pool.userPrincipal[positionKey];
            uint256 principalDeduction = leg.potBuyIn + leg.fee;
            if (principal < principalDeduction) {
                revert InsufficientPrincipal(principalDeduction, principal);
            }
            pool.userPrincipal[positionKey] = principal - principalDeduction;
            pool.totalDeposits -= principalDeduction;
        }

        if (leg.potBuyIn > 0) {
            if (pool.trackedBalance < leg.potBuyIn) {
                revert InsufficientPoolLiquidity(leg.potBuyIn, pool.trackedBalance);
            }
            pool.trackedBalance -= leg.potBuyIn;
            s().feePots[indexId][leg.asset] += leg.potBuyIn;
        }

        if (leg.fee > 0) {
            uint256 poolShare = Math.mulDiv(leg.fee, poolFeeShareBps, 10_000);
            uint256 potShare = leg.fee - poolShare;
            if (potShare > 0) {
                if (pool.trackedBalance < potShare) {
                    revert InsufficientPoolLiquidity(potShare, pool.trackedBalance);
                }
                pool.trackedBalance -= potShare;
                s().feePots[indexId][leg.asset] += potShare;
            }
            if (poolShare > 0) {
                LibFeeRouter.routeManagedShare(leg.poolId, poolShare, POSITION_INDEX_FEE_SOURCE, true, 0);
            }
        }
    }

    function _quotePositionBurnLeg(
        Index storage idx,
        uint256 indexId,
        uint256 i,
        uint256 units,
        uint256 totalSupply,
        uint16 poolFeeShareBps
    ) internal view returns (PositionBurnLeg memory leg) {
        leg.asset = idx.assets[i];
        uint256 vaultBalance = s().vaultBalances[indexId][leg.asset];
        uint256 potBalance = s().feePots[indexId][leg.asset];
        leg.bundleOut = Math.mulDiv(idx.bundleAmounts[i], units, POSITION_INDEX_SCALE);
        if (vaultBalance < leg.bundleOut) {
            revert InsufficientPoolLiquidity(leg.bundleOut, vaultBalance);
        }
        leg.potShare = Math.mulDiv(potBalance, units, totalSupply);
        uint256 gross = leg.bundleOut + leg.potShare;
        leg.burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);
        leg.payout = gross - leg.burnFee;
        leg.poolShare = Math.mulDiv(leg.burnFee, poolFeeShareBps, 10_000);
        leg.potFee = leg.burnFee - leg.poolShare;
    }

    function _preparePositionBurn(
        uint256 indexId,
        Index storage idx,
        uint256 units,
        uint256 totalSupply,
        bytes32 positionKey,
        uint16 poolFeeShareBps,
        PositionBurnState memory state
    ) internal {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint256 len = idx.assets.length;
        for (uint256 i = 0; i < len; i++) {
            PositionBurnLeg memory leg =
                _quotePositionBurnLeg(idx, indexId, i, units, totalSupply, poolFeeShareBps);
            _applyPositionBurnLeg(store, indexId, positionKey, i, leg, state);
        }
    }

    function _applyPositionBurnLeg(
        LibAppStorage.AppStorage storage store,
        uint256 indexId,
        bytes32 positionKey,
        uint256 i,
        PositionBurnLeg memory leg,
        PositionBurnState memory state
    ) internal {
        uint256 poolId = store.assetToPoolId[leg.asset];
        if (poolId == 0) revert NoPoolForAsset(leg.asset);

        LibPoolMembership._ensurePoolMembership(positionKey, poolId, true);
        Types.PoolData storage pool = store.pools[poolId];
        uint256 nextFeePot = s().feePots[indexId][leg.asset] - leg.potShare + leg.potFee;

        s().vaultBalances[indexId][leg.asset] -= leg.bundleOut;
        s().feePots[indexId][leg.asset] = nextFeePot;
        if (leg.poolShare > 0) {
            pool.trackedBalance += leg.poolShare;
            LibFeeRouter.routeManagedShare(poolId, leg.poolShare, POSITION_INDEX_FEE_SOURCE, true, 0);
        }

        state.assetsOut[i] = leg.payout;
        state.feeAmounts[i] = leg.burnFee;

        uint256 gross = leg.bundleOut + leg.potShare;
        if (gross == 0) return;

        uint256 navOut = Math.mulDiv(leg.payout, leg.bundleOut, gross);
        uint256 potOut = leg.payout - navOut;

        if (navOut > 0) {
            LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, navOut);
        }
        if (potOut > 0) {
            LibFeeIndex.settle(poolId, positionKey);
            uint256 currentPrincipal = pool.userPrincipal[positionKey];
            bool isNewUser = currentPrincipal == 0;
            if (isNewUser) {
                uint256 maxUsers = pool.poolConfig.maxUserCount;
                if (maxUsers > 0 && pool.userCount >= maxUsers) {
                    revert MaxUserCountExceeded(maxUsers);
                }
            }
            pool.userPrincipal[positionKey] = currentPrincipal + potOut;
            pool.totalDeposits += potOut;
            pool.trackedBalance += potOut;
            if (isNewUser) {
                pool.userCount += 1;
            }
            pool.userFeeIndex[positionKey] = pool.feeIndex;
            pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
        }
    }
}
