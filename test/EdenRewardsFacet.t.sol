// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {LibEdenStEVEStorage} from "src/libraries/LibEdenStEVEStorage.sol";
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

    function setProgramReserve(uint256 programId, uint256 reserve) external {
        LibEdenRewardsStorage.s().programs[programId].state.fundedReserve = reserve;
    }

    function setProgramEligibleSupply(uint256 programId, uint256 eligibleSupply) external {
        LibEdenRewardsStorage.s().programs[programId].state.eligibleSupply = eligibleSupply;
    }

    function setPositionNFT(address positionNFT_) external {
        LibPositionNFT.s().positionNFTContract = positionNFT_;
        LibPositionNFT.s().nftModeEnabled = positionNFT_ != address(0);
    }

    function setStEVEEligiblePrincipal(bytes32 positionKey, uint256 eligiblePrincipal) external {
        LibEdenStEVEStorage.s().eligiblePrincipal[positionKey] = eligiblePrincipal;
    }

    function setEqualIndexPool(uint256 indexId, uint256 poolId) external {
        LibEqualIndexStorage.s().indexToPoolId[indexId] = poolId;
    }

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = principal;
    }

    function accruedReward(bytes32 positionKey, uint256 programId) external view returns (uint256) {
        return LibEdenRewardsStorage.s().accruedRewards[programId][positionKey];
    }

    function rewardCheckpoint(bytes32 positionKey, uint256 programId) external view returns (uint256) {
        return LibEdenRewardsStorage.s().positionRewardIndex[programId][positionKey];
    }
}

