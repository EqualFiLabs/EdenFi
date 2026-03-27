// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibEdenLendingStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("eden.by.equalfi.lending.storage");
    uint16 internal constant DEFAULT_LTV_BPS = 10_000;

    struct LendingConfig {
        uint40 minDuration;
        uint40 maxDuration;
    }

    struct BorrowFeeTier {
        uint256 minCollateralUnits;
        uint256 flatFeeNative;
    }

    struct Loan {
        bytes32 borrowerPositionKey;
        uint256 basketId;
        uint256 collateralUnits;
        uint16 ltvBps;
        uint40 maturity;
    }

    struct LendingStorage {
        uint256 nextLoanId;
        mapping(uint256 => LendingConfig) lendingConfigs;
        mapping(uint256 => BorrowFeeTier[]) borrowFeeTiers;
        mapping(uint256 => uint256) lockedCollateralUnits;
        mapping(uint256 => mapping(address => uint256)) outstandingPrincipal;
        mapping(uint256 => Loan) loans;
        mapping(bytes32 => uint256[]) borrowerLoanIds;
        mapping(uint256 => bool) loanClosed;
        mapping(uint256 => uint256) loanClosedAt;
        mapping(uint256 => uint8) loanCloseReason;
        mapping(uint256 => uint256) loanCreatedAt;
    }

    function s() internal pure returns (LendingStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }
}
