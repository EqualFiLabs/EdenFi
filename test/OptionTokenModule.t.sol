// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";

contract OptionTokenModuleHarness is OptionTokenAdminFacet, OptionTokenViewFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }
}

contract OptionTokenModuleTest is Test {
    string internal constant BASE_URI = "ipfs://equalfi/options";

    OptionTokenModuleHarness internal harness;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal timelock = makeAddr("timelock");

    function setUp() public {
        harness = new OptionTokenModuleHarness();
        harness.setOwner(owner);
    }

    function test_OwnerCanDeployOptionTokenWhenTimelockUnset() public {
        vm.prank(owner);
        address tokenAddress = harness.deployOptionToken(BASE_URI, operator);

        assertEq(harness.getOptionToken(), tokenAddress);
        assertTrue(harness.hasOptionToken());
        assertEq(OptionToken(tokenAddress).owner(), operator);
        assertEq(OptionToken(tokenAddress).manager(), address(harness));
        assertEq(OptionToken(tokenAddress).uri(1), BASE_URI);
    }

    function test_RevertWhen_NonOwnerDeploysOptionTokenBeforeTimelockConfigured() public {
        vm.prank(operator);
        vm.expectRevert();
        harness.deployOptionToken(BASE_URI, operator);
    }

    function test_SetOptionTokenRejectsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(OptionTokenAdminFacet.OptionTokenAdmin_InvalidToken.selector, address(0))
        );
        harness.setOptionToken(address(0));
    }

    function test_TimelockTakesOverOptionTokenGovernanceWhenConfigured() public {
        vm.prank(owner);
        address tokenAddress = harness.deployOptionToken(BASE_URI, operator);
        assertEq(harness.getOptionToken(), tokenAddress);

        harness.setTimelock(timelock);

        vm.prank(owner);
        vm.expectRevert(bytes("LibAccess: not timelock"));
        harness.setOptionToken(tokenAddress);

        OptionToken adoptedToken = new OptionToken("ipfs://equalfi/options/v2", operator, address(harness));
        vm.prank(timelock);
        harness.setOptionToken(address(adoptedToken));

        assertEq(harness.getOptionToken(), address(adoptedToken));
    }
}
