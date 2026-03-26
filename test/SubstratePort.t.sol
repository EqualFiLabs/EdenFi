// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { PoolManagementFacet } from "src/equallend/PoolManagementFacet.sol";
import { PositionNFT } from "src/nft/PositionNFT.sol";
import { LibActiveCreditIndex } from "src/libraries/LibActiveCreditIndex.sol";
import { LibAppStorage } from "src/libraries/LibAppStorage.sol";
import { LibDiamond } from "src/libraries/LibDiamond.sol";
import { LibEncumbrance } from "src/libraries/LibEncumbrance.sol";
import { LibFeeIndex } from "src/libraries/LibFeeIndex.sol";
import { LibFeeRouter } from "src/libraries/LibFeeRouter.sol";
import { LibIndexEncumbrance } from "src/libraries/LibIndexEncumbrance.sol";
import { LibModuleEncumbrance } from "src/libraries/LibModuleEncumbrance.sol";
import { LibPositionNFT } from "src/libraries/LibPositionNFT.sol";
import { Types } from "src/libraries/Types.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EdenFiHarness is PoolManagementFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setTreasury(address treasury_) external {
        LibAppStorage.s().treasury = treasury_;
    }

    function setFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = uint16(treasuryBps);
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
        store.activeCreditShareConfigured = true;
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function setPositionNft(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function seedPrincipal(uint256 pid, bytes32 user, uint256 principal) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.userPrincipal[user] = principal;
        pool.userFeeIndex[user] = pool.feeIndex;
        pool.userMaintenanceIndex[user] = pool.maintenanceIndex;
    }

    function seedPoolBalances(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.totalDeposits = totalDeposits;
        pool.trackedBalance = trackedBalance;
    }

    function seedSameAssetDebt(uint256 pid, bytes32 user, uint256 debt) external {
        LibAppStorage.s().pools[pid].userSameAssetDebt[user] = debt;
    }

    function seedActiveCreditBase(uint256 pid, bytes32 user, uint256 principal, uint40 startTime) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.activeCreditPrincipalTotal = principal;
        pool.activeCreditMaturedTotal = principal;
        pool.userActiveCreditStateEncumbrance[user] =
            Types.ActiveCreditState({ principal: principal, startTime: startTime, indexSnapshot: pool.activeCreditIndex });
    }

    function routeFeeSamePool(uint256 pid, uint256 amount, bytes32 source)
        external
        returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex)
    {
        return LibFeeRouter.routeSamePool(pid, amount, source, true, 0);
    }

    function settleFeeIndex(uint256 pid, bytes32 user) external {
        LibFeeIndex.settle(pid, user);
    }

    function pendingFeeYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }

    function pendingActiveCreditYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibActiveCreditIndex.pendingYield(pid, user);
    }

    function encumberIndex(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) external {
        LibIndexEncumbrance.encumber(positionKey, poolId, indexId, amount);
    }

    function encumberModule(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
    }

    function unencumberIndex(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) external {
        LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, amount);
    }

    function getEncumbrance(bytes32 positionKey, uint256 poolId)
        external
        view
        returns (uint256 indexEncumbered, uint256 moduleEncumbered, uint256 totalEncumbered)
    {
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, poolId);
        return (enc.indexEncumbered, enc.moduleEncumbered, LibEncumbrance.total(positionKey, poolId));
    }

    function getPool(uint256 pid)
        external
        view
        returns (
            address underlying,
            bool initialized,
            uint256 totalDeposits,
            uint256 trackedBalance,
            uint16 depositorLtvBps,
            uint16 maintenanceRateBps
        )
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        return (
            pool.underlying,
            pool.initialized,
            pool.totalDeposits,
            pool.trackedBalance,
            pool.poolConfig.depositorLTVBps,
            pool.poolConfig.maintenanceRateBps
        );
    }
}

interface Vm {
    function prank(address) external;
}

