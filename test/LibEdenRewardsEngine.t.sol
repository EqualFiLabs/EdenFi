// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {LibEdenRewardsEngine} from "src/libraries/LibEdenRewardsEngine.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";

import {EdenRewardsFacetTest} from "test/EdenRewardsFacet.t.sol";

contract LibEdenRewardsEngineBugConditionTest is EdenRewardsFacetTest {
    function test_BugCondition_RewardReserve_ShouldOnlyDeductIndexedGrossLiability() public {
        uint256 alicePositionId = _fundEvePosition(alice, 6e18);
        uint256 indexId = _createRewardIndex("Rounding Reward Index", "RRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 3e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 1e18, 0, 0, true);

        vm.prank(manager);
        EdenRewardsFacet(diamond).setRewardProgramTransferFeeBps(programId, 500);

        alt.mint(address(this), 100e18);
        _fundRewardProgram(address(this), programId, alt, 100e18);

        (, LibEdenRewardsStorage.RewardProgramState memory beforeState) = EdenRewardsFacet(diamond).getRewardProgram(programId);

        vm.warp(block.timestamp + 1);
        EdenRewardsFacet(diamond).accrueRewardProgram(programId);

        (, LibEdenRewardsStorage.RewardProgramState memory afterState) = EdenRewardsFacet(diamond).getRewardProgram(programId);

        uint256 indexDelta = Math.mulDiv(1e18, LibEdenRewardsStorage.REWARD_INDEX_SCALE, beforeState.eligibleSupply);
        uint256 indexedNet =
            Math.mulDiv(indexDelta, beforeState.eligibleSupply, LibEdenRewardsStorage.REWARD_INDEX_SCALE);
        uint256 indexedGross = LibEdenRewardsEngine.grossUpNetAmount(indexedNet, 500);

        assertEq(afterState.fundedReserve, beforeState.fundedReserve - indexedGross);
    }

    function test_BugCondition_RewardReserve_ShouldNotBurnReserveWhenIndexDeltaTruncatesToZero() public {
        uint256 alicePositionId = _fundEvePosition(alice, 4e18);
        uint256 indexId = _createRewardIndex("Tiny Reward Index", "TRI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 2e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 1, 0, 0, true);

        alt.mint(address(this), 10);
        _fundRewardProgram(address(this), programId, alt, 10);

        (, LibEdenRewardsStorage.RewardProgramState memory beforeState) = EdenRewardsFacet(diamond).getRewardProgram(programId);

        vm.warp(block.timestamp + 1);
        EdenRewardsFacet(diamond).accrueRewardProgram(programId);

        (, LibEdenRewardsStorage.RewardProgramState memory afterState) = EdenRewardsFacet(diamond).getRewardProgram(programId);

        assertEq(afterState.fundedReserve, beforeState.fundedReserve);
    }
}

contract LibEdenRewardsEnginePreservationTest is EdenRewardsFacetTest {
    function test_Preservation_EdenRewardUtilities_GrossNetMathShouldRemainConsistent() public pure {
        uint256 gross = 1_000e18;
        uint16 bps = 500;

        uint256 net = LibEdenRewardsEngine.netFromGross(gross, bps);
        uint256 grossedUp = LibEdenRewardsEngine.grossUpNetAmount(net, bps);

        assertEq(net, 950e18);
        assertEq(LibEdenRewardsEngine.netFromGross(grossedUp, bps), net);
        assertEq(LibEdenRewardsEngine.netFromGross(100e18, 0), 100e18);
        assertEq(LibEdenRewardsEngine.grossUpNetAmount(100e18, 0), 100e18);
    }

    function test_Preservation_EdenRewardAccrual_ZeroSupplyOrReserveShouldShortCircuit() public {
        uint256 indexId = _createRewardIndex("Short Circuit Index", "SCI");
        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 10e18, 0, 0, true);

        (, LibEdenRewardsStorage.RewardProgramState memory beforeState) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(beforeState.eligibleSupply, 0);
        assertEq(beforeState.fundedReserve, 0);

        vm.warp(block.timestamp + 10);
        EdenRewardsFacet(diamond).accrueRewardProgram(programId);

        (, LibEdenRewardsStorage.RewardProgramState memory afterState) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(afterState.globalRewardIndex, beforeState.globalRewardIndex);
        assertEq(afterState.fundedReserve, beforeState.fundedReserve);
        assertEq(afterState.lastRewardUpdate, block.timestamp);
    }

    function test_Preservation_EdenRewardAccrual_ZeroTransferFeeShouldBehaveAsGrossEqualsNet() public {
        uint256 alicePositionId = _fundEvePosition(alice, 20e18);
        uint256 indexId = _createRewardIndex("Zero Fee Index", "ZFI");

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), manager, 10e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        (, LibEdenRewardsStorage.RewardProgramState memory beforeState) = EdenRewardsFacet(diamond).getRewardProgram(programId);

        vm.warp(block.timestamp + 10);
        EdenRewardsFacet(diamond).accrueRewardProgram(programId);

        (, LibEdenRewardsStorage.RewardProgramState memory afterState) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        EdenRewardsFacet.RewardProgramPositionView memory preview =
            EdenRewardsFacet(diamond).previewRewardProgramPosition(programId, alicePositionId);

        assertEq(afterState.fundedReserve, beforeState.fundedReserve - 100e18);
        assertEq(preview.claimableRewards, 100e18);
    }
}
