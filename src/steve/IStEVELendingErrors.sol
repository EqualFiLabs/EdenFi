// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

interface IStEVELendingErrors {
    error InvalidDuration(uint256 provided, uint256 minDuration, uint256 maxDuration);
    error InvalidTierConfiguration();
    error UnexpectedNativeFee(uint256 expected, uint256 actual);
    error InsufficientVaultBalance(address asset, uint256 expected, uint256 actual);
    error RedeemabilityInvariantBroken(address asset, uint256 required, uint256 remaining);
    error LoanNotFound(uint256 loanId);
    error LoanExpired(uint256 loanId, uint40 maturity);
    error LoanNotExpired(uint256 loanId, uint40 maturity);
    error BelowMinimumTier(uint256 collateralUnits);
    error PositionMismatch(bytes32 expected, bytes32 actual);
}