contract EdenRewardsFacetTest is Test {
    EdenRewardsFacetHarness internal facet;

    address internal owner = makeAddr("owner");
    address internal timelock = makeAddr("timelock");
    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");
    MockERC20Rewards internal rewardAsset;
    MockERC20Rewards internal altRewardAsset;
    MockFeeOnTransferRewards internal fotRewardAsset;
    PositionNFT internal positionNft;
    uint256 internal alicePositionId;
    bytes32 internal alicePositionKey;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        facet = new EdenRewardsFacetHarness();
        facet.setOwner(owner);
        facet.setTimelock(timelock);
        rewardAsset = new MockERC20Rewards("Reward", "RWD");
        altRewardAsset = new MockERC20Rewards("AltReward", "ALT");
        fotRewardAsset = new MockFeeOnTransferRewards("FoTReward", "FTR");
        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));
        facet.setPositionNFT(address(positionNft));
        alicePositionId = positionNft.mint(alice, 1);
        alicePositionKey = positionNft.getPositionKey(alicePositionId);
    }

    function test_CreateRewardProgram_PersistsImmutableTargetAndToken() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, 0, address(rewardAsset), manager, 5e18, 100, 500, true
        );

        (
            LibEdenRewardsStorage.RewardProgramConfig memory config,
            LibEdenRewardsStorage.RewardProgramState memory state
        ) = facet.getRewardProgram(programId);

        assertEq(programId, 0);
        assertEq(uint8(config.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION));
        assertEq(config.target.targetId, 0);
        assertEq(config.rewardToken, address(rewardAsset));
        assertEq(config.manager, manager);
        assertEq(config.rewardRatePerSecond, 5e18);
        assertEq(config.startTime, 100);
        assertEq(config.endTime, 500);
        assertTrue(config.enabled);
        assertFalse(config.paused);
        assertFalse(config.closed);
        assertEq(state.fundedReserve, 0);

        uint256[] memory programIds =
            facet.getRewardProgramIdsByTarget(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, 0);
        assertEq(programIds.length, 1);
        assertEq(programIds[0], programId);
    }

    function test_CreateRewardProgram_RevertsForInvalidConfig() public {
        vm.startPrank(timelock);

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "steveTargetId"));
            facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, 1, address(rewardAsset), manager, 1e18, 0, 10, true
        );

        vm.expectRevert(InvalidUnderlying.selector);
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7, address(0), manager, 1e18, 0, 10, true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "manager"));
            facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7, address(rewardAsset), address(0), 1e18, 0, 10, true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "rewardRatePerSecond"));
            facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7, address(rewardAsset), manager, 0, 0, 10, true
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "rewardWindow"));
            facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 7, address(rewardAsset), manager, 1e18, 10, 10, true
        );
    }

    function test_CreateRewardProgram_RevertsForUnauthorizedCaller() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("LibAccess: not timelock"));
        facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 3, address(rewardAsset), manager, 1e18, 0, 10, true
        );
    }

    function test_ManagerAndGovernanceCanDriveLifecycle() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, 4, address(rewardAsset), manager, 1e18, 0, 1000, true
        );

        vm.prank(manager);
        facet.setRewardProgramEnabled(programId, false);
        (LibEdenRewardsStorage.RewardProgramConfig memory config,) = facet.getRewardProgram(programId);
        assertFalse(config.enabled);

        vm.prank(manager);
        facet.pauseRewardProgram(programId);
        (config,) = facet.getRewardProgram(programId);
        assertTrue(config.paused);

        vm.prank(timelock);
        facet.resumeRewardProgram(programId);
        (config,) = facet.getRewardProgram(programId);
        assertFalse(config.paused);

        vm.warp(55);
        vm.prank(manager);
        facet.endRewardProgram(programId);
        (config,) = facet.getRewardProgram(programId);
        assertEq(config.endTime, 55);
        assertFalse(config.enabled);
        assertFalse(config.paused);
    }

    function test_LifecycleRevertsForUnauthorizedOrUnsafeClose() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            0,
            address(altRewardAsset),
            manager,
            1e18,
            0,
            100,
            true
        );

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        facet.setRewardProgramEnabled(programId, false);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "programNotPaused"));
        facet.resumeRewardProgram(programId);

        facet.setProgramReserve(programId, 10e18);
        vm.warp(101);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "programReserve"));
        facet.closeRewardProgram(programId);

        facet.setProgramReserve(programId, 0);
        vm.prank(manager);
        facet.closeRewardProgram(programId);

        (LibEdenRewardsStorage.RewardProgramConfig memory config,) = facet.getRewardProgram(programId);
        assertTrue(config.closed);
        assertFalse(config.enabled);
        assertFalse(config.paused);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "programClosed"));
        facet.pauseRewardProgram(programId);
    }

    function test_FundRewardProgram_SupportsRepeatedTopUpsAndFoTSafeFunding() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            11,
            address(rewardAsset),
            manager,
            1e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 200e18);
        rewardAsset.approve(address(facet), 200e18);

        uint256 funded = facet.fundRewardProgram(programId, 100e18, 100e18);
        assertEq(funded, 100e18);

        funded = facet.fundRewardProgram(programId, 50e18, 50e18);
        assertEq(funded, 50e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = facet.getRewardProgram(programId);
        assertEq(state.fundedReserve, 150e18);

        vm.prank(timelock);
        uint256 fotProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            12,
            address(fotRewardAsset),
            manager,
            1e18,
            0,
            0,
            true
        );

        fotRewardAsset.mint(address(this), 20e18);
        fotRewardAsset.approve(address(facet), 20e18);

        funded = facet.fundRewardProgram(fotProgramId, 9e18, 10e18);
        assertEq(funded, 9e18);

        (, state) = facet.getRewardProgram(fotProgramId);
        assertEq(state.fundedReserve, 9e18);

        vm.expectRevert(
            abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, 9e18, 10e18)
        );
        facet.fundRewardProgram(fotProgramId, 10e18, 10e18);
    }

    function test_AccrueRewardProgram_BoundsReserveAndRespectsWindows() public {
        vm.prank(timelock);
        uint256 boundedProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            15,
            address(rewardAsset),
            manager,
            15e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 100e18);
        rewardAsset.approve(address(facet), 100e18);
        facet.fundRewardProgram(boundedProgramId, 100e18, 100e18);
        facet.setProgramEligibleSupply(boundedProgramId, 10e18);

        vm.warp(block.timestamp + 10);
        facet.accrueRewardProgram(boundedProgramId);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = facet.getRewardProgram(boundedProgramId);
        assertEq(state.fundedReserve, 0);
        assertEq(state.globalRewardIndex, 10 * LibEdenRewardsStorage.REWARD_INDEX_SCALE);

        vm.prank(timelock);
        uint256 windowedProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            manager,
            2e18,
            100,
            120,
            true
        );

        rewardAsset.mint(address(this), 1_000e18);
        rewardAsset.approve(address(facet), 1_000e18);
        facet.fundRewardProgram(windowedProgramId, 1_000e18, 1_000e18);
        facet.setProgramEligibleSupply(windowedProgramId, 10e18);

        vm.warp(90);
        LibEdenRewardsStorage.RewardProgramState memory preview = facet.previewRewardProgramState(windowedProgramId);
        assertEq(preview.globalRewardIndex, 0);

        vm.warp(130);
        facet.accrueRewardProgram(windowedProgramId);
        (, state) = facet.getRewardProgram(windowedProgramId);
        assertEq(state.lastRewardUpdate, 120);
        assertEq(state.globalRewardIndex, 4 * LibEdenRewardsStorage.REWARD_INDEX_SCALE);
        assertEq(state.fundedReserve, 960e18);
    }

    function test_AccrualRemainsIsolatedPerProgram() public {
        vm.prank(timelock);
        uint256 firstProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            1,
            address(rewardAsset),
            manager,
            1e18,
            0,
            0,
            true
        );
        vm.prank(timelock);
        uint256 secondProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            2,
            address(rewardAsset),
            manager,
            3e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 500e18);
        rewardAsset.approve(address(facet), 500e18);
        facet.fundRewardProgram(firstProgramId, 100e18, 100e18);
        facet.fundRewardProgram(secondProgramId, 300e18, 300e18);
        facet.setProgramEligibleSupply(firstProgramId, 10e18);
        facet.setProgramEligibleSupply(secondProgramId, 10e18);

        vm.warp(block.timestamp + 10);
        facet.accrueRewardProgram(firstProgramId);

        (, LibEdenRewardsStorage.RewardProgramState memory firstState) = facet.getRewardProgram(firstProgramId);
        (, LibEdenRewardsStorage.RewardProgramState memory secondState) = facet.getRewardProgram(secondProgramId);

        assertEq(firstState.fundedReserve, 90e18);
        assertEq(firstState.globalRewardIndex, LibEdenRewardsStorage.REWARD_INDEX_SCALE);
        assertEq(secondState.fundedReserve, 300e18);
        assertEq(secondState.globalRewardIndex, 0);
    }

    function test_SettleRewardProgramPosition_AccruesPendingRewardsAndCheckpoints() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            manager,
            2e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 100e18);
        rewardAsset.approve(address(facet), 100e18);
        facet.fundRewardProgram(programId, 100e18, 100e18);
        facet.setProgramEligibleSupply(programId, 10e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 4e18);

        vm.warp(block.timestamp + 10);
        uint256 claimable = facet.settleRewardProgramPosition(programId, alicePositionId);

        assertEq(claimable, 8e18);
        assertEq(facet.accruedReward(alicePositionKey, programId), 8e18);
        assertEq(facet.rewardCheckpoint(alicePositionKey, programId), 2 * LibEdenRewardsStorage.REWARD_INDEX_SCALE);
    }

    function test_ClaimRewardProgram_PaysOriginTokenAndZerosAccrual() public {
        vm.prank(timelock);
        uint256 rewardProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            manager,
            3e18,
            0,
            0,
            true
        );
        vm.prank(timelock);
        uint256 altProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(altRewardAsset),
            manager,
            5e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 100e18);
        rewardAsset.approve(address(facet), 100e18);
        facet.fundRewardProgram(rewardProgramId, 100e18, 100e18);

        altRewardAsset.mint(address(this), 100e18);
        altRewardAsset.approve(address(facet), 100e18);
        facet.fundRewardProgram(altProgramId, 100e18, 100e18);

        facet.setProgramEligibleSupply(rewardProgramId, 10e18);
        facet.setProgramEligibleSupply(altProgramId, 10e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 4e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 claimed = facet.claimRewardProgram(rewardProgramId, alicePositionId, bob);

        assertEq(claimed, 12e18);
        assertEq(rewardAsset.balanceOf(bob), 12e18);
        assertEq(altRewardAsset.balanceOf(bob), 0);
        assertEq(facet.accruedReward(alicePositionKey, rewardProgramId), 0);
        assertEq(facet.rewardCheckpoint(alicePositionKey, rewardProgramId), 3 * LibEdenRewardsStorage.REWARD_INDEX_SCALE);

        vm.prank(alice);
        uint256 altClaimed = facet.claimRewardProgram(altProgramId, alicePositionId, alice);
        assertEq(altClaimed, 20e18);
        assertEq(altRewardAsset.balanceOf(alice), 20e18);
    }

    function test_ClaimRewardProgram_RevertsForUnauthorizedOwnerOrEmptyClaim() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            manager,
            1e18,
            0,
            0,
            true
        );

        vm.prank(stranger);
        vm.expectRevert();
        facet.claimRewardProgram(programId, alicePositionId, stranger);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "nothing claimable"));
        facet.claimRewardProgram(programId, alicePositionId, alice);
    }

    function test_SettleRewardProgramPosition_UsesCanonicalEqualIndexPrincipal() public {
        uint256 indexId = 77;
        uint256 poolId = 505;

        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            indexId,
            address(rewardAsset),
            manager,
            2e18,
            0,
            0,
            true
        );

        facet.setEqualIndexPool(indexId, poolId);
        facet.setPoolPrincipal(poolId, alicePositionKey, 6e18);
        facet.setProgramEligibleSupply(programId, 12e18);

        rewardAsset.mint(address(this), 100e18);
        rewardAsset.approve(address(facet), 100e18);
        facet.fundRewardProgram(programId, 100e18, 100e18);

        vm.warp(block.timestamp + 10);
        uint256 claimable = facet.settleRewardProgramPosition(programId, alicePositionId);

        assertEq(claimable, 9_999_999_999_999_999_999);
        assertEq(facet.accruedReward(alicePositionKey, programId), 9_999_999_999_999_999_999);
        assertEq(facet.rewardCheckpoint(alicePositionKey, programId), (5 * LibEdenRewardsStorage.REWARD_INDEX_SCALE) / 3);
    }
}
