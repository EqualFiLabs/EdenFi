// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibEdenBasketStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.by.equalfi.product.storage");
    uint256 internal constant PRODUCT_ID = 0;

    struct ProductConfig {
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

    struct ProductMetadata {
        string name;
        string symbol;
        string uri;
        address creator;
        uint64 createdAt;
        uint8 productType;
    }

    struct ProductAccounting {
        mapping(address => uint256) vaultBalances;
        mapping(address => uint256) feePots;
    }

    struct EdenProductStorage {
        bool productInitialized;
        uint16 poolFeeShareBps;
        ProductConfig product;
        ProductMetadata productMetadata;
        ProductAccounting accounting;
    }

    function s() internal pure returns (EdenProductStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}
