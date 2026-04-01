// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @notice Storage anchor for the canonical EqualFi option token configuration.
library LibOptionTokenStorage {
    bytes32 internal constant OPTION_TOKEN_STORAGE_POSITION = keccak256("equalfi.option.token.storage");

    struct OptionTokenStorage {
        address optionToken;
    }

    function s() internal pure returns (OptionTokenStorage storage store) {
        bytes32 position = OPTION_TOKEN_STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}
