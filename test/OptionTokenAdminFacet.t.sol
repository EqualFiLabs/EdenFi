// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract OptionTokenAdminFacetTest is LaunchFixture {
    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant STRIKE_PID = 2;
    uint256 internal constant STRIKE_PRICE = 2e18;
    uint256 internal constant BASE_CONTRACT_SIZE = 1;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function test_BugCondition_SetOptionTokenOrphans_ShouldRejectReplacementWhileSeriesLive() public {
        uint256 positionId = _fundCallWriter(alice, 10e18);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, 1e18, BASE_CONTRACT_SIZE));
        assertTrue(seriesId != 0);

        OptionToken replacement = new OptionToken("ipfs://equalfi/options/v2", address(this), diamond);
        bytes memory callData =
            abi.encodeWithSelector(OptionTokenAdminFacet.setOptionToken.selector, address(replacement));
        bytes32 salt = keccak256(abi.encodePacked("equalfi-test-salt", timelockSaltNonce++));

        timelockController.schedule(diamond, 0, callData, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("OptionTokenAdmin_ActiveSeriesExist(uint256)")), 1)
        );
        timelockController.execute(diamond, 0, callData, bytes32(0), salt);
    }

    function test_SetOptionToken_UpdatesCanonicalTokenWhenNoLiveSeriesExist() public {
        address previousToken = OptionTokenViewFacet(diamond).getOptionToken();
        OptionToken replacement = new OptionToken("ipfs://equalfi/options/v2", address(this), diamond);

        _timelockCall(diamond, abi.encodeWithSelector(OptionTokenAdminFacet.setOptionToken.selector, address(replacement)));

        assertEq(OptionTokenViewFacet(diamond).getOptionToken(), address(replacement));
        assertTrue(previousToken != address(replacement));
    }

    function test_Integration_SetOptionToken_RevertsWhileLiveAndSucceedsAfterReclaim() public {
        uint256 positionId = _fundCallWriter(alice, 10e18);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, 1e18, BASE_CONTRACT_SIZE));
        OptionToken replacement = new OptionToken("ipfs://equalfi/options/v2", address(this), diamond);

        bytes memory callData =
            abi.encodeWithSelector(OptionTokenAdminFacet.setOptionToken.selector, address(replacement));
        bytes32 revertSalt = keccak256(abi.encodePacked("equalfi-test-salt", timelockSaltNonce++));

        timelockController.schedule(diamond, 0, callData, bytes32(0), revertSalt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("OptionTokenAdmin_ActiveSeriesExist(uint256)")), 1)
        );
        timelockController.execute(diamond, 0, callData, bytes32(0), revertSalt);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        _timelockCall(diamond, callData);

        assertEq(OptionTokenViewFacet(diamond).getOptionToken(), address(replacement));
    }

    function _fundCallWriter(address user, uint256 amount) internal returns (uint256 positionId) {
        eve.mint(user, amount);
        positionId = _mintPosition(user, UNDERLYING_PID);

        vm.startPrank(user);
        IERC20(address(eve)).approve(diamond, amount);
        PositionManagementFacet(diamond).depositToPosition(positionId, UNDERLYING_PID, amount, amount);
        PositionManagementFacet(diamond).joinPositionPool(positionId, STRIKE_PID);
        vm.stopPrank();
    }

    function _createSeries(address maker, LibOptionsStorage.CreateOptionSeriesParams memory params)
        internal
        returns (uint256 seriesId)
    {
        vm.prank(maker);
        seriesId = OptionsFacet(diamond).createOptionSeries(params);
    }

    function _callParams(uint256 positionId, uint256 totalSize, uint256 contractSize)
        internal
        view
        returns (LibOptionsStorage.CreateOptionSeriesParams memory params)
    {
        params = LibOptionsStorage.CreateOptionSeriesParams({
            positionId: positionId,
            underlyingPoolId: UNDERLYING_PID,
            strikePoolId: STRIKE_PID,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: totalSize,
            contractSize: contractSize,
            isCall: true,
            isAmerican: true
        });
    }
}
