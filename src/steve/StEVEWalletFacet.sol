// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {BasketToken} from "../tokens/BasketToken.sol";
import {StEVELogic} from "./StEVELogic.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibStEVEStorage} from "../libraries/LibStEVEStorage.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import "../libraries/Errors.sol";

contract StEVEWalletFacet is StEVELogic, ReentrancyGuardModifiers {
    event StEVEMinted(address indexed caller, address indexed to, uint256 units);
    event StEVEBurned(address indexed caller, address indexed to, uint256 units);

    function mintStEVE(uint256 units, address to, uint256[] calldata maxInputAmounts)
        external
        payable
        nonReentrant
        returns (uint256 minted)
    {
        _requireStEVEConfigured();
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();

        LibStEVEStorage.ProductConfig storage product = LibStEVEStorage.s().product;
        if (product.paused) revert IndexPaused(LibStEVEStorage.PRODUCT_ID);
        if (maxInputAmounts.length != product.assets.length) revert InvalidArrayLength();

        WalletMintState memory state;
        state.required = new uint256[](product.assets.length);
        state.feeAmounts = new uint256[](product.assets.length);

        _prepareStEVEWalletMint(product, units, maxInputAmounts, state);

        product.totalUnits += units;
        BasketToken(product.token).mintIndexUnits(to, units);
        emit StEVEMinted(msg.sender, to, units);
        return units;
    }

    function burnStEVE(uint256 units, address to)
        external
        payable
        nonReentrant
        returns (uint256[] memory assetsOut)
    {
        _requireStEVEConfigured();
        LibCurrency.assertZeroMsgValue();
        if (units == 0 || units % UNIT_SCALE != 0) revert InvalidUnits();

        LibStEVEStorage.ProductConfig storage product = LibStEVEStorage.s().product;
        if (product.paused) revert IndexPaused(LibStEVEStorage.PRODUCT_ID);
        if (units > product.totalUnits) revert InvalidUnits();
        uint256 balance = BasketToken(product.token).balanceOf(msg.sender);
        if (balance < units) revert InsufficientIndexTokens(units, balance);

        WalletBurnState memory state;
        state.assetsOut = new uint256[](product.assets.length);
        state.feeAmounts = new uint256[](product.assets.length);

        _prepareStEVEWalletBurn(product, units, to, state);

        product.totalUnits -= units;
        BasketToken(product.token).burnIndexUnits(msg.sender, units);
        assetsOut = state.assetsOut;
        emit StEVEBurned(msg.sender, to, units);
    }
}
