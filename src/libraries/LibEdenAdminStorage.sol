// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibEdenAdminStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.by.equalfi.admin.storage");
    uint256 internal constant TIMELOCK_DELAY_SECONDS = 7 days;

    struct AdminStorage {
        string protocolURI;
        string contractVersion;
        mapping(address => string) facetVersions;
    }

    function s() internal pure returns (AdminStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}
