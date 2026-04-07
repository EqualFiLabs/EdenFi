// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {UnexpectedMsgValue} from "src/libraries/Errors.sol";

contract LibCurrencyHarness {
    receive() external payable {}

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function nativeAvailable() external view returns (uint256) {
        return LibCurrency.nativeAvailable();
    }

    function pullNative(uint256 amount) external payable returns (uint256 received) {
        received = LibCurrency.pull(address(0), msg.sender, amount);
    }

    function pullNativeAtLeast(uint256 minAmount, uint256 maxAmount) external payable returns (uint256 received) {
        received = LibCurrency.pullAtLeast(address(0), msg.sender, minAmount, maxAmount);
    }

    function transferNative(address to, uint256 amount) external {
        LibCurrency.transfer(address(0), to, amount);
    }

    function transferNativeWithMin(address to, uint256 amount, uint256 minReceived) external returns (uint256 received) {
        received = LibCurrency.transferWithMin(address(0), to, amount, minReceived);
    }

    function assertNativeMsgValue(uint256 amount) external payable {
        LibCurrency.assertMsgValue(address(0), amount);
    }

    function assertAndPullNative(uint256 amount) external payable returns (uint256 received) {
        LibCurrency.assertMsgValue(address(0), amount);
        received = LibCurrency.pull(address(0), msg.sender, amount);
    }
}

contract ForceSend {
    constructor() payable {}

    function destroy(address payable target) external {
        selfdestruct(target);
    }
}

contract LibCurrencyTest is Test {
    LibCurrencyHarness internal harness;

    address internal depositor = makeAddr("depositor");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        harness = new LibCurrencyHarness();
        vm.deal(depositor, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    function test_BugCondition_Transfer_ShouldDecreaseNativeTrackedTotal() public {
        vm.prank(depositor);
        harness.pullNative{value: 1 ether}(1 ether);

        assertEq(harness.nativeTrackedTotal(), 1 ether);

        harness.transferNative(recipient, 1 ether);

        assertEq(harness.nativeTrackedTotal(), 0);
    }

    function test_BugCondition_TransferWithMin_ShouldDecreaseNativeTrackedTotal() public {
        vm.prank(depositor);
        harness.pullNative{value: 1 ether}(1 ether);

        assertEq(harness.nativeTrackedTotal(), 1 ether);

        uint256 recipientBalanceBefore = recipient.balance;
        uint256 received = harness.transferNativeWithMin(recipient, 1 ether, 0.99 ether);

        assertEq(received, 1 ether);
        assertEq(recipient.balance - recipientBalanceBefore, 1 ether);
        assertEq(harness.nativeTrackedTotal(), 0);
    }

    function test_BugCondition_CumulativeTransfers_ShouldReturnNativeTrackedTotalToBaseline() public {
        vm.prank(depositor);
        harness.pullNative{value: 5 ether}(5 ether);

        assertEq(harness.nativeTrackedTotal(), 5 ether);

        for (uint256 i = 0; i < 5; i++) {
            harness.transferNative(recipient, 1 ether);
        }

        assertEq(harness.nativeTrackedTotal(), 0);
    }

    function test_BugCondition_AssertMsgValue_ShouldRevertWhenNativeAmountHasZeroMsgValue() public {
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 0));
        harness.assertNativeMsgValue(1 ether);
    }

    function test_BugCondition_AssertMsgValueZeroBypass_ShouldNotAllowClaimingOrphanedEth() public {
        ForceSend forceSend = new ForceSend{value: 1 ether}();
        forceSend.destroy(payable(address(harness)));

        assertEq(address(harness).balance, 1 ether);
        assertEq(harness.nativeTrackedTotal(), 0);
        assertEq(harness.nativeAvailable(), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 0));
        harness.assertAndPullNative(1 ether);
    }
}
