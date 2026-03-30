// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {LibStEVEEligibilityStorage} from "src/libraries/LibStEVEEligibilityStorage.sol";
import {LibEqualIndexStorage} from "src/libraries/LibEqualIndexStorage.sol";
import {LibStEVEStorage} from "src/libraries/LibStEVEStorage.sol";
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
        LibEdenRewardsStorage.RewardTarget memory target = LibEdenRewardsStorage.s().programs[programId].config.target;
        if (target.targetType == LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION) {
            uint256 poolId = LibStEVEStorage.s().product.poolId;
            if (poolId != 0) {
                LibAppStorage.s().pools[poolId].initialized = true;
                LibAppStorage.s().pools[poolId].totalDeposits = eligibleSupply;
            }
        } else if (target.targetType == LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION) {
            uint256 poolId = LibEqualIndexStorage.s().indexToPoolId[target.targetId];
            if (poolId == 0) {
                poolId = target.targetId + 1000;
                LibEqualIndexStorage.s().indexToPoolId[target.targetId] = poolId;
            }

            LibAppStorage.s().pools[poolId].initialized = true;
            LibAppStorage.s().pools[poolId].totalDeposits = eligibleSupply;
        }

        LibEdenRewardsStorage.s().programs[programId].state.eligibleSupply = eligibleSupply;
    }

    function setPositionNFT(address positionNFT_) external {
        LibPositionNFT.s().positionNFTContract = positionNFT_;
        LibPositionNFT.s().nftModeEnabled = positionNFT_ != address(0);
    }

    function configureStEVEPool(uint256 poolId) external {
        LibStEVEEligibilityStorage.s().configured = true;
        LibStEVEStorage.s().product.poolId = poolId;
        LibAppStorage.s().pools[poolId].initialized = true;
    }

    function setStEVEEligiblePrincipal(bytes32 positionKey, uint256 eligiblePrincipal) external {
        uint256 poolId = LibStEVEStorage.s().product.poolId;
        if (poolId == 0) {
            return;
        }

        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = eligiblePrincipal;
    }

    function setEqualIndexPool(uint256 indexId, uint256 poolId) external {
        LibEqualIndexStorage.s().indexToPoolId[indexId] = poolId;
    }

    function setPoolPrincipal(uint256 poolId, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userPrincipal[positionKey] = principal;
    }

    function setPoolMaintenanceIndex(uint256 poolId, uint256 maintenanceIndex) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].maintenanceIndex = maintenanceIndex;
    }

    function setPoolMaintenanceRateBps(uint256 poolId, uint16 maintenanceRateBps) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].poolConfig.maintenanceRateBps = maintenanceRateBps;
    }

    function setPoolLastMaintenanceTimestamp(uint256 poolId, uint64 lastMaintenanceTimestamp) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].lastMaintenanceTimestamp = lastMaintenanceTimestamp;
    }

    function setUserMaintenanceIndex(uint256 poolId, bytes32 positionKey, uint256 maintenanceIndex) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].userMaintenanceIndex[positionKey] = maintenanceIndex;
    }

    function setFoundationReceiver(address foundationReceiver) external {
        LibAppStorage.s().foundationReceiver = foundationReceiver;
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
        facet.configureStEVEPool(1);
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

    function test_LifecycleMutations_AccrueBeforeDisablePauseAndEnd() public {
        uint256 currentTime = block.timestamp;

        vm.prank(timelock);
        uint256 disableProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            LibEdenRewardsStorage.STEVE_TARGET_ID,
            address(rewardAsset),
            manager,
            1e18,
            0,
            0,
            true
        );
        facet.setProgramEligibleSupply(disableProgramId, 10e18);
        rewardAsset.mint(address(this), 30e18);
        rewardAsset.approve(address(facet), 30e18);
        facet.fundRewardProgram(disableProgramId, 10e18, 10e18);

        vm.warp(currentTime + 5);
        vm.prank(manager);
        facet.setRewardProgramEnabled(disableProgramId, false);

        (, LibEdenRewardsStorage.RewardProgramState memory disableState) = facet.getRewardProgram(disableProgramId);
        assertEq(disableState.lastRewardUpdate, currentTime + 5);
        assertEq(disableState.fundedReserve, 5e18);
        assertEq(disableState.globalRewardIndex, 5e26);

        currentTime = block.timestamp;
        vm.prank(timelock);
        uint256 pauseProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            LibEdenRewardsStorage.STEVE_TARGET_ID,
            address(rewardAsset),
            manager,
            1e18,
            0,
            0,
            true
        );
        facet.setProgramEligibleSupply(pauseProgramId, 10e18);
        facet.fundRewardProgram(pauseProgramId, 10e18, 10e18);

        vm.warp(currentTime + 6);
        vm.prank(manager);
        facet.pauseRewardProgram(pauseProgramId);

        (, LibEdenRewardsStorage.RewardProgramState memory pauseState) = facet.getRewardProgram(pauseProgramId);
        assertEq(pauseState.lastRewardUpdate, currentTime + 6);
        assertEq(pauseState.fundedReserve, 4e18);
        assertEq(pauseState.globalRewardIndex, 6e26);

        currentTime = block.timestamp;
        vm.prank(timelock);
        uint256 endProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            LibEdenRewardsStorage.STEVE_TARGET_ID,
            address(rewardAsset),
            manager,
            1e18,
            0,
            1000,
            true
        );
        facet.setProgramEligibleSupply(endProgramId, 10e18);
        facet.fundRewardProgram(endProgramId, 10e18, 10e18);

        vm.warp(currentTime + 7);
        vm.prank(manager);
        facet.endRewardProgram(endProgramId);

        (
            LibEdenRewardsStorage.RewardProgramConfig memory endConfig,
            LibEdenRewardsStorage.RewardProgramState memory endState
        ) = facet.getRewardProgram(endProgramId);
        assertEq(endConfig.endTime, currentTime + 7);
        assertFalse(endConfig.enabled);
        assertFalse(endConfig.paused);
        assertEq(endState.lastRewardUpdate, currentTime + 7);
        assertEq(endState.fundedReserve, 3e18);
        assertEq(endState.globalRewardIndex, 7e26);
    }

    function test_CloseRewardProgram_PreservesLaterClaimsAfterFinalAccrual() public {
        uint256 currentTime = block.timestamp;

        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            LibEdenRewardsStorage.STEVE_TARGET_ID,
            address(rewardAsset),
            manager,
            1e18,
            currentTime,
            0,
            true
        );

        facet.setProgramEligibleSupply(programId, 10e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 10e18);
        rewardAsset.mint(address(this), 10e18);
        rewardAsset.approve(address(facet), 10e18);
        facet.fundRewardProgram(programId, 10e18, 10e18);

        vm.prank(manager);
        vm.warp(currentTime + 10);
        facet.endRewardProgram(programId);

        vm.prank(manager);
        facet.closeRewardProgram(programId);

        (LibEdenRewardsStorage.RewardProgramConfig memory config, LibEdenRewardsStorage.RewardProgramState memory state) =
            facet.getRewardProgram(programId);
        assertTrue(config.closed);
        assertEq(config.endTime, currentTime + 10);
        assertEq(state.lastRewardUpdate, currentTime + 10);
        assertEq(state.fundedReserve, 0);
        assertEq(state.globalRewardIndex, LibEdenRewardsStorage.REWARD_INDEX_SCALE);

        uint256 preview = facet.previewRewardProgramPosition(programId, alicePositionId).claimableRewards;
        assertEq(preview, 10e18);

        vm.prank(alice);
        uint256 claimed = facet.claimRewardProgram(programId, alicePositionId, alice);
        assertEq(claimed, 10e18);
        assertEq(rewardAsset.balanceOf(alice), 10e18);
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

    function test_M01Regression_LiabilitiesRemainPayableInOriginTokenAfterReserveDepletion() public {
        vm.prank(timelock);
        uint256 originProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            manager,
            10e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 100e18);
        rewardAsset.approve(address(facet), 100e18);
        facet.fundRewardProgram(originProgramId, 100e18, 100e18);
        facet.setProgramEligibleSupply(originProgramId, 10e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 10e18);

        vm.warp(block.timestamp + 10);
        facet.accrueRewardProgram(originProgramId);

        (, LibEdenRewardsStorage.RewardProgramState memory originState) = facet.getRewardProgram(originProgramId);
        assertEq(originState.fundedReserve, 0);
        assertEq(originState.globalRewardIndex, 10 * LibEdenRewardsStorage.REWARD_INDEX_SCALE);

        vm.prank(timelock);
        uint256 replacementProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(altRewardAsset),
            manager,
            5e18,
            0,
            0,
            true
        );

        altRewardAsset.mint(address(this), 100e18);
        altRewardAsset.approve(address(facet), 100e18);
        facet.fundRewardProgram(replacementProgramId, 100e18, 100e18);

        vm.prank(alice);
        uint256 claimed = facet.claimRewardProgram(originProgramId, alicePositionId, alice);

        assertEq(claimed, 100e18);
        assertEq(rewardAsset.balanceOf(alice), 100e18);
        assertEq(altRewardAsset.balanceOf(alice), 0);

        (LibEdenRewardsStorage.RewardProgramConfig memory originConfig,) = facet.getRewardProgram(originProgramId);
        (LibEdenRewardsStorage.RewardProgramConfig memory replacementConfig,) = facet.getRewardProgram(replacementProgramId);
        assertEq(originConfig.rewardToken, address(rewardAsset));
        assertEq(replacementConfig.rewardToken, address(altRewardAsset));
    }

    function test_ProgramTokenIdentity_RemainsStableAcrossReserveDepletionAndTopUps() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            manager,
            10e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 100e18);
        rewardAsset.approve(address(facet), 100e18);
        facet.fundRewardProgram(programId, 60e18, 60e18);
        facet.setProgramEligibleSupply(programId, 10e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 10e18);

        vm.warp(block.timestamp + 6);
        facet.accrueRewardProgram(programId);

        (
            LibEdenRewardsStorage.RewardProgramConfig memory configAfterDepletion,
            LibEdenRewardsStorage.RewardProgramState memory stateAfterDepletion
        ) = facet.getRewardProgram(programId);
        assertEq(configAfterDepletion.rewardToken, address(rewardAsset));
        assertEq(stateAfterDepletion.fundedReserve, 0);

        uint256 fundedTopUp = facet.fundRewardProgram(programId, 40e18, 40e18);
        assertEq(fundedTopUp, 40e18);

        (LibEdenRewardsStorage.RewardProgramConfig memory configAfterTopUp, LibEdenRewardsStorage.RewardProgramState memory stateAfterTopUp) =
            facet.getRewardProgram(programId);
        assertEq(configAfterTopUp.rewardToken, address(rewardAsset));
        assertEq(stateAfterTopUp.fundedReserve, 40e18);

        vm.warp(block.timestamp + 4);
        vm.prank(alice);
        uint256 claimed = facet.claimRewardProgram(programId, alicePositionId, alice);

        assertEq(claimed, 100e18);
        assertEq(rewardAsset.balanceOf(alice), 100e18);
        assertEq(altRewardAsset.balanceOf(alice), 0);
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

    function test_PreviewRewardProgramPosition_ExposesAccruedAndPendingState() public {
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

        rewardAsset.mint(address(this), 200e18);
        rewardAsset.approve(address(facet), 200e18);
        facet.fundRewardProgram(programId, 200e18, 200e18);
        facet.setProgramEligibleSupply(programId, 10e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 4e18);

        vm.warp(block.timestamp + 5);
        facet.settleRewardProgramPosition(programId, alicePositionId);

        vm.warp(block.timestamp + 5);
        EdenRewardsFacet.RewardProgramPositionView memory view_ =
            facet.previewRewardProgramPosition(programId, alicePositionId);

        assertEq(view_.eligibleBalance, 4e18);
        assertEq(view_.rewardCheckpoint, LibEdenRewardsStorage.REWARD_INDEX_SCALE);
        assertEq(view_.accruedRewards, 4e18);
        assertEq(view_.pendingRewards, 4e18);
        assertEq(view_.claimableRewards, 8e18);
        assertEq(view_.previewGlobalRewardIndex, 2 * LibEdenRewardsStorage.REWARD_INDEX_SCALE);
        assertEq(view_.rewardToken, address(rewardAsset));
    }

    function test_StEVEPreview_UsesSettledPrincipalAndAuthoritativeSupply() public {
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

        rewardAsset.mint(address(this), 10e18);
        rewardAsset.approve(address(facet), 10e18);
        facet.fundRewardProgram(programId, 10e18, 10e18);
        facet.setProgramEligibleSupply(programId, 10e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 10e18);

        facet.setPoolMaintenanceIndex(1, 5e17);
        facet.setUserMaintenanceIndex(1, alicePositionKey, 0);
        facet.setProgramEligibleSupply(programId, 5e18);

        vm.warp(block.timestamp + 5);
        EdenRewardsFacet.RewardProgramPositionView memory positionPreview =
            facet.previewRewardProgramPosition(programId, alicePositionId);
        LibEdenRewardsStorage.RewardProgramState memory programPreview = facet.previewRewardProgramState(programId);

        assertEq(positionPreview.eligibleBalance, 5e18);
        assertEq(positionPreview.claimableRewards, 5e18);
        assertEq(programPreview.eligibleSupply, 5e18);
        assertEq(programPreview.globalRewardIndex, LibEdenRewardsStorage.REWARD_INDEX_SCALE);
    }

    function test_EqualIndexAccrual_RefreshesAuthoritativeSupplyAfterMaintenance() public {
        facet.setEqualIndexPool(7, 9);

        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            7,
            address(rewardAsset),
            manager,
            1e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 10e18);
        rewardAsset.approve(address(facet), 10e18);
        facet.fundRewardProgram(programId, 10e18, 10e18);
        facet.setProgramEligibleSupply(programId, 10e18);
        facet.setPoolPrincipal(9, alicePositionKey, 10e18);

        facet.setPoolMaintenanceIndex(9, 5e17);
        facet.setUserMaintenanceIndex(9, alicePositionKey, 0);
        facet.setProgramEligibleSupply(programId, 5e18);

        vm.warp(block.timestamp + 5);
        EdenRewardsFacet.RewardProgramPositionView memory positionPreview =
            facet.previewRewardProgramPosition(programId, alicePositionId);
        LibEdenRewardsStorage.RewardProgramState memory programPreview = facet.previewRewardProgramState(programId);

        assertEq(positionPreview.eligibleBalance, 5e18);
        assertEq(positionPreview.claimableRewards, 5e18);
        assertEq(programPreview.eligibleSupply, 5e18);
        assertEq(programPreview.globalRewardIndex, LibEdenRewardsStorage.REWARD_INDEX_SCALE);
    }

    function test_StEVEMaintenance_PreviewsAndClaimsStayBacked() public {
        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            manager,
            9e18,
            block.timestamp,
            0,
            true
        );

        rewardAsset.mint(address(this), 90e18);
        rewardAsset.approve(address(facet), 90e18);
        facet.fundRewardProgram(programId, 90e18, 90e18);
        facet.setProgramEligibleSupply(programId, 100e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 100e18);
        facet.setFoundationReceiver(makeAddr("foundation"));
        facet.setPoolMaintenanceRateBps(1, 1000);
        facet.setPoolLastMaintenanceTimestamp(1, uint64(block.timestamp));

        vm.warp(block.timestamp + 365 days + 10);
        EdenRewardsFacet.RewardProgramPositionView memory preview =
            facet.previewRewardProgramPosition(programId, alicePositionId);
        LibEdenRewardsStorage.RewardProgramState memory previewState = facet.previewRewardProgramState(programId);

        assertEq(preview.eligibleBalance, 90e18);
        assertEq(preview.claimableRewards, 90e18);
        assertEq(previewState.eligibleSupply, 90e18);
        assertEq(previewState.fundedReserve, 0);
        assertEq(previewState.globalRewardIndex, LibEdenRewardsStorage.REWARD_INDEX_SCALE);

        vm.prank(alice);
        uint256 claimed = facet.claimRewardProgram(programId, alicePositionId, alice);
        (, LibEdenRewardsStorage.RewardProgramState memory settledState) = facet.getRewardProgram(programId);

        assertEq(claimed, 90e18);
        assertEq(rewardAsset.balanceOf(alice), 90e18);
        assertEq(settledState.eligibleSupply, 90e18);
        assertEq(settledState.fundedReserve, 0);
    }

    function test_EqualIndexMaintenance_PreviewsAndClaimsStayBacked() public {
        facet.setEqualIndexPool(7, 9);

        vm.prank(timelock);
        uint256 programId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION,
            7,
            address(rewardAsset),
            manager,
            9e18,
            block.timestamp,
            0,
            true
        );

        rewardAsset.mint(address(this), 90e18);
        rewardAsset.approve(address(facet), 90e18);
        facet.fundRewardProgram(programId, 90e18, 90e18);
        facet.setProgramEligibleSupply(programId, 100e18);
        facet.setPoolPrincipal(9, alicePositionKey, 100e18);
        facet.setFoundationReceiver(makeAddr("foundation-eq"));
        facet.setPoolMaintenanceRateBps(9, 1000);
        facet.setPoolLastMaintenanceTimestamp(9, uint64(block.timestamp));

        vm.warp(block.timestamp + 365 days + 10);
        EdenRewardsFacet.RewardProgramPositionView memory preview =
            facet.previewRewardProgramPosition(programId, alicePositionId);
        LibEdenRewardsStorage.RewardProgramState memory previewState = facet.previewRewardProgramState(programId);

        assertEq(preview.eligibleBalance, 90e18);
        assertEq(preview.claimableRewards, 90e18);
        assertEq(previewState.eligibleSupply, 90e18);
        assertEq(previewState.fundedReserve, 0);
        assertEq(previewState.globalRewardIndex, LibEdenRewardsStorage.REWARD_INDEX_SCALE);

        vm.prank(alice);
        uint256 claimed = facet.claimRewardProgram(programId, alicePositionId, alice);
        (, LibEdenRewardsStorage.RewardProgramState memory settledState) = facet.getRewardProgram(programId);

        assertEq(claimed, 90e18);
        assertEq(rewardAsset.balanceOf(alice), 90e18);
        assertEq(settledState.eligibleSupply, 90e18);
        assertEq(settledState.fundedReserve, 0);
    }

    function test_PreviewRewardProgramsForPosition_AggregatesAcrossPrograms() public {
        vm.prank(timelock);
        uint256 firstProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            manager,
            2e18,
            0,
            0,
            true
        );
        vm.prank(timelock);
        uint256 secondProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(altRewardAsset),
            manager,
            5e18,
            0,
            0,
            true
        );

        rewardAsset.mint(address(this), 200e18);
        rewardAsset.approve(address(facet), 200e18);
        facet.fundRewardProgram(firstProgramId, 200e18, 200e18);

        altRewardAsset.mint(address(this), 200e18);
        altRewardAsset.approve(address(facet), 200e18);
        facet.fundRewardProgram(secondProgramId, 200e18, 200e18);

        facet.setProgramEligibleSupply(firstProgramId, 10e18);
        facet.setProgramEligibleSupply(secondProgramId, 10e18);
        facet.setStEVEEligiblePrincipal(alicePositionKey, 4e18);

        vm.warp(block.timestamp + 5);
        facet.settleRewardProgramPosition(firstProgramId, alicePositionId);

        vm.warp(block.timestamp + 5);
        uint256[] memory programIds = new uint256[](2);
        programIds[0] = firstProgramId;
        programIds[1] = secondProgramId;

        (EdenRewardsFacet.RewardProgramClaimPreview[] memory previews, uint256 totalClaimable) =
            facet.previewRewardProgramsForPosition(alicePositionId, programIds);

        assertEq(previews.length, 2);
        assertEq(previews[0].programId, firstProgramId);
        assertEq(previews[0].rewardToken, address(rewardAsset));
        assertEq(previews[0].claimableRewards, 8e18);

        assertEq(previews[1].programId, secondProgramId);
        assertEq(previews[1].rewardToken, address(altRewardAsset));
        assertEq(previews[1].claimableRewards, 20e18);

        assertEq(totalClaimable, 28e18);
    }
}

