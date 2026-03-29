// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

interface IFlashLoanReceiver {
    function onFlashLoan(address initiator, address token, uint256 amount, bytes calldata data)
        external
        returns (bytes32);
}
