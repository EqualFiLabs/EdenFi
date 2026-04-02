// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Types} from "../libraries/Types.sol";
import {InsufficientPoolLiquidity, PoolNotInitialized} from "../libraries/Errors.sol";

/// @notice Pool-level flash loans backed by tracked pool liquidity.
contract FlashLoanFacet is ReentrancyGuardModifiers {
    bytes32 internal constant FLASH_CALLBACK_SUCCESS = keccak256("IFlashLoanReceiver.onFlashLoan");
    bytes32 internal constant FLASH_LOAN_FEE_SOURCE = keccak256("FLASH_LOAN");

    event FlashLoan(uint256 indexed pid, address indexed receiver, uint256 amount, uint256 fee, uint16 feeBps);

    function previewFlashLoanRepayment(uint256 pid, uint256 amount) external view returns (uint256) {
        Types.PoolData storage p = _pool(pid);
        return amount + ((amount * p.poolConfig.flashLoanFeeBps) / 10_000);
    }

    function flashLoan(
        uint256 pid,
        address receiver,
        uint256 amount,
        bytes calldata data,
        uint256 maxRepayment
    ) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();

        Types.PoolData storage p = _pool(pid);
        require(amount > 0, "Flash: amount=0");
        if (amount > p.trackedBalance) {
            revert InsufficientPoolLiquidity(amount, p.trackedBalance);
        }

        uint16 feeBps = p.poolConfig.flashLoanFeeBps;
        require(feeBps > 0, "Flash: fee not set");
        uint256 fee = (amount * feeBps) / 10_000;

        if (p.poolConfig.flashLoanAntiSplit) {
            LibAppStorage.FlashAgg storage agg = LibAppStorage.s().flashAgg[receiver][pid];
            require(agg.blockNumber == 0 || agg.blockNumber < block.number, "Flash: split block");
            agg.blockNumber = block.number;
            agg.amount = amount;
        }

        uint256 balBefore = LibCurrency.balanceOfSelf(p.underlying);
        if (balBefore < amount) {
            revert InsufficientPoolLiquidity(amount, balBefore);
        }

        LibCurrency.transfer(p.underlying, receiver, amount);
        require(
            IFlashLoanReceiver(receiver).onFlashLoan(msg.sender, p.underlying, amount, data) == FLASH_CALLBACK_SUCCESS,
            "Flash: callback"
        );

        if (LibCurrency.isNative(p.underlying)) {
            uint256 balAfterNative = LibCurrency.balanceOfSelf(p.underlying);
            require(balAfterNative >= balBefore + fee, "Flash: not repaid");
        } else {
            LibCurrency.pullAtLeast(p.underlying, receiver, amount + fee, maxRepayment);
            uint256 balAfter = LibCurrency.balanceOfSelf(p.underlying);
            require(balAfter >= balBefore + fee, "Flash: not repaid");
        }

        if (fee > 0) {
            p.trackedBalance += fee;
            if (LibCurrency.isNative(p.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += fee;
            }
            LibFeeRouter.routeManagedShare(pid, fee, FLASH_LOAN_FEE_SOURCE, true, fee);
        }

        emit FlashLoan(pid, receiver, amount, fee, feeBps);
    }

    function _pool(uint256 pid) internal view returns (Types.PoolData storage p) {
        p = LibAppStorage.s().pools[pid];
        if (!p.initialized) {
            revert PoolNotInitialized(pid);
        }
    }
}
