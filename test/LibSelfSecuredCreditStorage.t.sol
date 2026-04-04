// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibEqualXCommunityAmmStorage} from "src/libraries/LibEqualXCommunityAmmStorage.sol";
import {LibEqualXCurveStorage} from "src/libraries/LibEqualXCurveStorage.sol";
import {LibEqualXSoloAmmStorage} from "src/libraries/LibEqualXSoloAmmStorage.sol";
import {LibOptionTokenStorage} from "src/libraries/LibOptionTokenStorage.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {LibSelfSecuredCreditStorage} from "src/libraries/LibSelfSecuredCreditStorage.sol";
import {Types} from "src/libraries/Types.sol";

contract SelfSecuredCreditStorageHarness {
    function sscSlot() external pure returns (bytes32) {
        return LibSelfSecuredCreditStorage.STORAGE_POSITION;
    }

    function setSscLine(
        bytes32 positionKey,
        uint256 poolId,
        uint256 outstandingDebt,
        uint256 requiredLockedCapital,
        Types.SscAciMode aciMode,
        bool active
    ) external {
        LibSelfSecuredCreditStorage.s().lines[positionKey][poolId] = Types.SscLine({
            outstandingDebt: outstandingDebt,
            requiredLockedCapital: requiredLockedCapital,
            aciMode: aciMode,
            active: active
        });
    }

    function getSscLine(bytes32 positionKey, uint256 poolId) external view returns (Types.SscLine memory) {
        Types.SscLine storage lineState = LibSelfSecuredCreditStorage.line(positionKey, poolId);
        return lineState;
    }

    function setClaimableAciYield(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibSelfSecuredCreditStorage.s().claimableAciYield[positionKey][poolId] = amount;
    }

    function claimableAciYield(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibSelfSecuredCreditStorage.claimableAciYieldOf(positionKey, poolId);
    }

    function addClaimableAciYield(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibSelfSecuredCreditStorage.increaseClaimableAciYield(positionKey, poolId, amount);
    }

    function subClaimableAciYield(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibSelfSecuredCreditStorage.decreaseClaimableAciYield(positionKey, poolId, amount);
    }

    function setTotalAciAppliedToDebt(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibSelfSecuredCreditStorage.s().totalAciAppliedToDebt[positionKey][poolId] = amount;
    }

    function totalAciAppliedToDebt(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibSelfSecuredCreditStorage.totalAciAppliedToDebtOf(positionKey, poolId);
    }

    function addTotalAciAppliedToDebt(bytes32 positionKey, uint256 poolId, uint256 amount) external {
        LibSelfSecuredCreditStorage.increaseTotalAciAppliedToDebt(positionKey, poolId, amount);
    }

    function setRewardAccrued(uint256 programId, bytes32 positionKey, uint256 amount) external {
        LibEdenRewardsStorage.s().accruedRewards[programId][positionKey] = amount;
    }

    function rewardAccrued(uint256 programId, bytes32 positionKey) external view returns (uint256) {
        return LibEdenRewardsStorage.s().accruedRewards[programId][positionKey];
    }

    function setPositionAgentId(uint256 positionId, uint256 agentId) external {
        LibPositionAgentStorage.s().positionToAgentId[positionId] = agentId;
    }

    function positionAgentId(uint256 positionId) external view returns (uint256) {
        return LibPositionAgentStorage.s().positionToAgentId[positionId];
    }

    function setDirectNextOfferId(uint256 nextOfferId) external {
        LibEqualLendDirectStorage.s().nextOfferId = nextOfferId;
    }

    function directNextOfferId() external view returns (uint256) {
        return LibEqualLendDirectStorage.s().nextOfferId;
    }
}

