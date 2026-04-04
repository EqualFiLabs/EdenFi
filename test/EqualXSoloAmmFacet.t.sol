// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {EqualXSoloAmmFacet} from "src/equalx/EqualXSoloAmmFacet.sol";
import {EqualXViewFacet} from "src/equalx/EqualXViewFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualXSoloAmmStorage} from "src/libraries/LibEqualXSoloAmmStorage.sol";
import {LibEqualXTypes} from "src/libraries/LibEqualXTypes.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20EqualX is ERC20 {
    uint8 internal immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract EqualXSoloAmmHarness is PoolManagementFacet, PositionManagementFacet, EqualXSoloAmmFacet, EqualXViewFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setTreasury(address treasury_) external {
        LibAppStorage.s().treasury = treasury_;
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function setManagedPoolCreationFee(uint256 fee) external {
        LibAppStorage.s().managedPoolCreationFee = fee;
    }

    function setFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = uint16(treasuryBps);
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
        store.activeCreditShareConfigured = true;
    }

    function setPositionNft(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function encumberedCapitalOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).encumberedCapital;
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function trackedBalanceOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDepositsOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function yieldReserveOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].yieldReserve;
    }

    function activeCreditPrincipalTotalOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function minRebalanceTimelock() external view returns (uint64) {
        return LibEqualXSoloAmmStorage.minRebalanceTimelock(LibEqualXSoloAmmStorage.s());
    }

    function getPendingRebalance(uint256 marketId)
        external
        view
        returns (LibEqualXSoloAmmStorage.SoloAmmPendingRebalance memory pending)
    {
        pending = LibEqualXSoloAmmStorage.s().pendingRebalances[marketId];
    }

    function setLastRebalanceExecutionAt(uint256 marketId, uint256 timestamp) external {
        if (timestamp > type(uint64).max) revert();
        LibEqualXSoloAmmStorage.s().markets[marketId].lastRebalanceExecutionAt = uint64(timestamp);
    }
}

