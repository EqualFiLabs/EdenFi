// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {EqualXSoloAmmFacet} from "src/equalx/EqualXSoloAmmFacet.sol";
import {EqualXCommunityAmmFacet} from "src/equalx/EqualXCommunityAmmFacet.sol";
import {EqualXCurveCreationFacet} from "src/equalx/EqualXCurveCreationFacet.sol";
import {EqualXCurveManagementFacet} from "src/equalx/EqualXCurveManagementFacet.sol";
import {EqualXCurveExecutionFacet} from "src/equalx/EqualXCurveExecutionFacet.sol";
import {EqualXViewFacet} from "src/equalx/EqualXViewFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualXCommunityAmmStorage} from "src/libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXSoloAmmStorage} from "src/libraries/LibEqualXSoloAmmStorage.sol";
import {LibEqualXCurveEngine} from "src/libraries/LibEqualXCurveEngine.sol";
import {LibEqualXCurveStorage} from "src/libraries/LibEqualXCurveStorage.sol";
import {LibEqualXTypes} from "src/libraries/LibEqualXTypes.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {ICurveProfile} from "src/interfaces/ICurveProfile.sol";

contract MockERC20EqualXInvariant is ERC20 {
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

contract MockCurveProfileInvariant is ICurveProfile {
    function computePrice(
        uint256 startPrice,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes32 profileParams
    ) external pure returns (uint256 price) {
        return startPrice + uint256(profileParams);
    }
}

contract EqualXHarnessBase is PoolManagementFacet, PositionManagementFacet, EqualXViewFacet {
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

    function encumberedCapitalOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).encumberedCapital;
    }

    function lockedCapitalOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).lockedCapital;
    }

    function totalEncumbranceOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.total(positionKey, pid);
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function activeCreditPrincipalTotalOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function getCommunityMaker(uint256 marketId, bytes32 positionKey)
        external
        view
        returns (LibEqualXCommunityAmmStorage.CommunityMakerPosition memory maker)
    {
        maker = LibEqualXCommunityAmmStorage.s().makers[marketId][positionKey];
    }
}

contract EqualXSoloInvariantHarness is EqualXHarnessBase, EqualXSoloAmmFacet {}

contract EqualXCommunityInvariantHarness is EqualXHarnessBase, EqualXCommunityAmmFacet {}

contract EqualXCurveInvariantHarness is
    EqualXHarnessBase,
    EqualXCurveCreationFacet,
    EqualXCurveManagementFacet,
    EqualXCurveExecutionFacet
{}

