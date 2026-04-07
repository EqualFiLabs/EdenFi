// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Types} from "src/libraries/Types.sol";

/// @notice Canonical diamond storage and typed records for the Self-Secured Credit rebuild.
library LibSelfSecuredCreditStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.self-secured-credit.storage");

    struct SelfSecuredCreditStorage {
        mapping(bytes32 => mapping(uint256 => Types.SscLine)) lines;
        mapping(bytes32 => mapping(uint256 => uint256)) claimableAciYield;
        mapping(bytes32 => mapping(uint256 => uint256)) protectedClaimableAciYield;
        mapping(bytes32 => mapping(uint256 => uint256)) totalAciAppliedToDebt;
    }

    function s() internal pure returns (SelfSecuredCreditStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function line(bytes32 positionKey, uint256 poolId) internal view returns (Types.SscLine storage sscLine) {
        sscLine = s().lines[positionKey][poolId];
    }

    function claimableAciYieldOf(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        return s().claimableAciYield[positionKey][poolId];
    }

    function totalAciAppliedToDebtOf(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        return s().totalAciAppliedToDebt[positionKey][poolId];
    }

    function protectedClaimableAciYieldOf(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        return s().protectedClaimableAciYield[positionKey][poolId];
    }

    function lineView(bytes32 positionKey, uint256 poolId) internal view returns (Types.SscLine memory sscLine) {
        sscLine = s().lines[positionKey][poolId];
    }

    function increaseClaimableAciYield(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) return;
        s().claimableAciYield[positionKey][poolId] += amount;
    }

    function decreaseClaimableAciYield(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) return;
        s().claimableAciYield[positionKey][poolId] -= amount;
    }

    function increaseTotalAciAppliedToDebt(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) return;
        s().totalAciAppliedToDebt[positionKey][poolId] += amount;
    }

    function setProtectedClaimableAciYield(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        s().protectedClaimableAciYield[positionKey][poolId] = amount;
    }
}
