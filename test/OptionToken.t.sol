// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";

contract OptionTokenTest is Test {
    string internal constant BASE_URI = "ipfs://equalfi/options";

    address internal constant OWNER = address(0xA11CE);
    address internal constant MANAGER = address(0xBEEF);
    address internal constant ALICE = address(0x1111);
    address internal constant BOB = address(0x2222);

    OptionToken internal token;

    function setUp() public {
        token = new OptionToken(BASE_URI, OWNER, MANAGER);
    }

    function test_RevertWhen_ManagerIsZeroAtConstruction() public {
        vm.expectRevert(abi.encodeWithSelector(OptionToken.OptionToken_InvalidManager.selector, address(0)));
        new OptionToken(BASE_URI, OWNER, address(0));
    }

    function test_ManagerControlsMintBurnAndSeriesUri() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.OptionToken_NotManager.selector, ALICE));
        token.mint(ALICE, 1, 5, "");

        vm.prank(MANAGER);
        token.mint(ALICE, 1, 5, "");
        assertEq(token.balanceOf(ALICE, 1), 5);

        vm.prank(MANAGER);
        token.setSeriesURI(1, "ipfs://equalfi/options/1");
        assertEq(token.uri(1), "ipfs://equalfi/options/1");
        assertEq(token.uri(999), BASE_URI);

        vm.prank(MANAGER);
        token.burn(ALICE, 1, 2);
        assertEq(token.balanceOf(ALICE, 1), 3);

        vm.prank(MANAGER);
        token.mint(ALICE, 2, 4, "");

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 3;

        vm.prank(MANAGER);
        token.burnBatch(ALICE, ids, amounts);

        assertEq(token.balanceOf(ALICE, 1), 2);
        assertEq(token.balanceOf(ALICE, 2), 1);
    }

    function test_OwnerControlsManagerAndBaseUri() public {
        vm.prank(ALICE);
        vm.expectRevert();
        token.setManager(BOB);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.OptionToken_InvalidManager.selector, address(0)));
        token.setManager(address(0));

        vm.prank(OWNER);
        token.setBaseURI("ipfs://equalfi/options/v2");
        assertEq(token.uri(7), "ipfs://equalfi/options/v2");

        vm.prank(OWNER);
        token.setManager(BOB);
        assertEq(token.manager(), BOB);

        vm.prank(BOB);
        token.mint(ALICE, 7, 9, "");
        assertEq(token.balanceOf(ALICE, 7), 9);
    }

    function test_HoldersCanTransferWithStandardErc1155Flow() public {
        vm.prank(MANAGER);
        token.mint(ALICE, 3, 6, "");

        vm.prank(ALICE);
        token.safeTransferFrom(ALICE, BOB, 3, 4, "");

        assertEq(token.balanceOf(ALICE, 3), 2);
        assertEq(token.balanceOf(BOB, 3), 4);
    }
}
