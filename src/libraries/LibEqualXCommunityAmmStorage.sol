// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibEqualXTypes} from "./LibEqualXTypes.sol";

library LibEqualXCommunityAmmStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalfi.equalx.community-amm.storage");

    struct CommunityAmmMarket {
        bytes32 creatorPositionKey;
        uint256 creatorPositionId;
        uint256 poolIdA;
        uint256 poolIdB;
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalShares;
        uint256 makerCount;
        uint64 startTime;
        uint64 endTime;
        uint16 feeBps;
        LibEqualXTypes.FeeAsset feeAsset;
        LibEqualXTypes.InvariantMode invariantMode;
        uint256 feeIndexA;
        uint256 feeIndexB;
        uint256 feeIndexRemainderA;
        uint256 feeIndexRemainderB;
        uint256 treasuryFeeAAccrued;
        uint256 treasuryFeeBAccrued;
        uint256 feeIndexFeeAAccrued;
        uint256 feeIndexFeeBAccrued;
        uint256 activeCreditFeeAAccrued;
        uint256 activeCreditFeeBAccrued;
        bool active;
        bool finalized;
    }

    struct CommunityMakerPosition {
        uint256 share;
        uint256 feeIndexSnapshotA;
        uint256 feeIndexSnapshotB;
        uint256 initialContributionA;
        uint256 initialContributionB;
        bool isParticipant;
    }

    struct CommunityAmmStorage {
        uint256 nextMarketId;
        mapping(uint256 => CommunityAmmMarket) markets;
        mapping(uint256 => mapping(bytes32 => CommunityMakerPosition)) makers;
    }

    function s() internal pure returns (CommunityAmmStorage storage store) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            store.slot := position
        }
    }

    function allocateMarketId(CommunityAmmStorage storage store) internal returns (uint256 marketId) {
        marketId = store.nextMarketId + 1;
        store.nextMarketId = marketId;
    }
}
