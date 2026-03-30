// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibEqualXTypes {
    enum MarketType {
        SOLO_AMM,
        COMMUNITY_AMM,
        CURVE_LIQUIDITY
    }

    enum FeeAsset {
        TokenIn,
        TokenOut
    }

    enum InvariantMode {
        Volatile,
        Stable
    }

    struct MarketPointer {
        MarketType marketType;
        uint256 marketId;
    }
}
