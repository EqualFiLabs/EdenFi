// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {BasketToken} from "../tokens/BasketToken.sol";
import {EdenBasketLogic} from "./EdenBasketLogic.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import "../libraries/Errors.sol";

contract EdenBasketWalletFacet is EdenBasketLogic, ReentrancyGuardModifiers {
    event BasketMinted(uint256 indexed basketId, address indexed caller, address indexed to, uint256 units);
    event BasketBurned(uint256 indexed basketId, address indexed caller, address indexed to, uint256 units);

    function createBasket(CreateBasketParams calldata params)
        external
        nonReentrant
        returns (uint256 basketId, address token)
    {
        LibAccess.enforceTimelockOrOwnerIfUnset();
        _validateCreateParams(params);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        for (uint256 i = 0; i < params.assets.length; i++) {
            if (app.assetToPoolId[params.assets[i]] == 0) revert NoPoolForAsset(params.assets[i]);
        }

        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        if (store.poolFeeShareBps == 0) {
            store.poolFeeShareBps = 1000;
        }

        basketId = LibEdenBasketStorage.PRODUCT_ID;
        token = address(new BasketToken(params.name, params.symbol, address(this), basketId));
        _createBasketInternal(params, basketId, token);
    }

    function mintBasket(uint256 basketId, uint256 units, address to, uint256[] calldata maxInputAmounts)
        external
        payable
        nonReentrant
        basketExists(basketId)
        returns (uint256 minted)
    {
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();
        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        if (basket.paused) revert IndexPaused(basketId);
        if (maxInputAmounts.length != basket.assets.length) revert InvalidArrayLength();

        WalletMintState memory state;
        state.required = new uint256[](basket.assets.length);
        state.feeAmounts = new uint256[](basket.assets.length);

        _prepareWalletMint(basketId, basket, units, maxInputAmounts, state);

        basket.totalUnits += units;
        BasketToken(basket.token).mintIndexUnits(to, units);
        emit BasketMinted(basketId, msg.sender, to, units);
        return units;
    }

    function burnBasket(uint256 basketId, uint256 units, address to)
        external
        payable
        nonReentrant
        basketExists(basketId)
        returns (uint256[] memory assetsOut)
    {
        LibCurrency.assertZeroMsgValue();
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();

        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        if (basket.paused) revert IndexPaused(basketId);
        if (units > basket.totalUnits) revert InvalidUnits();
        uint256 balance = BasketToken(basket.token).balanceOf(msg.sender);
        if (balance < units) revert InsufficientIndexTokens(units, balance);

        WalletBurnState memory state;
        state.assetsOut = new uint256[](basket.assets.length);
        state.feeAmounts = new uint256[](basket.assets.length);

        _prepareWalletBurn(basketId, basket, units, to, state);

        basket.totalUnits -= units;
        BasketToken(basket.token).burnIndexUnits(msg.sender, units);
        assetsOut = state.assetsOut;
        emit BasketBurned(basketId, msg.sender, to, units);
    }
}
