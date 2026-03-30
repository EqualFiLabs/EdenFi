// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {StEVEActionFacet} from "src/steve/StEVEActionFacet.sol";
import {StEVEViewFacet} from "src/steve/StEVEViewFacet.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {InvalidParameterRange, NotNFTOwner} from "src/libraries/Errors.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";

contract EdenRewardFacetTest is StEVELaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
        _configureRewards(address(eve), 30e18, true);
    }

    function test_OnlyPnftHeldStEVEEarns() public {
        eve.mint(alice, 30e18);
        eve.mint(bob, 30e18);
        eve.mint(address(this), 1_000e18);

        _mintWalletBasket(alice, steveBasketId, eve, 10e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);

        eve.approve(diamond, 1_000e18);
        EdenRewardFacet(diamond).fundRewards(1_000e18, 1_000e18);
        vm.warp(block.timestamp + 10);

        EdenRewardFacet.RewardView memory rewardConfig = EdenRewardFacet(diamond).getRewardConfig();
        assertEq(StEVEActionFacet(diamond).eligibleSupply(), 10e18);
        assertEq(rewardConfig.eligibleSupply, 10e18);
        assertTrue(rewardConfig.steveConfigured);
        assertTrue(rewardConfig.onlyPnftHeldStEVEEligible);
        assertTrue(!rewardConfig.walletHeldStEVERewardEligible);
        assertTrue(rewardConfig.rewardsAccrueToPosition);
        assertGt(EdenRewardFacet(diamond).previewClaimRewards(alicePositionId), 0);
        assertEq(EdenRewardFacet(diamond).previewClaimRewards(bobPositionId), 0);
    }

    function test_RewardAccrualAndSettlementAcrossPrincipalChanges() public {
        eve.mint(alice, 40e18);
        eve.mint(bob, 20e18);
        eve.mint(address(this), 2_000e18);

        _mintWalletBasket(alice, steveBasketId, eve, 20e18);
        _mintWalletBasket(bob, steveBasketId, eve, 10e18);

        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);

        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);
        _depositWalletStEVEToPosition(bob, bobPositionId, 10e18);

        eve.approve(diamond, 2_000e18);
        EdenRewardFacet(diamond).fundRewards(2_000e18, 2_000e18);

        vm.warp(block.timestamp + 10);
        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);

        vm.warp(block.timestamp + 10);

        assertEq(EdenRewardFacet(diamond).previewClaimRewards(alicePositionId), 350e18);
        assertEq(EdenRewardFacet(diamond).previewClaimRewards(bobPositionId), 250e18);
    }

    function test_ClaimRewardsAndFundingCap() public {
        eve.mint(alice, 20e18);
        eve.mint(address(this), 50e18);

        _mintWalletBasket(alice, steveBasketId, eve, 10e18);
        uint256 positionId = _mintPosition(alice, 1);
        _depositWalletStEVEToPosition(alice, positionId, 10e18);

        eve.approve(diamond, 50e18);
        EdenRewardFacet(diamond).fundRewards(50e18, 50e18);
        vm.warp(block.timestamp + 10);

        assertEq(EdenRewardFacet(diamond).previewClaimRewards(positionId), 50e18);

        uint256 balanceBefore = eve.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = EdenRewardFacet(diamond).claimRewards(positionId, alice);

        assertEq(claimed, 50e18);
        assertEq(eve.balanceOf(alice) - balanceBefore, 50e18);
        assertEq(EdenRewardFacet(diamond).previewClaimRewards(positionId), 0);
    }

    function test_PositionTransferPreservesRewardOwnership() public {
        eve.mint(alice, 20e18);
        eve.mint(address(this), 500e18);

        _mintWalletBasket(alice, steveBasketId, eve, 10e18);
        uint256 positionId = _mintPosition(alice, 1);
        _depositWalletStEVEToPosition(alice, positionId, 10e18);

        eve.approve(diamond, 500e18);
        EdenRewardFacet(diamond).fundRewards(500e18, 500e18);
        vm.warp(block.timestamp + 10);

        uint256 previewBeforeTransfer = EdenRewardFacet(diamond).previewClaimRewards(positionId);
        assertGt(previewBeforeTransfer, 0);

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, positionId);

        StEVEViewFacet.PositionPortfolio memory portfolio = StEVEViewFacet(diamond).getPositionPortfolio(positionId);
        assertEq(portfolio.owner, carol);
        assertTrue(portfolio.rewards.rewardsAccrueToPosition);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, alice, positionId));
        EdenRewardFacet(diamond).claimRewards(positionId, alice);

        uint256 carolBefore = eve.balanceOf(carol);
        vm.prank(carol);
        uint256 claimed = EdenRewardFacet(diamond).claimRewards(positionId, carol);

        assertEq(claimed, previewBeforeTransfer);
        assertEq(eve.balanceOf(carol) - carolBefore, previewBeforeTransfer);
    }

    function test_RewardAccrual_RevertsOnRepeatedClaimAndHandlesZeroEligibleSupply() public {
        eve.mint(address(this), 100e18);
        eve.approve(diamond, 100e18);
        EdenRewardFacet(diamond).fundRewards(100e18, 100e18);

        EdenRewardFacet.RewardView memory beforeWarp = EdenRewardFacet(diamond).getRewardConfig();
        vm.warp(block.timestamp + 10);
        EdenRewardFacet.RewardView memory afterWarp = EdenRewardFacet(diamond).getRewardConfig();
        assertEq(beforeWarp.rewardReserve, afterWarp.rewardReserve);

        eve.mint(alice, 20e18);
        _mintWalletBasket(alice, steveBasketId, eve, 10e18);
        uint256 positionId = _mintPosition(alice, 1);
        _depositWalletStEVEToPosition(alice, positionId, 10e18);

        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        uint256 claimed = EdenRewardFacet(diamond).claimRewards(positionId, alice);
        assertGt(claimed, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "nothing claimable"));
        EdenRewardFacet(diamond).claimRewards(positionId, alice);
    }

    function test_FundRewards_RevertsForZeroAmountAndFoTUnderreceipt() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "amount=0"));
        EdenRewardFacet(diamond).fundRewards(0, 0);

        _configureRewards(address(fot), 30e18, true);
        fot.mint(address(this), 100e18);
        fot.approve(diamond, 100e18);

        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, 9e18, 10e18));
        EdenRewardFacet(diamond).fundRewards(10e18, 10e18);
    }
}

contract EdenRewardFacetConfigGuardTest is StEVELaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function test_ConfigureRewards_RevertsUntilStEVEConfigured() public {
        bytes memory data =
            abi.encodeWithSelector(EdenRewardFacet.configureRewards.selector, address(eve), 30e18, true);
        bytes32 salt = keccak256("reward-config-without-steve");

        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "stEVE not configured"));
        timelockController.execute(diamond, 0, data, bytes32(0), salt);
    }
}
