// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StEVEProductBase} from "src/steve/StEVEProductBase.sol";
import {StEVEPositionFacet} from "src/steve/StEVEPositionFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {StEVEActionFacet} from "src/steve/StEVEActionFacet.sol";
import {StEVEViewFacet} from "src/steve/StEVEViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {InsufficientPrincipal, InvalidParameterRange, NotNFTOwner} from "src/libraries/Errors.sol";
import {BasketToken} from "src/tokens/BasketToken.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";
import {ILegacyStEVEPositionFacet} from "test/utils/LegacyStEVEPositionFacet.sol";

contract StEVEActionFacetTest is StEVELaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
    }

    function test_CreateStEVE_WalletMintStaysNonEligible() public {
        eve.mint(bob, 20e18);
        uint256 emptyPositionId = _mintPosition(bob, 1);

        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        assertEq(StEVEActionFacet(diamond).eligibleSupply(), 0);
        assertEq(StEVEActionFacet(diamond).eligiblePrincipalOfPosition(emptyPositionId), 0);
    }

    function test_DepositWithdrawStEVE_TracksEligibleSupply() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(bob, positionId, 10e18);

        StEVEViewFacet.PositionPortfolio memory portfolio = StEVEViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(StEVEActionFacet(diamond).eligibleSupply(), 10e18);
        assertEq(StEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 10e18);
        assertEq(portfolio.rewards.eligiblePrincipal, 10e18);
        assertTrue(portfolio.product.active);
        assertEq(portfolio.product.units, 10e18);
        assertEq(ERC20(steveToken).balanceOf(bob), 0);

        vm.prank(bob);
        uint256 withdrawn = StEVEActionFacet(diamond).withdrawStEVEFromPosition(positionId, 4e18, 4e18);

        assertEq(withdrawn, 4e18);
        assertEq(StEVEActionFacet(diamond).eligibleSupply(), 6e18);
        assertEq(StEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 6e18);
        assertEq(ERC20(steveToken).balanceOf(bob), 4e18);
    }

    function test_PositionMintAndBurnStEVE_TrackEligibleSupply() public {
        eve.mint(alice, 100e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 100e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100e18, 100e18);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(positionId, 50e18);
        vm.stopPrank();

        StEVEViewFacet.PositionPortfolio memory portfolio = StEVEViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(StEVEActionFacet(diamond).eligibleSupply(), 50e18);
        assertEq(StEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 50e18);
        assertTrue(portfolio.product.active);
        assertEq(portfolio.product.productId, steveBasketId);
        assertEq(portfolio.product.units, 50e18);

        vm.prank(alice);
        StEVEPositionFacet(diamond).burnStEVEFromPosition(positionId, 20e18);

        portfolio = StEVEViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(StEVEActionFacet(diamond).eligibleSupply(), 30e18);
        assertEq(StEVEActionFacet(diamond).eligiblePrincipalOfPosition(positionId), 30e18);
        assertTrue(portfolio.product.active);
        assertEq(portfolio.product.units, 30e18);
    }

    function test_GenericPositionBasketEntrypoints_AreUnavailable() public {
        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyStEVEPositionFacet(diamond).mintBasketFromPosition(1, steveBasketId, 1e18);

        vm.expectRevert(bytes("Diamond: selector not found"));
        ILegacyStEVEPositionFacet(diamond).burnBasketFromPosition(1, steveBasketId, 1e18);
    }

    function test_WithdrawStEVE_RevertsForNonOwner() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(bob, positionId, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, alice, positionId));
        StEVEActionFacet(diamond).withdrawStEVEFromPosition(positionId, 4e18, 4e18);
    }

    function test_CreateStEVE_RevertsWhenAlreadyConfigured() public {
        StEVEProductBase.CreateBasketParams memory params = _stEveParams(address(eve));
        params.basketType = 0;
        bytes memory data = abi.encodeWithSelector(StEVEActionFacet.createStEVE.selector, params);
        bytes32 salt = keccak256("invalid-steve-basket-type");

        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "stEVE already configured"));
        timelockController.execute(diamond, 0, data, bytes32(0), salt);
    }

    function test_DepositAndWithdrawStEVE_RevertForZeroAmountAndInsufficientPrincipal() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);

        vm.startPrank(bob);
        BasketToken(steveToken).approve(diamond, 10e18);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "amount=0"));
        StEVEActionFacet(diamond).depositStEVEToPosition(positionId, 0, 0);
        vm.stopPrank();

        _depositWalletStEVEToPosition(bob, positionId, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 11e18, 10e18));
        StEVEActionFacet(diamond).withdrawStEVEFromPosition(positionId, 11e18, 11e18);
    }

    function test_StEVERewardProgram_WalletHeldUnitsDoNotEarnButPnftHeldUnitsDo() public {
        eve.mint(bob, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(bob, 1);
        uint256 programId = _createStEVERewardProgram(address(alt), address(this), 10e18, 0, 0, true);

        alt.mint(address(this), 200e18);
        _fundRewardProgram(address(this), programId, alt, 100e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 0);

        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "nothing claimable"));
        EdenRewardsFacet(diamond).claimRewardProgram(programId, positionId, bob);

        _depositWalletStEVEToPosition(bob, positionId, 10e18);
        (, state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 10e18);

        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, positionId, bob);

        assertEq(claimed, 100e18);
        assertEq(alt.balanceOf(bob), 100e18);
    }

    function test_WithdrawStEVE_SettlesProgramRewardsBeforeBalanceDecrease() public {
        eve.mint(alice, 20e18);
        eve.mint(bob, 20e18);
        _mintWalletBasket(alice, steveBasketId, eve, 10e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);
        _depositWalletStEVEToPosition(bob, bobPositionId, 10e18);

        uint256 programId = _createStEVERewardProgram(address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 20e18);

        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        StEVEActionFacet(diamond).withdrawStEVEFromPosition(bobPositionId, 5e18, 5e18);

        (, state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 15e18);

        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);

        assertEq(bobClaimed, 250e18);
        assertEq(aliceClaimed, 350e18);
        assertEq(alt.balanceOf(bob), 250e18);
        assertEq(alt.balanceOf(alice), 350e18);
    }

    function test_MintAndBurnStEVEFromPosition_SettleProgramRewardsBeforeBalanceChange() public {
        eve.mint(alice, 20e18);
        eve.mint(bob, 20e18);
        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 20e18, 20e18);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(alicePositionId, 10e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 20e18, 20e18);
        StEVEPositionFacet(diamond).mintStEVEFromPosition(bobPositionId, 10e18);
        vm.stopPrank();

        uint256 programId = _createStEVERewardProgram(address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        StEVEPositionFacet(diamond).burnStEVEFromPosition(alicePositionId, 5e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 15e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);

        assertEq(aliceClaimed, 250e18);
        assertEq(bobClaimed, 350e18);
    }

    function test_StEVERewardClaims_FollowCurrentPositionOwner() public {
        eve.mint(alice, 20e18);
        _mintWalletBasket(alice, steveBasketId, eve, 10e18);

        uint256 positionId = _mintPosition(alice, 1);
        _depositWalletStEVEToPosition(alice, positionId, 10e18);

        uint256 programId = _createStEVERewardProgram(address(alt), address(this), 10e18, 0, 0, true);
        alt.mint(address(this), 200e18);
        _fundRewardProgram(address(this), programId, alt, 100e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        positionNft.transferFrom(alice, bob, positionId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, alice, positionId));
        EdenRewardsFacet(diamond).claimRewardProgram(programId, positionId, alice);

        vm.prank(bob);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, positionId, bob);
        assertEq(claimed, 100e18);
        assertEq(alt.balanceOf(bob), 100e18);
    }
}
