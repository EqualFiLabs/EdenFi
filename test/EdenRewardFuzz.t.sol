// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenRewardFuzzTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
        _configureRewards(address(eve), 1e18, true);
    }

    function testFuzz_RewardFundingAccrualAndTransferOwnership(
        uint96 fundSeed,
        uint96 aliceSeed,
        uint96 bobSeed,
        uint32 warpSeed,
        bool transferAlicePosition
    ) public {
        uint256 fundAmount = _boundUint(uint256(fundSeed), 100, 2_000) * 1e18;
        uint256 aliceUnits = _boundUint(uint256(aliceSeed), 1, 50) * 1e18;
        uint256 bobUnits = _boundUint(uint256(bobSeed), 1, 50) * 1e18;
        uint256 warpBy = _boundUint(uint256(warpSeed), 1 days, 30 days);

        eve.mint(alice, aliceUnits);
        eve.mint(bob, bobUnits);
        eve.mint(address(this), fundAmount);

        _mintWalletBasket(alice, steveBasketId, eve, aliceUnits);
        _mintWalletBasket(bob, steveBasketId, eve, bobUnits);

        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);
        _depositWalletStEVEToPosition(alice, alicePositionId, aliceUnits);
        _depositWalletStEVEToPosition(bob, bobPositionId, bobUnits);

        eve.approve(diamond, fundAmount);
        EdenRewardFacet(diamond).fundRewards(fundAmount, fundAmount);
        vm.warp(block.timestamp + warpBy);

        uint256 alicePreview = EdenRewardFacet(diamond).previewClaimRewards(alicePositionId);
        uint256 bobPreview = EdenRewardFacet(diamond).previewClaimRewards(bobPositionId);
        assertGt(alicePreview + bobPreview, 0);
        assertTrue(alicePreview + bobPreview <= fundAmount);

        address aliceRecipient = alice;
        if (transferAlicePosition) {
            vm.prank(alice);
            positionNft.transferFrom(alice, carol, alicePositionId);
            aliceRecipient = carol;
        }

        uint256 aliceBefore = eve.balanceOf(aliceRecipient);
        vm.prank(aliceRecipient);
        uint256 aliceClaimed = EdenRewardFacet(diamond).claimRewards(alicePositionId, aliceRecipient);

        uint256 bobBefore = eve.balanceOf(bob);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardFacet(diamond).claimRewards(bobPositionId, bob);

        assertEq(aliceClaimed, alicePreview);
        assertEq(bobClaimed, bobPreview);
        assertEq(eve.balanceOf(aliceRecipient), aliceBefore + aliceClaimed);
        assertEq(eve.balanceOf(bob), bobBefore + bobClaimed);
        assertTrue(aliceClaimed + bobClaimed <= fundAmount);
    }

    function testFuzz_RewardSettlementPersistsAcrossPrincipalChanges(
        uint96 fundSeed,
        uint96 initialSeed,
        uint96 extraSeed,
        uint32 firstWarpSeed,
        uint32 secondWarpSeed
    ) public {
        uint256 initialUnits = _boundUint(uint256(initialSeed), 2, 50) * 1e18;
        uint256 extraUnits = _boundUint(uint256(extraSeed), 1, 25) * 1e18;
        uint256 fundAmount = _boundUint(uint256(fundSeed), 100, 2_000) * 1e18;
        uint256 firstWarp = _boundUint(uint256(firstWarpSeed), 1 days, 15 days);
        uint256 secondWarp = _boundUint(uint256(secondWarpSeed), 1 days, 15 days);

        eve.mint(alice, initialUnits + extraUnits);
        eve.mint(address(this), fundAmount);

        _mintWalletBasket(alice, steveBasketId, eve, initialUnits + extraUnits);
        uint256 positionId = _mintPosition(alice, 1);
        _depositWalletStEVEToPosition(alice, positionId, initialUnits);

        eve.approve(diamond, fundAmount);
        EdenRewardFacet(diamond).fundRewards(fundAmount, fundAmount);

        vm.warp(block.timestamp + firstWarp);
        uint256 previewBefore = EdenRewardFacet(diamond).previewClaimRewards(positionId);

        _depositWalletStEVEToPosition(alice, positionId, extraUnits);
        vm.warp(block.timestamp + secondWarp);

        vm.prank(alice);
        uint256 claimed = EdenRewardFacet(diamond).claimRewards(positionId, alice);

        assertTrue(claimed >= previewBefore);
        assertEq(EdenRewardFacet(diamond).previewClaimRewards(positionId), 0);
    }
}
