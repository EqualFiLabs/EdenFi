// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibOptionTokenStorage} from "src/libraries/LibOptionTokenStorage.sol";

/// @notice View surface for the canonical EqualFi option token configuration.
contract OptionTokenViewFacet {
    function getOptionToken() external view returns (address token) {
        token = LibOptionTokenStorage.s().optionToken;
    }

    function hasOptionToken() external view returns (bool configured) {
        configured = LibOptionTokenStorage.s().optionToken != address(0);
    }
}