contract EdenRewardsInvariantHandler is Test {
    EdenRewardsFacetHarness internal facet;
    MockERC20Rewards internal rewardAsset;
    MockERC20Rewards internal altRewardAsset;

    uint256 public firstProgramId;
    uint256 public secondProgramId;
    uint256 public positionId;

    uint256 public firstFunded;
    uint256 public secondFunded;
    uint256 public firstClaimed;
    uint256 public secondClaimed;

    constructor(
        EdenRewardsFacetHarness facet_,
        MockERC20Rewards rewardAsset_,
        MockERC20Rewards altRewardAsset_,
        uint256 firstProgramId_,
        uint256 secondProgramId_
    ) {
        facet = facet_;
        rewardAsset = rewardAsset_;
        altRewardAsset = altRewardAsset_;
        firstProgramId = firstProgramId_;
        secondProgramId = secondProgramId_;

        rewardAsset.approve(address(facet), type(uint256).max);
        altRewardAsset.approve(address(facet), type(uint256).max);
    }

    function setPosition(uint256 positionId_) external {
        if (positionId != 0) revert("position already set");
        positionId = positionId_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function fundFirstProgram(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e18, 50e18);
        rewardAsset.mint(address(this), amount);
        uint256 funded = facet.fundRewardProgram(firstProgramId, amount, amount);
        firstFunded += funded;
    }

    function fundSecondProgram(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e18, 50e18);
        altRewardAsset.mint(address(this), amount);
        uint256 funded = facet.fundRewardProgram(secondProgramId, amount, amount);
        secondFunded += funded;
    }

    function warpTime(uint256 deltaSeed) external {
        uint256 delta = bound(deltaSeed, 1, 7 days);
        vm.warp(block.timestamp + delta);
    }

    function settleFirstProgram() external {
        if (positionId == 0) return;
        facet.settleRewardProgramPosition(firstProgramId, positionId);
    }

    function settleSecondProgram() external {
        if (positionId == 0) return;
        facet.settleRewardProgramPosition(secondProgramId, positionId);
    }

    function claimFirstProgram() external {
        if (positionId == 0) return;
        EdenRewardsFacet.RewardProgramPositionView memory preview =
            facet.previewRewardProgramPosition(firstProgramId, positionId);
        if (preview.claimableRewards == 0) return;
        firstClaimed += facet.claimRewardProgram(firstProgramId, positionId, address(this));
    }

    function claimSecondProgram() external {
        if (positionId == 0) return;
        EdenRewardsFacet.RewardProgramPositionView memory preview =
            facet.previewRewardProgramPosition(secondProgramId, positionId);
        if (preview.claimableRewards == 0) return;
        secondClaimed += facet.claimRewardProgram(secondProgramId, positionId, address(this));
    }
}

