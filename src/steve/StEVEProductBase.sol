// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibStEVEStorage} from "../libraries/LibStEVEStorage.sol";
import "../libraries/Errors.sol";

abstract contract StEVEProductBase {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant UNIT_SCALE = 1e18;

    struct CreateBasketParams {
        string name;
        string symbol;
        string uri;
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint8 basketType;
    }

    struct WalletMintLeg {
        address asset;
        uint256 baseDeposit;
        uint256 potBuyIn;
        uint256 grossInput;
        uint256 fee;
        uint256 totalRequired;
    }

    struct WalletMintState {
        uint256[] required;
        uint256[] feeAmounts;
    }

    struct WalletBurnLeg {
        address asset;
        uint256 bundleOut;
        uint256 potShare;
        uint256 payout;
        uint256 fee;
    }

    struct WalletBurnState {
        uint256[] assetsOut;
        uint256[] feeAmounts;
    }

    struct PositionMintLeg {
        address asset;
        uint256 poolId;
        uint256 baseDeposit;
        uint256 potBuyIn;
        uint256 grossInput;
        uint256 fee;
        uint256 totalRequired;
    }

    struct PositionMintState {
        uint256[] required;
        uint256[] feeAmounts;
    }

    struct PositionBurnLeg {
        address asset;
        uint256 bundleOut;
        uint256 potShare;
        uint256 payout;
        uint256 fee;
        uint256 poolShare;
        uint256 potFee;
    }

    struct PositionBurnState {
        uint256[] assetsOut;
        uint256[] feeAmounts;
    }

    modifier basketExists(uint256 basketId) {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        if (!store.productInitialized || basketId != LibStEVEStorage.PRODUCT_ID) revert UnknownIndex(basketId);
        _;
    }

    function _basketPoolFeeShareBps() internal view returns (uint16) {
        uint16 configured = LibStEVEStorage.s().poolFeeShareBps;
        if (configured == 0) {
            return 1000;
        }
        return configured;
    }

    function _validateCreateParams(CreateBasketParams calldata params) internal pure {
        uint256 len = params.assets.length;
        if (len == 0 || len != params.bundleAmounts.length) revert InvalidArrayLength();
        if (params.mintFeeBps.length != len || params.burnFeeBps.length != len) revert InvalidArrayLength();
        if (params.flashFeeBps > 1000) revert InvalidParameterRange("flashFeeBps too high");

        for (uint256 i = 0; i < len; i++) {
            if (params.assets[i] == address(0)) revert InvalidUnderlying();
            if (params.bundleAmounts[i] == 0) revert InvalidBundleDefinition();
            if (params.mintFeeBps[i] > 1000 || params.burnFeeBps[i] > 1000) {
                revert InvalidParameterRange("basket fee too high");
            }
            for (uint256 j = i + 1; j < len; j++) {
                if (params.assets[i] == params.assets[j]) revert InvalidBundleDefinition();
            }
        }
    }
}
