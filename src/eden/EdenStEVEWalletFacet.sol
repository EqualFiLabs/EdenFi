// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {BasketToken} from "../tokens/BasketToken.sol";
import {EdenBasketLogic} from "./EdenBasketLogic.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibEdenStEVEStorage} from "../libraries/LibEdenStEVEStorage.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import "../libraries/Errors.sol";

contract EdenStEVEWalletFacet is EdenBasketLogic, ReentrancyGuardModifiers {
    event StEVEMinted(address indexed caller, address indexed to, uint256 units);
    event StEVEBurned(address indexed caller, address indexed to, uint256 units);

    function mintStEVE(uint256 units, address to, uint256[] calldata maxInputAmounts)
        external
        payable
        nonReentrant
        returns (uint256 minted)
    {
        uint256 basketId = _requireStEVEConfigured();
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
        emit StEVEMinted(msg.sender, to, units);
        return units;
    }

    function burnStEVE(uint256 units, address to)
        external
        payable
        nonReentrant
        returns (uint256[] memory assetsOut)
    {
        uint256 basketId = _requireStEVEConfigured();
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
        emit StEVEBurned(msg.sender, to, units);
    }

    function _requireStEVEConfigured() internal view returns (uint256 basketId) {
        basketId = LibEdenBasketStorage.PRODUCT_ID;
        if (!LibEdenStEVEStorage.s().configured) revert InvalidParameterRange("stEVE not configured");
    }
}
