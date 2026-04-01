// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
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
import {PositionNFT} from "src/nft/PositionNFT.sol";

contract MockERC20OptionInvariant is ERC20 {
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

contract OptionsInvariantHarness is OptionTokenAdminFacet, OptionTokenViewFacet, OptionsFacet, OptionsViewFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
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
        if (pool.userPrincipal[positionKey] == 0 && principal > 0) {
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

    function availablePrincipalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        uint256 principal = LibAppStorage.s().pools[pid].userPrincipal[positionKey];
        uint256 totalEncumbrance = LibEncumbrance.total(positionKey, pid);
        return principal > totalEncumbrance ? principal - totalEncumbrance : 0;
    }

    function lockedCapitalOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).lockedCapital;
    }

    function activeCreditEncumbrancePrincipalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[positionKey].principal;
    }

    function activeCreditPrincipalTotalOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function accrueActiveCreditForTest(uint256 pid, uint256 amount, bytes32 source) external {
        LibFeeRouter.accrueActiveCredit(pid, amount, source, amount);
    }
}

contract OptionsInvariantHandler is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant STRIKE_PRICE = 2e18;
    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant STRIKE_PID = 2;
    uint256 internal constant MAX_TRACKED_SERIES = 32;

    OptionsInvariantHarness public immutable harness;
    PositionNFT public immutable positionNft;
    MockERC20OptionInvariant public immutable underlying;
    MockERC20OptionInvariant public immutable strike;
    address public immutable maker;
    uint256 public immutable makerPositionId;
    bytes32 public immutable makerPositionKey;

    uint256[] internal seriesIds;

    constructor(
        OptionsInvariantHarness harness_,
        PositionNFT positionNft_,
        MockERC20OptionInvariant underlying_,
        MockERC20OptionInvariant strike_,
        address maker_,
        uint256 makerPositionId_,
        bytes32 makerPositionKey_
    ) {
        harness = harness_;
        positionNft = positionNft_;
        underlying = underlying_;
        strike = strike_;
        maker = maker_;
        makerPositionId = makerPositionId_;
        makerPositionKey = makerPositionKey_;
    }

    function createCallSeries(uint256 contractsSeed, uint256 contractSizeSeed, uint256 expirySeed) external {
        if (seriesIds.length >= MAX_TRACKED_SERIES) return;

        uint256 contractSize = bound(contractSizeSeed, 1, 3);
        uint256 available = harness.availablePrincipalOf(UNDERLYING_PID, makerPositionKey);
        uint256 maxContracts = available / (contractSize * UNIT);
        if (maxContracts == 0) return;

        uint256 wholeContracts = bound(contractsSeed, 1, _min(maxContracts, 5));
        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(
            LibOptionsStorage.CreateOptionSeriesParams({
                positionId: makerPositionId,
                underlyingPoolId: UNDERLYING_PID,
                strikePoolId: STRIKE_PID,
                strikePrice: STRIKE_PRICE,
                expiry: uint64(block.timestamp + bound(expirySeed, 2 days, 14 days)),
                totalSize: wholeContracts * UNIT,
                contractSize: contractSize,
                isCall: true,
                isAmerican: true
            })
        );
        seriesIds.push(seriesId);
    }

    function createPutSeries(uint256 contractsSeed, uint256 contractSizeSeed, uint256 expirySeed) external {
        if (seriesIds.length >= MAX_TRACKED_SERIES) return;

        uint256 contractSize = bound(contractSizeSeed, 1, 3);
        uint256 available = harness.availablePrincipalOf(STRIKE_PID, makerPositionKey);
        uint256 maxContracts = available / (contractSize * 2e6);
        if (maxContracts == 0) return;

        uint256 wholeContracts = bound(contractsSeed, 1, _min(maxContracts, 5));
        vm.prank(maker);
        uint256 seriesId = harness.createOptionSeries(
            LibOptionsStorage.CreateOptionSeriesParams({
                positionId: makerPositionId,
                underlyingPoolId: UNDERLYING_PID,
                strikePoolId: STRIKE_PID,
                strikePrice: STRIKE_PRICE,
                expiry: uint64(block.timestamp + bound(expirySeed, 2 days, 14 days)),
                totalSize: wholeContracts * UNIT,
                contractSize: contractSize,
                isCall: false,
                isAmerican: true
            })
        );
        seriesIds.push(seriesId);
    }

    function exerciseSeries(uint256 indexSeed, uint256 contractsSeed) external {
        uint256 len = seriesIds.length;
        if (len == 0) return;

        uint256 seriesId = seriesIds[indexSeed % len];
        LibOptionsStorage.OptionSeries memory series = harness.getOptionSeries(seriesId);
        if (series.reclaimed || series.remainingSize == 0 || block.timestamp >= series.expiry) return;

        uint256 maxContracts = series.remainingSize / UNIT;
        if (maxContracts == 0) return;

        uint256 wholeContracts = bound(contractsSeed, 1, maxContracts);
        uint256 amount = wholeContracts * UNIT;
        uint256 payment = harness.previewExercisePayment(seriesId, amount);
        if (payment == 0) return;

        vm.prank(maker);
        harness.exerciseOptions(seriesId, amount, maker, payment, 0);
    }

    function reclaimSeries(uint256 indexSeed) external {
        uint256 len = seriesIds.length;
        if (len == 0) return;

        uint256 seriesId = seriesIds[indexSeed % len];
        LibOptionsStorage.OptionSeries memory series = harness.getOptionSeries(seriesId);
        if (series.reclaimed) return;

        if (block.timestamp <= series.expiry) {
            vm.warp(series.expiry + 1);
        }

        vm.prank(maker);
        harness.reclaimOptions(seriesId);
    }

    function accrueActiveCredit(uint256 poolSeed, uint256 amountSeed) external {
        uint256 pid = poolSeed % 2 == 0 ? UNDERLYING_PID : STRIKE_PID;
        uint256 amount = pid == UNDERLYING_PID ? bound(amountSeed, 1e15, 5e18) : bound(amountSeed, 1, 5e6);
        harness.accrueActiveCreditForTest(pid, amount, keccak256(abi.encodePacked("options-invariant", pid, amount)));
    }

    function warpTime(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1 hours, 5 days));
    }

    function seriesCount() external view returns (uint256) {
        return seriesIds.length;
    }

    function seriesIdAt(uint256 index) external view returns (uint256) {
        return seriesIds[index];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract OptionsInvariantTest is StdInvariant, Test {
    string internal constant BASE_URI = "ipfs://equalfi/options";
    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant STRIKE_PID = 2;

    OptionsInvariantHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20OptionInvariant internal underlying;
    MockERC20OptionInvariant internal strike;
    OptionsInvariantHandler internal handler;

    address internal maker = makeAddr("maker");
    bytes32 internal makerPositionKey;
    uint256 internal makerPositionId;

    function setUp() public {
        harness = new OptionsInvariantHarness();
        harness.setOwner(address(this));

        positionNft = new PositionNFT();
        positionNft.setMinter(address(this));
        harness.setPositionNFT(address(positionNft));

        underlying = new MockERC20OptionInvariant("Underlying", "UND", 18);
        strike = new MockERC20OptionInvariant("Strike", "STK", 6);

        harness.setPool(UNDERLYING_PID, address(underlying));
        harness.setPool(STRIKE_PID, address(strike));

        makerPositionId = positionNft.mint(maker, UNDERLYING_PID);
        makerPositionKey = positionNft.getPositionKey(makerPositionId);
        harness.joinPool(makerPositionKey, UNDERLYING_PID);
        harness.joinPool(makerPositionKey, STRIKE_PID);
        harness.seedPrincipal(UNDERLYING_PID, makerPositionKey, 500e18);
        harness.seedPrincipal(STRIKE_PID, makerPositionKey, 2_000e6);

        underlying.mint(address(harness), 500e18);
        strike.mint(address(harness), 2_000e6);
        underlying.mint(maker, 10_000e18);
        strike.mint(maker, 10_000e6);

        vm.startPrank(maker);
        underlying.approve(address(harness), type(uint256).max);
        strike.approve(address(harness), type(uint256).max);
        vm.stopPrank();

        harness.deployOptionToken(BASE_URI, address(this));

        handler = new OptionsInvariantHandler(
            harness, positionNft, underlying, strike, maker, makerPositionId, makerPositionKey
        );

        targetContract(address(handler));
    }

    function invariant_LockedCapitalTracksSeriesCollateralAcrossPools() public view {
        (uint256 expectedUnderlyingLocked, uint256 expectedStrikeLocked) = _aggregateSeriesCollateral();

        assertEq(harness.lockedCapitalOf(makerPositionKey, UNDERLYING_PID), expectedUnderlyingLocked);
        assertEq(harness.lockedCapitalOf(makerPositionKey, STRIKE_PID), expectedStrikeLocked);
    }

    function invariant_ActiveCreditEncumbranceTracksOptionLockedCapital() public view {
        (uint256 expectedUnderlyingLocked, uint256 expectedStrikeLocked) = _aggregateSeriesCollateral();

        assertEq(harness.activeCreditEncumbrancePrincipalOf(UNDERLYING_PID, makerPositionKey), expectedUnderlyingLocked);
        assertEq(harness.activeCreditEncumbrancePrincipalOf(STRIKE_PID, makerPositionKey), expectedStrikeLocked);
        assertEq(harness.activeCreditPrincipalTotalOf(UNDERLYING_PID), expectedUnderlyingLocked);
        assertEq(harness.activeCreditPrincipalTotalOf(STRIKE_PID), expectedStrikeLocked);
    }

    function invariant_ProductiveCollateralViewsStayAlignedWithSeriesAndPoolState() public view {
        LibOptionsStorage.ProductiveCollateralView[] memory views =
            harness.getOptionPositionProductiveCollateral(makerPositionId);
        uint256[] memory liveSeriesIds = harness.getOptionSeriesIdsByPosition(makerPositionId);
        assertEq(views.length, liveSeriesIds.length);

        for (uint256 i = 0; i < views.length; i++) {
            LibOptionsStorage.ProductiveCollateralView memory collateralView = views[i];
            LibOptionsStorage.OptionSeries memory series = harness.getOptionSeries(collateralView.seriesId);

            assertEq(collateralView.makerPositionKey, makerPositionKey);
            assertEq(collateralView.makerPositionId, makerPositionId);
            assertEq(collateralView.collateralLocked, series.collateralLocked);
            assertEq(collateralView.remainingSize, series.remainingSize);
            assertEq(collateralView.isCall, series.isCall);
            assertEq(collateralView.reclaimed, series.reclaimed);
            assertEq(
                collateralView.claimableYield,
                collateralView.accruedYield + collateralView.pendingActiveCreditYield + collateralView.pendingFeeYield
            );
        }
    }

    function _aggregateSeriesCollateral() internal view returns (uint256 expectedUnderlyingLocked, uint256 expectedStrikeLocked) {
        uint256 count = handler.seriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIdAt(i);
            LibOptionsStorage.OptionSeries memory series = harness.getOptionSeries(seriesId);
            if (series.isCall) {
                expectedUnderlyingLocked += series.collateralLocked;
            } else {
                expectedStrikeLocked += series.collateralLocked;
            }

            if (series.remainingSize == 0 || series.reclaimed) {
                assertEq(series.collateralLocked, 0);
            }
        }
    }
}
