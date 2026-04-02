// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionAgentStorage} from "../../libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../../libraries/Errors.sol";
import {
    PositionAgent_AlreadyRegistered,
    PositionAgent_InvalidExternalLinkSignature,
    PositionAgent_InvalidAgentId,
    PositionAgent_InvalidAgentOwner,
    PositionAgent_InvalidRegistrationMode,
    PositionAgent_NotIdentityOwner,
    PositionAgent_RegistrationExpired
} from "../../libraries/PositionAgentErrors.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {IERC8004IdentityRegistry} from "@agent-wallet-core/adapters/ERC8004IdentityAdapter.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface PositionNFTOwnerLike {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title PositionAgentRegistryFacet
/// @notice Records Position NFT agent registrations after external TBA execution.
contract PositionAgentRegistryFacet {
    event AgentRegistered(uint256 indexed positionTokenId, address indexed tbaAddress, uint256 indexed agentId);
    event ExternalAgentLinked(
        uint256 indexed positionTokenId, address indexed tbaAddress, uint256 indexed agentId, address authorizer
    );
    event ExternalAgentUnlinked(uint256 indexed positionTokenId, uint256 indexed agentId, address indexed authorizer);

    bytes32 internal constant EXTERNAL_LINK_TYPEHASH = keccak256(
        "EqualFiExternalAgentLink(uint256 chainId,address diamond,uint256 positionTokenId,uint256 agentId,address positionOwner,address tbaAddress,uint256 nonce,uint256 deadline)"
    );

    function recordAgentRegistration(uint256 positionTokenId, uint256 agentId) external {
        LibPositionAgentStorage.requirePositionOwner(positionTokenId);
        if (agentId == 0) {
            revert PositionAgent_InvalidAgentId(agentId);
        }

        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        if (ds.positionToAgentId[positionTokenId] != 0) {
            revert PositionAgent_AlreadyRegistered(positionTokenId);
        }

        address tbaAddress = _computeTBAAddress(ds, positionTokenId);
        address registryOwner = IERC8004IdentityRegistry(ds.identityRegistry).ownerOf(agentId);
        if (registryOwner != tbaAddress) {
            revert PositionAgent_InvalidAgentOwner(tbaAddress, registryOwner);
        }

        ds.positionToAgentId[positionTokenId] = agentId;
        ds.positionRegistrationMode[positionTokenId] = LibPositionAgentStorage.AgentRegistrationMode.CanonicalOwned;
        ds.externalAgentAuthorizer[positionTokenId] = address(0);
        emit AgentRegistered(positionTokenId, tbaAddress, agentId);
    }

    function linkExternalAgentRegistration(uint256 positionTokenId, uint256 agentId, uint256 deadline, bytes calldata signature)
        external
    {
        LibPositionAgentStorage.requirePositionOwner(positionTokenId);
        if (agentId == 0) {
            revert PositionAgent_InvalidAgentId(agentId);
        }
        if (block.timestamp > deadline) {
            revert PositionAgent_RegistrationExpired(deadline, block.timestamp);
        }

        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        if (ds.positionToAgentId[positionTokenId] != 0) {
            revert PositionAgent_AlreadyRegistered(positionTokenId);
        }

        address positionOwner = _positionNFTOwner(positionTokenId);
        address tbaAddress = _computeTBAAddress(ds, positionTokenId);
        address identityOwner = IERC8004IdentityRegistry(ds.identityRegistry).ownerOf(agentId);
        uint256 nonce = ds.externalLinkNonce[positionTokenId];
        bytes32 digest = _externalLinkDigest(positionTokenId, agentId, positionOwner, tbaAddress, nonce, deadline);

        if (!_isValidLinkSignature(identityOwner, digest, signature)) {
            revert PositionAgent_InvalidExternalLinkSignature();
        }

        ds.positionToAgentId[positionTokenId] = agentId;
        ds.positionRegistrationMode[positionTokenId] = LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked;
        ds.externalAgentAuthorizer[positionTokenId] = identityOwner;
        LibPositionAgentStorage.useExternalLinkNonce(positionTokenId);

        emit ExternalAgentLinked(positionTokenId, tbaAddress, agentId, identityOwner);
    }

    function unlinkExternalAgentRegistration(uint256 positionTokenId) external {
        LibPositionAgentStorage.requirePositionOwner(positionTokenId);
        _clearExternalRegistration(positionTokenId);
    }

    function revokeExternalAgentRegistration(uint256 positionTokenId) external {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        if (ds.positionRegistrationMode[positionTokenId] != LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked) {
            revert PositionAgent_InvalidRegistrationMode(
                uint8(LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked),
                uint8(ds.positionRegistrationMode[positionTokenId])
            );
        }

        address currentIdentityOwner = IERC8004IdentityRegistry(ds.identityRegistry).ownerOf(ds.positionToAgentId[positionTokenId]);
        if (msg.sender != currentIdentityOwner) {
            revert PositionAgent_NotIdentityOwner(msg.sender, currentIdentityOwner);
        }

        _clearExternalRegistration(positionTokenId);
    }

    function getIdentityRegistry() external view returns (address) {
        return LibPositionAgentStorage.s().identityRegistry;
    }

    function _computeTBAAddress(LibPositionAgentStorage.AgentStorage storage ds, uint256 positionTokenId)
        internal
        view
        returns (address)
    {
        address registry = ds.erc6551Registry;
        address implementation = ds.erc6551Implementation;
        address positionNFT = _positionNFTAddress();

        return IERC6551Registry(registry).account(
            implementation,
            ds.tbaSalt,
            block.chainid,
            positionNFT,
            positionTokenId
        );
    }

    function _positionNFTAddress() internal view virtual returns (address) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        return nftAddr;
    }

    function _positionNFTOwner(uint256 positionTokenId) internal view returns (address) {
        return PositionNFTOwnerLike(_positionNFTAddress()).ownerOf(positionTokenId);
    }

    function _externalLinkDigest(
        uint256 positionTokenId,
        uint256 agentId,
        address positionOwner,
        address tbaAddress,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EXTERNAL_LINK_TYPEHASH,
                block.chainid,
                address(this),
                positionTokenId,
                agentId,
                positionOwner,
                tbaAddress,
                nonce,
                deadline
            )
        );
    }

    function _isValidLinkSignature(address signer, bytes32 digest, bytes calldata signature) internal view returns (bool) {
        if (signer == address(0)) {
            return false;
        }
        if (signer.code.length == 0) {
            (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, signature);
            return err == ECDSA.RecoverError.NoError && recovered == signer;
        }

        (bool ok, bytes memory data) =
            signer.staticcall(abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature));
        return ok && data.length == 32 && bytes4(data) == IERC1271.isValidSignature.selector;
    }

    function _clearExternalRegistration(uint256 positionTokenId) internal {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        if (ds.positionRegistrationMode[positionTokenId] != LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked) {
            revert PositionAgent_InvalidRegistrationMode(
                uint8(LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked),
                uint8(ds.positionRegistrationMode[positionTokenId])
            );
        }

        uint256 agentId = ds.positionToAgentId[positionTokenId];
        address authorizer = ds.externalAgentAuthorizer[positionTokenId];

        delete ds.positionToAgentId[positionTokenId];
        ds.positionRegistrationMode[positionTokenId] = LibPositionAgentStorage.AgentRegistrationMode.None;
        ds.externalAgentAuthorizer[positionTokenId] = address(0);

        emit ExternalAgentUnlinked(positionTokenId, agentId, authorizer);
    }
}
