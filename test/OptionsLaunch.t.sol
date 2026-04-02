// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";

import {LaunchFixture, MockERC20Launch} from "test/utils/LaunchFixture.t.sol";

contract OptionsLaunchTest is LaunchFixture {
    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant STRIKE_PID = 2;
    uint256 internal constant STRIKE_PRICE = 2e18;
    uint256 internal constant CONTRACT_SIZE = 1;

    OptionToken internal optionToken;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();

        optionToken = OptionToken(OptionTokenViewFacet(diamond).getOptionToken());
    }

    function test_LiveLaunch_DiscoversCanonicalTokenCreatesCallSeriesExercisesAndReadsProductiveCollateral() public {
        (uint256 makerPositionId, bytes32 makerPositionKey) = _fundPosition(alice, UNDERLYING_PID, eve, 10e18);
        _joinPool(alice, makerPositionId, STRIKE_PID);

        assertTrue(OptionTokenViewFacet(diamond).hasOptionToken());
        assertEq(address(optionToken), OptionTokenViewFacet(diamond).getOptionToken());
        assertEq(optionToken.manager(), diamond);
        assertEq(optionToken.owner(), address(timelockController));

        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 seriesId = _createSeries(alice, makerPositionId, 5e18, expiry, true);

        LibOptionsStorage.OptionSeries memory createdSeries = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertEq(createdSeries.makerPositionId, makerPositionId);
        assertEq(createdSeries.totalSize, 5e18);
        assertEq(createdSeries.remainingSize, 5e18);
        assertEq(createdSeries.collateralLocked, 5e18);
        assertTrue(createdSeries.isCall);
        assertEq(optionToken.balanceOf(alice, seriesId), 5e18);

        uint256[] memory positionSeriesIds = OptionsViewFacet(diamond).getOptionSeriesIdsByPosition(makerPositionId);
        assertEq(positionSeriesIds.length, 1);
        assertEq(positionSeriesIds[0], seriesId);

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 2e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 2e18);
        assertEq(payment, 4e18);

        alt.mint(bob, payment);
        vm.startPrank(bob);
        alt.approve(diamond, payment);
        uint256 paid = OptionsFacet(diamond).exerciseOptions(seriesId, 2e18, bob, payment, 2e18);
        vm.stopPrank();

        assertEq(paid, payment);
        assertEq(eve.balanceOf(bob), 2e18);
        assertEq(testSupport.principalOf(UNDERLYING_PID, makerPositionKey), 8e18);
        assertEq(testSupport.principalOf(STRIKE_PID, makerPositionKey), 4e18);

        LibOptionsStorage.ProductiveCollateralView memory collateralView =
            OptionsViewFacet(diamond).getOptionSeriesProductiveCollateral(seriesId);

        assertEq(collateralView.seriesId, seriesId);
        assertEq(collateralView.makerPositionId, makerPositionId);
        assertEq(collateralView.collateralPoolId, UNDERLYING_PID);
        assertEq(collateralView.collateralAsset, address(eve));
        assertEq(collateralView.remainingSize, 3e18);
        assertEq(collateralView.collateralLocked, 3e18);
        assertEq(collateralView.settledPrincipal, 8e18);
        assertEq(collateralView.availablePrincipal, 5e18);
        assertEq(collateralView.totalEncumbrance, 3e18);
        assertEq(collateralView.activeCreditEncumbrancePrincipal, 3e18);
        assertTrue(!collateralView.reclaimed);

        LibOptionsStorage.ProductiveCollateralView[] memory byPosition =
            OptionsViewFacet(diamond).getOptionPositionProductiveCollateral(makerPositionId);
        assertEq(byPosition.length, 1);
        assertEq(byPosition[0].seriesId, seriesId);
    }

    function test_LiveLaunch_ExercisesPutAndReclaimsExpiredSeries() public {
        (uint256 makerPositionId, bytes32 makerPositionKey) = _fundPosition(carol, STRIKE_PID, alt, 10e18);
        _joinPool(carol, makerPositionId, UNDERLYING_PID);

        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 seriesId = _createSeries(carol, makerPositionId, 3e18, expiry, false);

        vm.prank(carol);
        optionToken.safeTransferFrom(carol, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        assertEq(payment, 1e18);

        eve.mint(bob, payment);
        vm.startPrank(bob);
        eve.approve(diamond, payment);
        uint256 paid = OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 2e18);
        vm.stopPrank();

        assertEq(paid, payment);
        assertEq(alt.balanceOf(bob), 2e18);
        assertEq(testSupport.principalOf(UNDERLYING_PID, makerPositionKey), 1e18);
        assertEq(testSupport.principalOf(STRIKE_PID, makerPositionKey), 8e18);

        LibOptionsStorage.ProductiveCollateralView memory activeView =
            OptionsViewFacet(diamond).getOptionSeriesProductiveCollateral(seriesId);
        assertEq(activeView.collateralPoolId, STRIKE_PID);
        assertEq(activeView.collateralLocked, 4e18);
        assertEq(activeView.remainingSize, 2e18);
        assertEq(activeView.totalEncumbrance, 4e18);
        assertEq(activeView.activeCreditEncumbrancePrincipal, 4e18);
        assertTrue(!activeView.reclaimed);

        vm.warp(expiry + 1);
        vm.prank(carol);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory reclaimedSeries = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertTrue(reclaimedSeries.reclaimed);
        assertEq(reclaimedSeries.remainingSize, 0);
        assertEq(reclaimedSeries.collateralLocked, 0);

        LibOptionsStorage.ProductiveCollateralView memory reclaimedView =
            OptionsViewFacet(diamond).getOptionSeriesProductiveCollateral(seriesId);
        assertTrue(reclaimedView.reclaimed);
        assertEq(reclaimedView.collateralLocked, 0);

        LibOptionsStorage.ProductiveCollateralView[] memory byPosition =
            OptionsViewFacet(diamond).getOptionPositionProductiveCollateral(makerPositionId);
        assertEq(byPosition.length, 0);
    }

    function _createSeries(address maker, uint256 positionId, uint256 totalSize, uint64 expiry, bool isCall)
        internal
        returns (uint256 seriesId)
    {
        LibOptionsStorage.CreateOptionSeriesParams memory params = LibOptionsStorage.CreateOptionSeriesParams({
            positionId: positionId,
            underlyingPoolId: UNDERLYING_PID,
            strikePoolId: STRIKE_PID,
            strikePrice: STRIKE_PRICE,
            expiry: expiry,
            totalSize: totalSize,
            contractSize: CONTRACT_SIZE,
            isCall: isCall,
            isAmerican: true
        });

        vm.prank(maker);
        seriesId = OptionsFacet(diamond).createOptionSeries(params);
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
