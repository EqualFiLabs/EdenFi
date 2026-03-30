// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

library LibStEVELendingStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.steve.lending.storage");
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
        uint256 collateralUnits;
        uint16 ltvBps;
        uint40 maturity;
    }

    struct LendingStorage {
        uint256 nextLoanId;
        LendingConfig lendingConfig;
        BorrowFeeTier[] borrowFeeTiers;
        uint256 lockedCollateralUnits;
        mapping(address => uint256) outstandingPrincipal;
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
