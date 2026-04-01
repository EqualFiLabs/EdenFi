// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {OptionToken} from "src/tokens/OptionToken.sol";
import {LibAccess} from "src/libraries/LibAccess.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibOptionTokenStorage} from "src/libraries/LibOptionTokenStorage.sol";

/// @notice Governance surface for the canonical EqualFi option token.
contract OptionTokenAdminFacet {
    error OptionTokenAdmin_InvalidToken(address token);

    event OptionTokenUpdated(address indexed previousToken, address indexed newToken);
    event OptionTokenDeployed(address indexed token, address indexed owner, string baseURI);

    function deployOptionToken(string calldata baseURI, address owner_) external returns (address token) {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        token = address(new OptionToken(baseURI, owner_, address(this)));
        _setOptionToken(token);

        emit OptionTokenDeployed(token, owner_, baseURI);
    }

    function setOptionToken(address token) external {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        _setOptionToken(token);
    }

    function _setOptionToken(address token) internal {
        if (token == address(0)) {
            revert OptionTokenAdmin_InvalidToken(token);
        }

        LibOptionTokenStorage.OptionTokenStorage storage store = LibOptionTokenStorage.s();
        address previousToken = store.optionToken;
        store.optionToken = token;

        emit OptionTokenUpdated(previousToken, token);
    }
}