contract EqualXSoloInvariantHandler is Test {
    EqualXSoloInvariantHarness public immutable harness;
    PositionNFT public immutable positionNft;
    MockERC20EqualXInvariant public immutable tokenA;
    MockERC20EqualXInvariant public immutable tokenB;
    address public immutable maker;
    address public immutable taker;

    uint256 public makerPositionId;
    bytes32 public makerPositionKey;
    uint256 public marketId;
    uint256 public fundedPrincipalA;
    uint256 public fundedPrincipalB;

    uint256 internal constant INITIAL_PRINCIPAL = 750e18;
    uint64 internal constant DEFAULT_REBALANCE_TIMELOCK = 15 minutes;

    constructor(
        EqualXSoloInvariantHarness harness_,
        PositionNFT positionNft_,
        MockERC20EqualXInvariant tokenA_,
        MockERC20EqualXInvariant tokenB_,
        address maker_,
        address taker_
    ) {
        harness = harness_;
        positionNft = positionNft_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        maker = maker_;
        taker = taker_;
    }

    function seedInitialState() external {
        vm.startPrank(maker);
        tokenA.approve(address(harness), type(uint256).max);
        tokenB.approve(address(harness), type(uint256).max);
        makerPositionId = harness.mintPosition(1);
        harness.depositToPosition(makerPositionId, 1, INITIAL_PRINCIPAL, INITIAL_PRINCIPAL);
        harness.depositToPosition(makerPositionId, 2, INITIAL_PRINCIPAL, INITIAL_PRINCIPAL);
        vm.stopPrank();

        makerPositionKey = positionNft.getPositionKey(makerPositionId);
        fundedPrincipalA = INITIAL_PRINCIPAL;
        fundedPrincipalB = INITIAL_PRINCIPAL;

        tokenA.mint(taker, 5_000e18);
        vm.prank(taker);
        tokenA.approve(address(harness), type(uint256).max);

        vm.prank(maker);
        marketId = harness.createEqualXSoloAmmMarket(
            makerPositionId,
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
    }

    function replenishBacking(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e18, 100e18);

        vm.startPrank(maker);
        harness.depositToPosition(makerPositionId, 1, amount, amount);
        harness.depositToPosition(makerPositionId, 2, amount, amount);
        vm.stopPrank();
        _syncFundedPrincipals();
    }

    function createMarket(uint256 reserveSeed, uint256 durationSeed) external {
        if (_marketActive()) return;
        uint256 reserve = bound(reserveSeed, 50e18, 200e18);
        uint64 endTime = uint64(block.timestamp + bound(durationSeed, 1 hours, 5 days));

        vm.prank(maker);
        try harness.createEqualXSoloAmmMarket(
            makerPositionId,
            1,
            2,
            reserve,
            reserve,
            uint64(block.timestamp),
            endTime,
            DEFAULT_REBALANCE_TIMELOCK,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        ) returns (uint256 newMarketId) {
            marketId = newMarketId;
            _syncFundedPrincipals();
        } catch {}
    }

    function swap(uint256 amountSeed) external {
        if (!_marketLive()) return;
        uint256 amountIn = bound(amountSeed, 1e18, 25e18);

        EqualXSoloAmmFacet.SoloAmmSwapPreview memory preview =
            harness.previewEqualXSoloAmmSwapExactIn(marketId, address(tokenA), amountIn);
        vm.prank(taker);
        uint256 amountOut =
            harness.swapEqualXSoloAmmExactIn(marketId, address(tokenA), amountIn, amountIn, preview.amountOut, taker);
        assertEq(amountOut, preview.amountOut);
    }

    function close(uint256 modeSeed) external {
        if (!_marketActive()) return;
        LibEqualXSoloAmmStorage.SoloAmmMarket memory market = harness.getEqualXSoloAmmMarket(marketId);
        if (block.timestamp > market.endTime) {
            vm.prank(taker);
            harness.finalizeEqualXSoloAmmMarket(marketId);
            _syncFundedPrincipals();
            return;
        }
        if (modeSeed % 2 == 0) {
            vm.prank(maker);
            harness.cancelEqualXSoloAmmMarket(marketId);
            _syncFundedPrincipals();
        }
    }

    function warpTime(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1 hours, 3 days));
    }

    function _marketActive() internal view returns (bool) {
        if (marketId == 0) return false;
        return harness.getEqualXSoloAmmMarket(marketId).active;
    }

    function _marketLive() internal view returns (bool) {
        if (!_marketActive()) return false;
        return harness.getEqualXSoloAmmStatus(marketId).live;
    }

    function _syncFundedPrincipals() internal {
        fundedPrincipalA = harness.principalOf(1, makerPositionKey);
        fundedPrincipalB = harness.principalOf(2, makerPositionKey);
    }
}

