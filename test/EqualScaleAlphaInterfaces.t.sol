// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";

struct Log {
    bytes32[] topics;
    bytes data;
    address emitter;
}

interface Vm {
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

contract EqualScaleAlphaInterfacesHarness is IEqualScaleAlphaEvents {
    function emitBorrowerProfileRegistered() external {
        emit BorrowerProfileRegistered(
            keccak256("borrower-position"), 7, address(0xA11CE), address(0xB0B), 13, keccak256("metadata")
        );
    }

    function emitCreditLineActivated() external {
        emit CreditLineActivated(
            11,
            100e18,
            LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted,
            1 days,
            30 days,
            37 days
        );
    }

    function emitCreditLineFreezeUpdated() external {
        emit CreditLineFreezeUpdated(11, true, keccak256("ops-freeze"));
    }

    function revertBorrowerPositionNotOwned() external pure {
        revert IEqualScaleAlphaErrors.BorrowerPositionNotOwned(address(0xB0B), 7);
    }

    function revertInvalidDrawPacing() external pure {
        revert IEqualScaleAlphaErrors.InvalidDrawPacing(50e18, 60e18, 100e18);
    }

    function revertInvalidWriteDownState() external pure {
        revert IEqualScaleAlphaErrors.InvalidWriteDownState(11, LibEqualScaleAlphaStorage.CreditLineStatus.Active);
    }
}

contract EqualScaleAlphaInterfacesTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EqualScaleAlphaInterfacesHarness internal harness;

    function setUp() public {
        harness = new EqualScaleAlphaInterfacesHarness();
    }

    function test_eventsExposeExpectedTopics() external {
        vm.recordLogs();
        harness.emitBorrowerProfileRegistered();
        harness.emitCreditLineActivated();
        harness.emitCreditLineFreezeUpdated();

        Log[] memory logs = vm.getRecordedLogs();

        require(logs.length == 3, "unexpected log count");
        require(
            logs[0].topics[0] == keccak256("BorrowerProfileRegistered(bytes32,uint256,address,address,uint256,bytes32)"),
            "bad borrower profile event topic"
        );
        require(logs[0].topics[1] == keccak256("borrower-position"), "bad borrower profile key topic");
        require(logs[0].topics[2] == bytes32(uint256(7)), "bad borrower profile id topic");

        require(
            logs[1].topics[0] == keccak256("CreditLineActivated(uint256,uint256,uint8,uint40,uint40,uint40)"),
            "bad activation event topic"
        );
        require(logs[1].topics[1] == bytes32(uint256(11)), "bad activation line topic");

        require(
            logs[2].topics[0] == keccak256("CreditLineFreezeUpdated(uint256,bool,bytes32)"),
            "bad freeze event topic"
        );
        require(logs[2].topics[1] == bytes32(uint256(11)), "bad freeze line topic");
    }

    function test_errorsExposeExpectedSelectors() external {
        _assertRevertSelector(
            abi.encodeWithSelector(EqualScaleAlphaInterfacesHarness.revertBorrowerPositionNotOwned.selector),
            IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector
        );
        _assertRevertSelector(
            abi.encodeWithSelector(EqualScaleAlphaInterfacesHarness.revertInvalidDrawPacing.selector),
            IEqualScaleAlphaErrors.InvalidDrawPacing.selector
        );
        _assertRevertSelector(
            abi.encodeWithSelector(EqualScaleAlphaInterfacesHarness.revertInvalidWriteDownState.selector),
            IEqualScaleAlphaErrors.InvalidWriteDownState.selector
        );
    }

    function _assertRevertSelector(bytes memory callData, bytes4 expectedSelector) internal {
        (bool ok, bytes memory revertData) = address(harness).call(callData);
        require(!ok, "expected revert");
        require(_revertSelector(revertData) == expectedSelector, "unexpected revert selector");
    }

    function _revertSelector(bytes memory revertData) internal pure returns (bytes4 selector) {
        require(revertData.length >= 4, "missing revert selector");
        assembly {
            selector := mload(add(revertData, 0x20))
        }
    }
}