contract SubstratePortTest {
    bytes32 internal constant ROUTER_SOURCE = keccak256("TEST_ROUTER");
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EdenFiHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20 internal token;

    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal treasury = _addr("treasury");

    function setUp() public {
        harness = new EdenFiHarness();
        harness.setOwner(address(this));
        harness.setTimelock(_addr("timelock"));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));
        harness.setPositionNft(address(positionNft));

        token = new MockERC20("Mock", "MOCK");
    }

    function test_PositionNft_MintsAndTransfersStablePositionKey() public {
        uint256 tokenId = positionNft.mint(alice, 7);
        bytes32 positionKeyBefore = positionNft.getPositionKey(tokenId);

        _assertEq(positionNft.ownerOf(tokenId), alice, "owner after mint");
        _assertEq(positionNft.getPoolId(tokenId), 7, "pool id after mint");
        _assertEq(positionNft.defaultPointsTokenId(alice), tokenId, "default points token");

        vm.prank(alice);
        positionNft.transferFrom(alice, bob, tokenId);

        _assertEq(positionNft.ownerOf(tokenId), bob, "owner after transfer");
        _assertEq(positionNft.defaultPointsTokenId(alice), 0, "sender default cleared");
        _assertEq(positionNft.defaultPointsTokenId(bob), tokenId, "receiver default set");
        _assertEq(positionNft.getPositionKey(tokenId), positionKeyBefore, "position key stable");
    }

    function test_Encumbrance_TracksIndexAndModuleBuckets() public {
        bytes32 positionKey = keccak256("position");

        harness.encumberIndex(positionKey, 1, 11, 25e18);
        harness.encumberModule(positionKey, 1, 77, 10e18);

        (uint256 indexEncumbered, uint256 moduleEncumbered, uint256 totalEncumbered) =
            harness.getEncumbrance(positionKey, 1);

        _assertEq(indexEncumbered, 25e18, "index encumbrance");
        _assertEq(moduleEncumbered, 10e18, "module encumbrance");
        _assertEq(totalEncumbered, 35e18, "encumbrance total");

        harness.unencumberIndex(positionKey, 1, 11, 5e18);
        (indexEncumbered,, totalEncumbered) = harness.getEncumbrance(positionKey, 1);
        _assertEq(indexEncumbered, 20e18, "index encumbrance after release");
        _assertEq(totalEncumbered, 30e18, "encumbrance total after release");
    }

    function test_PoolManagement_InitializesPool() public {
        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;

        harness.initPoolWithActionFees(1, address(token), cfg, actionFees);

        (
            address underlying,
            bool initialized,
            uint256 totalDeposits,
            uint256 trackedBalance,
            uint16 depositorLtvBps,
            uint16 maintenanceRateBps
        ) = harness.getPool(1);

        _assertEq(underlying, address(token), "pool underlying");
        _assertTrue(initialized, "pool initialized");
        _assertEq(totalDeposits, 0, "pool deposits");
        _assertEq(trackedBalance, 0, "pool tracked balance");
        _assertEq(depositorLtvBps, cfg.depositorLTVBps, "pool ltv");
        _assertEq(maintenanceRateBps, cfg.maintenanceRateBps, "maintenance rate");
    }

    function test_FeeRouterAndIndex_RoutesTreasuryAndAccruesYield() public {
        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(token), cfg, actionFees);

        bytes32 positionKey = keccak256("alice-position");
        harness.seedPoolBalances(1, 100e18, 110e18);
        harness.seedPrincipal(1, positionKey, 100e18);

        token.mint(address(harness), 110e18);

        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) =
            harness.routeFeeSamePool(1, 10e18, ROUTER_SOURCE);

        _assertEq(toTreasury, 1e18, "treasury split");
        _assertEq(toActiveCredit, 0, "active credit split");
        _assertEq(toFeeIndex, 9e18, "fee index split");
        _assertEq(token.balanceOf(treasury), 1e18, "treasury balance");
        _assertEq(harness.pendingFeeYield(1, positionKey), 9e18, "pending indexed fee yield");

        harness.settleFeeIndex(1, positionKey);
        _assertEq(harness.pendingFeeYield(1, positionKey), 9e18, "settled indexed fee yield");
    }

    function _poolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](1);
        fixedTerms[0] = Types.FixedTermConfig({ durationSecs: 7 days, apyBps: 500 });

        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 20;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1e18;
        cfg.minLoanAmount = 1e18;
        cfg.minTopupAmount = 1e18;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 10;
        cfg.aumFeeMaxBps = 100;
        cfg.fixedTermConfigs = fixedTerms;
    }

    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }

    function _assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function _assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function _assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function _assertEq(bytes32 left, bytes32 right, string memory message) internal pure {
        require(left == right, message);
    }
}
