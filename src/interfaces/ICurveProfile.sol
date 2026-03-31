// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @notice Interface for EqualX custom curve pricing profiles.
interface ICurveProfile {
    function computePrice(
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 duration,
        uint256 currentTime,
        bytes32 profileParams
    ) external view returns (uint256 price);
}
