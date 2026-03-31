// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibEqualXCommunityAmmStorage} from "./LibEqualXCommunityAmmStorage.sol";

/// @notice Fee index accounting for EqualX community AMM maker fees.
library LibEqualXCommunityFeeIndex {
    uint256 internal constant INDEX_SCALE = 1e18;

    function accrueTokenAFee(uint256 marketId, uint256 amount) internal {
        if (amount == 0) return;
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        uint256 totalShares = market.totalShares;
        if (totalShares == 0) return;

        uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
        uint256 dividend = scaledAmount + market.feeIndexRemainderA;
        uint256 delta = dividend / totalShares;
        if (delta == 0) {
            market.feeIndexRemainderA = dividend;
            return;
        }
        market.feeIndexA += delta;
        market.feeIndexRemainderA = dividend - (delta * totalShares);
    }

    function accrueTokenBFee(uint256 marketId, uint256 amount) internal {
        if (amount == 0) return;
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        uint256 totalShares = market.totalShares;
        if (totalShares == 0) return;

        uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
        uint256 dividend = scaledAmount + market.feeIndexRemainderB;
        uint256 delta = dividend / totalShares;
        if (delta == 0) {
            market.feeIndexRemainderB = dividend;
            return;
        }
        market.feeIndexB += delta;
        market.feeIndexRemainderB = dividend - (delta * totalShares);
    }

    function settleMaker(uint256 marketId, bytes32 positionKey) internal returns (uint256 feesA, uint256 feesB) {
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        LibEqualXCommunityAmmStorage.CommunityMakerPosition storage maker = store.makers[marketId][positionKey];
        uint256 share = maker.share;

        if (share > 0) {
            uint256 indexA = market.feeIndexA;
            uint256 indexB = market.feeIndexB;

            if (indexA > maker.feeIndexSnapshotA) {
                feesA = Math.mulDiv(share, indexA - maker.feeIndexSnapshotA, INDEX_SCALE);
            }
            if (indexB > maker.feeIndexSnapshotB) {
                feesB = Math.mulDiv(share, indexB - maker.feeIndexSnapshotB, INDEX_SCALE);
            }

            if (feesA > 0) {
                LibAppStorage.s().pools[market.poolIdA].userAccruedYield[positionKey] += feesA;
            }
            if (feesB > 0) {
                LibAppStorage.s().pools[market.poolIdB].userAccruedYield[positionKey] += feesB;
            }
        }

        maker.feeIndexSnapshotA = market.feeIndexA;
        maker.feeIndexSnapshotB = market.feeIndexB;
    }

    function pendingFees(uint256 marketId, bytes32 positionKey) internal view returns (uint256 feesA, uint256 feesB) {
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        LibEqualXCommunityAmmStorage.CommunityMakerPosition storage maker = store.makers[marketId][positionKey];
        uint256 share = maker.share;
        if (share == 0) return (0, 0);

        if (market.feeIndexA > maker.feeIndexSnapshotA) {
            feesA = Math.mulDiv(share, market.feeIndexA - maker.feeIndexSnapshotA, INDEX_SCALE);
        }
        if (market.feeIndexB > maker.feeIndexSnapshotB) {
            feesB = Math.mulDiv(share, market.feeIndexB - maker.feeIndexSnapshotB, INDEX_SCALE);
        }
    }

    function snapshotIndexes(uint256 marketId, bytes32 positionKey) internal {
        LibEqualXCommunityAmmStorage.CommunityAmmStorage storage store = LibEqualXCommunityAmmStorage.s();
        LibEqualXCommunityAmmStorage.CommunityAmmMarket storage market = store.markets[marketId];
        LibEqualXCommunityAmmStorage.CommunityMakerPosition storage maker = store.makers[marketId][positionKey];
        maker.feeIndexSnapshotA = market.feeIndexA;
        maker.feeIndexSnapshotB = market.feeIndexB;
    }
}
