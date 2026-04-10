// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenRewardsConsumer} from "../libraries/LibEdenRewardsConsumer.sol";
import {LibEdenRewardsEngine} from "../libraries/LibEdenRewardsEngine.sol";
import {LibEdenRewardsStorage} from "../libraries/LibEdenRewardsStorage.sol";
import {LibEqualIndexStorage} from "../libraries/LibEqualIndexStorage.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Unauthorized, InvalidParameterRange, InvalidUnderlying} from "../libraries/Errors.sol";

contract EdenRewardsFacet is ReentrancyGuardModifiers {
    error RewardProgramNotFound(uint256 programId);

    struct RewardProgramPositionView {
        uint256 eligibleBalance;
        uint256 rewardCheckpoint;
        uint256 accruedRewards;
        uint256 pendingRewards;
        uint256 claimableRewards;
        uint256 previewGlobalRewardIndex;
        address rewardToken;
    }

    struct RewardProgramClaimPreview {
        uint256 programId;
        address rewardToken;
        uint256 claimableRewards;
    }

    event RewardProgramCreated(
        uint256 indexed programId,
        uint8 indexed targetType,
        uint256 indexed targetId,
        address rewardToken,
        address manager,
        uint256 rewardRatePerSecond,
        uint256 startTime,
        uint256 endTime,
        bool enabled
    );
    event RewardProgramEnabledUpdated(uint256 indexed programId, bool enabled);
    event RewardProgramPaused(uint256 indexed programId);
    event RewardProgramResumed(uint256 indexed programId);
    event RewardProgramEnded(uint256 indexed programId, uint256 endTime);
    event RewardProgramClosed(uint256 indexed programId);
    event RewardProgramTransferFeeUpdated(uint256 indexed programId, uint16 outboundTransferBps);
    event RewardProgramFunded(uint256 indexed programId, address indexed funder, uint256 amount);
    event RewardProgramAccrued(
        uint256 indexed programId, uint256 allocated, uint256 globalRewardIndex, uint256 fundedReserve, uint256 lastRewardUpdate
    );
    event RewardProgramPositionSettled(
        uint256 indexed programId,
        bytes32 indexed positionKey,
        uint256 eligibleBalance,
        uint256 claimable,
        uint256 rewardCheckpoint
    );
    event RewardProgramClaimed(
        uint256 indexed programId,
        uint256 indexed positionId,
        bytes32 indexed positionKey,
        address to,
        uint256 amount
    );

    function createRewardProgram(
        LibEdenRewardsStorage.RewardTargetType targetType,
        uint256 targetId,
        address rewardToken,
        address manager,
        uint256 rewardRatePerSecond,
        uint256 startTime,
        uint256 endTime,
        bool enabled
    ) external nonReentrant returns (uint256 programId) {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();
        _validateTarget(targetType, targetId);
        if (rewardToken == address(0)) revert InvalidUnderlying();
        if (manager == address(0)) revert InvalidParameterRange("manager");
        if (rewardRatePerSecond == 0) revert InvalidParameterRange("rewardRatePerSecond");
        if (endTime != 0 && endTime <= startTime) revert InvalidParameterRange("rewardWindow");

        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        programId = LibEdenRewardsStorage.allocateProgramId(store);

        LibEdenRewardsStorage.RewardTarget memory target =
            LibEdenRewardsStorage.RewardTarget({targetType: targetType, targetId: targetId});

        store.programs[programId].config = LibEdenRewardsStorage.RewardProgramConfig({
            target: target,
            rewardToken: rewardToken,
            manager: manager,
            outboundTransferBps: 0,
            rewardRatePerSecond: rewardRatePerSecond,
            startTime: startTime,
            endTime: endTime,
            enabled: enabled,
            paused: false,
            closed: false
        });
        store.programs[programId].state.lastRewardUpdate = block.timestamp;
        store.programs[programId].state.eligibleSupply = LibEdenRewardsConsumer.currentEligibleSupply(target);
        LibEdenRewardsStorage.registerProgramTarget(store, programId, target);

        emit RewardProgramCreated(
            programId, uint8(targetType), targetId, rewardToken, manager, rewardRatePerSecond, startTime, endTime, enabled
        );
    }

    function setRewardProgramTransferFeeBps(uint256 programId, uint16 outboundTransferBps) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        if (outboundTransferBps >= LibEdenRewardsStorage.TRANSFER_FEE_BPS_SCALE) {
            revert InvalidParameterRange("outboundTransferBps");
        }

        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");
        if (program.state.globalRewardIndex != 0) revert InvalidParameterRange("programAccrued");

        program.config.outboundTransferBps = outboundTransferBps;
        emit RewardProgramTransferFeeUpdated(programId, outboundTransferBps);
    }

    function setRewardProgramEnabled(uint256 programId, bool enabled) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");
        _accrueBeforeLifecycleMutation(programId, program);
        program.config.enabled = enabled;
        emit RewardProgramEnabledUpdated(programId, enabled);
    }

    function pauseRewardProgram(uint256 programId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");
        if (program.config.paused) revert InvalidParameterRange("programPaused");
        _accrueBeforeLifecycleMutation(programId, program);
        program.config.paused = true;
        emit RewardProgramPaused(programId);
    }

    function resumeRewardProgram(uint256 programId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");
        if (!program.config.paused) revert InvalidParameterRange("programNotPaused");
        _accrueBeforeLifecycleMutation(programId, program);
        program.config.paused = false;
        emit RewardProgramResumed(programId);
    }

    function endRewardProgram(uint256 programId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");

        uint256 currentEndTime = program.config.endTime;
        if (currentEndTime != 0 && currentEndTime <= block.timestamp) revert InvalidParameterRange("programEnded");

        _accrueBeforeLifecycleMutation(programId, program);
        program.config.endTime = block.timestamp;
        program.config.enabled = false;
        program.config.paused = false;

        emit RewardProgramEnded(programId, block.timestamp);
    }

    function closeRewardProgram(uint256 programId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");
        _accrueBeforeLifecycleMutation(programId, program);
        if (program.state.fundedReserve != 0) revert InvalidParameterRange("programReserve");

        uint256 endTime = program.config.endTime;
        if (endTime == 0 || endTime > block.timestamp) revert InvalidParameterRange("programNotEnded");

        program.config.closed = true;
        program.config.enabled = false;
        program.config.paused = false;

        emit RewardProgramClosed(programId);
    }

    function fundRewardProgram(uint256 programId, uint256 amount, uint256 maxAmount)
        external
        payable
        nonReentrant
        returns (uint256 funded)
    {
        LibCurrency.assertZeroMsgValue();
        if (amount == 0) revert InvalidParameterRange("amount=0");

        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        if (program.config.closed) revert InvalidParameterRange("programClosed");

        LibEdenRewardsStorage.RewardProgramState memory stateBefore = program.state;
        LibEdenRewardsStorage.RewardProgramState memory stateAfterAccrual = LibEdenRewardsEngine.accrueProgram(programId);
        funded = LibCurrency.pullAtLeast(program.config.rewardToken, msg.sender, amount, maxAmount);
        program.state.fundedReserve = stateAfterAccrual.fundedReserve + funded;

        _emitAccrual(programId, stateBefore, stateAfterAccrual);
        emit RewardProgramFunded(programId, msg.sender, funded);
    }

    function accrueRewardProgram(uint256 programId)
        external
        nonReentrant
        returns (LibEdenRewardsStorage.RewardProgramState memory state)
    {
        LibCurrency.assertZeroMsgValue();
        _program(programId);

        LibEdenRewardsStorage.RewardProgramState memory stateBefore =
            LibEdenRewardsStorage.s().programs[programId].state;
        state = LibEdenRewardsEngine.accrueProgram(programId);
        _emitAccrual(programId, stateBefore, state);
    }

    function settleRewardProgramPosition(uint256 programId, uint256 positionId)
        external
        nonReentrant
        returns (uint256 claimable)
    {
        LibCurrency.assertZeroMsgValue();
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        claimable = _settleRewardProgramPosition(programId, positionKey);
    }

    function claimRewardProgram(uint256 programId, uint256 positionId, address to)
        external
        nonReentrant
        returns (uint256 claimed)
    {
        LibCurrency.assertZeroMsgValue();
        LibPositionHelpers.requireOwnership(positionId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        claimed = _settleRewardProgramPosition(programId, positionKey);
        if (claimed == 0) revert InvalidParameterRange("nothing claimable");

        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        uint256 grossClaimAmount =
            LibEdenRewardsEngine.grossUpNetAmount(claimed, program.config.outboundTransferBps);
        uint256 availableGross = LibCurrency.balanceOfSelf(program.config.rewardToken);
        if (grossClaimAmount > availableGross) {
            grossClaimAmount = availableGross;
        }
        if (grossClaimAmount == 0) revert InvalidParameterRange("programBalance");

        uint256 recipientBalanceBefore = IERC20(program.config.rewardToken).balanceOf(to);
        LibEdenRewardsStorage.s().accruedRewards[programId][positionKey] = 0;
        LibCurrency.transfer(program.config.rewardToken, to, grossClaimAmount);
        uint256 recipientBalanceAfter = IERC20(program.config.rewardToken).balanceOf(to);
        uint256 netReceived = recipientBalanceAfter - recipientBalanceBefore;
        if (netReceived < claimed) {
            LibEdenRewardsStorage.s().accruedRewards[programId][positionKey] = claimed - netReceived;
            claimed = netReceived;
        }

        emit RewardProgramClaimed(programId, positionId, positionKey, to, claimed);
    }

    function getRewardProgram(uint256 programId)
        external
        view
        returns (
            LibEdenRewardsStorage.RewardProgramConfig memory config,
            LibEdenRewardsStorage.RewardProgramState memory state
        )
    {
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        config = program.config;
        state = program.state;
    }

    function previewRewardProgramState(uint256 programId)
        external
        view
        returns (LibEdenRewardsStorage.RewardProgramState memory state)
    {
        _program(programId);
        state = LibEdenRewardsEngine.previewProgramState(programId);
    }

    function getRewardProgramIdsByTarget(LibEdenRewardsStorage.RewardTargetType targetType, uint256 targetId)
        external
        view
        returns (uint256[] memory programIds)
    {
        uint256[] storage storedIds =
            LibEdenRewardsStorage.programIdsForTarget(LibEdenRewardsStorage.s(), targetType, targetId);
        uint256 len = storedIds.length;
        programIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            programIds[i] = storedIds[i];
        }
    }

    function previewRewardProgramPosition(uint256 programId, uint256 positionId)
        external
        view
        returns (RewardProgramPositionView memory view_)
    {
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibEdenRewardsStorage.RewardProgramState memory previewState = LibEdenRewardsEngine.previewProgramState(programId);
        uint256 checkpoint = LibEdenRewardsStorage.s().positionRewardIndex[programId][positionKey];
        uint256 accrued = LibEdenRewardsStorage.s().accruedRewards[programId][positionKey];
        uint256 eligibleBalance = _eligibleBalanceView(program.config.target, positionKey);
        uint256 pending;

        if (previewState.globalRewardIndex > checkpoint && eligibleBalance > 0) {
            pending = Math.mulDiv(
                eligibleBalance,
                previewState.globalRewardIndex - checkpoint,
                LibEdenRewardsStorage.REWARD_INDEX_SCALE
            );
        }

        view_ = RewardProgramPositionView({
            eligibleBalance: eligibleBalance,
            rewardCheckpoint: checkpoint,
            accruedRewards: accrued,
            pendingRewards: pending,
            claimableRewards: accrued + pending,
            previewGlobalRewardIndex: previewState.globalRewardIndex,
            rewardToken: program.config.rewardToken
        });
    }

    function previewRewardProgramsForPosition(uint256 positionId, uint256[] calldata programIds)
        external
        view
        returns (RewardProgramClaimPreview[] memory previews, uint256 totalClaimable)
    {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        uint256 len = programIds.length;
        previews = new RewardProgramClaimPreview[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 programId = programIds[i];
            LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
            uint256 claimable = _previewClaimableRewards(programId, positionKey, program.config.target);
            previews[i] = RewardProgramClaimPreview({
                programId: programId,
                rewardToken: program.config.rewardToken,
                claimableRewards: claimable
            });
            totalClaimable += claimable;
        }
    }

    function _validateTarget(LibEdenRewardsStorage.RewardTargetType targetType, uint256) private pure {
        if (targetType == LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION) {
            return;
        }

        revert InvalidParameterRange("targetType");
    }

    function _program(uint256 programId) private view returns (LibEdenRewardsStorage.RewardProgram storage program) {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        if (programId == 0 || programId > store.nextProgramId) revert RewardProgramNotFound(programId);
        program = store.programs[programId];
    }

    function _enforceManagerOrGovernance(address manager) private view {
        if (LibAccess.isTimelockOrOwnerIfUnset(msg.sender) || msg.sender == manager) {
            return;
        }
        revert Unauthorized();
    }

    function _settleRewardProgramPosition(uint256 programId, bytes32 positionKey) private returns (uint256 claimable) {
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        LibEdenRewardsStorage.RewardProgramState memory stateBefore = program.state;
        uint256 eligibleBalance = _eligibleBalance(program.config.target, positionKey);
        claimable = LibEdenRewardsEngine.settleProgramPosition(programId, positionKey, eligibleBalance);
        LibEdenRewardsStorage.RewardProgramState memory stateAfter = program.state;

        _emitAccrual(programId, stateBefore, stateAfter);
        emit RewardProgramPositionSettled(
            programId, positionKey, eligibleBalance, claimable, stateAfter.globalRewardIndex
        );
    }

    function _eligibleBalance(LibEdenRewardsStorage.RewardTarget memory target, bytes32 positionKey)
        private
        returns (uint256 eligibleBalance)
    {
        if (target.targetType == LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION) {
            uint256 poolId = LibEqualIndexStorage.poolIdForIndex(target.targetId);
            if (poolId == 0) {
                return 0;
            }

            LibFeeIndex.settle(poolId, positionKey);
            return LibAppStorage.s().pools[poolId].userPrincipal[positionKey];
        }

        revert InvalidParameterRange("targetType");
    }

    function _eligibleBalanceView(LibEdenRewardsStorage.RewardTarget memory target, bytes32 positionKey)
        private
        view
        returns (uint256 eligibleBalance)
    {
        if (target.targetType == LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION) {
            uint256 poolId = LibEqualIndexStorage.poolIdForIndex(target.targetId);
            if (poolId == 0) {
                return 0;
            }

            return LibFeeIndex.previewSettledPrincipal(poolId, positionKey);
        }

        revert InvalidParameterRange("targetType");
    }

    function _previewClaimableRewards(
        uint256 programId,
        bytes32 positionKey,
        LibEdenRewardsStorage.RewardTarget memory target
    ) private view returns (uint256 claimable) {
        LibEdenRewardsStorage.RewardProgramState memory previewState = LibEdenRewardsEngine.previewProgramState(programId);
        uint256 checkpoint = LibEdenRewardsStorage.s().positionRewardIndex[programId][positionKey];
        uint256 accrued = LibEdenRewardsStorage.s().accruedRewards[programId][positionKey];
        uint256 eligibleBalance = _eligibleBalanceView(target, positionKey);

        if (previewState.globalRewardIndex > checkpoint && eligibleBalance > 0) {
            accrued += Math.mulDiv(
                eligibleBalance,
                previewState.globalRewardIndex - checkpoint,
                LibEdenRewardsStorage.REWARD_INDEX_SCALE
            );
        }

        return accrued;
    }

    function _emitAccrual(
        uint256 programId,
        LibEdenRewardsStorage.RewardProgramState memory stateBefore,
        LibEdenRewardsStorage.RewardProgramState memory stateAfter
    ) private {
        uint256 allocated = stateBefore.fundedReserve > stateAfter.fundedReserve
            ? stateBefore.fundedReserve - stateAfter.fundedReserve
            : 0;
        emit RewardProgramAccrued(
            programId, allocated, stateAfter.globalRewardIndex, stateAfter.fundedReserve, stateAfter.lastRewardUpdate
        );
    }

    function _accrueBeforeLifecycleMutation(uint256 programId, LibEdenRewardsStorage.RewardProgram storage program)
        private
    {
        LibEdenRewardsStorage.RewardProgramState memory stateBefore = program.state;
        LibEdenRewardsStorage.RewardProgramState memory stateAfter = LibEdenRewardsEngine.accrueProgram(programId);
        _emitAccrual(programId, stateBefore, stateAfter);
    }
}
