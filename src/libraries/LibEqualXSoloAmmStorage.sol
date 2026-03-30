// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibEqualXTypes} from "./LibEqualXTypes.sol";

library LibEqualXSoloAmmStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.equalx.solo-amm.storage");

    struct SoloAmmMarket {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint64 startTime;
        uint64 endTime;
        uint16 feeBps;
        LibEqualXTypes.FeeAsset feeAsset;
        LibEqualXTypes.InvariantMode invariantMode;
        bool active;
        bool finalized;
    }

    struct SoloAmmStorage {
        uint256 nextMarketId;
        mapping(uint256 => SoloAmmMarket) markets;
    }

    function s() internal pure returns (SoloAmmStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function allocateMarketId(SoloAmmStorage storage store) internal returns (uint256 marketId) {
        marketId = store.nextMarketId + 1;
        store.nextMarketId = marketId;
    }
}
