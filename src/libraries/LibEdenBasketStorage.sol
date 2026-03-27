// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibEdenBasketStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.by.equalfi.basket.storage");

    struct BasketConfig {
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint256 totalUnits;
        address token;
        uint256 poolId;
        bool paused;
    }

    struct BasketMetadata {
        string name;
        string symbol;
        string uri;
        address creator;
        uint64 createdAt;
        uint8 basketType;
    }

    struct EdenBasketStorage {
        uint256 basketCount;
        uint16 poolFeeShareBps;
        mapping(uint256 => BasketConfig) baskets;
        mapping(uint256 => BasketMetadata) basketMetadata;
        mapping(uint256 => mapping(address => uint256)) vaultBalances;
        mapping(uint256 => mapping(address => uint256)) feePots;
        mapping(address => uint256) tokenToBasketIdPlusOne;
    }

    function s() internal pure returns (EdenBasketStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}