contract EqualXSoloAmmFacetTest is Test {
    event EqualXSoloAmmRebalanceScheduled(
        uint256 indexed marketId,
        bytes32 indexed makerPositionKey,
        uint256 snapshotReserveA,
        uint256 snapshotReserveB,
        uint256 targetReserveA,
        uint256 targetReserveB,
        uint64 executeAfter
    );
    event EqualXSoloAmmRebalanceCancelled(uint256 indexed marketId, bytes32 indexed makerPositionKey);
    event EqualXSoloAmmRebalanceExecuted(
        uint256 indexed marketId,
        bytes32 indexed makerPositionKey,
        address indexed executor,
        uint256 previousReserveA,
        uint256 previousReserveB,
        uint256 targetReserveA,
        uint256 targetReserveB
    );

    EqualXSoloAmmHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20EqualX internal tokenA;
    MockERC20EqualX internal tokenB;
    MockERC20EqualX internal stableToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");
    uint64 internal constant DEFAULT_REBALANCE_TIMELOCK = 15 minutes;

    uint256 internal alicePositionId;
    bytes32 internal alicePositionKey;

    function setUp() public {
        harness = new EqualXSoloAmmHarness();
        harness.setOwner(address(this));
        harness.setTimelock(makeAddr("timelock"));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1000, 7000);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        tokenA = new MockERC20EqualX("Token A", "TKA", 18);
        tokenB = new MockERC20EqualX("Token B", "TKB", 18);
        stableToken = new MockERC20EqualX("Stable", "STB", 6);

        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(tokenA), _poolConfig(), actionFees);
        harness.initPoolWithActionFees(2, address(tokenB), _poolConfig(), actionFees);
        harness.initPoolWithActionFees(3, address(stableToken), _poolConfig(), actionFees);

        tokenA.mint(alice, 1_000e18);
        tokenB.mint(alice, 1_000e18);
        stableToken.mint(alice, 1_000_000e6);

        vm.startPrank(alice);
        tokenA.approve(address(harness), type(uint256).max);
        tokenB.approve(address(harness), type(uint256).max);
        stableToken.approve(address(harness), type(uint256).max);
        alicePositionId = harness.mintPosition(1);
        harness.depositToPosition(alicePositionId, 1, 500e18, 500e18);
        harness.depositToPosition(alicePositionId, 2, 500e18, 500e18);
        harness.depositToPosition(alicePositionId, 3, 500_000e6, 500_000e6);
        vm.stopPrank();

        alicePositionKey = positionNft.getPositionKey(alicePositionId);
    }

    function test_CreateSoloAmm_ValidatesMembershipAndLocksBackingCapital() public {
        vm.startPrank(alice);
        uint256 secondPositionId = harness.mintPosition(1);
        harness.depositToPosition(secondPositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSignature(
                "PoolMembershipRequired(bytes32,uint256)", positionNft.getPositionKey(secondPositionId), 2
            )
        );
        vm.prank(alice);
        harness.createEqualXSoloAmmMarket(
            secondPositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        uint256 marketId;
        vm.prank(alice);
        marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        LibEqualXSoloAmmStorage.SoloAmmMarket memory market = harness.getEqualXSoloAmmMarket(marketId);
        assertEq(market.makerPositionId, alicePositionId);
        assertEq(market.reserveA, 100e18);
        assertEq(market.reserveB, 100e18);
        assertEq(market.baselineReserveA, 100e18);
        assertEq(market.baselineReserveB, 100e18);
        assertEq(market.rebalanceTimelock, DEFAULT_REBALANCE_TIMELOCK);
        assertEq(market.lastRebalanceExecutionAt, 0);
        assertTrue(market.active);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 100e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 2), 100e18);
        assertEq(harness.activeCreditPrincipalTotalOf(1), 100e18);
        assertEq(harness.activeCreditPrincipalTotalOf(2), 100e18);
        assertEq(harness.minRebalanceTimelock(), 1 minutes);
    }

    function test_CreateSoloAmm_SupportsStableInvariantMode() public {
        uint256 marketId;
        vm.prank(alice);
        marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            3,
            100e18,
            100_000e6,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            DEFAULT_REBALANCE_TIMELOCK,
            100,
            LibEqualXTypes.FeeAsset.TokenOut,
            LibEqualXTypes.InvariantMode.Stable
        );

        LibEqualXSoloAmmStorage.SoloAmmMarket memory market = harness.getEqualXSoloAmmMarket(marketId);
        assertEq(uint8(market.invariantMode), uint8(LibEqualXTypes.InvariantMode.Stable));
        assertEq(market.tokenADecimals, 18);
        assertEq(market.tokenBDecimals, 6);
    }

    function test_CreateSoloAmm_UsesSettledPrincipalAfterMaintenance() public {
        harness.setFoundationReceiver(makeAddr("foundation"));
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert();
        vm.prank(alice);
        harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            500e18,
            500e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );
    }

    function test_CreateSoloAmm_RevertsWhenRebalanceTimelockBelowProtocolMinimum() public {
        harness.setEqualXSoloAmmMinRebalanceTimelock(5 minutes);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameterRange(string)", "rebalanceTimelock"));
        harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            4 minutes,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );
    }

    function test_SetMinRebalanceTimelock_RequiresGovernanceAndRejectsZero() public {
        vm.prank(alice);
        vm.expectRevert("LibAccess: not owner or timelock");
        harness.setEqualXSoloAmmMinRebalanceTimelock(5 minutes);

        vm.expectRevert(abi.encodeWithSignature("InvalidParameterRange(string)", "minRebalanceTimelock"));
        harness.setEqualXSoloAmmMinRebalanceTimelock(0);

        harness.setEqualXSoloAmmMinRebalanceTimelock(7 minutes);
        assertEq(harness.minRebalanceTimelock(), 7 minutes);
    }

    function test_ScheduleRebalance_StoresPendingStateAndEmitsEvent() public {
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 3 days), DEFAULT_REBALANCE_TIMELOCK);
        uint64 expectedExecuteAfter = uint64(block.timestamp + DEFAULT_REBALANCE_TIMELOCK);

        vm.expectEmit(true, true, false, true);
        emit EqualXSoloAmmRebalanceScheduled(
            marketId, alicePositionKey, 100e18, 100e18, 110e18, 90e18, expectedExecuteAfter
        );

        vm.prank(alice);
        uint64 executeAfter = harness.scheduleEqualXSoloAmmRebalance(marketId, 110e18, 90e18);

        LibEqualXSoloAmmStorage.SoloAmmPendingRebalance memory pending = harness.getPendingRebalance(marketId);
        assertEq(executeAfter, expectedExecuteAfter);
        assertEq(pending.snapshotReserveA, 100e18);
        assertEq(pending.snapshotReserveB, 100e18);
        assertEq(pending.targetReserveA, 110e18);
        assertEq(pending.targetReserveB, 90e18);
        assertEq(pending.executeAfter, expectedExecuteAfter);
        assertTrue(pending.exists);
    }

    function test_ScheduleRebalance_RequiresMakerAndLiveMarket() public {
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 3 days), DEFAULT_REBALANCE_TIMELOCK);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotNFTOwner(address,uint256)", bob, alicePositionId));
        harness.scheduleEqualXSoloAmmRebalance(marketId, 105e18, 95e18);

        uint256 delayedMarketId =
            _createSoloMarket(uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), DEFAULT_REBALANCE_TIMELOCK);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EqualXSoloAmmFacet.EqualXSoloAmm_NotStarted.selector, delayedMarketId));
        harness.scheduleEqualXSoloAmmRebalance(delayedMarketId, 105e18, 95e18);

        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EqualXSoloAmmFacet.EqualXSoloAmm_Expired.selector, delayedMarketId));
        harness.scheduleEqualXSoloAmmRebalance(delayedMarketId, 105e18, 95e18);
    }

    function test_ScheduleRebalance_RejectsInvalidTargetsAndExistingPending() public {
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 3 days), DEFAULT_REBALANCE_TIMELOCK);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameterRange(string)", "targetReserveA"));
        harness.scheduleEqualXSoloAmmRebalance(marketId, 0, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameterRange(string)", "targetReserveB"));
        harness.scheduleEqualXSoloAmmRebalance(marketId, 100e18, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameterRange(string)", "targetReserveA"));
        harness.scheduleEqualXSoloAmmRebalance(marketId, 111e18, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameterRange(string)", "targetReserveB"));
        harness.scheduleEqualXSoloAmmRebalance(marketId, 100e18, 89e18);

        vm.prank(alice);
        harness.scheduleEqualXSoloAmmRebalance(marketId, 110e18, 90e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EqualXSoloAmmFacet.EqualXSoloAmm_PendingRebalanceExists.selector, marketId));
        harness.scheduleEqualXSoloAmmRebalance(marketId, 105e18, 95e18);
    }

    function test_ScheduleRebalance_UsesMarketTimelockAndCooldownReadyTime() public {
        uint64 customTimelock = 30 minutes;
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 3 days), customTimelock);
        harness.setLastRebalanceExecutionAt(marketId, block.timestamp);

        vm.prank(alice);
        uint64 executeAfter = harness.scheduleEqualXSoloAmmRebalance(marketId, 105e18, 95e18);

        assertEq(executeAfter, uint64(block.timestamp + customTimelock));
        assertEq(harness.getPendingRebalance(marketId).executeAfter, uint64(block.timestamp + customTimelock));
    }

    function test_CancelRebalance_RequiresMakerAndClearsPendingState() public {
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 3 days), DEFAULT_REBALANCE_TIMELOCK);

        vm.prank(alice);
        harness.scheduleEqualXSoloAmmRebalance(marketId, 105e18, 95e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("NotNFTOwner(address,uint256)", bob, alicePositionId));
        harness.cancelEqualXSoloAmmRebalance(marketId);

        vm.expectEmit(true, true, false, true);
        emit EqualXSoloAmmRebalanceCancelled(marketId, alicePositionKey);

        vm.prank(alice);
        harness.cancelEqualXSoloAmmRebalance(marketId);

        LibEqualXSoloAmmStorage.SoloAmmPendingRebalance memory pending = harness.getPendingRebalance(marketId);
        assertEq(pending.snapshotReserveA, 0);
        assertEq(pending.snapshotReserveB, 0);
        assertEq(pending.targetReserveA, 0);
        assertEq(pending.targetReserveB, 0);
        assertEq(pending.executeAfter, 0);
        assertFalse(pending.exists);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EqualXSoloAmmFacet.EqualXSoloAmm_NoPendingRebalance.selector, marketId));
        harness.cancelEqualXSoloAmmRebalance(marketId);
    }

    function test_ExecuteRebalance_RevertsWithoutPendingOrBeforeReady() public {
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 3 days), DEFAULT_REBALANCE_TIMELOCK);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EqualXSoloAmmFacet.EqualXSoloAmm_NoPendingRebalance.selector, marketId));
        harness.executeEqualXSoloAmmRebalance(marketId);

        vm.prank(alice);
        uint64 executeAfter = harness.scheduleEqualXSoloAmmRebalance(marketId, 110e18, 90e18);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(EqualXSoloAmmFacet.EqualXSoloAmm_RebalanceNotReady.selector, marketId, executeAfter)
        );
        harness.executeEqualXSoloAmmRebalance(marketId);
    }

    function test_ExecuteRebalance_PermissionlessUpdatesBackingAndClearsPending() public {
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 3 days), DEFAULT_REBALANCE_TIMELOCK);

        vm.prank(alice);
        uint64 executeAfter = harness.scheduleEqualXSoloAmmRebalance(marketId, 110e18, 90e18);

        vm.warp(executeAfter);
        vm.expectEmit(true, true, true, true);
        emit EqualXSoloAmmRebalanceExecuted(marketId, alicePositionKey, bob, 100e18, 100e18, 110e18, 90e18);

        vm.prank(bob);
        harness.executeEqualXSoloAmmRebalance(marketId);

        LibEqualXSoloAmmStorage.SoloAmmMarket memory market = harness.getEqualXSoloAmmMarket(marketId);
        LibEqualXSoloAmmStorage.SoloAmmPendingRebalance memory pending = harness.getPendingRebalance(marketId);

        assertEq(market.reserveA, 110e18);
        assertEq(market.reserveB, 90e18);
        assertEq(market.baselineReserveA, 110e18);
        assertEq(market.baselineReserveB, 90e18);
        assertEq(market.lastRebalanceExecutionAt, executeAfter);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 110e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 2), 90e18);
        assertEq(harness.activeCreditPrincipalTotalOf(1), 110e18);
        assertEq(harness.activeCreditPrincipalTotalOf(2), 90e18);
        assertFalse(pending.exists);
    }

    function test_ExecuteRebalance_UsesStoredTargetsAfterLiveReservesDrift() public {
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 5 days), DEFAULT_REBALANCE_TIMELOCK);

        vm.prank(alice);
        uint64 executeAfter = harness.scheduleEqualXSoloAmmRebalance(marketId, 95e18, 105e18);

        tokenA.mint(bob, 100e18);
        vm.prank(bob);
        tokenA.approve(address(harness), type(uint256).max);

        EqualXSoloAmmFacet.SoloAmmSwapPreview memory preview =
            harness.previewEqualXSoloAmmSwapExactIn(marketId, address(tokenA), 10e18);
        vm.prank(bob);
        harness.swapEqualXSoloAmmExactIn(marketId, address(tokenA), 10e18, 10e18, preview.amountOut, bob);

        LibEqualXSoloAmmStorage.SoloAmmMarket memory drifted = harness.getEqualXSoloAmmMarket(marketId);
        assertGt(drifted.reserveA, 100e18);
        assertLt(drifted.reserveB, 100e18);
        assertEq(harness.activeCreditPrincipalTotalOf(1), 100e18);
        assertEq(harness.activeCreditPrincipalTotalOf(2), 100e18);

        vm.warp(executeAfter);
        vm.prank(makeAddr("executor"));
        harness.executeEqualXSoloAmmRebalance(marketId);

        LibEqualXSoloAmmStorage.SoloAmmMarket memory rebalanced = harness.getEqualXSoloAmmMarket(marketId);
        assertEq(rebalanced.reserveA, 95e18);
        assertEq(rebalanced.reserveB, 105e18);
        assertEq(rebalanced.baselineReserveA, 95e18);
        assertEq(rebalanced.baselineReserveB, 105e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 95e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 2), 105e18);
        assertEq(harness.activeCreditPrincipalTotalOf(1), 95e18);
        assertEq(harness.activeCreditPrincipalTotalOf(2), 105e18);
    }

    function test_ExecuteRebalance_RevertsWhenIncreaseBackingIsInsufficient() public {
        vm.prank(alice);
        uint256 marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            470e18,
            470e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.prank(alice);
        uint64 executeAfter = harness.scheduleEqualXSoloAmmRebalance(marketId, 517e18, 423e18);

        vm.warp(executeAfter);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("InsufficientPrincipal(uint256,uint256)", 47e18, 30e18));
        harness.executeEqualXSoloAmmRebalance(marketId);

        assertTrue(harness.getPendingRebalance(marketId).exists);
    }

    function test_ExecuteRebalance_DecreaseReleasesBackingForWithdrawal() public {
        uint256 marketId = _createSoloMarket(uint64(block.timestamp), uint64(block.timestamp + 3 days), DEFAULT_REBALANCE_TIMELOCK);

        vm.prank(alice);
        uint64 executeAfter = harness.scheduleEqualXSoloAmmRebalance(marketId, 90e18, 90e18);

        vm.warp(executeAfter);
        vm.prank(bob);
        harness.executeEqualXSoloAmmRebalance(marketId);

        vm.prank(alice);
        harness.withdrawFromPosition(alicePositionId, 1, 410e18, 410e18);

        assertEq(harness.principalOf(1, alicePositionKey), 90e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 90e18);
    }

    function test_CreateSoloAmm_BackingBlockedByManagedPoolDepositCap() public {
        harness.setManagedPoolCreationFee(1 wei);
        vm.deal(alice, 1 wei);

        Types.PoolConfig memory config = _poolConfig();
        config.isCapped = true;
        config.depositCap = 100e18;

        vm.prank(alice);
        harness.initManagedPool{value: 1 wei}(4, address(tokenB), config);

        vm.startPrank(alice);
        uint256 managedPositionId = harness.mintPosition(4);
        harness.depositToPosition(managedPositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        vm.prank(alice);
        harness.addToWhitelist(4, managedPositionId);

        vm.expectRevert(abi.encodeWithSignature("DepositCapExceeded(uint256,uint256)", 150e18, 100e18));
        vm.prank(alice);
        harness.depositToPosition(managedPositionId, 4, 150e18, 150e18);
    }

    function test_CreateSoloAmm_BackingBlockedByManagedPoolWhitelistUntilApproved() public {
        harness.setManagedPoolCreationFee(1 wei);
        vm.deal(alice, 1 wei);

        vm.prank(alice);
        harness.initManagedPool{value: 1 wei}(4, address(tokenB), _poolConfig());

        vm.prank(alice);
        uint256 managedPositionId = harness.mintPosition(4);
        bytes32 managedPositionKey = positionNft.getPositionKey(managedPositionId);

        vm.expectRevert(
            abi.encodeWithSignature("WhitelistRequired(bytes32,uint256)", managedPositionKey, 4)
        );
        vm.prank(alice);
        harness.depositToPosition(managedPositionId, 4, 100e18, 100e18);

        vm.prank(alice);
        harness.addToWhitelist(4, managedPositionId);

        vm.startPrank(alice);
        harness.depositToPosition(managedPositionId, 1, 100e18, 100e18);
        harness.depositToPosition(managedPositionId, 4, 100e18, 100e18);
        uint256 marketId = harness.createEqualXSoloAmmMarket(
            managedPositionId,
            1,
            4,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );
        vm.stopPrank();

        LibEqualXSoloAmmStorage.SoloAmmMarket memory market = harness.getEqualXSoloAmmMarket(marketId);
        assertTrue(market.active);
        assertEq(market.poolIdB, 4);
    }

    function test_WithdrawFromPosition_BlockedWhileSoloAmmBackingIsEncumbered() public {
        vm.prank(alice);
        harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.expectRevert(abi.encodeWithSignature("InsufficientPrincipal(uint256,uint256)", 450000000000000000000, 400000000000000000000));
        vm.prank(alice);
        harness.withdrawFromPosition(alicePositionId, 1, 450e18, 450e18);
    }

    function test_SwapExactIn_MatchesPreviewAndRoutesFees() public {
        uint256 marketId;
        vm.prank(alice);
        marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 5 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.warp(block.timestamp + 2 days);

        tokenA.mint(bob, 100e18);
        vm.prank(bob);
        tokenA.approve(address(harness), type(uint256).max);

        EqualXSoloAmmFacet.SoloAmmSwapPreview memory preview =
            harness.previewEqualXSoloAmmSwapExactIn(marketId, address(tokenA), 10e18);

        vm.prank(bob);
        uint256 amountOut =
            harness.swapEqualXSoloAmmExactIn(marketId, address(tokenA), 10e18, 10e18, preview.amountOut, bob);

        LibEqualXSoloAmmStorage.SoloAmmMarket memory market = harness.getEqualXSoloAmmMarket(marketId);
        assertEq(amountOut, preview.amountOut);
        assertEq(tokenB.balanceOf(bob), preview.amountOut);
        assertEq(market.makerFeeAAccrued, preview.makerFee);
        assertEq(market.treasuryFeeAAccrued, preview.treasuryFee);
        assertEq(market.activeCreditFeeAAccrued, preview.activeCreditFee);
        assertEq(market.feeIndexFeeAAccrued, preview.feeIndexFee);
        assertEq(tokenA.balanceOf(treasury), preview.treasuryFee);
        assertEq(harness.yieldReserveOf(1), preview.activeCreditFee + preview.feeIndexFee);
        assertEq(harness.principalOf(1, alicePositionKey), 500e18);
        assertEq(harness.principalOf(2, alicePositionKey), 500e18);
        assertEq(harness.trackedBalanceOf(1), 500e18);
        assertEq(harness.trackedBalanceOf(2), 500e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), market.reserveA);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 2), market.reserveB);
        assertEq(harness.activeCreditPrincipalTotalOf(1), 100e18);
        assertEq(harness.activeCreditPrincipalTotalOf(2), 100e18);
    }

    function test_ViewHelpers_MatchSoloPreviewAndDiscovery() public {
        uint256 marketId;
        vm.prank(alice);
        marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 5 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.warp(block.timestamp + 1 days);

        EqualXSoloAmmFacet.SoloAmmSwapPreview memory modulePreview =
            harness.previewEqualXSoloAmmSwapExactIn(marketId, address(tokenA), 10e18);
        EqualXViewFacet.EqualXSwapQuote memory viewPreview =
            harness.quoteEqualXSoloAmmExactIn(marketId, address(tokenA), 10e18);

        assertEq(viewPreview.rawOut, modulePreview.rawOut);
        assertEq(viewPreview.amountOut, modulePreview.amountOut);
        assertEq(viewPreview.feeAmount, modulePreview.feeAmount);
        assertEq(viewPreview.makerFee, modulePreview.makerFee);
        assertEq(viewPreview.treasuryFee, modulePreview.treasuryFee);
        assertEq(viewPreview.activeCreditFee, modulePreview.activeCreditFee);
        assertEq(viewPreview.feeIndexFee, modulePreview.feeIndexFee);
        assertEq(viewPreview.feeToken, modulePreview.feeToken);
        assertEq(viewPreview.feePoolId, modulePreview.feePoolId);

        LibEqualXTypes.MarketPointer[] memory byPositionId = harness.getEqualXMarketsByPositionId(alicePositionId);
        assertEq(byPositionId.length, 1);
        assertEq(uint8(byPositionId[0].marketType), uint8(LibEqualXTypes.MarketType.SOLO_AMM));
        assertEq(byPositionId[0].marketId, marketId);

        LibEqualXTypes.MarketPointer[] memory activeByPositionId = harness.getEqualXActiveMarketsByPositionId(alicePositionId);
        assertEq(activeByPositionId.length, 1);
        assertEq(activeByPositionId[0].marketId, marketId);

        EqualXViewFacet.EqualXLinearMarketStatus memory status = harness.getEqualXSoloAmmStatus(marketId);
        assertTrue(status.exists);
        assertTrue(status.active);
        assertTrue(status.started);
        assertTrue(status.live);
        assertFalse(status.expired);
    }

    function test_SwapExactIn_RejectsBeforeStartAndAfterExpiry() public {
        uint256 marketId;
        vm.prank(alice);
        marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp + 1 days),
            uint64(block.timestamp + 2 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        tokenA.mint(bob, 20e18);
        vm.prank(bob);
        tokenA.approve(address(harness), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(EqualXSoloAmmFacet.EqualXSoloAmm_NotStarted.selector, marketId));
        vm.prank(bob);
        harness.swapEqualXSoloAmmExactIn(marketId, address(tokenA), 10e18, 10e18, 1, bob);

        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(abi.encodeWithSelector(EqualXSoloAmmFacet.EqualXSoloAmm_Expired.selector, marketId));
        vm.prank(bob);
        harness.swapEqualXSoloAmmExactIn(marketId, address(tokenA), 10e18, 10e18, 1, bob);
    }

    function test_FinalizeIsPermissionlessAndCancelRequiresMaker() public {
        uint256 marketId;
        vm.prank(alice);
        marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.expectRevert(abi.encodeWithSignature("NotNFTOwner(address,uint256)", bob, alicePositionId));
        vm.prank(bob);
        harness.cancelEqualXSoloAmmMarket(marketId);

        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        harness.finalizeEqualXSoloAmmMarket(marketId);

        LibEqualXSoloAmmStorage.SoloAmmMarket memory finalized = harness.getEqualXSoloAmmMarket(marketId);
        assertTrue(finalized.finalized);
        assertFalse(finalized.active);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 0);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 2), 0);

        vm.prank(alice);
        uint256 cancelledMarketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            50e18,
            50e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.prank(alice);
        harness.cancelEqualXSoloAmmMarket(cancelledMarketId);

        LibEqualXSoloAmmStorage.SoloAmmMarket memory cancelled = harness.getEqualXSoloAmmMarket(cancelledMarketId);
        assertTrue(cancelled.finalized);
        assertFalse(cancelled.active);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 0);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 2), 0);
    }

    function test_Finalize_ReconcilesPrincipalOnlyOnClose() public {
        uint256 marketId;
        vm.prank(alice);
        marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 5 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.warp(block.timestamp + 1 days);
        tokenA.mint(bob, 100e18);
        vm.prank(bob);
        tokenA.approve(address(harness), type(uint256).max);

        EqualXSoloAmmFacet.SoloAmmSwapPreview memory preview =
            harness.previewEqualXSoloAmmSwapExactIn(marketId, address(tokenA), 10e18);

        vm.prank(bob);
        harness.swapEqualXSoloAmmExactIn(marketId, address(tokenA), 10e18, 10e18, preview.amountOut, bob);

        assertEq(harness.principalOf(1, alicePositionKey), 500e18);
        assertEq(harness.principalOf(2, alicePositionKey), 500e18);

        vm.warp(block.timestamp + 5 days);
        vm.prank(bob);
        harness.finalizeEqualXSoloAmmMarket(marketId);

        LibEqualXSoloAmmStorage.SoloAmmMarket memory market = harness.getEqualXSoloAmmMarket(marketId);
        uint256 reserveAForPrincipal = market.reserveA - market.feeIndexFeeAAccrued - market.activeCreditFeeAAccrued;
        uint256 reserveBForPrincipal = market.reserveB - market.feeIndexFeeBAccrued - market.activeCreditFeeBAccrued;

        assertEq(harness.principalOf(1, alicePositionKey), 500e18 + (reserveAForPrincipal - 100e18));
        assertEq(harness.principalOf(2, alicePositionKey), 500e18 - (100e18 - reserveBForPrincipal));
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 0);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 2), 0);
    }

    function test_Finalize_AfterPartialUtilizationZeroesActiveCreditAndLeavesClaimableYield() public {
        vm.prank(alice);
        uint256 marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 5 days),
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.warp(block.timestamp + 1 days);
        tokenA.mint(bob, 100e18);
        vm.prank(bob);
        tokenA.approve(address(harness), type(uint256).max);

        EqualXSoloAmmFacet.SoloAmmSwapPreview memory preview =
            harness.previewEqualXSoloAmmSwapExactIn(marketId, address(tokenA), 10e18);

        vm.prank(bob);
        harness.swapEqualXSoloAmmExactIn(marketId, address(tokenA), 10e18, 10e18, preview.amountOut, bob);

        vm.warp(block.timestamp + 5 days);
        vm.prank(bob);
        harness.finalizeEqualXSoloAmmMarket(marketId);

        assertEq(harness.activeCreditPrincipalTotalOf(1), 0);
        assertEq(harness.activeCreditPrincipalTotalOf(2), 0);

        uint256 claimable = harness.previewPositionYield(alicePositionId, 1);
        assertGt(claimable, 0);

        uint256 reserveBeforeClaim = harness.yieldReserveOf(1);
        vm.prank(alice);
        uint256 claimed = harness.claimPositionYield(alicePositionId, 1, alice, 0);

        assertEq(claimed, claimable);
        assertEq(harness.yieldReserveOf(1), reserveBeforeClaim - claimed);
    }

    function _createSoloMarket(uint64 startTime, uint64 endTime, uint64 rebalanceTimelock)
        internal
        returns (uint256 marketId)
    {
        vm.prank(alice);
        marketId = harness.createEqualXSoloAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            startTime,
            endTime,
            rebalanceTimelock,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );
    }

    function _poolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 7000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 30;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMaxBps = 500;
    }
}
