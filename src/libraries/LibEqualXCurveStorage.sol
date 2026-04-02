// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEqualXTypes} from "./LibEqualXTypes.sol";

library LibEqualXCurveStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.equalx.curve.storage");

    struct CurveMarket {
        bytes32 commitment;
        uint128 remainingVolume;
        uint64 endTime;
        uint32 generation;
        bool active;
    }

    struct CurveData {
        bytes32 makerPositionKey;
        uint256 makerPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
    }

    struct CurveImmutables {
        address tokenA;
        address tokenB;
        uint128 maxVolume;
        uint96 salt;
        uint16 feeRateBps;
        bool priceIsQuotePerBase;
        LibEqualXTypes.FeeAsset feeAsset;
    }

    struct CurvePricing {
        uint128 startPrice;
        uint128 endPrice;
        uint64 startTime;
        uint64 duration;
    }

    struct CurveProfileData {
        uint16 profileId;
        bytes32 profileParams;
    }

    struct CurveProfileRegistryEntry {
        address impl;
        uint32 flags;
        bool approved;
    }

    struct CurveStorage {
        uint256 nextCurveId;
        mapping(uint256 => CurveMarket) markets;
        mapping(uint256 => CurveData) curveData;
        mapping(uint256 => CurveImmutables) curveImmutables;
        mapping(uint256 => CurvePricing) curvePricing;
        mapping(uint256 => CurveProfileData) curveProfileData;
        mapping(uint16 => CurveProfileRegistryEntry) curveProfiles;
        mapping(uint256 => bytes32) curveImmutableHash;
        mapping(uint256 => bool) curveBaseIsA;
    }

    function s() internal pure returns (CurveStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function allocateCurveId(CurveStorage storage store) internal returns (uint256 curveId) {
        curveId = store.nextCurveId + 1;
        store.nextCurveId = curveId;
    }
}
