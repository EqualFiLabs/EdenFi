// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {UnexpectedMsgValue} from "src/libraries/Errors.sol";

contract MockERC20LibCurrency is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LibCurrencyHarness {
    receive() external payable {}

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function nativeAvailable() external view returns (uint256) {
        return LibCurrency.nativeAvailable();
    }

    function balanceOfSelf(address token) external view returns (uint256) {
        return LibCurrency.balanceOfSelf(token);
    }

    function decimalsOf(address token) external view returns (uint8) {
        return LibCurrency.decimals(token);
    }

    function pullNative(uint256 amount) external payable returns (uint256 received) {
        received = LibCurrency.pull(address(0), msg.sender, amount);
    }

    function pullNativeAtLeast(uint256 minAmount, uint256 maxAmount) external payable returns (uint256 received) {
        received = LibCurrency.pullAtLeast(address(0), msg.sender, minAmount, maxAmount);
    }

    function pullToken(address token, uint256 amount) external returns (uint256 received) {
        received = LibCurrency.pull(token, msg.sender, amount);
    }

    function pullTokenAtLeast(address token, uint256 minAmount, uint256 maxAmount) external returns (uint256 received) {
        received = LibCurrency.pullAtLeast(token, msg.sender, minAmount, maxAmount);
    }

    function transferNative(address to, uint256 amount) external {
        LibCurrency.transfer(address(0), to, amount);
    }

    function transferNativeWithMin(address to, uint256 amount, uint256 minReceived) external returns (uint256 received) {
        received = LibCurrency.transferWithMin(address(0), to, amount, minReceived);
    }

    function transferToken(address token, address to, uint256 amount) external {
        LibCurrency.transfer(token, to, amount);
    }

    function transferTokenWithMin(
        address token,
        address to,
        uint256 amount,
        uint256 minReceived
    ) external returns (uint256 received) {
        received = LibCurrency.transferWithMin(token, to, amount, minReceived);
    }

    function assertNativeMsgValue(uint256 amount) external payable {
        LibCurrency.assertMsgValue(address(0), amount);
    }

    function assertTokenMsgValue(address token, uint256 amount) external payable {
        LibCurrency.assertMsgValue(token, amount);
    }

    function assertZeroMsgValueHarness() external payable {
        LibCurrency.assertZeroMsgValue();
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
    MockERC20LibCurrency internal token;

    address internal depositor = makeAddr("depositor");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        harness = new LibCurrencyHarness();
        token = new MockERC20LibCurrency("Mock Token", "MOCK");
        vm.deal(depositor, 10 ether);
        vm.deal(attacker, 10 ether);
        token.mint(depositor, 10 ether);
        token.mint(address(harness), 10 ether);
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

    function test_TransferToken_PreservesNativeTrackedTotal() public {
        uint256 trackedBefore = harness.nativeTrackedTotal();
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        harness.transferToken(address(token), recipient, 1 ether);

        assertEq(token.balanceOf(recipient) - recipientBalanceBefore, 1 ether);
        assertEq(harness.nativeTrackedTotal(), trackedBefore);
    }

    function test_TransferTokenWithMin_PreservesNativeTrackedTotal() public {
        uint256 trackedBefore = harness.nativeTrackedTotal();
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        uint256 received = harness.transferTokenWithMin(address(token), recipient, 1 ether, 1 ether);

        assertEq(received, 1 ether);
        assertEq(token.balanceOf(recipient) - recipientBalanceBefore, 1 ether);
        assertEq(harness.nativeTrackedTotal(), trackedBefore);
    }

    function test_PullToken_PreservesNativeTrackedTotal() public {
        uint256 trackedBefore = harness.nativeTrackedTotal();
        uint256 harnessBalanceBefore = token.balanceOf(address(harness));

        vm.startPrank(depositor);
        token.approve(address(harness), 2 ether);
        uint256 received = harness.pullToken(address(token), 2 ether);
        vm.stopPrank();

        assertEq(received, 2 ether);
        assertEq(token.balanceOf(address(harness)) - harnessBalanceBefore, 2 ether);
        assertEq(harness.nativeTrackedTotal(), trackedBefore);
    }

    function test_PullTokenAtLeast_PreservesNativeTrackedTotal() public {
        uint256 trackedBefore = harness.nativeTrackedTotal();
        uint256 harnessBalanceBefore = token.balanceOf(address(harness));

        vm.startPrank(depositor);
        token.approve(address(harness), 3 ether);
        uint256 received = harness.pullTokenAtLeast(address(token), 2 ether, 3 ether);
        vm.stopPrank();

        assertEq(received, 3 ether);
        assertEq(token.balanceOf(address(harness)) - harnessBalanceBefore, 3 ether);
        assertEq(harness.nativeTrackedTotal(), trackedBefore);
    }

    function test_PullNative_IncrementsNativeTrackedTotal() public {
        vm.prank(depositor);
        uint256 received = harness.pullNative{value: 1 ether}(1 ether);

        assertEq(received, 1 ether);
        assertEq(harness.nativeTrackedTotal(), 1 ether);
    }

    function test_PullNativeAtLeast_IncrementsNativeTrackedTotalByMaxAmount() public {
        vm.prank(depositor);
        uint256 received = harness.pullNativeAtLeast{value: 2 ether}(1 ether, 2 ether);

        assertEq(received, 2 ether);
        assertEq(harness.nativeTrackedTotal(), 2 ether);
    }

    function test_AssertMsgValueErc20_PreservesValidationBehavior() public {
        harness.assertTokenMsgValue(address(token), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 1 wei));
        harness.assertTokenMsgValue{value: 1 wei}(address(token), 1 ether);
    }

    function test_AssertZeroMsgValue_RevertsWhenMsgValueIsPresent() public {
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 1 wei));
        harness.assertZeroMsgValueHarness{value: 1 wei}();
    }

    function test_TransferNative_ZeroAmountReturnsEarlyWithoutStateChange() public {
        uint256 trackedBefore = harness.nativeTrackedTotal();
        uint256 recipientBalanceBefore = recipient.balance;

        harness.transferNative(recipient, 0);

        assertEq(harness.nativeTrackedTotal(), trackedBefore);
        assertEq(recipient.balance, recipientBalanceBefore);
    }

    function test_PullNative_ZeroAmountReturnsEarlyWithoutStateChange() public {
        uint256 trackedBefore = harness.nativeTrackedTotal();

        vm.prank(depositor);
        uint256 received = harness.pullNative(0);

        assertEq(received, 0);
        assertEq(harness.nativeTrackedTotal(), trackedBefore);
    }

    function test_UtilityFunctions_PreserveNativeSemantics() public {
        assertEq(harness.decimalsOf(address(0)), 18);
        assertEq(harness.balanceOfSelf(address(0)), address(harness).balance);

        vm.prank(depositor);
        harness.pullNative{value: 1 ether}(1 ether);

        assertEq(harness.balanceOfSelf(address(0)), 1 ether);
        assertEq(harness.nativeAvailable(), 0);

        harness.transferNative(recipient, 1 ether);

        assertEq(harness.balanceOfSelf(address(0)), 0);
        assertEq(harness.nativeTrackedTotal(), 1 ether);
        assertEq(harness.nativeAvailable(), 0);
    }
}
