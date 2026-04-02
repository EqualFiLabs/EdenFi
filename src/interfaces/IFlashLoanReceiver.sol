// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IFlashLoanReceiver {
    function onFlashLoan(address initiator, address token, uint256 amount, bytes calldata data)
        external
        returns (bytes32);
}
