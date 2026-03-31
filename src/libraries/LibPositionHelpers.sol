// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibActiveCreditIndex} from "./LibActiveCreditIndex.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibEncumbrance} from "./LibEncumbrance.sol";
import {LibFeeIndex} from "./LibFeeIndex.sol";
import {LibPositionNFT} from "./LibPositionNFT.sol";
import {LibPoolMembership} from "./LibPoolMembership.sol";
import {Types} from "./Types.sol";
import {NotNFTOwner, PoolNotInitialized} from "./Errors.sol";

/// @title LibPositionHelpers
/// @notice Shared helpers for position ownership, pool validation, and membership.
library LibPositionHelpers {
    function appStorage() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function pool(uint256 pid) internal view returns (Types.PoolData storage p) {
        p = appStorage().pools[pid];
        if (!p.initialized) {
            revert PoolNotInitialized(pid);
        }
    }

    function requireOwnership(uint256 tokenId) internal view returns (address owner) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        owner = nft.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert NotNFTOwner(msg.sender, tokenId);
        }
    }

    function positionKey(uint256 tokenId) internal view returns (bytes32) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        return nft.getPositionKey(tokenId);
    }

    function systemPositionKey(address systemAccount) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("equal.lend.system.position", systemAccount));
    }

    function derivePoolId(uint256 tokenId) internal view returns (uint256) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        return nft.getPoolId(tokenId);
    }

    function ensurePoolMembership(bytes32 posKey, uint256 pid, bool allowAutoJoin)
        internal
        returns (bool alreadyMember)
    {
        return LibPoolMembership._ensurePoolMembership(posKey, pid, allowAutoJoin);
    }

    function availablePrincipal(Types.PoolData storage poolData, bytes32 posKey, uint256 poolId)
        internal
        view
        returns (uint256 available)
    {
        uint256 principal = poolData.userPrincipal[posKey];
        uint256 totalEncumbered = LibEncumbrance.total(posKey, poolId);
        if (totalEncumbered >= principal) {
            return 0;
        }
        return principal - totalEncumbered;
    }

    function settlePosition(uint256 pid, bytes32 posKey) internal {
        LibActiveCreditIndex.settle(pid, posKey);
        LibFeeIndex.settle(pid, posKey);
    }

    function settledAvailablePrincipal(Types.PoolData storage poolData, bytes32 posKey, uint256 poolId)
        internal
        returns (uint256 available)
    {
        settlePosition(poolId, posKey);
        return availablePrincipal(poolData, posKey, poolId);
    }
}
