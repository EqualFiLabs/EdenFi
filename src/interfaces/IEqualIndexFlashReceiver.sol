// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

interface IEqualIndexFlashReceiver {
    function onEqualIndexFlashLoan(
        uint256 indexId,
        uint256 units,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata data
    ) external;
}
