// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "src/libraries/Errors.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

interface IPositionAgentIdentityRead {
    function getAgentId(uint256 positionTokenId) external view returns (uint256);
    function isRegistrationComplete(uint256 positionTokenId) external view returns (bool);
}

/// @notice Borrower-profile writes for EqualScale Alpha.
contract EqualScaleAlphaFacet is IEqualScaleAlphaEvents, IEqualScaleAlphaErrors {
    function registerBorrowerProfile(
        uint256 positionId,
        address treasuryWallet,
        address bankrToken,
        bytes32 metadataHash
    ) external {
        _requireProfileAddresses(treasuryWallet, bankrToken);

        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(positionId);
        uint256 resolvedAgentId = _requireCompletedBorrowerIdentity(positionId);

        LibEqualScaleAlphaStorage.BorrowerProfile storage profile =
            LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];
        if (profile.active) {
            revert BorrowerProfileAlreadyActive(borrowerPositionKey);
        }

        profile.borrowerPositionKey = borrowerPositionKey;
        profile.treasuryWallet = treasuryWallet;
        profile.bankrToken = bankrToken;
        profile.metadataHash = metadataHash;
        profile.active = true;

        emit BorrowerProfileRegistered(
            borrowerPositionKey, positionId, treasuryWallet, bankrToken, resolvedAgentId, metadataHash
        );
    }

    function updateBorrowerProfile(
        uint256 positionId,
        address treasuryWallet,
        address bankrToken,
        bytes32 metadataHash
    ) external {
        _requireProfileAddresses(treasuryWallet, bankrToken);

        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(positionId);
        LibEqualScaleAlphaStorage.BorrowerProfile storage profile =
            LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];
        if (!profile.active) {
            revert BorrowerProfileNotActive(borrowerPositionKey);
        }

        profile.treasuryWallet = treasuryWallet;
        profile.bankrToken = bankrToken;
        profile.metadataHash = metadataHash;

        emit BorrowerProfileUpdated(borrowerPositionKey, positionId, treasuryWallet, bankrToken, metadataHash);
    }

    function _requireBorrowerPositionOwner(uint256 positionId) internal view returns (bytes32 borrowerPositionKey) {
        PositionNFT positionNft = _positionNft();
        address owner = positionNft.ownerOf(positionId);
        if (owner != msg.sender) {
            revert BorrowerPositionNotOwned(msg.sender, positionId);
        }

        borrowerPositionKey = positionNft.getPositionKey(positionId);
    }

    function _requireCompletedBorrowerIdentity(uint256 positionId) internal view returns (uint256 resolvedAgentId) {
        IPositionAgentIdentityRead identityView = IPositionAgentIdentityRead(address(this));
        if (!identityView.isRegistrationComplete(positionId)) {
            revert BorrowerIdentityNotRegistered(positionId);
        }

        resolvedAgentId = identityView.getAgentId(positionId);
        if (resolvedAgentId == 0) {
            revert BorrowerIdentityNotRegistered(positionId);
        }
    }

    function _requireProfileAddresses(address treasuryWallet, address bankrToken) internal pure {
        if (treasuryWallet == address(0)) {
            revert InvalidTreasuryWallet();
        }
        if (bankrToken == address(0)) {
            revert InvalidBankrToken();
        }
    }

    function _positionNft() internal view returns (PositionNFT positionNft) {
        address positionNftAddress = LibPositionNFT.s().positionNFTContract;
        if (positionNftAddress == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        positionNft = PositionNFT(positionNftAddress);
    }
}
