// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibEqualXTypes} from "./LibEqualXTypes.sol";

library LibEqualXDiscoveryStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.equalx.discovery.storage");

    struct DiscoveryStorage {
        mapping(bytes32 => LibEqualXTypes.MarketPointer[]) marketsByPosition;
        mapping(bytes32 => LibEqualXTypes.MarketPointer[]) marketsByPair;
        mapping(uint8 => LibEqualXTypes.MarketPointer[]) activeMarketsByType;
    }

    function s() internal pure returns (DiscoveryStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address left, address right) = tokenA <= tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(left, right));
    }

    function registerMarket(
        DiscoveryStorage storage store,
        bytes32 positionKey,
        address tokenA,
        address tokenB,
        LibEqualXTypes.MarketType marketType,
        uint256 marketId
    ) internal {
        LibEqualXTypes.MarketPointer memory pointer =
            LibEqualXTypes.MarketPointer({marketType: marketType, marketId: marketId});
        store.marketsByPosition[positionKey].push(pointer);
        store.marketsByPair[pairKey(tokenA, tokenB)].push(pointer);
        store.activeMarketsByType[uint8(marketType)].push(pointer);
    }

    function removeActiveMarket(
        DiscoveryStorage storage store,
        LibEqualXTypes.MarketType marketType,
        uint256 marketId
    ) internal {
        LibEqualXTypes.MarketPointer[] storage active = store.activeMarketsByType[uint8(marketType)];
        uint256 len = active.length;
        for (uint256 i; i < len; ++i) {
            if (active[i].marketId == marketId && active[i].marketType == marketType) {
                uint256 last = len - 1;
                if (i != last) {
                    active[i] = active[last];
                }
                active.pop();
                return;
            }
        }
    }

    function marketsByPosition(DiscoveryStorage storage store, bytes32 positionKey)
        internal
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        LibEqualXTypes.MarketPointer[] storage stored = store.marketsByPosition[positionKey];
        uint256 len = stored.length;
        pointers = new LibEqualXTypes.MarketPointer[](len);
        for (uint256 i = 0; i < len; i++) {
            pointers[i] = stored[i];
        }
    }

    function marketsByPair(DiscoveryStorage storage store, address tokenA, address tokenB)
        internal
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        LibEqualXTypes.MarketPointer[] storage stored = store.marketsByPair[pairKey(tokenA, tokenB)];
        uint256 len = stored.length;
        pointers = new LibEqualXTypes.MarketPointer[](len);
        for (uint256 i = 0; i < len; i++) {
            pointers[i] = stored[i];
        }
    }

    function activeMarketsByType(DiscoveryStorage storage store, LibEqualXTypes.MarketType marketType)
        internal
        view
        returns (LibEqualXTypes.MarketPointer[] memory pointers)
    {
        LibEqualXTypes.MarketPointer[] storage stored = store.activeMarketsByType[uint8(marketType)];
        uint256 len = stored.length;
        pointers = new LibEqualXTypes.MarketPointer[](len);
        for (uint256 i = 0; i < len; i++) {
            pointers[i] = stored[i];
        }
    }
}
