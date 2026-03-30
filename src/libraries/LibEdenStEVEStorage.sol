// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibEdenStEVEStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.by.equalfi.steve.storage");

    struct StEVEStorage {
        bool configured;
        uint256 eligibleSupply;
        mapping(bytes32 => uint256) eligiblePrincipal;
    }

    function s() internal pure returns (StEVEStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}
