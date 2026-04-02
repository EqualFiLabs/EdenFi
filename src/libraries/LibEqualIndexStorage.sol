// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

library LibEqualIndexStorage {
    struct Index {
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint256 totalUnits;
        address token;
        bool paused;
    }

    struct EqualIndexStorage {
        uint256 indexCount;
        mapping(uint256 => Index) indexes;
        mapping(uint256 => mapping(address => uint256)) vaultBalances;
        mapping(uint256 => mapping(address => uint256)) feePots;
        mapping(uint256 => uint256) indexToPoolId;
        uint16 poolFeeShareBps;
        uint16 mintBurnFeeIndexShareBps;
    }

    bytes32 internal constant STORAGE_POSITION = keccak256("equal.index.storage.v3");

    function s() internal pure returns (EqualIndexStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function poolIdForIndex(uint256 indexId) internal view returns (uint256 poolId) {
        poolId = s().indexToPoolId[indexId];
    }
}
