// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EqualIndexBaseV3} from "./EqualIndexBaseV3.sol";
import {IndexToken} from "./IndexToken.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEqualIndexLending} from "../libraries/LibEqualIndexLending.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

/// @notice Core wallet-mode mint/burn operations for EqualIndex V3.
contract EqualIndexActionsFacetV3 is EqualIndexBaseV3, ReentrancyGuardModifiers {
    uint256 internal constant INDEX_SCALE = 1e18;
    bytes32 internal constant INDEX_FEE_SOURCE = keccak256("INDEX_FEE");

    struct MintLeg {
        address asset;
        uint256 vaultIn;
        uint256 grossIn;
        uint256 potBuyIn;
        uint256 fee;
        uint256 total;
    }

    struct MintState {
        uint256 nativeTotal;
        bool hasNative;
        uint256[] vaultInputs;
        uint256[] required;
        uint256[] potBuyIns;
        uint256[] fees;
    }

    struct BurnLeg {
        address asset;
        uint256 bundleOut;
        uint256 potShare;
        uint256 payout;
        uint256 fee;
    }

    struct BurnState {
        uint256[] assetsOut;
        uint256[] feeAmounts;
    }

    function mint(uint256 indexId, uint256 units, address to, uint256[] calldata maxInputAmounts)
        external
        payable
        nonReentrant
        indexExists(indexId)
        returns (uint256 minted)
    {
        if (units == 0 || units % INDEX_SCALE != 0) revert InvalidUnits();
        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);

        uint256 len = idx.assets.length;
        if (maxInputAmounts.length != len) revert InvalidArrayLength();
        uint16 feeIndexShareBps = _mintBurnFeeIndexShareBps();
        MintState memory state = _prepareMint(indexId, idx, units, maxInputAmounts);

        if (state.hasNative) {
            _pullNativeMint(state.nativeTotal);
        } else {
            LibCurrency.assertZeroMsgValue();
        }

        for (uint256 i = 0; i < len; i++) {
            address asset = idx.assets[i];
            s().vaultBalances[indexId][asset] += state.vaultInputs[i];
            if (state.potBuyIns[i] > 0) {
                s().feePots[indexId][asset] += state.potBuyIns[i];
            }
            _distributeIndexFee(indexId, asset, state.fees[i], feeIndexShareBps);
        }

        minted = units;
        idx.totalUnits += minted;
        IndexToken(idx.token).mintIndexUnits(to, minted);
        IndexToken(idx.token).recordMintDetails(to, minted, idx.assets, state.required, state.fees, 0);
    }

    function burn(uint256 indexId, uint256 units, address to)
        external
        payable
        nonReentrant
        indexExists(indexId)
        returns (uint256[] memory assetsOut)
    {
        LibCurrency.assertZeroMsgValue();
        if (units == 0 || units % INDEX_SCALE != 0) revert InvalidUnits();
        Index storage idx = s().indexes[indexId];
        _requireIndexActive(idx, indexId);
        uint256 totalSupply = idx.totalUnits;
        if (units > totalSupply) revert InvalidUnits();
        if (IndexToken(idx.token).balanceOf(msg.sender) < units) revert InvalidUnits();

        uint256 len = idx.assets.length;
        BurnState memory state;
        state.assetsOut = new uint256[](len);
        state.feeAmounts = new uint256[](len);
        uint16 feeIndexShareBps = _mintBurnFeeIndexShareBps();
        _prepareBurn(indexId, idx, units, totalSupply, to, feeIndexShareBps, state);

        idx.totalUnits = totalSupply - units;
        IndexToken(idx.token).burnIndexUnits(msg.sender, units);
        assetsOut = state.assetsOut;
        IndexToken(idx.token).recordBurnDetails(msg.sender, units, idx.assets, state.assetsOut, state.feeAmounts, 0);
    }

    function _pullNativeMint(uint256 amount) internal {
        if (amount == 0) {
            LibCurrency.assertZeroMsgValue();
            return;
        }
        if (msg.value == 0) {
            uint256 availableNative = LibCurrency.nativeAvailable();
            if (amount > availableNative) {
                revert InsufficientPoolLiquidity(amount, availableNative);
            }
            LibAppStorage.s().nativeTrackedTotal += amount;
            return;
        }
        if (msg.value != amount) {
            revert UnexpectedMsgValue(msg.value);
        }
        LibAppStorage.s().nativeTrackedTotal += amount;
    }

    function _quoteMintLeg(
        Index storage idx,
        uint256 indexId,
        uint256 i,
        uint256 units,
        uint256 totalSupply
    ) internal view returns (MintLeg memory leg) {
        leg.asset = idx.assets[i];
        if (totalSupply == 0) {
            leg.vaultIn = Math.mulDiv(idx.bundleAmounts[i], units, INDEX_SCALE);
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

    function _prepareMint(
        uint256 indexId,
        Index storage idx,
        uint256 units,
        uint256[] calldata maxInputAmounts
    ) internal returns (MintState memory state) {
        uint256 len = idx.assets.length;
        state.vaultInputs = new uint256[](len);
        state.required = new uint256[](len);
        state.potBuyIns = new uint256[](len);
        state.fees = new uint256[](len);

        uint256 totalSupply = idx.totalUnits;

        for (uint256 i = 0; i < len; i++) {
            MintLeg memory leg = _quoteMintLeg(idx, indexId, i, units, totalSupply);

            if (LibCurrency.isNative(leg.asset)) {
                state.hasNative = true;
                state.nativeTotal += leg.total;
                if (maxInputAmounts[i] < leg.total) {
                    revert LibCurrency.LibCurrency_InvalidMax(maxInputAmounts[i], leg.total);
                }
            } else {
                uint256 received = LibCurrency.pullAtLeast(leg.asset, msg.sender, leg.total, maxInputAmounts[i]);
                if (received < leg.total) {
                    revert LibCurrency.LibCurrency_InsufficientReceived(received, leg.total);
                }
            }

            state.vaultInputs[i] = leg.vaultIn;
            state.required[i] = leg.grossIn;
            state.potBuyIns[i] = leg.potBuyIn;
            state.fees[i] = leg.fee;
        }
    }

    function _quoteBurnLeg(
        Index storage idx,
        uint256 indexId,
        uint256 i,
        uint256 units,
        uint256 totalSupply
    ) internal view returns (BurnLeg memory leg) {
        leg.asset = idx.assets[i];
        uint256 vaultBalance = s().vaultBalances[indexId][leg.asset];
        uint256 potBalance = s().feePots[indexId][leg.asset];
        leg.bundleOut = Math.mulDiv(idx.bundleAmounts[i], units, INDEX_SCALE);
        if (vaultBalance < leg.bundleOut) {
            revert InsufficientPoolLiquidity(leg.bundleOut, vaultBalance);
        }
        leg.potShare = Math.mulDiv(potBalance, units, totalSupply);
        uint256 gross = leg.bundleOut + leg.potShare;
        leg.fee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);
        leg.payout = gross - leg.fee;
    }

    function _prepareBurn(
        uint256 indexId,
        Index storage idx,
        uint256 units,
        uint256 totalSupply,
        address to,
        uint16 feeIndexShareBps,
        BurnState memory state
    ) internal {
        uint256 len = idx.assets.length;
        for (uint256 i = 0; i < len; i++) {
            BurnLeg memory leg = _quoteBurnLeg(idx, indexId, i, units, totalSupply);

            s().vaultBalances[indexId][leg.asset] -= leg.bundleOut;
            s().feePots[indexId][leg.asset] -= leg.potShare;
            _distributeIndexFee(indexId, leg.asset, leg.fee, feeIndexShareBps);

            if (leg.payout > 0) {
                if (LibCurrency.isNative(leg.asset)) {
                    LibAppStorage.s().nativeTrackedTotal -= leg.payout;
                }
                LibCurrency.transfer(leg.asset, to, leg.payout);
            }

            state.assetsOut[i] = leg.payout;
            state.feeAmounts[i] = leg.fee;
        }
    }

    function _distributeIndexFee(
        uint256 indexId,
        address asset,
        uint256 fee,
        uint16 feeIndexShareBps
    ) internal {
        if (fee == 0) return;

        uint256 poolShare = Math.mulDiv(fee, feeIndexShareBps, 10_000);
        uint256 potFee = fee - poolShare;
        if (potFee > 0) {
            s().feePots[indexId][asset] += potFee;
        }

        if (poolShare > 0) {
            uint256 poolId = LibAppStorage.s().assetToPoolId[asset];
            if (poolId == 0) revert NoPoolForAsset(asset);
            Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
            pool.trackedBalance += poolShare;
            if (LibCurrency.isNative(asset)) {
                _routeIndexPoolShareNative(pool, poolId, poolShare);
            } else {
                LibFeeRouter.routeSamePool(poolId, poolShare, INDEX_FEE_SOURCE, true, poolShare);
            }
        }
    }

    function _routeIndexPoolShareNative(Types.PoolData storage pool, uint256 pid, uint256 amount) internal {
        if (amount == 0) return;
        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) = LibFeeRouter.previewSplit(amount);
        if (toTreasury > 0) {
            address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
            if (treasury != address(0)) {
                uint256 tracked = pool.trackedBalance;
                if (tracked < toTreasury) revert InsufficientPrincipal(toTreasury, tracked);
                uint256 contractBal = LibCurrency.balanceOfSelf(pool.underlying);
                if (contractBal < toTreasury) revert InsufficientPrincipal(toTreasury, contractBal);
                pool.trackedBalance = tracked - toTreasury;
                LibAppStorage.s().nativeTrackedTotal -= toTreasury;
                LibCurrency.transfer(pool.underlying, treasury, toTreasury);
            }
        }
        if (toActiveCredit > 0) {
            LibFeeRouter.accrueActiveCredit(pid, toActiveCredit, INDEX_FEE_SOURCE, amount);
        }
        if (toFeeIndex > 0) {
            LibFeeIndex.accrueWithSourceUsingBacking(pid, toFeeIndex, INDEX_FEE_SOURCE, amount);
        }
    }
}
