// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibStEVEAdminStorage} from "src/libraries/LibStEVEAdminStorage.sol";
import {LibStEVEStorage} from "src/libraries/LibStEVEStorage.sol";
import {LibStEVELendingStorage} from "src/libraries/LibStEVELendingStorage.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {LibStEVEEligibilityStorage} from "src/libraries/LibStEVEEligibilityStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {DirectError_InvalidPositionNFT} from "src/libraries/Errors.sol";
import {PositionAgent_Unauthorized} from "src/libraries/PositionAgentErrors.sol";

contract PositionAgentStorageHarness {
    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
    }

    function requirePositionOwner(uint256 tokenId) external view {
        LibPositionAgentStorage.requirePositionOwner(tokenId);
    }

    function slot() external pure returns (bytes32) {
        return LibPositionAgentStorage.STORAGE_POSITION;
    }
}

contract LibPositionAgentStorageTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    PositionNFT internal positionNft;
    PositionAgentStorageHarness internal harness;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));
        harness = new PositionAgentStorageHarness();
    }

    function test_storageSlot_isIsolatedFromExistingNamespaces() external {
        bytes32 slot_ = harness.slot();

        require(slot_ == keccak256("equal.lend.erc6551.agent.storage"), "unexpected wallet slot");
        require(slot_ != LibAppStorage.APP_STORAGE_POSITION, "collides with app storage");
        require(slot_ != LibDiamond.DIAMOND_STORAGE_POSITION, "collides with diamond storage");
        require(slot_ != LibPositionNFT.POSITION_NFT_STORAGE_POSITION, "collides with position nft storage");
        require(slot_ != LibPoolMembership.POOL_MEMBERSHIP_STORAGE_POSITION, "collides with pool membership");
        require(slot_ != LibEncumbrance.STORAGE_POSITION, "collides with encumbrance");
        require(slot_ != LibStEVEAdminStorage.STORAGE_POSITION, "collides with eden admin");
        require(slot_ != LibStEVEStorage.STORAGE_POSITION, "collides with eden basket");
        require(slot_ != LibStEVELendingStorage.STORAGE_POSITION, "collides with eden lending");
        require(slot_ != LibEdenRewardsStorage.STORAGE_POSITION, "collides with eden rewards");
        require(slot_ != LibStEVEEligibilityStorage.STORAGE_POSITION, "collides with eden steve");
        require(slot_ != keccak256("equalscale.alpha.storage"), "collides with equalscale alpha");
    }

    function test_requirePositionOwner_revertsWhenPositionNFTUnset() external {
        vm.expectRevert(DirectError_InvalidPositionNFT.selector);
        harness.requirePositionOwner(1);
    }

    function test_requirePositionOwner_usesPositionOwner() external {
        harness.setPositionNFT(address(positionNft));
        uint256 tokenId = positionNft.mint(alice, 1);

        vm.prank(alice);
        harness.requirePositionOwner(tokenId);
    }

    function test_requirePositionOwner_rejectsNonOwnerAndApprovedOperator() external {
        harness.setPositionNFT(address(positionNft));
        uint256 tokenId = positionNft.mint(alice, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_Unauthorized.selector, bob, tokenId));
        harness.requirePositionOwner(tokenId);

        vm.prank(alice);
        positionNft.approve(bob, tokenId);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_Unauthorized.selector, bob, tokenId));
        harness.requirePositionOwner(tokenId);
    }

    function test_requirePositionOwner_revertsForUnknownTokenId() external {
        harness.setPositionNFT(address(positionNft));

        vm.prank(alice);
        vm.expectRevert();
        harness.requirePositionOwner(999);
    }
}
