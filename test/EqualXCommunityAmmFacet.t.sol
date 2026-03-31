// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {EqualXCommunityAmmFacet} from "src/equalx/EqualXCommunityAmmFacet.sol";
import {EqualXViewFacet} from "src/equalx/EqualXViewFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualXCommunityAmmStorage} from "src/libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXTypes} from "src/libraries/LibEqualXTypes.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20EqualXCommunity is ERC20 {
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

contract EqualXCommunityAmmHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualXCommunityAmmFacet,
    EqualXViewFacet
{
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

    function seedCrossPoolPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.userPrincipal[positionKey] = principal;
        pool.userFeeIndex[positionKey] = pool.feeIndex;
        pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
        pool.totalDeposits += principal;
        pool.trackedBalance += principal;
        if (!LibPoolMembership.isMember(positionKey, pid)) {
            LibPoolMembership._joinPool(positionKey, pid);
        }
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

    function yieldReserveOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].yieldReserve;
    }

    function activeCreditPrincipalTotalOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function accruedYieldOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function getCommunityMaker(uint256 marketId, bytes32 positionKey)
        external
        view
        returns (LibEqualXCommunityAmmStorage.CommunityMakerPosition memory maker)
    {
        maker = LibEqualXCommunityAmmStorage.s().makers[marketId][positionKey];
    }
}

