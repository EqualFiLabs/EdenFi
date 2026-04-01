// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "src/libraries/LibFeeRouter.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {PoolMembershipRequired} from "src/libraries/Errors.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

contract MockERC20Option is ERC20 {
    uint8 internal immutable _customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }
}

contract OptionsHarness is OptionTokenAdminFacet, OptionTokenViewFacet, OptionsFacet, OptionsViewFacet {
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

    function setPool(uint256 pid, address underlying) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.initialized = true;
        pool.underlying = underlying;
        pool.lastMaintenanceTimestamp = uint64(block.timestamp);
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function seedPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        uint256 currentPrincipal = pool.userPrincipal[positionKey];
        if (currentPrincipal == 0 && principal > 0) {
            pool.userCount += 1;
        }
        pool.userPrincipal[positionKey] = principal;
        pool.totalDeposits = principal;
        pool.trackedBalance = principal;
        pool.userFeeIndex[positionKey] = pool.feeIndex;
        pool.userMaintenanceIndex[positionKey] = pool.maintenanceIndex;
        LibActiveCreditIndex.settle(pid, positionKey);
        LibFeeIndex.settle(pid, positionKey);
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function lockedCollateral(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).lockedCapital;
    }

    function activeCreditEncumbrancePrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[positionKey].principal;
    }

    function pendingActiveCreditYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibActiveCreditIndex.pendingActiveCredit(pid, positionKey);
    }

    function pendingFeeYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        uint256 accrued = LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
        uint256 total = LibFeeIndex.pendingYield(pid, positionKey);
        return total > accrued ? total - accrued : 0;
    }

    function accruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function accrueActiveCreditForTest(uint256 pid, uint256 amount, bytes32 source) external {
        LibFeeRouter.accrueActiveCredit(pid, amount, source, amount);
    }
}

