// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";

import {LaunchFixture, MockERC20Launch} from "test/utils/LaunchFixture.t.sol";
import {ProtocolTestSupportFacet} from "test/utils/ProtocolTestSupport.sol";

contract OptionsInvariantHandler is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant STRIKE_PRICE = 2e18;
    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant STRIKE_PID = 2;
    uint256 internal constant MAX_TRACKED_SERIES = 64;

    address public immutable diamond;
    ProtocolTestSupportFacet public immutable testSupport;
    OptionToken public immutable optionToken;
    MockERC20Launch public immutable underlying;
    MockERC20Launch public immutable strike;

    address public callMaker;
    address public putMaker;
    address public holderA;
    address public holderB;
    uint256 public callMakerPositionId;
    uint256 public putMakerPositionId;
    bytes32 public callMakerPositionKey;
    bytes32 public putMakerPositionKey;

    uint256[] internal trackedSeriesIds;
    mapping(uint256 => uint256) internal issuedBySeries;
    mapping(uint256 => uint256) internal burnedBySeries;
    mapping(uint256 => bool) internal reclaimedBySeries;

    constructor(
        address diamond_,
        ProtocolTestSupportFacet testSupport_,
        OptionToken optionToken_,
        MockERC20Launch underlying_,
        MockERC20Launch strike_
    ) {
        diamond = diamond_;
        testSupport = testSupport_;
        optionToken = optionToken_;
        underlying = underlying_;
        strike = strike_;
    }

    function configureParticipants(
        address callMaker_,
        address putMaker_,
        address holderA_,
        address holderB_,
        uint256 callMakerPositionId_,
        uint256 putMakerPositionId_,
        bytes32 callMakerPositionKey_,
        bytes32 putMakerPositionKey_
    ) external {
        callMaker = callMaker_;
        putMaker = putMaker_;
        holderA = holderA_;
        holderB = holderB_;
        callMakerPositionId = callMakerPositionId_;
        putMakerPositionId = putMakerPositionId_;
        callMakerPositionKey = callMakerPositionKey_;
        putMakerPositionKey = putMakerPositionKey_;
    }

    function createCallSeries(uint256 contractsSeed, uint256 contractSizeSeed, uint256 expirySeed) external {
        if (trackedSeriesIds.length >= MAX_TRACKED_SERIES) return;

        uint256 contractSize = bound(contractSizeSeed, 1, 3);
        uint256 available = _availablePrincipal(callMakerPositionId, callMakerPositionKey, UNDERLYING_PID);
        uint256 unitCollateral = contractSize * UNIT;
        uint256 maxContracts = available / unitCollateral;
        if (maxContracts == 0) return;

        uint256 wholeContracts = bound(contractsSeed, 1, _min(maxContracts, 5));
        uint256 totalSize = wholeContracts * UNIT;
        uint64 expiry = uint64(block.timestamp + bound(expirySeed, 2 days, 14 days));

        vm.prank(callMaker);
        uint256 seriesId = OptionsFacet(diamond).createOptionSeries(
            LibOptionsStorage.CreateOptionSeriesParams({
                positionId: callMakerPositionId,
                underlyingPoolId: UNDERLYING_PID,
                strikePoolId: STRIKE_PID,
                strikePrice: STRIKE_PRICE,
                expiry: expiry,
                totalSize: totalSize,
                contractSize: contractSize,
                isCall: true,
                isAmerican: true
            })
        );

        trackedSeriesIds.push(seriesId);
        issuedBySeries[seriesId] = totalSize;
    }

    function createPutSeries(uint256 contractsSeed, uint256 contractSizeSeed, uint256 expirySeed) external {
        if (trackedSeriesIds.length >= MAX_TRACKED_SERIES) return;

        uint256 contractSize = bound(contractSizeSeed, 1, 3);
        uint256 available = _availablePrincipal(putMakerPositionId, putMakerPositionKey, STRIKE_PID);
        uint256 unitCollateral = _normalizeStrikeAmount(contractSize * UNIT);
        uint256 maxContracts = available / unitCollateral;
        if (maxContracts == 0) return;

        uint256 wholeContracts = bound(contractsSeed, 1, _min(maxContracts, 5));
        uint256 totalSize = wholeContracts * UNIT;
        uint64 expiry = uint64(block.timestamp + bound(expirySeed, 2 days, 14 days));

        vm.prank(putMaker);
        uint256 seriesId = OptionsFacet(diamond).createOptionSeries(
            LibOptionsStorage.CreateOptionSeriesParams({
                positionId: putMakerPositionId,
                underlyingPoolId: UNDERLYING_PID,
                strikePoolId: STRIKE_PID,
                strikePrice: STRIKE_PRICE,
                expiry: expiry,
                totalSize: totalSize,
                contractSize: contractSize,
                isCall: false,
                isAmerican: true
            })
        );

        trackedSeriesIds.push(seriesId);
        issuedBySeries[seriesId] = totalSize;
    }

    function transferClaims(uint256 seriesSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (trackedSeriesIds.length == 0) return;

        uint256 seriesId = trackedSeriesIds[seriesSeed % trackedSeriesIds.length];
        address from = _actor(fromSeed);
        address to = _actor(toSeed + 1);
        if (from == to) return;

        uint256 balance = optionToken.balanceOf(from, seriesId);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(from);
        optionToken.safeTransferFrom(from, to, seriesId, amount, "");
    }

    function exerciseSeries(uint256 seriesSeed, uint256 holderSeed, uint256 amountSeed) external {
        if (trackedSeriesIds.length == 0) return;

        uint256 seriesId = trackedSeriesIds[seriesSeed % trackedSeriesIds.length];
        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        if (series.reclaimed || series.remainingSize == 0 || block.timestamp >= series.expiry) return;

        address holder = _actor(holderSeed);
        uint256 holderBalance = optionToken.balanceOf(holder, seriesId);
        uint256 wholeUnits = _maxWholeUnits(_min(holderBalance, series.remainingSize));
        if (wholeUnits == 0) return;

        uint256 amount = bound(amountSeed, 1, wholeUnits) * UNIT;
        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, amount);
        if (payment == 0) return;

        MockERC20Launch paymentToken = series.isCall ? strike : underlying;
        paymentToken.mint(holder, payment);

        vm.startPrank(holder);
        IERC20(address(paymentToken)).approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, amount, holder, payment, _expectedDelivery(series, amount));
        vm.stopPrank();

        burnedBySeries[seriesId] += amount;
    }

    function exerciseSeriesAsOperator(
        uint256 seriesSeed,
        uint256 holderSeed,
        uint256 operatorSeed,
        uint256 amountSeed
    ) external {
        if (trackedSeriesIds.length == 0) return;

        uint256 seriesId = trackedSeriesIds[seriesSeed % trackedSeriesIds.length];
        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        if (series.reclaimed || series.remainingSize == 0 || block.timestamp >= series.expiry) return;

        address holder = _actor(holderSeed);
        address operator = _actor(operatorSeed + 1);
        if (holder == operator) return;

        uint256 holderBalance = optionToken.balanceOf(holder, seriesId);
        uint256 wholeUnits = _maxWholeUnits(_min(holderBalance, series.remainingSize));
        if (wholeUnits == 0) return;

        uint256 amount = bound(amountSeed, 1, wholeUnits) * UNIT;
        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, amount);
        if (payment == 0) return;

        MockERC20Launch paymentToken = series.isCall ? strike : underlying;
        paymentToken.mint(holder, payment);

        vm.startPrank(holder);
        optionToken.setApprovalForAll(operator, true);
        IERC20(address(paymentToken)).approve(diamond, payment);
        vm.stopPrank();

        vm.prank(operator);
        OptionsFacet(diamond).exerciseOptionsFor(
            seriesId,
            amount,
            holder,
            holder,
            payment,
            _expectedDelivery(series, amount)
        );

        burnedBySeries[seriesId] += amount;
    }

    function reclaimSeries(uint256 seriesSeed) external {
        if (trackedSeriesIds.length == 0) return;

        uint256 seriesId = trackedSeriesIds[seriesSeed % trackedSeriesIds.length];
        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        if (series.reclaimed) return;

        if (block.timestamp <= series.expiry) {
            vm.warp(series.expiry + 1);
        }

        vm.prank(_makerForSeries(series));
        OptionsFacet(diamond).reclaimOptions(seriesId);
        reclaimedBySeries[seriesId] = true;
    }

    function burnReclaimedClaims(uint256 seriesSeed, uint256 holderSeed, uint256 amountSeed) external {
        if (trackedSeriesIds.length == 0) return;

        uint256 seriesId = trackedSeriesIds[seriesSeed % trackedSeriesIds.length];
        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        if (!series.reclaimed) return;

        address holder = _actor(holderSeed);
        uint256 holderBalance = optionToken.balanceOf(holder, seriesId);
        if (holderBalance == 0) return;

        uint256 amount = bound(amountSeed, 1, holderBalance);
        OptionsFacet(diamond).burnReclaimedOptionsClaims(holder, seriesId, amount);
        burnedBySeries[seriesId] += amount;
    }

    function warpTime(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1 hours, 5 days));
    }

    function seriesCount() external view returns (uint256) {
        return trackedSeriesIds.length;
    }

    function seriesIdAt(uint256 index) external view returns (uint256) {
        return trackedSeriesIds[index];
    }

    function issuedFor(uint256 seriesId) external view returns (uint256) {
        return issuedBySeries[seriesId];
    }

    function burnedFor(uint256 seriesId) external view returns (uint256) {
        return burnedBySeries[seriesId];
    }

    function wasReclaimed(uint256 seriesId) external view returns (bool) {
        return reclaimedBySeries[seriesId];
    }

    function _availablePrincipal(uint256 positionId, bytes32 positionKey, uint256 pid) internal view returns (uint256) {
        uint256 principal = testSupport.principalOf(pid, positionKey);
        uint256 locked = _aggregateLockedForPositionPool(positionId, pid);
        return principal > locked ? principal - locked : 0;
    }

    function _aggregateLockedForPositionPool(uint256 positionId, uint256 pid) internal view returns (uint256 locked) {
        uint256 len = trackedSeriesIds.length;
        for (uint256 i = 0; i < len; i++) {
            LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(trackedSeriesIds[i]);
            uint256 collateralPoolId = series.isCall ? series.underlyingPoolId : series.strikePoolId;
            if (series.makerPositionId == positionId && collateralPoolId == pid) {
                locked += series.collateralLocked;
            }
        }
    }

    function _expectedDelivery(LibOptionsStorage.OptionSeries memory series, uint256 amount)
        internal
        pure
        returns (uint256 delivery)
    {
        uint256 underlyingAmount = amount * series.contractSize;
        delivery = series.isCall ? underlyingAmount : _normalizeStrikeAmount(underlyingAmount);
    }

    function _normalizeStrikeAmount(uint256 underlyingAmount) internal pure returns (uint256 strikeAmount) {
        strikeAmount = (underlyingAmount * STRIKE_PRICE) / 1e18;
    }

    function _maxWholeUnits(uint256 amount) internal pure returns (uint256 wholeUnits) {
        wholeUnits = amount / UNIT;
    }

    function _makerForSeries(LibOptionsStorage.OptionSeries memory series) internal view returns (address maker_) {
        maker_ = series.makerPositionId == callMakerPositionId ? callMaker : putMaker;
    }

    function _actor(uint256 seed) internal view returns (address actor_) {
        uint256 slot = seed % 4;
        if (slot == 0) return callMaker;
        if (slot == 1) return putMaker;
        if (slot == 2) return holderA;
        return holderB;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract OptionsInvariantTest is StdInvariant, LaunchFixture {
    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant STRIKE_PID = 2;

    OptionToken internal optionToken;
    OptionsInvariantHandler internal handler;

    address internal callMaker;
    address internal putMaker;
    address internal holderA;
    address internal holderB;
    uint256 internal callMakerPositionId;
    uint256 internal putMakerPositionId;
    bytes32 internal callMakerPositionKey;
    bytes32 internal putMakerPositionKey;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();

        optionToken = OptionToken(OptionTokenViewFacet(diamond).getOptionToken());
        callMaker = alice;
        putMaker = bob;
        holderA = carol;
        holderB = _addr("dave");

        (callMakerPositionId, callMakerPositionKey) = _fundPosition(callMaker, UNDERLYING_PID, eve, 500e18);
        _joinPool(callMaker, callMakerPositionId, STRIKE_PID);

        (putMakerPositionId, putMakerPositionKey) = _fundPosition(putMaker, STRIKE_PID, alt, 1_000e18);
        _joinPool(putMaker, putMakerPositionId, UNDERLYING_PID);

        handler = new OptionsInvariantHandler(diamond, testSupport, optionToken, eve, alt);
        handler.configureParticipants(
            callMaker,
            putMaker,
            holderA,
            holderB,
            callMakerPositionId,
            putMakerPositionId,
            callMakerPositionKey,
            putMakerPositionKey
        );

        targetContract(address(handler));
    }

    function invariant_HolderBalancesPlusBurnedClaimsReconcileToIssuedClaims() public view {
        uint256 count = handler.seriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIdAt(i);
            uint256 balances = optionToken.balanceOf(callMaker, seriesId) + optionToken.balanceOf(putMaker, seriesId)
                + optionToken.balanceOf(holderA, seriesId) + optionToken.balanceOf(holderB, seriesId);
            uint256 burned = handler.burnedFor(seriesId);
            uint256 issued = handler.issuedFor(seriesId);

            assertEq(balances + burned, issued);
        }
    }

    function invariant_RemainingSizeAndCollateralStayConsistentForTrackedSeries() public view {
        uint256 count = handler.seriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIdAt(i);
            LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
            uint256 expectedCollateral;

            if (!series.reclaimed && series.remainingSize != 0) {
                uint256 underlyingAmount = series.remainingSize * series.contractSize;
                expectedCollateral = series.isCall ? underlyingAmount : _normalizeStrikeAmount(underlyingAmount);
            }

            assertEq(series.collateralLocked, expectedCollateral);
        }
    }

    function invariant_ReclaimedSeriesCannotRegainLockedCollateral() public view {
        uint256 count = handler.seriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIdAt(i);
            if (!handler.wasReclaimed(seriesId)) continue;

            LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
            assertTrue(series.reclaimed);
            assertEq(series.remainingSize, 0);
            assertEq(series.collateralLocked, 0);
        }
    }

    function invariant_ProductiveCollateralViewsStayAlignedAfterTransfersAndOperatorExercises() public view {
        _assertPositionViewsAligned(callMakerPositionId, callMakerPositionKey, UNDERLYING_PID);
        _assertPositionViewsAligned(putMakerPositionId, putMakerPositionKey, STRIKE_PID);

        ProtocolTestSupportFacet.PoolView memory underlyingView = testSupport.getPoolView(UNDERLYING_PID);
        ProtocolTestSupportFacet.PoolView memory strikeView = testSupport.getPoolView(STRIKE_PID);
        assertEq(underlyingView.activeCreditPrincipalTotal, _aggregateLockedAcrossPool(UNDERLYING_PID));
        assertEq(strikeView.activeCreditPrincipalTotal, _aggregateLockedAcrossPool(STRIKE_PID));
    }

    function _assertPositionViewsAligned(uint256 positionId, bytes32 positionKey, uint256 collateralPid) internal view {
        LibOptionsStorage.ProductiveCollateralView[] memory views =
            OptionsViewFacet(diamond).getOptionPositionProductiveCollateral(positionId);
        uint256[] memory activeSeriesIds = OptionsViewFacet(diamond).getOptionSeriesIdsByPosition(positionId);
        uint256 expectedLocked = _aggregateLockedForPositionPool(positionId, collateralPid);
        uint256 expectedLiveCount = _liveSeriesCountForPosition(positionId);

        assertEq(views.length, expectedLiveCount);
        assertEq(activeSeriesIds.length, expectedLiveCount);

        for (uint256 i = 0; i < views.length; i++) {
            LibOptionsStorage.ProductiveCollateralView memory viewData = views[i];
            LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(viewData.seriesId);

            assertEq(activeSeriesIds[i], viewData.seriesId);
            assertEq(viewData.makerPositionId, positionId);
            assertEq(viewData.makerPositionKey, positionKey);
            assertEq(viewData.collateralPoolId, collateralPid);
            assertEq(viewData.collateralLocked, series.collateralLocked);
            assertEq(viewData.remainingSize, series.remainingSize);
            assertEq(viewData.totalEncumbrance, expectedLocked);
            assertEq(viewData.activeCreditEncumbrancePrincipal, expectedLocked);
            assertEq(viewData.availablePrincipal + viewData.totalEncumbrance, viewData.settledPrincipal);
            assertEq(
                viewData.claimableYield,
                viewData.accruedYield + viewData.pendingActiveCreditYield + viewData.pendingFeeYield
            );
            assertTrue(!viewData.reclaimed);
        }
    }

    function _aggregateLockedAcrossPool(uint256 pid) internal view returns (uint256 locked) {
        uint256 count = handler.seriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIdAt(i);
            LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
            uint256 collateralPoolId = series.isCall ? series.underlyingPoolId : series.strikePoolId;
            if (collateralPoolId == pid) {
                locked += series.collateralLocked;
            }
        }
    }

    function _aggregateLockedForPositionPool(uint256 positionId, uint256 pid) internal view returns (uint256 locked) {
        uint256 count = handler.seriesCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 seriesId = handler.seriesIdAt(i);
            LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
            uint256 collateralPoolId = series.isCall ? series.underlyingPoolId : series.strikePoolId;
            if (series.makerPositionId == positionId && collateralPoolId == pid) {
                locked += series.collateralLocked;
            }
        }
    }

    function _liveSeriesCountForPosition(uint256 positionId) internal view returns (uint256 liveCount) {
        uint256 count = handler.seriesCount();
        for (uint256 i = 0; i < count; i++) {
            LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(handler.seriesIdAt(i));
            if (series.makerPositionId == positionId && !series.reclaimed) {
                liveCount += 1;
            }
        }
    }

    function _normalizeStrikeAmount(uint256 underlyingAmount) internal pure returns (uint256 strikeAmount) {
        strikeAmount = (underlyingAmount * 2e18) / 1e18;
    }

    function _fundPosition(address user, uint256 pid, MockERC20Launch token, uint256 amount)
        internal
        returns (uint256 positionId, bytes32 positionKey)
    {
        token.mint(user, amount);
        positionId = _mintPosition(user, pid);
        positionKey = positionNft.getPositionKey(positionId);

        vm.startPrank(user);
        token.approve(diamond, amount);
        PositionManagementFacet(diamond).depositToPosition(positionId, pid, amount, amount);
        vm.stopPrank();
    }

    function _joinPool(address user, uint256 positionId, uint256 pid) internal {
        vm.prank(user);
        PositionManagementFacet(diamond).joinPositionPool(positionId, pid);
    }
}