contract EqualXCommunityAmmFacetTest is Test {
    EqualXCommunityAmmHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20EqualXCommunity internal tokenA;
    MockERC20EqualXCommunity internal tokenB;
    MockERC20EqualXCommunity internal stableToken;

    address internal alice = makeAddr("alice");
    address internal charlie = makeAddr("charlie");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    uint256 internal alicePositionId;
    bytes32 internal alicePositionKey;
    uint256 internal charliePositionId;
    bytes32 internal charliePositionKey;

    function setUp() public {
        harness = new EqualXCommunityAmmHarness();
        harness.setOwner(address(this));
        harness.setTimelock(makeAddr("timelock"));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1000, 7000);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        tokenA = new MockERC20EqualXCommunity("Token A", "TKA", 18);
        tokenB = new MockERC20EqualXCommunity("Token B", "TKB", 18);
        stableToken = new MockERC20EqualXCommunity("Stable", "STB", 6);

        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(tokenA), _poolConfig(), actionFees);
        harness.initPoolWithActionFees(2, address(tokenB), _poolConfig(), actionFees);
        harness.initPoolWithActionFees(3, address(stableToken), _poolConfig(), actionFees);

        tokenA.mint(alice, 1_000e18);
        tokenA.mint(charlie, 1_000e18);
        tokenA.mint(bob, 1_000e18);
        tokenB.mint(address(harness), 2_000e18);
        stableToken.mint(address(harness), 2_000_000e6);

        vm.startPrank(alice);
        tokenA.approve(address(harness), type(uint256).max);
        alicePositionId = harness.mintPosition(1);
        harness.depositToPosition(alicePositionId, 1, 500e18, 500e18);
        vm.stopPrank();
        alicePositionKey = positionNft.getPositionKey(alicePositionId);
        harness.seedCrossPoolPrincipal(2, alicePositionKey, 500e18);
        harness.seedCrossPoolPrincipal(3, alicePositionKey, 500_000e6);

        vm.startPrank(charlie);
        tokenA.approve(address(harness), type(uint256).max);
        charliePositionId = harness.mintPosition(1);
        harness.depositToPosition(charliePositionId, 1, 500e18, 500e18);
        vm.stopPrank();
        charliePositionKey = positionNft.getPositionKey(charliePositionId);
        harness.seedCrossPoolPrincipal(2, charliePositionKey, 500e18);
        harness.seedCrossPoolPrincipal(3, charliePositionKey, 500_000e6);

        vm.prank(bob);
        tokenA.approve(address(harness), type(uint256).max);
    }

    function test_CreateCommunityAmm_ValidatesMembershipAndSeedsInitialState() public {
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
        harness.createEqualXCommunityAmmMarket(
            secondPositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.prank(alice);
        uint256 marketId = harness.createEqualXCommunityAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory market = harness.getEqualXCommunityAmmMarket(marketId);
        LibEqualXCommunityAmmStorage.CommunityMakerPosition memory maker =
            harness.getCommunityMaker(marketId, alicePositionKey);

        assertEq(market.creatorPositionId, alicePositionId);
        assertEq(market.totalShares, 100e18);
        assertEq(market.makerCount, 1);
        assertEq(maker.share, 100e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 100e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 2), 100e18);
        assertEq(harness.activeCreditPrincipalTotalOf(1), 100e18);
        assertEq(harness.activeCreditPrincipalTotalOf(2), 100e18);
    }

    function test_CreateCommunityAmm_SupportsStableInvariantMode() public {
        vm.prank(alice);
        uint256 marketId = harness.createEqualXCommunityAmmMarket(
            alicePositionId,
            1,
            3,
            100e18,
            100_000e6,
            uint64(block.timestamp),
            uint64(block.timestamp + 3 days),
            100,
            LibEqualXTypes.FeeAsset.TokenOut,
            LibEqualXTypes.InvariantMode.Stable
        );

        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory market = harness.getEqualXCommunityAmmMarket(marketId);
        assertEq(uint8(market.invariantMode), uint8(LibEqualXTypes.InvariantMode.Stable));
        assertEq(market.tokenADecimals, 18);
        assertEq(market.tokenBDecimals, 6);
    }

    function test_JoinAndClaim_UseIndexedFees() public {
        uint256 marketId = _createJoinedCommunityMarket();

        LibEqualXCommunityAmmStorage.CommunityMakerPosition memory joined =
            harness.getCommunityMaker(marketId, charliePositionKey);
        assertEq(joined.share, 50e18);
        assertEq(harness.encumberedCapitalOf(charliePositionKey, 1), 50e18);
        assertEq(harness.encumberedCapitalOf(charliePositionKey, 2), 50e18);

        vm.warp(block.timestamp + 1 days);
        EqualXCommunityAmmFacet.CommunityAmmSwapPreview memory preview =
            harness.previewEqualXCommunityAmmSwapExactIn(marketId, address(tokenA), 15e18);
        vm.prank(bob);
        harness.swapEqualXCommunityAmmExactIn(marketId, address(tokenA), 15e18, 15e18, preview.amountOut, bob);

        uint256 yieldReserveBeforeClaim = harness.yieldReserveOf(1);
        uint256 trackedBeforeClaim = harness.trackedBalanceOf(1);
        vm.prank(charlie);
        (uint256 feesA, uint256 feesB) = harness.claimEqualXCommunityAmmFees(marketId, charliePositionId);

        assertGt(feesA, 0);
        assertEq(feesB, 0);
        assertEq(harness.accruedYieldOf(1, charliePositionKey), feesA);
        assertEq(harness.yieldReserveOf(1), yieldReserveBeforeClaim + feesA);
        assertEq(harness.trackedBalanceOf(1), trackedBeforeClaim + feesA);
    }

    function test_ViewHelpers_MatchCommunityPreviewAndMakerState() public {
        uint256 marketId = _createJoinedCommunityMarket();

        vm.warp(block.timestamp + 1 days);
        EqualXCommunityAmmFacet.CommunityAmmSwapPreview memory modulePreview =
            harness.previewEqualXCommunityAmmSwapExactIn(marketId, address(tokenA), 15e18);
        EqualXViewFacet.EqualXSwapQuote memory viewPreview =
            harness.quoteEqualXCommunityAmmExactIn(marketId, address(tokenA), 15e18);

        assertEq(viewPreview.rawOut, modulePreview.rawOut);
        assertEq(viewPreview.amountOut, modulePreview.amountOut);
        assertEq(viewPreview.feeAmount, modulePreview.feeAmount);
        assertEq(viewPreview.makerFee, modulePreview.makerFee);
        assertEq(viewPreview.treasuryFee, modulePreview.treasuryFee);
        assertEq(viewPreview.activeCreditFee, modulePreview.activeCreditFee);
        assertEq(viewPreview.feeIndexFee, modulePreview.feeIndexFee);
        assertEq(viewPreview.feeToken, modulePreview.feeToken);
        assertEq(viewPreview.feePoolId, modulePreview.feePoolId);

        LibEqualXTypes.MarketPointer[] memory byPositionId = harness.getEqualXMarketsByPositionId(charliePositionId);
        assertEq(byPositionId.length, 1);
        assertEq(uint8(byPositionId[0].marketType), uint8(LibEqualXTypes.MarketType.COMMUNITY_AMM));
        assertEq(byPositionId[0].marketId, marketId);

        EqualXViewFacet.EqualXCommunityMakerView memory makerView =
            harness.getEqualXCommunityMakerViewById(marketId, charliePositionId);
        (uint256 pendingFeesA, uint256 pendingFeesB) =
            harness.previewEqualXCommunityMakerFees(marketId, charliePositionKey);

        assertEq(makerView.maker.share, 50e18);
        assertEq(makerView.pendingFeesA, pendingFeesA);
        assertEq(makerView.pendingFeesB, pendingFeesB);

        EqualXViewFacet.EqualXLinearMarketStatus memory status = harness.getEqualXCommunityAmmStatus(marketId);
        assertTrue(status.exists);
        assertTrue(status.active);
        assertTrue(status.started);
        assertTrue(status.live);
    }

    function test_JoinCommunityAmm_UsesSettledPrincipalAfterMaintenance() public {
        vm.prank(alice);
        uint256 marketId = harness.createEqualXCommunityAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 5 days),
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        harness.setFoundationReceiver(makeAddr("foundation"));
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert();
        vm.prank(charlie);
        harness.joinEqualXCommunityAmmMarket(marketId, charliePositionId, 500e18, 500e18);
    }

    function test_Leave_ReconcilesBackingAndContributions() public {
        uint256 marketId = _createJoinedCommunityMarket();

        vm.warp(block.timestamp + 1 days);
        EqualXCommunityAmmFacet.CommunityAmmSwapPreview memory preview =
            harness.previewEqualXCommunityAmmSwapExactIn(marketId, address(tokenA), 15e18);
        vm.prank(bob);
        harness.swapEqualXCommunityAmmExactIn(marketId, address(tokenA), 15e18, 15e18, preview.amountOut, bob);

        LibEqualXCommunityAmmStorage.CommunityMakerPosition memory joined =
            harness.getCommunityMaker(marketId, charliePositionKey);
        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory marketBeforeLeave =
            harness.getEqualXCommunityAmmMarket(marketId);
        uint256 reservedA = marketBeforeLeave.feeIndexFeeAAccrued + marketBeforeLeave.activeCreditFeeAAccrued;
        uint256 reservedB = marketBeforeLeave.feeIndexFeeBAccrued + marketBeforeLeave.activeCreditFeeBAccrued;
        vm.prank(charlie);
        (uint256 withdrawnA, uint256 withdrawnB, uint256 leaveFeesA, uint256 leaveFeesB) =
            harness.leaveEqualXCommunityAmmMarket(marketId, charliePositionId);

        uint256 withdrawableReserveA =
            marketBeforeLeave.reserveA > leaveFeesA + reservedA ? marketBeforeLeave.reserveA - leaveFeesA - reservedA : 0;
        uint256 withdrawableReserveB =
            marketBeforeLeave.reserveB > leaveFeesB + reservedB ? marketBeforeLeave.reserveB - leaveFeesB - reservedB : 0;

        assertGt(leaveFeesA, 0);
        assertEq(leaveFeesB, 0);
        assertEq(withdrawnA, Math.mulDiv(withdrawableReserveA, joined.share, marketBeforeLeave.totalShares));
        assertEq(withdrawnB, Math.mulDiv(withdrawableReserveB, joined.share, marketBeforeLeave.totalShares));
        assertEq(harness.encumberedCapitalOf(charliePositionKey, 1), 0);
        assertEq(harness.encumberedCapitalOf(charliePositionKey, 2), 0);
        assertEq(harness.principalOf(1, charliePositionKey), 500e18 + (withdrawnA - 50e18));
        assertEq(harness.principalOf(2, charliePositionKey), 500e18 - (50e18 - withdrawnB));
    }

    function test_WithdrawFromPosition_BlockedWhileCommunityAmmBackingIsEncumbered() public {
        _createJoinedCommunityMarket();

        vm.expectRevert(abi.encodeWithSignature("InsufficientPrincipal(uint256,uint256)", 480000000000000000000, 450000000000000000000));
        vm.prank(charlie);
        harness.withdrawFromPosition(charliePositionId, 1, 480e18, 480e18);
    }

    function test_Swap_MatchesPreviewAndPreservesLowGasHotPath() public {
        vm.prank(alice);
        uint256 marketId = harness.createEqualXCommunityAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 5 days),
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.prank(charlie);
        harness.joinEqualXCommunityAmmMarket(marketId, charliePositionId, 50e18, 50e18);

        vm.warp(block.timestamp + 1 days);
        EqualXCommunityAmmFacet.CommunityAmmSwapPreview memory preview =
            harness.previewEqualXCommunityAmmSwapExactIn(marketId, address(tokenA), 10e18);
        vm.prank(bob);
        uint256 amountOut =
            harness.swapEqualXCommunityAmmExactIn(marketId, address(tokenA), 10e18, 10e18, preview.amountOut, bob);

        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory market = harness.getEqualXCommunityAmmMarket(marketId);
        assertEq(amountOut, preview.amountOut);
        assertEq(tokenB.balanceOf(bob), preview.amountOut);
        assertEq(tokenA.balanceOf(treasury), preview.treasuryFee);
        assertEq(harness.principalOf(1, alicePositionKey), 500e18);
        assertEq(harness.principalOf(2, alicePositionKey), 500e18);
        assertEq(harness.principalOf(1, charliePositionKey), 500e18);
        assertEq(harness.principalOf(2, charliePositionKey), 500e18);
        assertEq(harness.encumberedCapitalOf(alicePositionKey, 1), 100e18);
        assertEq(harness.encumberedCapitalOf(charliePositionKey, 1), 50e18);
        assertEq(market.treasuryFeeAAccrued, preview.treasuryFee);
        assertEq(market.activeCreditFeeAAccrued, preview.activeCreditFee);
        assertEq(market.feeIndexFeeAAccrued, preview.feeIndexFee);
        assertEq(harness.yieldReserveOf(1), preview.activeCreditFee + preview.feeIndexFee);
    }

    function test_FinalizeIsPermissionlessAndCancelRequiresCreator() public {
        vm.prank(alice);
        uint256 marketId = harness.createEqualXCommunityAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp + 1 days),
            uint64(block.timestamp + 2 days),
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.expectRevert(abi.encodeWithSignature("NotNFTOwner(address,uint256)", bob, alicePositionId));
        vm.prank(bob);
        harness.cancelEqualXCommunityAmmMarket(marketId);

        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        harness.finalizeEqualXCommunityAmmMarket(marketId);

        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory finalized = harness.getEqualXCommunityAmmMarket(marketId);
        assertTrue(finalized.finalized);
        assertFalse(finalized.active);

        vm.prank(alice);
        uint256 cancelledMarketId = harness.createEqualXCommunityAmmMarket(
            alicePositionId,
            1,
            2,
            50e18,
            50e18,
            uint64(block.timestamp + 1 days),
            uint64(block.timestamp + 3 days),
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.prank(alice);
        harness.cancelEqualXCommunityAmmMarket(cancelledMarketId);

        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory cancelled = harness.getEqualXCommunityAmmMarket(cancelledMarketId);
        assertTrue(cancelled.finalized);
        assertFalse(cancelled.active);
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

    function _createJoinedCommunityMarket() internal returns (uint256 marketId) {
        vm.prank(alice);
        marketId = harness.createEqualXCommunityAmmMarket(
            alicePositionId,
            1,
            2,
            100e18,
            100e18,
            uint64(block.timestamp),
            uint64(block.timestamp + 5 days),
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        );

        vm.prank(charlie);
        harness.joinEqualXCommunityAmmMarket(marketId, charliePositionId, 50e18, 50e18);
    }
}