contract EqualXCommunityInvariantHandler is Test {
    EqualXCommunityInvariantHarness public immutable harness;
    PositionNFT public immutable positionNft;
    MockERC20EqualXInvariant public immutable tokenA;
    MockERC20EqualXInvariant public immutable tokenB;
    address public immutable creator;
    address public immutable joiner;
    address public immutable taker;

    uint256 public creatorPositionId;
    bytes32 public creatorPositionKey;
    uint256 public joinerPositionId;
    bytes32 public joinerPositionKey;
    uint256 public marketId;

    uint256 internal constant INITIAL_PRINCIPAL = 750e18;

    constructor(
        EqualXCommunityInvariantHarness harness_,
        PositionNFT positionNft_,
        MockERC20EqualXInvariant tokenA_,
        MockERC20EqualXInvariant tokenB_,
        address creator_,
        address joiner_,
        address taker_
    ) {
        harness = harness_;
        positionNft = positionNft_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        creator = creator_;
        joiner = joiner_;
        taker = taker_;
    }

    function seedInitialState() external {
        _seedPosition(creator, creatorPositionId, creatorPositionKey);
        _seedPosition(joiner, joinerPositionId, joinerPositionKey);

        tokenA.mint(taker, 5_000e18);
        vm.prank(taker);
        tokenA.approve(address(harness), type(uint256).max);

        vm.prank(creator);
        marketId = harness.createEqualXCommunityAmmMarket(
            creatorPositionId,
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
    }

    function createMarket(uint256 reserveSeed, uint256 durationSeed) external {
        if (_marketActive()) return;
        uint256 reserve = bound(reserveSeed, 50e18, 200e18);
        uint64 endTime = uint64(block.timestamp + bound(durationSeed, 1 hours, 5 days));

        vm.prank(creator);
        try harness.createEqualXCommunityAmmMarket(
            creatorPositionId,
            1,
            2,
            reserve,
            reserve,
            uint64(block.timestamp),
            endTime,
            300,
            LibEqualXTypes.FeeAsset.TokenIn,
            LibEqualXTypes.InvariantMode.Volatile
        ) returns (uint256 newMarketId) {
            marketId = newMarketId;
        } catch {}
    }

    function join(uint256 amountSeed) external {
        if (!_marketActive()) return;
        LibEqualXCommunityAmmStorage.CommunityMakerPosition memory maker = harness.getCommunityMaker(marketId, joinerPositionKey);
        if (maker.isParticipant && maker.share > 0) return;

        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory market = harness.getEqualXCommunityAmmMarket(marketId);
        uint256 amountA = bound(amountSeed, 5e18, 50e18);
        uint256 amountB = Math.mulDiv(amountA, market.reserveB, market.reserveA);
        if (amountB == 0) return;

        vm.prank(joiner);
        try harness.joinEqualXCommunityAmmMarket(marketId, joinerPositionId, amountA, amountB) {} catch {}
    }

    function swap(uint256 amountSeed) external {
        if (!_marketLive()) return;
        uint256 amountIn = bound(amountSeed, 1e18, 25e18);

        EqualXCommunityAmmFacet.CommunityAmmSwapPreview memory preview =
            harness.previewEqualXCommunityAmmSwapExactIn(marketId, address(tokenA), amountIn);
        vm.prank(taker);
        uint256 amountOut =
            harness.swapEqualXCommunityAmmExactIn(marketId, address(tokenA), amountIn, amountIn, preview.amountOut, taker);
        assertEq(amountOut, preview.amountOut);
    }

    function claim() external {
        if (marketId == 0) return;
        (uint256 pendingA, uint256 pendingB) = harness.previewEqualXCommunityMakerFees(marketId, joinerPositionKey);
        if (pendingA == 0 && pendingB == 0) return;

        vm.prank(joiner);
        (uint256 feesA, uint256 feesB) = harness.claimEqualXCommunityAmmFees(marketId, joinerPositionId);
        assertEq(feesA, pendingA);
        assertEq(feesB, pendingB);
    }

    function replenishBacking(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actorSeed % 2 == 0 ? creator : joiner;
        uint256 positionId = actorSeed % 2 == 0 ? creatorPositionId : joinerPositionId;
        uint256 amount = bound(amountSeed, 1e18, 100e18);

        vm.startPrank(actor);
        harness.depositToPosition(positionId, 1, amount, amount);
        harness.depositToPosition(positionId, 2, amount, amount);
        vm.stopPrank();
    }

    function leave() external {
        if (marketId == 0) return;
        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory market = harness.getEqualXCommunityAmmMarket(marketId);
        LibEqualXCommunityAmmStorage.CommunityMakerPosition memory maker = harness.getCommunityMaker(marketId, joinerPositionKey);
        if (!maker.isParticipant || maker.share == 0) return;
        if (market.totalShares <= maker.share) return;

        uint256 remainingShares = market.totalShares - maker.share;
        if (market.feeIndexRemainderA >= remainingShares || market.feeIndexRemainderB >= remainingShares) return;

        vm.prank(joiner);
        harness.leaveEqualXCommunityAmmMarket(marketId, joinerPositionId);
        maker = harness.getCommunityMaker(marketId, joinerPositionKey);
        assertEq(maker.share, 0);
        assertFalse(maker.isParticipant);
    }

    function close(uint256 modeSeed) external {
        if (!_marketActive()) return;
        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory market = harness.getEqualXCommunityAmmMarket(marketId);
        if (block.timestamp > market.endTime) {
            vm.prank(taker);
            harness.finalizeEqualXCommunityAmmMarket(marketId);
            return;
        }
        if (modeSeed % 2 == 0) {
            vm.prank(creator);
            harness.cancelEqualXCommunityAmmMarket(marketId);
        }
    }

    function warpTime(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1 hours, 3 days));
    }

    function _seedPosition(address actor, uint256 positionId, bytes32 positionKey) internal {
        vm.startPrank(actor);
        tokenA.approve(address(harness), type(uint256).max);
        tokenB.approve(address(harness), type(uint256).max);
        positionId = harness.mintPosition(1);
        harness.depositToPosition(positionId, 1, INITIAL_PRINCIPAL, INITIAL_PRINCIPAL);
        harness.depositToPosition(positionId, 2, INITIAL_PRINCIPAL, INITIAL_PRINCIPAL);
        vm.stopPrank();

        positionKey = positionNft.getPositionKey(positionId);

        if (actor == creator) {
            creatorPositionId = positionId;
            creatorPositionKey = positionKey;
        } else {
            joinerPositionId = positionId;
            joinerPositionKey = positionKey;
        }
    }

    function _marketActive() internal view returns (bool) {
        if (marketId == 0) return false;
        return harness.getEqualXCommunityAmmMarket(marketId).active;
    }

    function _marketLive() internal view returns (bool) {
        if (!_marketActive()) return false;
        return harness.getEqualXCommunityAmmStatus(marketId).live;
    }
}

