// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {EqualXCurveCreationFacet} from "src/equalx/EqualXCurveCreationFacet.sol";
import {EqualXCurveExecutionFacet} from "src/equalx/EqualXCurveExecutionFacet.sol";
import {EqualXCurveManagementFacet} from "src/equalx/EqualXCurveManagementFacet.sol";
import {EqualXViewFacet} from "src/equalx/EqualXViewFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualXCurveEngine} from "src/libraries/LibEqualXCurveEngine.sol";
import {LibEqualXCurveStorage} from "src/libraries/LibEqualXCurveStorage.sol";
import {LibEqualXTypes} from "src/libraries/LibEqualXTypes.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20EqualXCurve is ERC20 {
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

contract EqualXCurveHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualXCurveCreationFacet,
    EqualXCurveManagementFacet,
    EqualXCurveExecutionFacet,
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

    function directLockedOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).directLocked;
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
}

contract EqualXCurveFacetTest is Test {
    EqualXCurveHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20EqualXCurve internal tokenA;
    MockERC20EqualXCurve internal tokenB;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    uint256 internal alicePositionId;
    bytes32 internal alicePositionKey;

    function setUp() public {
        harness = new EqualXCurveHarness();
        harness.setOwner(address(this));
        harness.setTimelock(makeAddr("timelock"));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1000, 7000);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        tokenA = new MockERC20EqualXCurve("Token A", "TKA", 18);
        tokenB = new MockERC20EqualXCurve("Token B", "TKB", 18);

        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(tokenA), _poolConfig(), actionFees);
        harness.initPoolWithActionFees(2, address(tokenB), _poolConfig(), actionFees);

        tokenA.mint(alice, 1_000e18);
        tokenB.mint(bob, 1_000e18);

        vm.startPrank(alice);
        tokenA.approve(address(harness), type(uint256).max);
        alicePositionId = harness.mintPosition(1);
        harness.depositToPosition(alicePositionId, 1, 500e18, 500e18);
        vm.stopPrank();

        alicePositionKey = positionNft.getPositionKey(alicePositionId);
        harness.seedCrossPoolPrincipal(2, alicePositionKey, 500e18);

        vm.prank(bob);
        tokenB.approve(address(harness), type(uint256).max);
    }

    function test_CreateCurve_ValidatesDescriptorAndLocksBaseBacking() public {
        LibEqualXCurveEngine.CurveDescriptor memory desc = _defaultDescriptor();
        desc.profileId = 2;

        vm.expectRevert(
            abi.encodeWithSelector(LibEqualXCurveEngine.EqualXCurve_NotBuiltInLinearProfile.selector, uint16(2))
        );
        vm.prank(alice);
        harness.createEqualXCurve(desc);

        vm.prank(alice);
        uint256 curveId = harness.createEqualXCurve(_defaultDescriptor());

        (
            LibEqualXCurveStorage.CurveMarket memory market,
            LibEqualXCurveStorage.CurveData memory data,
            LibEqualXCurveStorage.CurvePricing memory pricing,
            LibEqualXCurveStorage.CurveProfileData memory profileData,
            LibEqualXCurveStorage.CurveImmutables memory immutables,
            bool baseIsA
        ) = harness.getEqualXCurveMarket(curveId);

        assertTrue(market.active);
        assertEq(market.remainingVolume, 100e18);
        assertEq(data.makerPositionId, alicePositionId);
        assertEq(pricing.startPrice, 2e18);
        assertEq(pricing.endPrice, 2e18);
        assertEq(profileData.profileId, LibEqualXCurveEngine.builtInLinearProfileId());
        assertEq(immutables.feeRateBps, 300);
        assertTrue(baseIsA);
        assertEq(harness.directLockedOf(alicePositionKey, 1), 100e18);
    }

    function test_UpdateCurve_IncrementsGenerationAndRecomputesCommitment() public {
        vm.prank(alice);
        uint256 curveId = harness.createEqualXCurve(_defaultDescriptor());

        (uint32 generationBefore, bytes32 commitmentBefore) = harness.getEqualXCurveCommitment(curveId);
        assertEq(generationBefore, 1);

        LibEqualXCurveEngine.CurveUpdateParams memory params = LibEqualXCurveEngine.CurveUpdateParams({
            startPrice: 3e18,
            endPrice: 15e17,
            startTime: uint64(block.timestamp + 1 hours),
            duration: 5 days,
            updateProfile: false,
            profileId: 0,
            updateProfileParams: true,
            profileParams: bytes32(uint256(7))
        });

        vm.prank(alice);
        harness.updateEqualXCurve(curveId, params);

        (uint32 generationAfter, bytes32 commitmentAfter) = harness.getEqualXCurveCommitment(curveId);
        assertEq(generationAfter, 2);
        assertTrue(commitmentAfter != commitmentBefore);
    }

    function test_ExecuteCurveSwap_MatchesPreviewAndTracksVolume() public {
        vm.prank(alice);
        uint256 curveId = harness.createEqualXCurve(_defaultDescriptor());

        vm.warp(block.timestamp + 1 days);
        LibEqualXCurveEngine.CurveExecutionPreview memory preview = harness.previewEqualXCurveQuote(curveId, 10e18);
        (uint32 generation, bytes32 commitment) = harness.getEqualXCurveCommitment(curveId);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibEqualXCurveEngine.EqualXCurve_GenerationMismatch.selector, generation + 1, generation
            )
        );
        vm.prank(bob);
        harness.executeEqualXCurveSwap(curveId, 10e18, preview.totalQuote, preview.amountOut, uint64(block.timestamp + 1 days), bob, generation + 1, commitment);

        uint256 treasuryBalanceBefore = tokenB.balanceOf(treasury);
        vm.prank(bob);
        uint256 amountOut = harness.executeEqualXCurveSwap(
            curveId, 10e18, preview.totalQuote, preview.amountOut, uint64(block.timestamp + 1 days), bob, generation, commitment
        );

        (LibEqualXCurveStorage.CurveMarket memory market,,,,,) = harness.getEqualXCurveMarket(curveId);

        uint256 makerFee = (preview.feeAmount * 7000) / 10_000;
        uint256 protocolFee = preview.feeAmount - makerFee;
        uint256 treasuryFee = (protocolFee * 1000) / 10_000;
        assertEq(amountOut, preview.amountOut);
        assertEq(tokenA.balanceOf(bob), preview.amountOut);
        assertEq(tokenB.balanceOf(treasury) - treasuryBalanceBefore, treasuryFee);
        assertEq(harness.principalOf(2, alicePositionKey), 500e18 + 10e18 + makerFee);
        assertEq(harness.principalOf(1, alicePositionKey), 500e18 - preview.amountOut);
        assertEq(harness.directLockedOf(alicePositionKey, 1), 100e18 - preview.amountOut);
        assertEq(market.remainingVolume, 100e18 - preview.amountOut);
        assertEq(harness.yieldReserveOf(2), protocolFee - treasuryFee);
    }

    function test_CancelCurve_ReleasesLockedBacking() public {
        vm.prank(alice);
        uint256 curveId = harness.createEqualXCurve(_defaultDescriptor());

        assertEq(harness.directLockedOf(alicePositionKey, 1), 100e18);

        vm.prank(alice);
        harness.cancelEqualXCurve(curveId);

        (LibEqualXCurveStorage.CurveMarket memory market,,,,,) = harness.getEqualXCurveMarket(curveId);

        assertFalse(market.active);
        assertEq(market.remainingVolume, 0);
        assertEq(harness.directLockedOf(alicePositionKey, 1), 0);
    }

    function test_ExpireCurve_PermissionlesslyReleasesLockedBacking() public {
        vm.prank(alice);
        uint256 curveId = harness.createEqualXCurve(_defaultDescriptor());

        vm.warp(block.timestamp + 4 days);
        vm.prank(bob);
        harness.expireEqualXCurve(curveId);

        (LibEqualXCurveStorage.CurveMarket memory market,,,,,) = harness.getEqualXCurveMarket(curveId);

        assertFalse(market.active);
        assertEq(harness.directLockedOf(alicePositionKey, 1), 0);
    }

    function _defaultDescriptor() internal view returns (LibEqualXCurveEngine.CurveDescriptor memory desc) {
        desc = LibEqualXCurveEngine.CurveDescriptor({
            makerPositionKey: alicePositionKey,
            makerPositionId: alicePositionId,
            poolIdA: 1,
            poolIdB: 2,
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            side: false,
            priceIsQuotePerBase: true,
            maxVolume: 100e18,
            startPrice: 2e18,
            endPrice: 2e18,
            startTime: uint64(block.timestamp),
            duration: 3 days,
            generation: 1,
            feeRateBps: 300,
            feeAsset: LibEqualXTypes.FeeAsset.TokenIn,
            salt: 1,
            profileId: 1,
            profileParams: bytes32(0)
        });
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