contract OptionsFacetTest is Test {
    string internal constant BASE_URI = "ipfs://equalfi/options";
    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant STRIKE_PID = 2;
    uint256 internal constant STRIKE_PRICE = 2e18;

    OptionsHarness internal harness;
    MockERC20Option internal underlying;
    MockERC20Option internal strike;
    PositionNFT internal positionNft;
    OptionToken internal optionToken;

    address internal owner = makeAddr("owner");
    address internal maker = makeAddr("maker");
    address internal holder = makeAddr("holder");
    address internal operator = makeAddr("operator");
    bytes32 internal makerPositionKey;
    uint256 internal makerPositionId;

    function setUp() public {
        harness = new OptionsHarness();
        harness.setOwner(owner);

        underlying = new MockERC20Option("Underlying", "UND", 18);
        strike = new MockERC20Option("Strike", "STK", 6);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));
        harness.setPositionNFT(address(positionNft));

        harness.setPool(UNDERLYING_PID, address(underlying));
        harness.setPool(STRIKE_PID, address(strike));

        makerPositionId = positionNft.mint(maker, UNDERLYING_PID);
        makerPositionKey = positionNft.getPositionKey(makerPositionId);
        harness.joinPool(makerPositionKey, UNDERLYING_PID);
        harness.joinPool(makerPositionKey, STRIKE_PID);
        harness.seedPrincipal(UNDERLYING_PID, makerPositionKey, 20e18);
        harness.seedPrincipal(STRIKE_PID, makerPositionKey, 100e6);
        underlying.mint(address(harness), 20e18);
        strike.mint(address(harness), 100e6);

        vm.prank(owner);
        address tokenAddress = harness.deployOptionToken(BASE_URI, owner);
        optionToken = OptionToken(tokenAddress);
    }

    function test_CreateOptionSeries_LocksCollateralMintsClaimsAndIndexesPosition() public {
        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(_defaultParams(5e18, true, true));

        LibOptionsStorage.OptionSeries memory series = harness.getOptionSeries(seriesId);
        assertEq(series.makerPositionId, makerPositionId);
        assertEq(series.totalSize, 5e18);
        assertEq(series.remainingSize, 5e18);
        assertEq(series.contractSize, 1);
        assertEq(series.collateralLocked, 5e18);
        assertTrue(series.isCall);
        assertEq(optionToken.balanceOf(maker, seriesId), 5e18);
        assertEq(harness.lockedCollateral(UNDERLYING_PID, makerPositionKey), 5e18);

        uint256[] memory ids = harness.getOptionSeriesIdsByPosition(makerPositionId);
        assertEq(ids.length, 1);
        assertEq(ids[0], seriesId);
    }

    function test_ExerciseCallAndReclaim_RemainOnCurrentSubstrate() public {
        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(_defaultParams(5e18, true, true));

        uint256 exercised = 2e18;
        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, exercised, "");

        uint256 payment = harness.previewExercisePayment(seriesId, exercised);
        assertEq(payment, 4e6);

        strike.mint(holder, payment);
        vm.prank(holder);
        strike.approve(address(harness), payment);

        uint256 makerUnderlyingBefore = harness.principalOf(UNDERLYING_PID, makerPositionKey);
        uint256 makerStrikeBefore = harness.principalOf(STRIKE_PID, makerPositionKey);

        vm.prank(holder);
        uint256 paid = harness.exerciseOptions(seriesId, exercised, holder, payment, exercised);

        assertEq(paid, payment);
        assertEq(underlying.balanceOf(holder), exercised);
        assertEq(harness.principalOf(UNDERLYING_PID, makerPositionKey), makerUnderlyingBefore - exercised);
        assertEq(harness.principalOf(STRIKE_PID, makerPositionKey), makerStrikeBefore + payment);
        assertEq(harness.lockedCollateral(UNDERLYING_PID, makerPositionKey), 3e18);

        vm.warp(block.timestamp + 2 days);
        vm.prank(maker);
        harness.reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory series = harness.getOptionSeries(seriesId);
        assertTrue(series.reclaimed);
        assertEq(series.remainingSize, 0);
        assertEq(harness.lockedCollateral(UNDERLYING_PID, makerPositionKey), 0);

        uint256 makerClaims = optionToken.balanceOf(maker, seriesId);
        vm.prank(operator);
        harness.burnReclaimedOptionsClaims(maker, seriesId, makerClaims / 2);
        assertEq(optionToken.balanceOf(maker, seriesId), makerClaims / 2);
    }

    function test_ExercisePut_TransfersStrikeAndCreditsUnderlyingPrincipal() public {
        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(_defaultParams(3e18, false, true));

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        uint256 payment = harness.previewExercisePayment(seriesId, 1e18);
        assertEq(payment, 1e18);

        underlying.mint(holder, payment);
        vm.prank(holder);
        underlying.approve(address(harness), payment);

        uint256 makerUnderlyingBefore = harness.principalOf(UNDERLYING_PID, makerPositionKey);
        uint256 makerStrikeBefore = harness.principalOf(STRIKE_PID, makerPositionKey);

        vm.prank(holder);
        uint256 paid = harness.exerciseOptions(seriesId, 1e18, holder, payment, 2e6);

        assertEq(paid, payment);
        assertEq(strike.balanceOf(holder), 2e6);
        assertEq(harness.principalOf(UNDERLYING_PID, makerPositionKey), makerUnderlyingBefore + payment);
        assertEq(harness.principalOf(STRIKE_PID, makerPositionKey), makerStrikeBefore - 2e6);
        assertEq(harness.lockedCollateral(STRIKE_PID, makerPositionKey), 4e6);
    }

    function test_EuropeanWindow_UsesConfiguredTolerance() public {
        vm.prank(owner);
        harness.setEuropeanTolerance(100);

        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(_defaultParams(1e18, true, false));

        vm.prank(maker);
        optionToken.safeTransferFrom(maker, holder, seriesId, 1e18, "");

        uint256 payment = harness.previewExercisePayment(seriesId, 1e18);
        strike.mint(holder, payment);
        vm.prank(holder);
        strike.approve(address(harness), payment);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_ExerciseWindowClosed.selector, seriesId));
        harness.exerciseOptions(seriesId, 1e18, holder, payment, 0);

        vm.warp(block.timestamp + 1 days - 50);
        vm.prank(holder);
        harness.exerciseOptions(seriesId, 1e18, holder, payment, 0);
    }

    function test_ProductiveCollateralView_ShowsLockedCollateralStillAccruingActiveCredit() public {
        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(_defaultParams(5e18, true, true));

        vm.warp(block.timestamp + 1 days + 1);
        harness.accrueActiveCreditForTest(UNDERLYING_PID, 1e18, keccak256("options-active-credit"));

        LibOptionsStorage.ProductiveCollateralView memory viewData =
            harness.getOptionSeriesProductiveCollateral(seriesId);

        assertEq(viewData.seriesId, seriesId);
        assertEq(viewData.collateralPoolId, UNDERLYING_PID);
        assertEq(viewData.collateralAsset, address(underlying));
        assertEq(viewData.collateralLocked, 5e18);
        assertEq(viewData.remainingSize, 5e18);
        assertEq(viewData.settledPrincipal, 20e18);
        assertEq(viewData.availablePrincipal, 15e18);
        assertEq(viewData.totalEncumbrance, 5e18);
        assertEq(viewData.activeCreditEncumbrancePrincipal, 5e18);
        assertEq(viewData.pendingActiveCreditYield, harness.pendingActiveCreditYield(UNDERLYING_PID, makerPositionKey));
        assertEq(viewData.pendingFeeYield, harness.pendingFeeYield(UNDERLYING_PID, makerPositionKey));
        assertEq(viewData.accruedYield, harness.accruedYield(UNDERLYING_PID, makerPositionKey));
        assertEq(
            viewData.claimableYield,
            viewData.accruedYield + viewData.pendingActiveCreditYield + viewData.pendingFeeYield
        );
        assertGt(viewData.pendingActiveCreditYield, 0);
    }

    function test_ProductiveCollateralViews_ByPosition_ReturnActiveSeriesOnly() public {
        vm.startPrank(maker);
        uint256 activeSeriesId = harness.createOptionSeries(_defaultParams(3e18, true, true));
        uint256 reclaimableSeriesId = harness.createOptionSeries(_defaultParams(2e18, false, true));
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.prank(maker);
        harness.reclaimOptions(reclaimableSeriesId);

        LibOptionsStorage.ProductiveCollateralView[] memory byPosition =
            harness.getOptionPositionProductiveCollateral(makerPositionId);
        assertEq(byPosition.length, 1);
        assertEq(byPosition[0].seriesId, activeSeriesId);

        LibOptionsStorage.ProductiveCollateralView memory reclaimedView =
            harness.getOptionSeriesProductiveCollateral(reclaimableSeriesId);
        assertTrue(reclaimedView.reclaimed);
        assertEq(reclaimedView.collateralLocked, 0);
    }

    function test_RevertWhen_CreateSeriesWithoutRequiredPoolMembership() public {
        uint256 secondPositionId = positionNft.mint(maker, UNDERLYING_PID);
        bytes32 secondKey = positionNft.getPositionKey(secondPositionId);
        harness.joinPool(secondKey, UNDERLYING_PID);
        harness.seedPrincipal(UNDERLYING_PID, secondKey, 5e18);

        LibOptionsStorage.CreateOptionSeriesParams memory params = LibOptionsStorage.CreateOptionSeriesParams({
            positionId: secondPositionId,
            underlyingPoolId: UNDERLYING_PID,
            strikePoolId: STRIKE_PID,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: 1e18,
            contractSize: 1,
            isCall: true,
            isAmerican: true
        });

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, secondKey, STRIKE_PID));
        harness.createOptionSeries(params);
    }

    function _defaultParams(uint256 totalSize, bool isCall, bool isAmerican)
        internal
        view
        returns (LibOptionsStorage.CreateOptionSeriesParams memory)
    {
        return LibOptionsStorage.CreateOptionSeriesParams({
            positionId: makerPositionId,
            underlyingPoolId: UNDERLYING_PID,
            strikePoolId: STRIKE_PID,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: totalSize,
            contractSize: 1,
            isCall: isCall,
            isAmerican: isAmerican
        });
    }
}