contract LibSelfSecuredCreditStorageTest is Test {
    SelfSecuredCreditStorageHarness internal harness;

    function setUp() public {
        harness = new SelfSecuredCreditStorageHarness();
    }

    function test_storageSlot_isIsolatedFromExistingNamespaces() external view {
        bytes32 slot_ = harness.sscSlot();

        assertEq(slot_, keccak256("equalfi.self-secured-credit.storage"), "unexpected ssc slot");
        assertTrue(slot_ != LibAppStorage.APP_STORAGE_POSITION, "collides with app storage");
        assertTrue(slot_ != LibDiamond.DIAMOND_STORAGE_POSITION, "collides with diamond storage");
        assertTrue(slot_ != LibPositionNFT.POSITION_NFT_STORAGE_POSITION, "collides with position nft");
        assertTrue(slot_ != LibPoolMembership.POOL_MEMBERSHIP_STORAGE_POSITION, "collides with pool membership");
        assertTrue(slot_ != LibEncumbrance.STORAGE_POSITION, "collides with encumbrance");
        assertTrue(slot_ != LibEdenRewardsStorage.STORAGE_POSITION, "collides with eden rewards");
        assertTrue(slot_ != LibPositionAgentStorage.STORAGE_POSITION, "collides with position agent");
        assertTrue(slot_ != LibEqualLendDirectStorage.STORAGE_POSITION, "collides with direct storage");
        assertTrue(slot_ != LibEqualScaleAlphaStorage.STORAGE_POSITION, "collides with equalscale alpha");
        assertTrue(slot_ != LibOptionsStorage.OPTIONS_STORAGE_POSITION, "collides with options");
        assertTrue(slot_ != LibOptionTokenStorage.OPTION_TOKEN_STORAGE_POSITION, "collides with option token");
        assertTrue(slot_ != LibEqualXSoloAmmStorage.STORAGE_POSITION, "collides with equalx solo amm");
        assertTrue(slot_ != LibEqualXCommunityAmmStorage.STORAGE_POSITION, "collides with equalx community amm");
        assertTrue(slot_ != LibEqualXCurveStorage.STORAGE_POSITION, "collides with equalx curve");
    }

    function test_storageWrites_roundTripSscLineAndSourceSeparatedAciState() external {
        bytes32 positionKey = keccak256("ssc.position");
        uint256 poolId = 7;

        harness.setSscLine(positionKey, poolId, 95 ether, 100 ether, Types.SscAciMode.SelfPay, true);
        harness.setClaimableAciYield(positionKey, poolId, 4 ether);
        harness.setTotalAciAppliedToDebt(positionKey, poolId, 2 ether);

        Types.SscLine memory lineState = harness.getSscLine(positionKey, poolId);
        assertEq(lineState.outstandingDebt, 95 ether, "outstanding debt");
        assertEq(lineState.requiredLockedCapital, 100 ether, "required lock");
        assertEq(uint8(lineState.aciMode), uint8(Types.SscAciMode.SelfPay), "aci mode");
        assertTrue(lineState.active, "active");
        assertEq(harness.claimableAciYield(positionKey, poolId), 4 ether, "claimable aci");
        assertEq(harness.totalAciAppliedToDebt(positionKey, poolId), 2 ether, "aci applied");

        harness.addClaimableAciYield(positionKey, poolId, 1 ether);
        harness.subClaimableAciYield(positionKey, poolId, 0.5 ether);
        harness.addTotalAciAppliedToDebt(positionKey, poolId, 3 ether);

        assertEq(harness.claimableAciYield(positionKey, poolId), 4.5 ether, "claimable aci delta");
        assertEq(harness.totalAciAppliedToDebt(positionKey, poolId), 5 ether, "aci applied delta");
    }

    function test_storageWrites_doNotOverlapRewardsPositionAgentOrDirectStorage() external {
        bytes32 positionKey = keccak256("ssc.position.isolation");
        uint256 poolId = 11;
        bytes32 rewardPositionKey = keccak256("ssc.rewards.position");

        harness.setSscLine(positionKey, poolId, 42 ether, 45 ether, Types.SscAciMode.Yield, true);
        harness.setClaimableAciYield(positionKey, poolId, 3 ether);
        harness.setTotalAciAppliedToDebt(positionKey, poolId, 1 ether);

        assertEq(harness.rewardAccrued(9, rewardPositionKey), 0, "ssc write mutated rewards");
        assertEq(harness.positionAgentId(55), 0, "ssc write mutated position agent");
        assertEq(harness.directNextOfferId(), 0, "ssc write mutated direct storage");

        harness.setRewardAccrued(9, rewardPositionKey, 77);
        harness.setPositionAgentId(55, 88);
        harness.setDirectNextOfferId(99);

        Types.SscLine memory lineState = harness.getSscLine(positionKey, poolId);
        assertEq(lineState.outstandingDebt, 42 ether, "ssc debt mutated");
        assertEq(lineState.requiredLockedCapital, 45 ether, "ssc lock mutated");
        assertEq(uint8(lineState.aciMode), uint8(Types.SscAciMode.Yield), "ssc mode mutated");
        assertTrue(lineState.active, "ssc active mutated");
        assertEq(harness.claimableAciYield(positionKey, poolId), 3 ether, "ssc claimable aci mutated");
        assertEq(harness.totalAciAppliedToDebt(positionKey, poolId), 1 ether, "ssc aci applied mutated");
        assertEq(harness.rewardAccrued(9, rewardPositionKey), 77, "rewards write missing");
        assertEq(harness.positionAgentId(55), 88, "position agent write missing");
        assertEq(harness.directNextOfferId(), 99, "direct write missing");
    }
}