contract EdenRewardsInvariantTest is StdInvariant, Test {
    EdenRewardsFacetHarness internal facet;
    MockERC20Rewards internal rewardAsset;
    MockERC20Rewards internal altRewardAsset;
    PositionNFT internal positionNft;
    EdenRewardsInvariantHandler internal handler;

    uint256 internal firstProgramId;
    uint256 internal secondProgramId;
    uint256 internal positionId;

    function setUp() public {
        facet = new EdenRewardsFacetHarness();
        facet.setOwner(address(this));
        facet.setTimelock(address(this));

        rewardAsset = new MockERC20Rewards("Reward", "RWD");
        altRewardAsset = new MockERC20Rewards("AltReward", "ALT");

        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));
        facet.setPositionNFT(address(positionNft));

        firstProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(rewardAsset),
            address(this),
            3e18,
            0,
            0,
            true
        );
        secondProgramId = facet.createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            0,
            address(altRewardAsset),
            address(this),
            5e18,
            0,
            0,
            true
        );

        handler = new EdenRewardsInvariantHandler(facet, rewardAsset, altRewardAsset, firstProgramId, secondProgramId);
        positionId = positionNft.mint(address(handler), 1);
        handler.setPosition(positionId);

        bytes32 positionKey = positionNft.getPositionKey(positionId);
        facet.setStEVEEligiblePrincipal(positionKey, 10e18);
        facet.setProgramEligibleSupply(firstProgramId, 10e18);
        facet.setProgramEligibleSupply(secondProgramId, 10e18);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.fundFirstProgram.selector;
        selectors[1] = handler.fundSecondProgram.selector;
        selectors[2] = handler.warpTime.selector;
        selectors[3] = handler.settleFirstProgram.selector;
        selectors[4] = handler.settleSecondProgram.selector;
        selectors[5] = handler.claimFirstProgram.selector;
        selectors[6] = handler.claimSecondProgram.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ProgramLiabilitiesStayBackedPerProgram() public view {
        EdenRewardsFacet.RewardProgramPositionView memory firstPreview =
            facet.previewRewardProgramPosition(firstProgramId, positionId);
        EdenRewardsFacet.RewardProgramPositionView memory secondPreview =
            facet.previewRewardProgramPosition(secondProgramId, positionId);

        LibEdenRewardsStorage.RewardProgramState memory firstState = facet.previewRewardProgramState(firstProgramId);
        LibEdenRewardsStorage.RewardProgramState memory secondState = facet.previewRewardProgramState(secondProgramId);

        assertLe(firstPreview.claimableRewards + firstState.fundedReserve + handler.firstClaimed(), handler.firstFunded());
        assertLe(
            secondPreview.claimableRewards + secondState.fundedReserve + handler.secondClaimed(), handler.secondFunded()
        );
    }

    function invariant_ProgramTokenIdentityAndIsolationRemainStable() public view {
        (LibEdenRewardsStorage.RewardProgramConfig memory firstConfig,) = facet.getRewardProgram(firstProgramId);
        (LibEdenRewardsStorage.RewardProgramConfig memory secondConfig,) = facet.getRewardProgram(secondProgramId);

        assertEq(firstConfig.rewardToken, address(rewardAsset));
        assertEq(secondConfig.rewardToken, address(altRewardAsset));
        assertEq(firstConfig.target.targetId, 0);
        assertEq(secondConfig.target.targetId, 0);
        assertEq(uint8(firstConfig.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION));
        assertEq(uint8(secondConfig.target.targetType), uint8(LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION));

        assertEq(rewardAsset.balanceOf(address(handler)), handler.firstClaimed());
        assertEq(altRewardAsset.balanceOf(address(handler)), handler.secondClaimed());
    }
}
