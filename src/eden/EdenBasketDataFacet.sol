// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {EdenBasketBase} from "./EdenBasketBase.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";

contract EdenBasketDataFacet is EdenBasketBase {
    function getBasket(uint256 basketId) external view basketExists(basketId) returns (BasketView memory basket_) {
        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        basket_.assets = basket.assets;
        basket_.bundleAmounts = basket.bundleAmounts;
        basket_.mintFeeBps = basket.mintFeeBps;
        basket_.burnFeeBps = basket.burnFeeBps;
        basket_.flashFeeBps = basket.flashFeeBps;
        basket_.totalUnits = basket.totalUnits;
        basket_.token = basket.token;
        basket_.poolId = basket.poolId;
        basket_.paused = basket.paused;
    }

    function getBasketMetadata(uint256 basketId)
        external
        view
        basketExists(basketId)
        returns (LibEdenBasketStorage.ProductMetadata memory)
    {
        return LibEdenBasketStorage.s().productMetadata;
    }

    function getBasketPoolId(uint256 basketId) external view basketExists(basketId) returns (uint256) {
        return LibEdenBasketStorage.s().product.poolId;
    }

    function getBasketVaultBalance(uint256 basketId, address asset)
        external
        view
        basketExists(basketId)
        returns (uint256)
    {
        return LibEdenBasketStorage.s().accounting.vaultBalances[asset];
    }

    function getBasketFeePot(uint256 basketId, address asset)
        external
        view
        basketExists(basketId)
        returns (uint256)
    {
        return LibEdenBasketStorage.s().accounting.feePots[asset];
    }
}
