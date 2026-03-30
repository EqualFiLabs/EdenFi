// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StEVEProductBase} from "src/steve/StEVEProductBase.sol";

interface ILegacyStEVEWalletFacet {
    function createBasket(StEVEProductBase.CreateBasketParams calldata params)
        external
        returns (uint256 basketId, address token);

    function mintBasket(uint256 basketId, uint256 units, address to, uint256[] calldata maxInputAmounts)
        external
        payable
        returns (uint256 minted);

    function burnBasket(uint256 basketId, uint256 units, address to)
        external
        payable
        returns (uint256[] memory assetsOut);
}
