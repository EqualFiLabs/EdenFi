// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibFeeRouter} from "src/libraries/LibFeeRouter.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract ProtocolTestSupportFacet {
    struct PoolView {
        address underlying;
        bool initialized;
        bool isManagedPool;
        address manager;
        bool whitelistEnabled;
        uint16 currentAumFeeBps;
        uint256 trackedBalance;
        uint256 totalDeposits;
        uint256 yieldReserve;
        uint256 feeIndex;
        uint256 activeCreditPrincipalTotal;
        uint256 userCount;
    }

    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
    }

    function setManagedPoolSystemShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.managedPoolSystemShareBps = bps;
        store.managedPoolSystemShareConfigured = true;
    }

    function setTreasuryShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = bps;
        store.treasuryShareConfigured = true;
    }

    function setActiveCreditShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.activeCreditShareBps = bps;
        store.activeCreditShareConfigured = true;
    }

    function assetToPoolId(address asset) external view returns (uint256) {
        return LibAppStorage.s().assetToPoolId[asset];
    }

    function permissionlessPoolForToken(address asset) external view returns (uint256) {
        return LibAppStorage.s().permissionlessPoolForToken[asset];
    }

    function getPoolView(uint256 pid) external view returns (PoolView memory view_) {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        view_.underlying = pool.underlying;
        view_.initialized = pool.initialized;
        view_.isManagedPool = pool.isManagedPool;
        view_.manager = pool.manager;
        view_.whitelistEnabled = pool.whitelistEnabled;
        view_.currentAumFeeBps = pool.currentAumFeeBps;
        view_.trackedBalance = pool.trackedBalance;
        view_.totalDeposits = pool.totalDeposits;
        view_.yieldReserve = pool.yieldReserve;
        view_.feeIndex = pool.feeIndex;
        view_.activeCreditPrincipalTotal = pool.activeCreditPrincipalTotal;
        view_.userCount = pool.userCount;
    }

    function isWhitelisted(uint256 pid, uint256 tokenId) external view returns (bool) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        bytes32 positionKey = nft.getPositionKey(tokenId);
        return LibAppStorage.s().pools[pid].whitelist[positionKey];
    }

    function routeManagedShareExternal(
        uint256 pid,
        uint256 amount,
        bytes32 source,
        bool pullFromTracked,
        uint256 extraBacking
    ) external returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) {
        return LibFeeRouter.routeManagedShare(pid, amount, source, pullFromTracked, extraBacking);
    }
}
