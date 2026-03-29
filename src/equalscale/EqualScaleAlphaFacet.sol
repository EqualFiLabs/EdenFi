// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibModuleEncumbrance} from "src/libraries/LibModuleEncumbrance.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT, InsufficientPoolLiquidity} from "src/libraries/Errors.sol";
import {Types} from "src/libraries/Types.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

interface IPositionAgentIdentityRead {
    function getAgentId(uint256 positionTokenId) external view returns (uint256);
    function isRegistrationComplete(uint256 positionTokenId) external view returns (bool);
}

/// @notice Borrower-profile writes for EqualScale Alpha.
contract EqualScaleAlphaFacet is IEqualScaleAlphaEvents, IEqualScaleAlphaErrors {
    uint40 internal constant SOLO_WINDOW_DURATION = 3 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant YEAR_SECS = 365 days;
    bytes32 internal constant LINE_PROPOSAL_CREATED_TOPIC0 =
        keccak256(
            "LineProposalCreated(uint256,uint256,bytes32,uint256,uint256,uint256,uint16,uint256,uint256,uint32,uint32,uint40,uint40,uint8,uint256,uint256)"
        );
    bytes32 internal constant LINE_PROPOSAL_UPDATED_TOPIC0 =
        keccak256(
            "LineProposalUpdated(uint256,uint256,bytes32,uint256,uint256,uint256,uint16,uint256,uint256,uint32,uint32,uint40,uint40,uint8,uint256,uint256)"
        );

    struct LineProposalParams {
        uint256 settlementPoolId;
        uint256 requestedTargetLimit;
        uint256 minimumViableLine;
        uint16 aprBps;
        uint256 minimumPaymentPerPeriod;
        uint256 maxDrawPerPeriod;
        uint32 paymentIntervalSecs;
        uint32 gracePeriodSecs;
        uint40 facilityTermSecs;
        uint40 refinanceWindowSecs;
        LibEqualScaleAlphaStorage.CollateralMode collateralMode;
        uint256 borrowerCollateralPoolId;
        uint256 borrowerCollateralAmount;
    }

    function registerBorrowerProfile(
        uint256 positionId,
        address treasuryWallet,
        address bankrToken,
        bytes32 metadataHash
    ) external {
        _requireProfileAddresses(treasuryWallet, bankrToken);

        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(positionId);
        uint256 resolvedAgentId = _requireCompletedBorrowerIdentity(positionId);

        LibEqualScaleAlphaStorage.BorrowerProfile storage profile =
            LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];
        if (profile.active) {
            revert BorrowerProfileAlreadyActive(borrowerPositionKey);
        }

        profile.borrowerPositionKey = borrowerPositionKey;
        profile.treasuryWallet = treasuryWallet;
        profile.bankrToken = bankrToken;
        profile.metadataHash = metadataHash;
        profile.active = true;

        emit BorrowerProfileRegistered(
            borrowerPositionKey, positionId, treasuryWallet, bankrToken, resolvedAgentId, metadataHash
        );
    }

    function updateBorrowerProfile(
        uint256 positionId,
        address treasuryWallet,
        address bankrToken,
        bytes32 metadataHash
    ) external {
        _requireProfileAddresses(treasuryWallet, bankrToken);

        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(positionId);
        LibEqualScaleAlphaStorage.BorrowerProfile storage profile =
            LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];
        if (!profile.active) {
            revert BorrowerProfileNotActive(borrowerPositionKey);
        }

        profile.treasuryWallet = treasuryWallet;
        profile.bankrToken = bankrToken;
        profile.metadataHash = metadataHash;

        emit BorrowerProfileUpdated(borrowerPositionKey, positionId, treasuryWallet, bankrToken, metadataHash);
    }

    function createLineProposal(uint256 borrowerPositionId, LineProposalParams calldata params)
        external
        returns (uint256 lineId)
    {
        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(borrowerPositionId);
        _requireActiveBorrowerProfile(borrowerPositionKey);
        _validateProposalTerms(params);

        lineId = _createLineProposal(borrowerPositionId, borrowerPositionKey, params);
    }

    function updateLineProposal(uint256 lineId, LineProposalParams calldata params) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(line.borrowerPositionId);
        _requireActiveBorrowerProfile(borrowerPositionKey);
        _requireMutableProposal(lineId, line);
        _validateProposalTerms(params);

        _updateLineProposal(lineId, line, borrowerPositionKey, params);
    }

    function cancelLineProposal(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(line.borrowerPositionId);
        _requireMutableProposal(lineId, line);

        line.currentCommittedAmount = 0;
        line.activeLimit = 0;
        line.outstandingPrincipal = 0;
        line.accruedInterest = 0;
        line.interestAccruedSinceLastDue = 0;
        line.totalPrincipalRepaid = 0;
        line.totalInterestRepaid = 0;
        line.paidSinceLastDue = 0;
        line.currentPeriodDrawn = 0;
        line.currentPeriodStartedAt = 0;
        line.interestAccruedAt = 0;
        line.nextDueAt = 0;
        line.termStartedAt = 0;
        line.termEndAt = 0;
        line.refinanceEndAt = 0;
        line.soloExclusiveUntil = 0;
        line.delinquentSince = 0;
        line.missedPayments = 0;
        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Closed;

        emit ProposalCancelled(lineId, line.borrowerPositionId, borrowerPositionKey);
    }

    function commitSolo(uint256 lineId, uint256 lenderPositionId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow) {
            revert InvalidProposalTerms(_statusMutationReason(lineId, line.status));
        }
        if (block.timestamp > line.soloExclusiveUntil) {
            revert InvalidProposalTerms("solo window expired");
        }
        if (line.currentCommittedAmount != 0) {
            revert InvalidProposalTerms("solo commitment already exists");
        }

        _addCommitment(lineId, line, lenderPositionId, line.requestedTargetLimit);
    }

    function transitionToPooledOpen(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow) {
            revert InvalidProposalTerms(_statusMutationReason(lineId, line.status));
        }
        if (block.timestamp <= line.soloExclusiveUntil) {
            revert InvalidProposalTerms("solo window still active");
        }
        if (line.currentCommittedAmount != 0) {
            revert InvalidProposalTerms("solo commitment already exists");
        }

        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen;
        emit CreditLineOpenedToPool(lineId);
    }

    function commitPooled(uint256 lineId, uint256 lenderPositionId, uint256 amount) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (
            line.status != LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen
                && line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing
        ) {
            revert InvalidProposalTerms("line not open to pooled commitments");
        }
        if (amount == 0) {
            revert InvalidProposalTerms("amount == 0");
        }

        uint256 remainingCapacity = line.requestedTargetLimit - line.currentCommittedAmount;
        if (amount > remainingCapacity) {
            revert InvalidProposalTerms("commitment exceeds remaining capacity");
        }

        _addCommitment(lineId, line, lenderPositionId, amount);
    }

    function cancelCommitment(uint256 lineId, uint256 lenderPositionId) external {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen) {
            revert InvalidProposalTerms("line not cancelable during current status");
        }

        bytes32 lenderPositionKey = _requireLenderPositionOwner(lenderPositionId, line.settlementPoolId);
        LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionId];
        if (
            commitment.status != LibEqualScaleAlphaStorage.CommitmentStatus.Active || commitment.committedAmount == 0
                || commitment.lenderPositionKey != lenderPositionKey
        ) {
            revert InvalidProposalTerms("no active commitment");
        }

        uint256 canceledAmount = commitment.committedAmount;
        commitment.committedAmount = 0;
        commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Canceled;
        line.currentCommittedAmount -= canceledAmount;

        _settleSettlementPosition(line.settlementPoolId, lenderPositionKey);
        LibModuleEncumbrance.unencumber(
            lenderPositionKey, line.settlementPoolId, _settlementCommitmentModuleId(lineId), canceledAmount
        );

        emit CommitmentCancelled(
            lineId, lenderPositionId, lenderPositionKey, canceledAmount, line.currentCommittedAmount
        );
    }

    function activateLine(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (
            line.status != LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow
                && line.status != LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen
        ) {
            revert InvalidProposalTerms("line not activatable during current status");
        }

        uint256 acceptedAmount = _acceptedActivationAmount(line);
        uint40 activatedAt = uint40(block.timestamp);

        if (
            acceptedAmount < line.requestedTargetLimit
                && line.status == LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen
        ) {
            _requireBorrowerPositionOwner(line.borrowerPositionId);
        }

        if (line.collateralMode == LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted) {
            _encumberBorrowerCollateral(lineId, line);
        }

        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Active;
        line.activeLimit = acceptedAmount;
        line.currentPeriodDrawn = 0;
        line.currentPeriodStartedAt = activatedAt;
        line.interestAccruedAt = activatedAt;
        line.nextDueAt = activatedAt + line.paymentIntervalSecs;
        line.termStartedAt = activatedAt;
        line.termEndAt = activatedAt + line.facilityTermSecs;
        line.refinanceEndAt = line.termEndAt + line.refinanceWindowSecs;
        line.delinquentSince = 0;
        line.missedPayments = 0;

        emit CreditLineActivated(
            lineId, acceptedAmount, line.collateralMode, line.nextDueAt, line.termEndAt, line.refinanceEndAt
        );
    }

    function draw(uint256 lineId, uint256 amount) external {
        if (amount == 0) {
            revert InvalidProposalTerms("amount == 0");
        }

        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(line.borrowerPositionId);
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active) {
            revert InvalidProposalTerms("line not active for draw");
        }

        _accrueInterest(line);
        _resetDrawPeriodIfRolled(line);

        uint256 nextPeriodDrawn = line.currentPeriodDrawn + amount;
        if (nextPeriodDrawn > line.maxDrawPerPeriod) {
            revert InvalidDrawPacing(amount, line.currentPeriodDrawn, line.maxDrawPerPeriod);
        }

        uint256 nextOutstandingPrincipal = line.outstandingPrincipal + amount;
        if (nextOutstandingPrincipal > line.activeLimit) {
            revert InvalidProposalTerms("draw exceeds available capacity");
        }

        LibEqualScaleAlphaStorage.BorrowerProfile storage profile = store.borrowerProfiles[borrowerPositionKey];
        Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
        if (!settlementPool.initialized) {
            revert InvalidProposalTerms("settlement pool not initialized");
        }
        if (settlementPool.trackedBalance < amount) {
            revert InsufficientPoolLiquidity(amount, settlementPool.trackedBalance);
        }

        LibPoolMembership._ensurePoolMembership(borrowerPositionKey, line.settlementPoolId, true);
        _settleSettlementPosition(line.settlementPoolId, borrowerPositionKey);

        line.outstandingPrincipal = nextOutstandingPrincipal;
        line.currentPeriodDrawn = nextPeriodDrawn;

        settlementPool.userSameAssetDebt[borrowerPositionKey] += amount;
        settlementPool.activeCreditPrincipalTotal += amount;
        LibActiveCreditIndex.applyWeightedIncreaseWithGate(
            settlementPool,
            settlementPool.userActiveCreditStateDebt[borrowerPositionKey],
            amount,
            line.settlementPoolId,
            borrowerPositionKey,
            true
        );
        settlementPool.userActiveCreditStateDebt[borrowerPositionKey].indexSnapshot = settlementPool.activeCreditIndex;

        settlementPool.trackedBalance -= amount;
        if (LibCurrency.isNative(settlementPool.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }

        _allocateDrawExposure(store, lineId, amount);
        LibCurrency.transfer(settlementPool.underlying, profile.treasuryWallet, amount);

        emit CreditDrawn(lineId, amount, line.outstandingPrincipal, line.currentPeriodDrawn);
    }

    function repay(uint256 lineId, uint256 amount) external {
        if (amount == 0) {
            revert InvalidProposalTerms("amount == 0");
        }

        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        bytes32 borrowerPositionKey = _requireBorrowerPositionOwner(line.borrowerPositionId);
        if (!_repaymentAllowed(line.status)) {
            revert InvalidProposalTerms("line not repayable during current status");
        }

        _accrueInterest(line);

        uint256 totalOutstanding = line.outstandingPrincipal + line.accruedInterest;
        if (totalOutstanding == 0) {
            revert InvalidProposalTerms("line has no outstanding obligation");
        }

        uint256 effectiveAmount = amount > totalOutstanding ? totalOutstanding : amount;
        uint256 requiredMinimumDue = _requiredMinimumDue(line);
        uint256 interestComponent = effectiveAmount > line.accruedInterest ? line.accruedInterest : effectiveAmount;
        uint256 principalComponent = effectiveAmount - interestComponent;

        Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
        uint256 received =
            LibCurrency.pullAtLeast(settlementPool.underlying, msg.sender, effectiveAmount, effectiveAmount);
        settlementPool.trackedBalance += received;

        _settleSettlementPosition(line.settlementPoolId, borrowerPositionKey);

        line.accruedInterest -= interestComponent;
        line.outstandingPrincipal -= principalComponent;
        line.totalInterestRepaid += interestComponent;
        line.totalPrincipalRepaid += principalComponent;
        line.paidSinceLastDue += effectiveAmount;

        if (principalComponent != 0) {
            _reduceBorrowerDebt(settlementPool, line.settlementPoolId, borrowerPositionKey, principalComponent);
        }

        _allocateRepayment(store, lineId, interestComponent, principalComponent);
        _recordPaymentRecord(store, lineId, effectiveAmount, principalComponent, interestComponent);

        bool minimumDueSatisfied = requiredMinimumDue == 0 || line.paidSinceLastDue >= requiredMinimumDue;
        if (minimumDueSatisfied) {
            _advanceDueCheckpoint(line);
        }

        _cureLineIfCovered(line, minimumDueSatisfied);

        _emitCreditPaymentMade(lineId, effectiveAmount, principalComponent, interestComponent, line);
    }

    function enterRefinancing(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active) {
            revert InvalidProposalTerms("line not active for refinancing");
        }
        if (block.timestamp < line.termEndAt) {
            revert InvalidProposalTerms("facility term still active");
        }

        _accrueInterest(line);
        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing;

        emit CreditLineEnteredRefinancing(
            lineId, line.refinanceEndAt, line.currentCommittedAmount, line.outstandingPrincipal
        );
    }

    function rollCommitment(uint256 lineId, uint256 lenderPositionId) external {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing) {
            revert InvalidProposalTerms("line not in refinancing");
        }

        bytes32 lenderPositionKey = _requireLenderPositionOwner(lenderPositionId, line.settlementPoolId);
        LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionId];
        if (
            commitment.committedAmount == 0 || commitment.lenderPositionKey != lenderPositionKey
                || !_refinanceCommitmentMutable(commitment.status)
        ) {
            revert InvalidProposalTerms("no active commitment");
        }

        commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Rolled;

        emit CommitmentRolled(
            lineId, lenderPositionId, lenderPositionKey, commitment.committedAmount, line.currentCommittedAmount
        );
    }

    function exitCommitment(uint256 lineId, uint256 lenderPositionId) external {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing) {
            revert InvalidProposalTerms("line not in refinancing");
        }

        bytes32 lenderPositionKey = _requireLenderPositionOwner(lenderPositionId, line.settlementPoolId);
        LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionId];
        if (
            commitment.committedAmount == 0 || commitment.lenderPositionKey != lenderPositionKey
                || !_refinanceCommitmentMutable(commitment.status)
        ) {
            revert InvalidProposalTerms("no active commitment");
        }

        uint256 exitedAmount = commitment.committedAmount;
        commitment.committedAmount = 0;
        commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Exited;
        line.currentCommittedAmount -= exitedAmount;

        _settleSettlementPosition(line.settlementPoolId, lenderPositionKey);
        LibModuleEncumbrance.unencumber(
            lenderPositionKey, line.settlementPoolId, _settlementCommitmentModuleId(lineId), exitedAmount
        );

        emit CommitmentExited(lineId, lenderPositionId, lenderPositionKey, exitedAmount, line.currentCommittedAmount);
    }

    function resolveRefinancing(uint256 lineId) external {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        if (line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing) {
            revert InvalidProposalTerms("line not in refinancing");
        }
        if (block.timestamp < line.refinanceEndAt) {
            revert InvalidProposalTerms("refinance window still active");
        }

        _accrueInterest(line);

        if (line.currentCommittedAmount >= line.requestedTargetLimit) {
            _restartLineTerm(line, line.requestedTargetLimit);
        } else if (
            line.currentCommittedAmount >= line.outstandingPrincipal
                && line.currentCommittedAmount >= line.minimumViableLine
        ) {
            _restartLineTerm(line, line.currentCommittedAmount);
        } else {
            line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Runoff;
            line.activeLimit = line.currentCommittedAmount;
            line.currentPeriodDrawn = 0;

            emit CreditLineEnteredRunoff(lineId, line.outstandingPrincipal, line.currentCommittedAmount);
        }

        emit CreditLineRefinancingResolved(lineId, line.status, line.activeLimit, line.currentCommittedAmount);
    }

    function _createLineProposal(
        uint256 borrowerPositionId,
        bytes32 borrowerPositionKey,
        LineProposalParams calldata params
    ) internal returns (uint256 lineId) {

        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        lineId = ++store.nextLineId;

        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        line.borrowerPositionKey = borrowerPositionKey;
        line.borrowerPositionId = borrowerPositionId;
        _applyProposalTerms(line, params);
        line.soloExclusiveUntil = uint40(block.timestamp) + SOLO_WINDOW_DURATION;
        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow;

        store.borrowerLineIds[borrowerPositionKey].push(lineId);

        _emitLineProposalCreated(lineId, borrowerPositionId, borrowerPositionKey, params, line.soloExclusiveUntil);
    }

    function _updateLineProposal(
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        bytes32 borrowerPositionKey,
        LineProposalParams calldata params
    ) internal {
        _applyProposalTerms(line, params);
        _emitLineProposalUpdated(lineId, line.borrowerPositionId, borrowerPositionKey, params);
    }

    function _addCommitment(
        uint256 lineId,
        LibEqualScaleAlphaStorage.CreditLine storage line,
        uint256 lenderPositionId,
        uint256 amount
    ) internal {
        bytes32 lenderPositionKey = _requireLenderPositionOwner(lenderPositionId, line.settlementPoolId);
        _settleSettlementPosition(line.settlementPoolId, lenderPositionKey);

        Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
        if (!settlementPool.initialized) {
            revert InvalidProposalTerms("settlement pool not initialized");
        }
        uint256 available = _availablePrincipal(settlementPool, lenderPositionKey, line.settlementPoolId);
        if (available < amount) {
            revert InsufficientLenderPrincipal(lenderPositionId, amount, available);
        }

        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionId];
        if (!store.lineHasCommitmentPosition[lineId][lenderPositionId]) {
            store.lineHasCommitmentPosition[lineId][lenderPositionId] = true;
            store.lineCommitmentPositionIds[lineId].push(lenderPositionId);
        }
        if (!store.lenderPositionHasLine[lenderPositionId][lineId]) {
            store.lenderPositionHasLine[lenderPositionId][lineId] = true;
            store.lenderPositionLineIds[lenderPositionId].push(lineId);
        }

        if (commitment.lenderPositionId == 0) {
            commitment.lenderPositionId = lenderPositionId;
        }
        commitment.lenderPositionKey = lenderPositionKey;
        commitment.settlementPoolId = line.settlementPoolId;
        commitment.committedAmount += amount;
        commitment.status = LibEqualScaleAlphaStorage.CommitmentStatus.Active;

        line.currentCommittedAmount += amount;

        LibModuleEncumbrance.encumber(
            lenderPositionKey, line.settlementPoolId, _settlementCommitmentModuleId(lineId), amount
        );

        emit CommitmentAdded(lineId, lenderPositionId, lenderPositionKey, amount, line.currentCommittedAmount);
    }

    function _requireBorrowerPositionOwner(uint256 positionId) internal view returns (bytes32 borrowerPositionKey) {
        PositionNFT positionNft = _positionNft();
        address owner = positionNft.ownerOf(positionId);
        if (owner != msg.sender) {
            revert BorrowerPositionNotOwned(msg.sender, positionId);
        }

        borrowerPositionKey = positionNft.getPositionKey(positionId);
    }

    function _requireLenderPositionOwner(uint256 lenderPositionId, uint256 settlementPoolId)
        internal
        view
        returns (bytes32 lenderPositionKey)
    {
        PositionNFT positionNft = _positionNft();
        address owner = positionNft.ownerOf(lenderPositionId);
        if (owner != msg.sender) {
            revert LenderPositionNotOwned(msg.sender, lenderPositionId);
        }
        if (positionNft.getPoolId(lenderPositionId) != settlementPoolId) {
            revert InvalidProposalTerms("lender position not in settlement pool");
        }

        lenderPositionKey = positionNft.getPositionKey(lenderPositionId);
    }

    function _requireCompletedBorrowerIdentity(uint256 positionId) internal view returns (uint256 resolvedAgentId) {
        IPositionAgentIdentityRead identityView = IPositionAgentIdentityRead(address(this));
        if (!identityView.isRegistrationComplete(positionId)) {
            revert BorrowerIdentityNotRegistered(positionId);
        }

        resolvedAgentId = identityView.getAgentId(positionId);
        if (resolvedAgentId == 0) {
            revert BorrowerIdentityNotRegistered(positionId);
        }
    }

    function _requireProfileAddresses(address treasuryWallet, address bankrToken) internal pure {
        if (treasuryWallet == address(0)) {
            revert InvalidTreasuryWallet();
        }
        if (bankrToken == address(0)) {
            revert InvalidBankrToken();
        }
    }

    function _requireActiveBorrowerProfile(bytes32 borrowerPositionKey) internal view {
        if (!LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey].active) {
            revert BorrowerProfileNotActive(borrowerPositionKey);
        }
    }

    function _requireMutableProposal(uint256 lineId, LibEqualScaleAlphaStorage.CreditLine storage line) internal view {
        if (
            line.status != LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow
                && line.status != LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen
        ) {
            revert InvalidProposalTerms(_statusMutationReason(lineId, line.status));
        }
        if (line.currentCommittedAmount != 0) {
            revert InvalidProposalTerms("proposal has active commitments");
        }
    }

    function _applyProposalTerms(
        LibEqualScaleAlphaStorage.CreditLine storage line,
        LineProposalParams calldata params
    ) internal {
        line.settlementPoolId = params.settlementPoolId;
        line.requestedTargetLimit = params.requestedTargetLimit;
        line.minimumViableLine = params.minimumViableLine;
        line.aprBps = params.aprBps;
        line.minimumPaymentPerPeriod = params.minimumPaymentPerPeriod;
        line.maxDrawPerPeriod = params.maxDrawPerPeriod;
        line.paymentIntervalSecs = params.paymentIntervalSecs;
        line.gracePeriodSecs = params.gracePeriodSecs;
        line.facilityTermSecs = params.facilityTermSecs;
        line.refinanceWindowSecs = params.refinanceWindowSecs;
        line.collateralMode = params.collateralMode;
        line.borrowerCollateralPoolId = params.borrowerCollateralPoolId;
        line.borrowerCollateralAmount = params.borrowerCollateralAmount;
    }

    function _emitLineProposalCreated(
        uint256 lineId,
        uint256 borrowerPositionId,
        bytes32 borrowerPositionKey,
        LineProposalParams calldata params,
        uint40 soloExclusiveUntil
    ) internal {
        _logLineProposalEvent(LINE_PROPOSAL_CREATED_TOPIC0, lineId, borrowerPositionId, borrowerPositionKey, params);
        emit CreditLineEnteredSoloWindow(lineId, soloExclusiveUntil);
    }

    function _emitLineProposalUpdated(
        uint256 lineId,
        uint256 borrowerPositionId,
        bytes32 borrowerPositionKey,
        LineProposalParams calldata params
    ) internal {
        _logLineProposalEvent(LINE_PROPOSAL_UPDATED_TOPIC0, lineId, borrowerPositionId, borrowerPositionKey, params);
    }

    function _logLineProposalEvent(
        bytes32 signatureTopic,
        uint256 lineId,
        uint256 borrowerPositionId,
        bytes32 borrowerPositionKey,
        LineProposalParams calldata params
    ) internal {
        bytes memory data = new bytes(13 * 32);

        assembly {
            let ptr := add(data, 0x20)
            mstore(ptr, calldataload(params))
            mstore(add(ptr, 0x20), calldataload(add(params, 0x20)))
            mstore(add(ptr, 0x40), calldataload(add(params, 0x40)))
            mstore(add(ptr, 0x60), calldataload(add(params, 0x60)))
            mstore(add(ptr, 0x80), calldataload(add(params, 0x80)))
            mstore(add(ptr, 0xa0), calldataload(add(params, 0xa0)))
            mstore(add(ptr, 0xc0), calldataload(add(params, 0xc0)))
            mstore(add(ptr, 0xe0), calldataload(add(params, 0xe0)))
            mstore(add(ptr, 0x100), calldataload(add(params, 0x100)))
            mstore(add(ptr, 0x120), calldataload(add(params, 0x120)))
            mstore(add(ptr, 0x140), calldataload(add(params, 0x140)))
            mstore(add(ptr, 0x160), calldataload(add(params, 0x160)))
            mstore(add(ptr, 0x180), calldataload(add(params, 0x180)))
            log4(ptr, 0x1a0, signatureTopic, lineId, borrowerPositionId, borrowerPositionKey)
        }
    }

    function _validateProposalTerms(LineProposalParams calldata params) internal pure {
        if (params.settlementPoolId == 0) {
            revert InvalidProposalTerms("settlementPoolId == 0");
        }
        if (params.requestedTargetLimit == 0) {
            revert InvalidProposalTerms("targetLimit == 0");
        }
        if (params.minimumViableLine == 0) {
            revert InvalidProposalTerms("minimumViableLine == 0");
        }
        if (params.minimumViableLine > params.requestedTargetLimit) {
            revert InvalidProposalTerms("minimumViableLine > targetLimit");
        }
        if (params.maxDrawPerPeriod == 0) {
            revert InvalidProposalTerms("maxDrawPerPeriod == 0");
        }
        if (params.maxDrawPerPeriod > params.requestedTargetLimit) {
            revert InvalidProposalTerms("maxDrawPerPeriod > targetLimit");
        }
        if (params.paymentIntervalSecs == 0) {
            revert InvalidProposalTerms("paymentIntervalSecs == 0");
        }
        if (params.facilityTermSecs == 0) {
            revert InvalidProposalTerms("facilityTermSecs == 0");
        }
        if (params.refinanceWindowSecs == 0) {
            revert InvalidProposalTerms("refinanceWindowSecs == 0");
        }

        _validateCollateralMode(params.collateralMode, params.borrowerCollateralPoolId, params.borrowerCollateralAmount);
    }

    function _validateCollateralMode(
        LibEqualScaleAlphaStorage.CollateralMode collateralMode,
        uint256 borrowerCollateralPoolId,
        uint256 borrowerCollateralAmount
    ) internal pure {
        if (collateralMode == LibEqualScaleAlphaStorage.CollateralMode.None) {
            if (borrowerCollateralPoolId != 0 || borrowerCollateralAmount != 0) {
                revert InvalidCollateralMode(collateralMode, borrowerCollateralPoolId, borrowerCollateralAmount);
            }
            return;
        }

        if (collateralMode == LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted) {
            if (borrowerCollateralPoolId == 0 || borrowerCollateralAmount == 0) {
                revert InvalidCollateralMode(collateralMode, borrowerCollateralPoolId, borrowerCollateralAmount);
            }
            return;
        }

        revert InvalidCollateralMode(collateralMode, borrowerCollateralPoolId, borrowerCollateralAmount);
    }

    function _acceptedActivationAmount(LibEqualScaleAlphaStorage.CreditLine storage line)
        internal
        view
        returns (uint256 acceptedAmount)
    {
        acceptedAmount = line.currentCommittedAmount;
        if (acceptedAmount >= line.requestedTargetLimit) {
            return line.requestedTargetLimit;
        }
        if (acceptedAmount < line.minimumViableLine) {
            revert InvalidProposalTerms("commitments below minimum viable line");
        }
    }

    function _encumberBorrowerCollateral(uint256 lineId, LibEqualScaleAlphaStorage.CreditLine storage line) internal {
        bytes32 borrowerPositionKey = line.borrowerPositionKey;
        uint256 collateralPoolId = line.borrowerCollateralPoolId;
        _settlePosition(collateralPoolId, borrowerPositionKey);

        Types.PoolData storage collateralPool = LibAppStorage.s().pools[collateralPoolId];
        if (!collateralPool.initialized) {
            revert InvalidProposalTerms("borrower collateral pool not initialized");
        }

        uint256 available = _availablePrincipal(collateralPool, borrowerPositionKey, collateralPoolId);
        if (available < line.borrowerCollateralAmount) {
            revert InvalidProposalTerms("insufficient borrower collateral");
        }

        LibModuleEncumbrance.encumber(
            borrowerPositionKey, collateralPoolId, _borrowerCollateralModuleId(lineId), line.borrowerCollateralAmount
        );
    }

    function _resetDrawPeriodIfRolled(LibEqualScaleAlphaStorage.CreditLine storage line) internal {
        if (block.timestamp < uint256(line.currentPeriodStartedAt) + line.paymentIntervalSecs) {
            return;
        }

        line.currentPeriodStartedAt = uint40(block.timestamp);
        line.currentPeriodDrawn = 0;
    }

    function _allocateDrawExposure(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 amount
    ) internal {
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 totalCommitted;
        uint256 activeCommitmentCount;
        uint256 len = lenderPositionIds.length;

        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionIds[i]];
            if (_countsForFutureCoverage(commitment.status) && commitment.committedAmount != 0) {
                totalCommitted += commitment.committedAmount;
                activeCommitmentCount++;
            }
        }

        if (totalCommitted == 0 || activeCommitmentCount == 0) {
            revert InvalidProposalTerms("line has no active commitments");
        }

        uint256 remaining = amount;
        uint256 seenActiveCommitments;
        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionIds[i]];
            if (!_countsForFutureCoverage(commitment.status) || commitment.committedAmount == 0) {
                continue;
            }

            seenActiveCommitments++;
            uint256 exposureShare = remaining;
            if (seenActiveCommitments != activeCommitmentCount) {
                exposureShare = Math.mulDiv(amount, commitment.committedAmount, totalCommitted);
                remaining -= exposureShare;
            }

            commitment.principalExposed += exposureShare;
        }
    }

    function _allocateRepayment(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 interestComponent,
        uint256 principalComponent
    ) internal {
        if (interestComponent == 0 && principalComponent == 0) {
            return;
        }

        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 totalExposed;
        uint256 activeCommitmentCount;
        uint256 len = lenderPositionIds.length;

        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.principalExposed != 0) {
                totalExposed += commitment.principalExposed;
                activeCommitmentCount++;
            }
        }

        if (totalExposed == 0 || activeCommitmentCount == 0) {
            return;
        }

        uint256 remainingInterest = interestComponent;
        uint256 remainingPrincipal = principalComponent;
        uint256 seenActiveCommitments;
        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment = store.lineCommitments[lineId][lenderPositionIds[i]];
            if (commitment.principalExposed == 0) {
                continue;
            }

            seenActiveCommitments++;
            uint256 interestShare = remainingInterest;
            uint256 principalShare = remainingPrincipal;
            if (seenActiveCommitments != activeCommitmentCount) {
                interestShare = Math.mulDiv(interestComponent, commitment.principalExposed, totalExposed);
                principalShare = Math.mulDiv(principalComponent, commitment.principalExposed, totalExposed);
                remainingInterest -= interestShare;
                remainingPrincipal -= principalShare;
            }

            commitment.interestReceived += interestShare;
            commitment.principalRepaid += principalShare;
            commitment.principalExposed -= principalShare;
        }
    }

    function _recordPaymentRecord(
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store,
        uint256 lineId,
        uint256 effectiveAmount,
        uint256 principalComponent,
        uint256 interestComponent
    ) internal {
        store.paymentRecords[lineId].push(
            LibEqualScaleAlphaStorage.PaymentRecord({
                paidAt: uint40(block.timestamp),
                amount: effectiveAmount,
                principalComponent: principalComponent,
                interestComponent: interestComponent
            })
        );
    }

    function _accrueInterest(LibEqualScaleAlphaStorage.CreditLine storage line) internal {
        uint40 accruedAt = line.interestAccruedAt;
        if (accruedAt == 0 || line.outstandingPrincipal == 0) {
            line.interestAccruedAt = uint40(block.timestamp);
            return;
        }

        uint256 elapsed = block.timestamp - uint256(accruedAt);
        if (elapsed == 0) {
            return;
        }

        uint256 accrued = Math.mulDiv(line.outstandingPrincipal, uint256(line.aprBps) * elapsed, BPS_DENOMINATOR * YEAR_SECS);
        if (accrued != 0) {
            line.accruedInterest += accrued;
            line.interestAccruedSinceLastDue += accrued;
        }
        line.interestAccruedAt = uint40(block.timestamp);
    }

    function _requiredMinimumDue(LibEqualScaleAlphaStorage.CreditLine storage line) internal view returns (uint256) {
        return line.interestAccruedSinceLastDue > line.minimumPaymentPerPeriod
            ? line.interestAccruedSinceLastDue
            : line.minimumPaymentPerPeriod;
    }

    function _advanceDueCheckpoint(LibEqualScaleAlphaStorage.CreditLine storage line) internal {
        line.nextDueAt += line.paymentIntervalSecs;
        line.interestAccruedSinceLastDue = 0;
        line.paidSinceLastDue = 0;
    }

    function _cureLineIfCovered(LibEqualScaleAlphaStorage.CreditLine storage line, bool minimumDueSatisfied) internal {
        if (line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent && minimumDueSatisfied) {
            if (line.delinquentSince != 0) {
                line.delinquentSince = 0;
            }
            line.missedPayments = 0;
            line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Active;
            return;
        }

        if (
            line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff
                && line.outstandingPrincipal <= line.currentCommittedAmount
        ) {
            _restartLineTerm(line, line.currentCommittedAmount);
        }
    }

    function _restartLineTerm(LibEqualScaleAlphaStorage.CreditLine storage line, uint256 activeLimit) internal {
        uint40 restartedAt = uint40(block.timestamp);
        line.status = LibEqualScaleAlphaStorage.CreditLineStatus.Active;
        line.activeLimit = activeLimit;
        line.currentPeriodDrawn = 0;
        line.currentPeriodStartedAt = restartedAt;
        line.interestAccruedAt = restartedAt;
        line.nextDueAt = restartedAt + line.paymentIntervalSecs;
        line.termStartedAt = restartedAt;
        line.termEndAt = restartedAt + line.facilityTermSecs;
        line.refinanceEndAt = line.termEndAt + line.refinanceWindowSecs;
        line.delinquentSince = 0;
        line.missedPayments = 0;
        line.interestAccruedSinceLastDue = 0;
        line.paidSinceLastDue = 0;
    }

    function _reduceBorrowerDebt(
        Types.PoolData storage settlementPool,
        uint256 settlementPoolId,
        bytes32 borrowerPositionKey,
        uint256 principalComponent
    ) internal {
        uint256 sameAssetDebt = settlementPool.userSameAssetDebt[borrowerPositionKey];
        settlementPool.userSameAssetDebt[borrowerPositionKey] =
            sameAssetDebt > principalComponent ? sameAssetDebt - principalComponent : 0;

        Types.ActiveCreditState storage debtState = settlementPool.userActiveCreditStateDebt[borrowerPositionKey];
        uint256 debtPrincipalBefore = debtState.principal;
        uint256 debtDecrease = debtPrincipalBefore > principalComponent ? principalComponent : debtPrincipalBefore;
        LibActiveCreditIndex.applyPrincipalDecrease(settlementPool, debtState, debtDecrease);

        if (debtPrincipalBefore <= principalComponent || debtState.principal == 0) {
            LibActiveCreditIndex.resetIfZeroWithGate(debtState, settlementPoolId, borrowerPositionKey, true);
        } else {
            debtState.indexSnapshot = settlementPool.activeCreditIndex;
        }

        if (settlementPool.activeCreditPrincipalTotal >= debtDecrease) {
            settlementPool.activeCreditPrincipalTotal -= debtDecrease;
        } else {
            settlementPool.activeCreditPrincipalTotal = 0;
        }
    }

    function _repaymentAllowed(LibEqualScaleAlphaStorage.CreditLineStatus status) internal pure returns (bool) {
        return status == LibEqualScaleAlphaStorage.CreditLineStatus.Active
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent
            || status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen;
    }

    function _emitCreditPaymentMade(
        uint256 lineId,
        uint256 effectiveAmount,
        uint256 principalComponent,
        uint256 interestComponent,
        LibEqualScaleAlphaStorage.CreditLine storage line
    ) internal {
        emit CreditPaymentMade(
            lineId,
            effectiveAmount,
            principalComponent,
            interestComponent,
            line.outstandingPrincipal,
            line.accruedInterest,
            line.nextDueAt
        );
    }

    function _statusMutationReason(uint256 lineId, LibEqualScaleAlphaStorage.CreditLineStatus status)
        internal
        pure
        returns (string memory)
    {
        return string(abi.encodePacked("proposal not mutable in status ", _statusLabel(status), " for line ", _toString(lineId)));
    }

    function _statusLabel(LibEqualScaleAlphaStorage.CreditLineStatus status) internal pure returns (string memory) {
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow) return "SoloWindow";
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen) return "PooledOpen";
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.Active) return "Active";
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing) return "Refinancing";
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff) return "Runoff";
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent) return "Delinquent";
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen) return "Frozen";
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.ChargedOff) return "ChargedOff";
        if (status == LibEqualScaleAlphaStorage.CreditLineStatus.Closed) return "Closed";
        return "Unknown";
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            unchecked {
                ++digits;
            }
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            unchecked {
                --digits;
            }
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _availablePrincipal(Types.PoolData storage pool, bytes32 positionKey, uint256 pid)
        internal
        view
        returns (uint256 available)
    {
        uint256 principal = pool.userPrincipal[positionKey];
        uint256 totalEncumbered = LibEncumbrance.total(positionKey, pid);
        if (totalEncumbered >= principal) {
            return 0;
        }
        return principal - totalEncumbered;
    }

    function _settlementCommitmentModuleId(uint256 lineId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("equalscale.alpha.commitment.", lineId)));
    }

    function _borrowerCollateralModuleId(uint256 lineId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("equalscale.alpha.collateral.", lineId)));
    }

    function _settleSettlementPosition(uint256 settlementPoolId, bytes32 lenderPositionKey) internal {
        _settlePosition(settlementPoolId, lenderPositionKey);
    }

    function _settlePosition(uint256 poolId, bytes32 positionKey) internal {
        LibActiveCreditIndex.settle(poolId, positionKey);
        LibFeeIndex.settle(poolId, positionKey);
    }

    function _positionNft() internal view returns (PositionNFT positionNft) {
        address positionNftAddress = LibPositionNFT.s().positionNFTContract;
        if (positionNftAddress == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        positionNft = PositionNFT(positionNftAddress);
    }

    function _countsForFutureCoverage(LibEqualScaleAlphaStorage.CommitmentStatus status) internal pure returns (bool) {
        return status == LibEqualScaleAlphaStorage.CommitmentStatus.Active
            || status == LibEqualScaleAlphaStorage.CommitmentStatus.Rolled;
    }

    function _refinanceCommitmentMutable(LibEqualScaleAlphaStorage.CommitmentStatus status) internal pure returns (bool) {
        return status == LibEqualScaleAlphaStorage.CommitmentStatus.Active
            || status == LibEqualScaleAlphaStorage.CommitmentStatus.Rolled;
    }
}
