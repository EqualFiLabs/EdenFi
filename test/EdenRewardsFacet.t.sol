// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {LibEqualIndexStorage} from "src/libraries/LibEqualIndexStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {InvalidParameterRange, InvalidUnderlying, Unauthorized} from "src/libraries/Errors.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

contract MockERC20Rewards is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeOnTransferRewards is ERC20 {
    uint256 internal constant BPS = 10_000;

    uint256 public feeBps = 1000;
    address public feeSink = address(0xdead);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * feeBps) / BPS;
        uint256 remainder = value - fee;
        super._update(from, feeSink, fee);
        super._update(from, to, remainder);
    }
}

contract EdenRewardsFacetHarness is EdenRewardsFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setPositionNFT(address positionNFT_) external {
        LibPositionNFT.s().positionNFTContract = positionNFT_;
        LibPositionNFT.s().nftModeEnabled = positionNFT_ != address(0);
    }

    function setEqualIndexPool(uint256 indexId, uint256 poolId) external {
        LibEqualIndexStorage.s().indexToPoolId[indexId] = poolId;
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function setPoolDeposits(uint256 poolId, uint256 totalDeposits) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].totalDeposits = totalDeposits;
    }

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = principal;
    }

    function accruedReward(bytes32 positionKey, uint256 programId) external view returns (uint256) {
        return LibEdenRewardsStorage.s().accruedRewards[programId][positionKey];
    }
}

contract EdenRewardsFacetTest is Test {
    uint256 internal constant INDEX_ID = 7;
    uint256 internal constant POOL_ID = 107;

    EdenRewardsFacetHarness internal facet;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");

    MockERC20Rewards internal rewardAsset;
    MockERC20Rewards internal altRewardAsset;
    MockFeeOnTransferRewards internal fotRewardAsset;
    PositionNFT internal positionNft;
    uint256 internal alicePositionId;
    bytes32 internal alicePositionKey;

    function setUp() public {
        facet = new EdenRewardsFacetHarness();
        facet.setOwner(owner);
        facet.setTimelock(timelock);
        facet.setEqualIndexPool(INDEX_ID, POOL_ID);
        facet.setPoolDeposits(POOL_ID, 100e18);

        rewardAsset = new MockERC20Rewards("Reward", "RWD");
        altRewardAsset = new MockERC20Rewards("AltReward", "ALT");
        fotRewardAsset = new MockFeeOnTransferRewards("FoTReward", "FTR");

        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));
        facet.setPositionNFT(address(positionNft));
        alicePositionId = positionNft.mint(alice, 1);
        alicePositionKey = positionNft.getPositionKey(alicePositionId);
        facet.setPoolPrincipal(POOL_ID, alicePositionKey, 100e18);
    }

    function test_CreateRewardProgram_PersistsEqualIndexTargetAndDiscovery() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(rewardAsset),
            manager,
            5e18,
            100,
            500,
            true
        );

        (
            LibEdenRewardsStorage.RewardProgramConfig memory config,
            LibEdenRewardsStorage.RewardProgramState memory state
        ) = facet.getRewardProgram(programId);

        assertEq(programId, 0);
        assertEq(uint8(config.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION));
        assertEq(config.target.targetId, INDEX_ID);
        assertEq(config.rewardToken, address(rewardAsset));
        assertEq(config.manager, manager);
        assertEq(state.eligibleSupply, 100e18);

        uint256[] memory programIds =
            facet.getRewardProgramIdsByTarget(LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, INDEX_ID);
        assertEq(programIds.length, 1);
        assertEq(programIds[0], programId);
    }

    function test_CreateRewardProgram_RevertsForInvalidConfigAndUnauthorizedCaller() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("LibAccess: not timelock"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(rewardAsset),
            manager,
            1e18,
            0,
            10,
            true
        );

        vm.startPrank(timelock);

        vm.expectRevert(InvalidUnderlying.selector);
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(0),
            manager,
            1e18,
            0,
            10,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "manager"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(rewardAsset),
            address(0),
            1e18,
            0,
            10,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "rewardRatePerSecond"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(rewardAsset),
            manager,
            0,
            0,
            10,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "rewardWindow"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(rewardAsset),
            manager,
            1e18,
            10,
            10,
            true
        );
    }

    function test_ManagerAndGovernanceCanDriveLifecycle() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(rewardAsset),
            manager,
            1e18,
            0,
            1000,
            true
        );

        vm.prank(manager);
        facet.setRewardProgramEnabled(programId, false);

        vm.prank(manager);
        facet.pauseRewardProgram(programId);

        vm.prank(manager);
        facet.resumeRewardProgram(programId);

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        facet.endRewardProgram(programId);

        vm.prank(timelock);
        facet.endRewardProgram(programId);
        vm.warp(block.timestamp + 1);

        vm.prank(timelock);
        facet.closeRewardProgram(programId);

        (LibEdenRewardsStorage.RewardProgramConfig memory config,) = facet.getRewardProgram(programId);
        assertTrue(config.closed);
        assertFalse(config.enabled);
        assertFalse(config.paused);
    }

    function test_FundAccrueAndClaim_ForEqualIndexTarget() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(rewardAsset),
            manager,
            10e18,
            block.timestamp,
            block.timestamp + 100,
            true
        );

        rewardAsset.mint(address(this), 1_000e18);
        rewardAsset.approve(address(facet), 1_000e18);
        facet.fundRewardProgram(programId, 1_000e18, 1_000e18);

        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        uint256 claimed = facet.claimRewardProgram(programId, alicePositionId, alice);

        assertEq(claimed, 100e18);
        assertEq(rewardAsset.balanceOf(alice), 100e18);
        assertEq(facet.accruedReward(alicePositionKey, programId), 0);
    }

    function test_ClaimRewardProgram_GrossesUpFeeOnTransferRewards() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            INDEX_ID,
            address(fotRewardAsset),
            manager,
            10e18,
            block.timestamp,
            block.timestamp + 100,
            true
        );

        vm.prank(manager);
        facet.setRewardProgramTransferFeeBps(programId, 1000);

        fotRewardAsset.mint(address(this), 1_000e18);
        fotRewardAsset.approve(address(facet), 1_000e18);
        facet.fundRewardProgram(programId, 180e18, 200e18);

        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        uint256 claimed = facet.claimRewardProgram(programId, alicePositionId, alice);

        assertEq(claimed, 100e18);
        assertEq(fotRewardAsset.balanceOf(alice), 100e18);
        assertEq(facet.accruedReward(alicePositionKey, programId), 0);
    }
}
