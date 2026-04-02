// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import "../libraries/Errors.sol";

/// @notice Shared storage + helpers for EqualIndex V3 facets.
abstract contract EqualIndexBaseV3 {
    struct CreateIndexParams {
        string name;
        string symbol;
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
    }

    struct IndexView {
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint256 totalUnits;
        address token;
        bool paused;
    }

    struct Index {
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint256 totalUnits;
        address token;
        bool paused;
    }

    struct EqualIndexStorage {
        uint256 indexCount;
        mapping(uint256 => Index) indexes;
        mapping(uint256 => mapping(address => uint256)) vaultBalances;
        mapping(uint256 => mapping(address => uint256)) feePots;
        mapping(uint256 => uint256) indexToPoolId;
        uint16 poolFeeShareBps;
        uint16 mintBurnFeeIndexShareBps;
    }

    bytes32 internal constant EQUAL_INDEX_V3_STORAGE_POSITION = keccak256("equal.index.storage.v3");

    modifier onlyTimelock() {
        if (msg.sender != LibAppStorage.timelockAddress(LibAppStorage.s())) revert Unauthorized();
        _;
    }

    modifier indexExists(uint256 indexId) {
        if (indexId >= s().indexCount) revert UnknownIndex(indexId);
        _;
    }

    function s() internal pure returns (EqualIndexStorage storage store) {
        bytes32 position = EQUAL_INDEX_V3_STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function _requireIndexActive(Index storage idx, uint256 indexId) internal view {
        if (idx.paused) revert IndexPaused(indexId);
    }

    function _validateFeeCaps(uint16[] calldata mintFeeBps, uint16[] calldata burnFeeBps, uint16 flashFeeBps)
        internal
        pure
    {
        uint256 len = mintFeeBps.length;
        for (uint256 i = 0; i < len; i++) {
            if (mintFeeBps[i] > 1000) revert InvalidParameterRange("mintFeeBps too high");
        }

        len = burnFeeBps.length;
        for (uint256 i = 0; i < len; i++) {
            if (burnFeeBps[i] > 1000) revert InvalidParameterRange("burnFeeBps too high");
        }

        if (flashFeeBps > 1000) revert InvalidParameterRange("flashFeeBps too high");
    }

    function _poolFeeShareBps() internal view returns (uint16) {
        uint16 configured = s().poolFeeShareBps;
        if (configured == 0) {
            return 1000;
        }
        return configured;
    }

    function _mintBurnFeeIndexShareBps() internal view returns (uint16) {
        uint16 configured = s().mintBurnFeeIndexShareBps;
        if (configured == 0) {
            return 4000;
        }
        return configured;
    }
}
