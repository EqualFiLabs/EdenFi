// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenRewardsEngine} from "../libraries/LibEdenRewardsEngine.sol";
import {LibEdenRewardsStorage} from "../libraries/LibEdenRewardsStorage.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {Unauthorized, InvalidParameterRange, InvalidUnderlying} from "../libraries/Errors.sol";

contract EdenRewardsFacet is ReentrancyGuardModifiers {
    error RewardProgramNotFound(uint256 programId);

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
    event RewardProgramFunded(uint256 indexed programId, address indexed funder, uint256 amount);
    event RewardProgramAccrued(
        uint256 indexed programId, uint256 allocated, uint256 globalRewardIndex, uint256 fundedReserve, uint256 lastRewardUpdate
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
            rewardRatePerSecond: rewardRatePerSecond,
            startTime: startTime,
            endTime: endTime,
            enabled: enabled,
            paused: false,
            closed: false
        });
        store.programs[programId].state.lastRewardUpdate = block.timestamp;
        LibEdenRewardsStorage.registerProgramTarget(store, programId, target);

        emit RewardProgramCreated(
            programId, uint8(targetType), targetId, rewardToken, manager, rewardRatePerSecond, startTime, endTime, enabled
        );
    }

    function setRewardProgramEnabled(uint256 programId, bool enabled) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");
        program.config.enabled = enabled;
        emit RewardProgramEnabledUpdated(programId, enabled);
    }

    function pauseRewardProgram(uint256 programId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");
        if (program.config.paused) revert InvalidParameterRange("programPaused");
        program.config.paused = true;
        emit RewardProgramPaused(programId);
    }

    function resumeRewardProgram(uint256 programId) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibEdenRewardsStorage.RewardProgram storage program = _program(programId);
        _enforceManagerOrGovernance(program.config.manager);
        if (program.config.closed) revert InvalidParameterRange("programClosed");
        if (!program.config.paused) revert InvalidParameterRange("programNotPaused");
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

    function _validateTarget(LibEdenRewardsStorage.RewardTargetType targetType, uint256 targetId) private pure {
        if (targetType == LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION) {
            if (targetId != LibEdenRewardsStorage.STEVE_TARGET_ID) revert InvalidParameterRange("steveTargetId");
            return;
        }

        if (targetType == LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION) {
            return;
        }

        revert InvalidParameterRange("targetType");
    }

    function _program(uint256 programId) private view returns (LibEdenRewardsStorage.RewardProgram storage program) {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        if (programId >= store.nextProgramId) revert RewardProgramNotFound(programId);
        program = store.programs[programId];
    }

    function _enforceManagerOrGovernance(address manager) private view {
        if (LibAccess.isTimelockOrOwnerIfUnset(msg.sender) || msg.sender == manager) {
            return;
        }
        revert Unauthorized();
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
}
