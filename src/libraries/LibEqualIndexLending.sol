// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @notice Storage and shared types for EqualIndex lending.
library LibEqualIndexLending {
    bytes32 internal constant STORAGE_POSITION = keccak256("equal.index.lending.storage");

    struct LendingConfig {
        uint16 ltvBps;
        uint16 originationFeeBps;
        uint40 minDuration;
        uint40 maxDuration;
    }

    struct BorrowFeeTier {
        uint256 minCollateralUnits;
        uint256 flatFeeNative;
    }

    struct IndexLoan {
        bytes32 positionKey;
        uint256 indexId;
        uint256 collateralUnits;
        uint16 ltvBps;
        uint40 maturity;
    }

    struct LendingStorage {
        mapping(uint256 => IndexLoan) loans;
        uint256 nextLoanId;
        mapping(uint256 => mapping(address => uint256)) outstandingPrincipal;
        mapping(uint256 => uint256) lockedCollateralUnits;
        mapping(uint256 => LendingConfig) lendingConfigs;
        mapping(uint256 => BorrowFeeTier[]) borrowFeeTiers;
    }

    function s() internal pure returns (LendingStorage storage ls) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            ls.slot := position
        }
    }

    /// @notice Computes economic balance used by pricing code.
    function getEconomicBalance(uint256 indexId, address asset, uint256 vaultBalance) internal view returns (uint256) {
        return vaultBalance + s().outstandingPrincipal[indexId][asset];
    }
}