contract EqualXCurveInvariantHandler is Test {
    EqualXCurveInvariantHarness public immutable harness;
    PositionNFT public immutable positionNft;
    MockERC20EqualXInvariant public immutable tokenA;
    MockERC20EqualXInvariant public immutable tokenB;
    MockCurveProfileInvariant public immutable customProfile;
    address public immutable maker;
    address public immutable taker;

    uint256 public makerPositionId;
    bytes32 public makerPositionKey;
    uint256 public curveId;

    uint256 internal constant INITIAL_PRINCIPAL = 750e18;

    constructor(
        EqualXCurveInvariantHarness harness_,
        PositionNFT positionNft_,
        MockERC20EqualXInvariant tokenA_,
        MockERC20EqualXInvariant tokenB_,
        MockCurveProfileInvariant customProfile_,
        address maker_,
        address taker_
    ) {
        harness = harness_;
        positionNft = positionNft_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        customProfile = customProfile_;
        maker = maker_;
        taker = taker_;
    }

    function seedInitialState() external {
        vm.startPrank(maker);
        tokenA.approve(address(harness), type(uint256).max);
        tokenB.approve(address(harness), type(uint256).max);
        makerPositionId = harness.mintPosition(1);
        harness.depositToPosition(makerPositionId, 1, INITIAL_PRINCIPAL, INITIAL_PRINCIPAL);
        harness.depositToPosition(makerPositionId, 2, INITIAL_PRINCIPAL, INITIAL_PRINCIPAL);
        vm.stopPrank();

        makerPositionKey = positionNft.getPositionKey(makerPositionId);

        tokenB.mint(taker, 5_000e18);
        vm.prank(taker);
        tokenB.approve(address(harness), type(uint256).max);

        vm.prank(maker);
        curveId = harness.createEqualXCurve(_defaultDescriptor());
    }

    function replenishBacking(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e18, 100e18);

        vm.startPrank(maker);
        harness.depositToPosition(makerPositionId, 1, amount, amount);
        harness.depositToPosition(makerPositionId, 2, amount, amount);
        vm.stopPrank();
    }

    function configureProfile(uint256 modeSeed) external {
        bool approved = modeSeed % 2 == 0;
        address impl = approved ? address(customProfile) : address(0);
        harness.setEqualXCurveProfile(7, impl, approved ? 1 : 0, approved);
    }

    function createCurve(uint256 volumeSeed, uint256 durationSeed) external {
        if (_curveActive()) return;
        LibEqualXCurveEngine.CurveDescriptor memory desc = _defaultDescriptor();
        desc.maxVolume = uint128(bound(volumeSeed, 20e18, 120e18));
        desc.duration = uint64(bound(durationSeed, 1 hours, 5 days));
        desc.startTime = uint64(block.timestamp);

        vm.prank(maker);
        try harness.createEqualXCurve(desc) returns (uint256 newCurveId) {
            curveId = newCurveId;
        } catch {}
    }

    function updateCurve(uint256 startPriceSeed, uint256 modeSeed, uint256 paramSeed) external {
        if (!_curveActive()) return;
        bool customApproved = harness.isEqualXCurveProfileApproved(7);
        bool useCustom = customApproved && modeSeed % 2 == 0;

        LibEqualXCurveEngine.CurveUpdateParams memory params = LibEqualXCurveEngine.CurveUpdateParams({
            startPrice: uint128(bound(startPriceSeed, 1e18, 5e18)),
            endPrice: uint128(bound(startPriceSeed / 2 + 1e18, 1e18, 5e18)),
            startTime: uint64(block.timestamp + bound(modeSeed, 0, 4 hours)),
            duration: uint64(bound(paramSeed, 1 hours, 5 days)),
            updateProfile: useCustom,
            profileId: useCustom ? uint16(7) : uint16(1),
            updateProfileParams: useCustom,
            profileParams: bytes32(bound(paramSeed, 1, 1e18))
        });

        vm.prank(maker);
        harness.updateEqualXCurve(curveId, params);
    }

    function executeCurve(uint256 amountSeed) external {
        if (!_curveLive()) return;
        (, , , LibEqualXCurveStorage.CurveProfileData memory profileData,,) = harness.getEqualXCurveMarket(curveId);
        if (!harness.isEqualXCurveProfileApproved(profileData.profileId)) return;

        uint256 amountIn = bound(amountSeed, 1e18, 20e18);
        try harness.previewEqualXCurveQuote(curveId, amountIn) returns (LibEqualXCurveEngine.CurveExecutionPreview memory preview) {
            vm.prank(taker);
            uint256 amountOut = harness.executeEqualXCurveSwap(
                curveId, amountIn, preview.totalQuote, preview.amountOut, uint64(block.timestamp + 1 days), taker
            );
            assertEq(amountOut, preview.amountOut);
        } catch {}
    }

    function staleExecutionMustRevert(uint256 amountSeed) external {
        if (!_curveLive()) return;
        (, , , LibEqualXCurveStorage.CurveProfileData memory profileData,,) = harness.getEqualXCurveMarket(curveId);
        if (!harness.isEqualXCurveProfileApproved(profileData.profileId)) return;

        uint256 amountIn = bound(amountSeed, 1e18, 20e18);
        try harness.previewEqualXCurveQuote(curveId, amountIn) returns (LibEqualXCurveEngine.CurveExecutionPreview memory preview) {
            (uint32 generation, bytes32 commitment) = harness.getEqualXCurveCommitment(curveId);
            vm.expectRevert();
            vm.prank(taker);
            harness.executeEqualXCurveSwap(
                curveId, amountIn, preview.totalQuote, preview.amountOut, uint64(block.timestamp + 1 days), taker, generation + 1, commitment
            );
        } catch {}
    }

    function revokedPreviewMustRevert(uint256 amountSeed) external {
        if (!_curveActive()) return;
        (, , , LibEqualXCurveStorage.CurveProfileData memory profileData,,) = harness.getEqualXCurveMarket(curveId);
        if (harness.isEqualXCurveProfileApproved(profileData.profileId)) return;

        uint256 amountIn = bound(amountSeed, 1e18, 20e18);
        vm.expectRevert();
        harness.quoteEqualXCurveExactIn(curveId, amountIn);
    }

    function closeCurve(uint256 modeSeed) external {
        if (!_curveActive()) return;
        EqualXViewFacet.EqualXCurveStatus memory status = harness.getEqualXCurveStatus(curveId);
        if (status.expired) {
            vm.prank(taker);
            harness.expireEqualXCurve(curveId);
            return;
        }
        if (modeSeed % 2 == 0) {
            vm.prank(maker);
            harness.cancelEqualXCurve(curveId);
        }
    }

    function warpTime(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1 hours, 3 days));
    }

    function _defaultDescriptor() internal view returns (LibEqualXCurveEngine.CurveDescriptor memory desc) {
        desc = LibEqualXCurveEngine.CurveDescriptor({
            makerPositionKey: makerPositionKey,
            makerPositionId: makerPositionId,
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

    function _curveActive() internal view returns (bool) {
        if (curveId == 0) return false;
        return harness.getEqualXCurveStatus(curveId).active;
    }

    function _curveLive() internal view returns (bool) {
        if (!_curveActive()) return false;
        return harness.getEqualXCurveStatus(curveId).live;
    }
}

contract EqualXSoloInvariantTest is StdInvariant, Test {
    EqualXSoloInvariantHarness internal harness;
    EqualXSoloInvariantHandler internal handler;
    PositionNFT internal positionNft;
    MockERC20EqualXInvariant internal tokenA;
    MockERC20EqualXInvariant internal tokenB;

    address internal maker = makeAddr("solo-maker");
    address internal taker = makeAddr("solo-taker");

    function setUp() public {
        harness = new EqualXSoloInvariantHarness();
        harness.setOwner(address(this));
        harness.setTimelock(makeAddr("timelock"));
        harness.setTreasury(makeAddr("treasury"));
        harness.setFeeSplits(1000, 7000);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        tokenA = new MockERC20EqualXInvariant("Token A", "TKA", 18);
        tokenB = new MockERC20EqualXInvariant("Token B", "TKB", 18);
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(tokenA), _poolConfig(), actionFees);
        harness.initPoolWithActionFees(2, address(tokenB), _poolConfig(), actionFees);
        tokenA.mint(maker, 20_000e18);
        tokenB.mint(maker, 20_000e18);

        handler = new EqualXSoloInvariantHandler(harness, positionNft, tokenA, tokenB, maker, taker);
        handler.seedInitialState();

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.createMarket.selector;
        selectors[1] = handler.swap.selector;
        selectors[2] = handler.close.selector;
        selectors[3] = handler.replenishBacking.selector;
        selectors[4] = handler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SoloReserveAndBackingCorrectness() public view {
        uint256 marketId = handler.marketId();
        if (marketId == 0) return;

        LibEqualXSoloAmmStorage.SoloAmmMarket memory market = harness.getEqualXSoloAmmMarket(marketId);
        bytes32 makerKey = handler.makerPositionKey();
        if (market.active) {
            assertEq(harness.encumberedCapitalOf(makerKey, market.poolIdA), market.reserveA);
            assertEq(harness.encumberedCapitalOf(makerKey, market.poolIdB), market.reserveB);
            assertEq(harness.principalOf(1, makerKey), handler.fundedPrincipalA());
            assertEq(harness.principalOf(2, makerKey), handler.fundedPrincipalB());
        } else if (market.finalized) {
            assertFalse(market.active);
            assertEq(harness.encumberedCapitalOf(makerKey, market.poolIdA), 0);
            assertEq(harness.encumberedCapitalOf(makerKey, market.poolIdB), 0);
        }
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

contract EqualXCommunityInvariantTest is StdInvariant, Test {
    EqualXCommunityInvariantHarness internal harness;
    EqualXCommunityInvariantHandler internal handler;
    PositionNFT internal positionNft;
    MockERC20EqualXInvariant internal tokenA;
    MockERC20EqualXInvariant internal tokenB;

    address internal creator = makeAddr("community-creator");
    address internal joiner = makeAddr("community-joiner");
    address internal taker = makeAddr("community-taker");

    function setUp() public {
        harness = new EqualXCommunityInvariantHarness();
        harness.setOwner(address(this));
        harness.setTimelock(makeAddr("timelock"));
        harness.setTreasury(makeAddr("treasury"));
        harness.setFeeSplits(1000, 7000);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        tokenA = new MockERC20EqualXInvariant("Token A", "TKA", 18);
        tokenB = new MockERC20EqualXInvariant("Token B", "TKB", 18);
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(tokenA), _poolConfig(), actionFees);
        harness.initPoolWithActionFees(2, address(tokenB), _poolConfig(), actionFees);
        tokenA.mint(creator, 20_000e18);
        tokenB.mint(creator, 20_000e18);
        tokenA.mint(joiner, 20_000e18);
        tokenB.mint(joiner, 20_000e18);

        handler = new EqualXCommunityInvariantHandler(harness, positionNft, tokenA, tokenB, creator, joiner, taker);
        handler.seedInitialState();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.createMarket.selector;
        selectors[1] = handler.join.selector;
        selectors[2] = handler.swap.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.leave.selector;
        selectors[5] = handler.close.selector;
        selectors[6] = handler.replenishBacking.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = handler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors2}));
    }

    function invariant_CommunityFeeIndexAndShareAccountingCorrectness() public view {
        uint256 marketId = handler.marketId();
        if (marketId == 0) return;

        LibEqualXCommunityAmmStorage.CommunityAmmMarket memory market = harness.getEqualXCommunityAmmMarket(marketId);
        LibEqualXCommunityAmmStorage.CommunityMakerPosition memory creatorMaker =
            harness.getCommunityMaker(marketId, handler.creatorPositionKey());
        LibEqualXCommunityAmmStorage.CommunityMakerPosition memory joinerMaker =
            harness.getCommunityMaker(marketId, handler.joinerPositionKey());

        uint256 participantCount;
        if (creatorMaker.isParticipant && creatorMaker.share > 0) ++participantCount;
        if (joinerMaker.isParticipant && joinerMaker.share > 0) ++participantCount;

        assertEq(creatorMaker.share + joinerMaker.share, market.totalShares);
        assertEq(participantCount, market.makerCount);

        if (market.totalShares > 0) {
            assertLt(market.feeIndexRemainderA, market.totalShares);
            assertLt(market.feeIndexRemainderB, market.totalShares);
        } else {
            assertTrue(market.finalized);
            assertFalse(market.active);
        }
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

contract EqualXCurveInvariantTest is StdInvariant, Test {
    EqualXCurveInvariantHarness internal harness;
    EqualXCurveInvariantHandler internal handler;
    PositionNFT internal positionNft;
    MockERC20EqualXInvariant internal tokenA;
    MockERC20EqualXInvariant internal tokenB;
    MockCurveProfileInvariant internal customProfile;

    address internal maker = makeAddr("curve-maker");
    address internal taker = makeAddr("curve-taker");

    function setUp() public {
        harness = new EqualXCurveInvariantHarness();
        harness.setOwner(address(this));
        harness.setTimelock(makeAddr("timelock"));
        harness.setTreasury(makeAddr("treasury"));
        harness.setFeeSplits(1000, 7000);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        tokenA = new MockERC20EqualXInvariant("Token A", "TKA", 18);
        tokenB = new MockERC20EqualXInvariant("Token B", "TKB", 18);
        customProfile = new MockCurveProfileInvariant();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(tokenA), _poolConfig(), actionFees);
        harness.initPoolWithActionFees(2, address(tokenB), _poolConfig(), actionFees);
        tokenA.mint(maker, 20_000e18);
        tokenB.mint(maker, 20_000e18);

        handler = new EqualXCurveInvariantHandler(harness, positionNft, tokenA, tokenB, customProfile, maker, taker);
        harness.setOwner(address(handler));
        handler.seedInitialState();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.configureProfile.selector;
        selectors[1] = handler.createCurve.selector;
        selectors[2] = handler.updateCurve.selector;
        selectors[3] = handler.executeCurve.selector;
        selectors[4] = handler.staleExecutionMustRevert.selector;
        selectors[5] = handler.revokedPreviewMustRevert.selector;
        selectors[6] = handler.closeCurve.selector;
        selectors[7] = handler.replenishBacking.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = handler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors2}));
    }

    function invariant_CurveGenerationVolumeAndProfileRegistrySafety() public {
        assertTrue(harness.isEqualXCurveProfileApproved(1));

        uint256 curveId = handler.curveId();
        if (curveId == 0) return;

        (
            LibEqualXCurveStorage.CurveMarket memory market,
            LibEqualXCurveStorage.CurveData memory data,
            ,
            LibEqualXCurveStorage.CurveProfileData memory profileData,
            LibEqualXCurveStorage.CurveImmutables memory immutables,
            bool baseIsA
        ) = harness.getEqualXCurveMarket(curveId);
        uint256 basePoolId = baseIsA ? data.poolIdA : data.poolIdB;
        uint256 locked = harness.lockedCapitalOf(data.makerPositionKey, basePoolId);

        assertLe(market.remainingVolume, immutables.maxVolume);
        if (market.active) {
            assertGt(market.generation, 0);
            assertTrue(market.commitment != bytes32(0));
            assertEq(locked, market.remainingVolume);
        } else {
            assertEq(locked, 0);
        }

        if (market.active && !harness.isEqualXCurveProfileApproved(profileData.profileId)) {
            vm.expectRevert();
            harness.quoteEqualXCurveExactIn(curveId, 1e18);
        }
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
