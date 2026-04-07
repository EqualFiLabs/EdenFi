// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEqualXTypes} from "./LibEqualXTypes.sol";

library LibEqualXSoloAmmStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.equalx.solo-amm.storage");
    uint64 internal constant DEFAULT_MIN_REBALANCE_TIMELOCK = 1 minutes;

    struct SoloAmmPendingRebalance {
        uint256 snapshotReserveA;
        uint256 snapshotReserveB;
        uint256 targetReserveA;
        uint256 targetReserveB;
        uint64 executeAfter;
        bool exists;
    }

    struct SoloAmmMarket {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 baselineReserveA;
        uint256 baselineReserveB;
        uint64 startTime;
        uint64 endTime;
        uint64 lastRebalanceExecutionAt;
        uint64 rebalanceTimelock;
        uint16 feeBps;
        LibEqualXTypes.FeeAsset feeAsset;
        LibEqualXTypes.InvariantMode invariantMode;
        uint8 tokenADecimals;
        uint8 tokenBDecimals;
        uint256 makerFeeAAccrued;
        uint256 makerFeeBAccrued;
        uint256 treasuryFeeAAccrued;
        uint256 treasuryFeeBAccrued;
        uint256 feeIndexFeeAAccrued;
        uint256 feeIndexFeeBAccrued;
        uint256 activeCreditFeeAAccrued;
        uint256 activeCreditFeeBAccrued;
        bool active;
        bool finalized;
    }

    struct SoloAmmStorage {
        uint256 nextMarketId;
        uint64 minRebalanceTimelock;
        mapping(uint256 => SoloAmmMarket) markets;
        mapping(uint256 => SoloAmmPendingRebalance) pendingRebalances;
    }

    function s() internal pure returns (SoloAmmStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function minRebalanceTimelock(SoloAmmStorage storage store) internal view returns (uint64 timelock) {
        timelock = store.minRebalanceTimelock;
        if (timelock == 0) {
            timelock = DEFAULT_MIN_REBALANCE_TIMELOCK;
        }
    }

    function allocateMarketId(SoloAmmStorage storage store) internal returns (uint256 marketId) {
        if (store.minRebalanceTimelock == 0) {
            store.minRebalanceTimelock = DEFAULT_MIN_REBALANCE_TIMELOCK;
        }
        marketId = store.nextMarketId + 1;
        store.nextMarketId = marketId;
    }
}
