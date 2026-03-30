// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibStEVELendingStorage} from "src/libraries/LibStEVELendingStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";

contract EqualScaleAlphaStorageHarness {
    function alphaSlot() external pure returns (bytes32) {
        return LibEqualScaleAlphaStorage.STORAGE_POSITION;
    }

    function setAlphaNextLineId(uint256 nextLineId) external {
        LibEqualScaleAlphaStorage.s().nextLineId = nextLineId;
    }

    function alphaNextLineId() external view returns (uint256) {
        return LibEqualScaleAlphaStorage.s().nextLineId;
    }

    function setBorrowerProfile(
        bytes32 borrowerPositionKey,
        address treasuryWallet,
        address bankrToken,
        bytes32 metadataHash,
        bool active
    ) external {
        LibEqualScaleAlphaStorage.BorrowerProfile storage profile =
            LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];
        profile.borrowerPositionKey = borrowerPositionKey;
        profile.treasuryWallet = treasuryWallet;
        profile.bankrToken = bankrToken;
        profile.metadataHash = metadataHash;
        profile.active = active;
    }

    function getBorrowerProfile(bytes32 borrowerPositionKey)
        external
        view
        returns (bytes32 storedKey, address treasuryWallet, address bankrToken, bytes32 metadataHash, bool active)
    {
        LibEqualScaleAlphaStorage.BorrowerProfile storage profile =
            LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];
        return (
            profile.borrowerPositionKey,
            profile.treasuryWallet,
            profile.bankrToken,
            profile.metadataHash,
            profile.active
        );
    }

    function setLendingNextLoanId(uint256 nextLoanId) external {
        LibStEVELendingStorage.s().nextLoanId = nextLoanId;
    }

    function lendingNextLoanId() external view returns (uint256) {
        return LibStEVELendingStorage.s().nextLoanId;
    }

    function setPositionAgentId(uint256 positionId, uint256 agentId) external {
        LibPositionAgentStorage.s().positionToAgentId[positionId] = agentId;
    }

    function positionAgentId(uint256 positionId) external view returns (uint256) {
        return LibPositionAgentStorage.s().positionToAgentId[positionId];
    }
}

contract LibEqualScaleAlphaStorageTest {
    EqualScaleAlphaStorageHarness internal harness;

    function setUp() public {
        harness = new EqualScaleAlphaStorageHarness();
    }

    function test_storageSlot_isIsolatedFromExistingNamespaces() external view {
        bytes32 slot_ = harness.alphaSlot();

        require(slot_ == keccak256("equalscale.alpha.storage"), "unexpected alpha slot");
        require(slot_ != LibAppStorage.APP_STORAGE_POSITION, "collides with app storage");
        require(slot_ != LibDiamond.DIAMOND_STORAGE_POSITION, "collides with diamond storage");
        require(slot_ != LibPositionNFT.POSITION_NFT_STORAGE_POSITION, "collides with position nft storage");
        require(slot_ != LibPoolMembership.POOL_MEMBERSHIP_STORAGE_POSITION, "collides with pool membership");
        require(slot_ != LibEncumbrance.STORAGE_POSITION, "collides with encumbrance");
        require(slot_ != LibStEVELendingStorage.STORAGE_POSITION, "collides with eden lending");
        require(slot_ != LibPositionAgentStorage.STORAGE_POSITION, "collides with position agent storage");
    }

    function test_storageWrites_doNotOverlapEdenLendingOrPositionAgentStorage() external {
        bytes32 borrowerPositionKey = keccak256("equalscale.borrower");
        address treasuryWallet = address(0xA11CE);
        address bankrToken = address(0xBEEF);
        bytes32 metadataHash = keccak256("metadata");

        harness.setAlphaNextLineId(7);
        harness.setBorrowerProfile(borrowerPositionKey, treasuryWallet, bankrToken, metadataHash, true);

        require(harness.lendingNextLoanId() == 0, "alpha write mutated lending");
        require(harness.positionAgentId(55) == 0, "alpha write mutated position agent");

        harness.setLendingNextLoanId(19);
        harness.setPositionAgentId(55, 73);

        require(harness.alphaNextLineId() == 7, "lending or wallet write mutated alpha counter");

        (
            bytes32 storedKey,
            address storedTreasuryWallet,
            address storedBankrToken,
            bytes32 storedMetadataHash,
            bool profileActive
        ) = harness.getBorrowerProfile(borrowerPositionKey);

        require(storedKey == borrowerPositionKey, "alpha profile key mutated");
        require(storedTreasuryWallet == treasuryWallet, "alpha treasury mutated");
        require(storedBankrToken == bankrToken, "alpha bankr mutated");
        require(storedMetadataHash == metadataHash, "alpha metadata mutated");
        require(profileActive, "alpha active flag mutated");
        require(harness.lendingNextLoanId() == 19, "lending write missing");
        require(harness.positionAgentId(55) == 73, "position agent write missing");
    }
}
