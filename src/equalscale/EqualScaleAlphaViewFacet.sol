// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {IERC8004IdentityRegistry} from "@agent-wallet-core/adapters/ERC8004IdentityAdapter.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "src/libraries/Errors.sol";
import {Types} from "src/libraries/Types.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

/// @notice Read-only EqualScale Alpha views over stored line state and live position-agent identity data.
contract EqualScaleAlphaViewFacet {
    uint256 internal constant VIEW_BPS_DENOMINATOR = 10_000;
    uint256 internal constant VIEW_YEAR_SECS = 365 days;

    struct BorrowerProfileView {
        bytes32 borrowerPositionKey;
        uint256 borrowerPositionId;
        address owner;
        address treasuryWallet;
        address bankrToken;
        bytes32 metadataHash;
        bool active;
        uint256 agentId;
        uint8 registrationMode;
        address tbaAddress;
        address externalAuthorizer;
        bool canonicalLink;
        bool externalLink;
        bool registrationComplete;
    }

    struct DrawPreview {
        uint256 requestedAmount;
        uint256 maxDrawableAmount;
        uint256 availableLineCapacity;
        uint256 remainingPeriodCapacity;
        uint256 poolLiquidity;
        uint256 currentPeriodDrawn;
        uint256 nextCurrentPeriodDrawn;
        uint256 projectedOutstandingPrincipal;
        bool eligible;
        bool drawsFrozen;
        LibEqualScaleAlphaStorage.CreditLineStatus status;
    }

    struct RepayPreview {
        uint256 requestedAmount;
        uint256 effectiveAmount;
        uint256 totalOutstanding;
        uint256 outstandingPrincipal;
        uint256 accruedInterest;
        uint256 interestComponent;
        uint256 principalComponent;
        uint256 currentMinimumDue;
        bool minimumDueSatisfied;
        uint256 remainingOutstandingPrincipal;
        uint256 remainingAccruedInterest;
        uint40 nextDueAt;
        LibEqualScaleAlphaStorage.CreditLineStatus status;
    }

    struct LenderPositionCommitmentView {
        uint256 lineId;
        LibEqualScaleAlphaStorage.Commitment commitment;
    }

    struct LineLossSummaryView {
        uint256 totalPrincipalExposed;
        uint256 totalPrincipalRepaid;
        uint256 totalInterestReceived;
        uint256 totalRecoveryReceived;
        uint256 totalLossWrittenDown;
        uint256 commitmentCount;
        bool hasRecognizedLoss;
    }

    function getBorrowerProfile(uint256 borrowerPositionId) external view returns (BorrowerProfileView memory view_) {
        PositionNFT positionNft = _positionNftContract();
        bytes32 borrowerPositionKey = positionNft.getPositionKey(borrowerPositionId);
        LibEqualScaleAlphaStorage.BorrowerProfile storage profile =
            LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];

        view_.borrowerPositionKey = borrowerPositionKey;
        view_.borrowerPositionId = borrowerPositionId;
        view_.owner = positionNft.ownerOf(borrowerPositionId);
        view_.treasuryWallet = profile.treasuryWallet;
        view_.bankrToken = profile.bankrToken;
        view_.metadataHash = profile.metadataHash;
        view_.active = profile.active;

        _fillLiveIdentity(view_, borrowerPositionId);
    }

    function getCreditLine(uint256 lineId) external view returns (LibEqualScaleAlphaStorage.CreditLine memory) {
        return LibEqualScaleAlphaStorage.s().lines[lineId];
    }

    function getBorrowerLineIds(uint256 borrowerPositionId) external view returns (uint256[] memory) {
        bytes32 borrowerPositionKey = _positionNftContract().getPositionKey(borrowerPositionId);
        return LibEqualScaleAlphaStorage.s().borrowerLineIds[borrowerPositionKey];
    }

    function getLineCommitments(uint256 lineId)
        external
        view
        returns (LibEqualScaleAlphaStorage.Commitment[] memory commitments)
    {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 len = lenderPositionIds.length;

        commitments = new LibEqualScaleAlphaStorage.Commitment[](len);
        for (uint256 i = 0; i < len; i++) {
            commitments[i] = store.lineCommitments[lineId][lenderPositionIds[i]];
        }
    }

    function getLenderPositionCommitments(uint256 lenderPositionId)
        external
        view
        returns (LenderPositionCommitmentView[] memory commitments)
    {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        uint256[] storage lineIds = store.lenderPositionLineIds[lenderPositionId];
        uint256 len = lineIds.length;

        commitments = new LenderPositionCommitmentView[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 lineId = lineIds[i];
            commitments[i] =
                LenderPositionCommitmentView({lineId: lineId, commitment: store.lineCommitments[lineId][lenderPositionId]});
        }
    }

    function previewDraw(uint256 lineId, uint256 amount) external view returns (DrawPreview memory preview) {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        uint256 currentPeriodDrawn = _effectiveCurrentPeriodDrawn(line);
        uint256 availableLineCapacity = line.activeLimit > line.outstandingPrincipal
            ? line.activeLimit - line.outstandingPrincipal
            : 0;
        uint256 remainingPeriodCapacity = line.maxDrawPerPeriod > currentPeriodDrawn
            ? line.maxDrawPerPeriod - currentPeriodDrawn
            : 0;
        uint256 poolLiquidity = _poolLiquidity(line.settlementPoolId);
        uint256 maxDrawableAmount = _min(_min(availableLineCapacity, remainingPeriodCapacity), poolLiquidity);
        bool eligible = line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active && amount != 0
            && maxDrawableAmount >= amount;

        preview = DrawPreview({
            requestedAmount: amount,
            maxDrawableAmount: maxDrawableAmount,
            availableLineCapacity: availableLineCapacity,
            remainingPeriodCapacity: remainingPeriodCapacity,
            poolLiquidity: poolLiquidity,
            currentPeriodDrawn: currentPeriodDrawn,
            nextCurrentPeriodDrawn: eligible ? currentPeriodDrawn + amount : currentPeriodDrawn,
            projectedOutstandingPrincipal: eligible ? line.outstandingPrincipal + amount : line.outstandingPrincipal,
            eligible: eligible,
            drawsFrozen: line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active,
            status: line.status
        });
    }

    function previewLineRepay(uint256 lineId, uint256 amount) external view returns (RepayPreview memory preview) {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        (uint256 accruedInterest,, uint256 minimumDue) = _liveAccounting(line);
        uint256 totalOutstanding = line.outstandingPrincipal + accruedInterest;
        uint256 effectiveAmount = amount > totalOutstanding ? totalOutstanding : amount;
        uint256 interestComponent = effectiveAmount > accruedInterest ? accruedInterest : effectiveAmount;
        uint256 principalComponent = effectiveAmount - interestComponent;

        preview = RepayPreview({
            requestedAmount: amount,
            effectiveAmount: effectiveAmount,
            totalOutstanding: totalOutstanding,
            outstandingPrincipal: line.outstandingPrincipal,
            accruedInterest: accruedInterest,
            interestComponent: interestComponent,
            principalComponent: principalComponent,
            currentMinimumDue: minimumDue,
            minimumDueSatisfied: minimumDue == 0 || line.paidSinceLastDue + effectiveAmount >= minimumDue,
            remainingOutstandingPrincipal: line.outstandingPrincipal > principalComponent
                ? line.outstandingPrincipal - principalComponent
                : 0,
            remainingAccruedInterest: accruedInterest > interestComponent ? accruedInterest - interestComponent : 0,
            nextDueAt: line.nextDueAt,
            status: line.status
        });
    }

    function isLineDrawEligible(uint256 lineId, uint256 amount) external view returns (bool) {
        DrawPreview memory preview = this.previewDraw(lineId, amount);
        return preview.eligible;
    }

    function currentMinimumDue(uint256 lineId) external view returns (uint256) {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];
        (, , uint256 minimumDue) = _liveAccounting(line);
        return minimumDue;
    }

    function getTreasuryTelemetry(uint256 lineId)
        external
        view
        returns (LibEqualScaleAlphaStorage.TreasuryTelemetryView memory telemetry)
    {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        LibEqualScaleAlphaStorage.CreditLine storage line = store.lines[lineId];
        LibEqualScaleAlphaStorage.BorrowerProfile storage profile = store.borrowerProfiles[line.borrowerPositionKey];
        Types.PoolData storage settlementPool = LibAppStorage.s().pools[line.settlementPoolId];
        (uint256 accruedInterest,, uint256 minimumDue) = _liveAccounting(line);

        telemetry.treasuryBalance = _walletBalance(settlementPool.underlying, profile.treasuryWallet, settlementPool.initialized);
        telemetry.outstandingPrincipal = line.outstandingPrincipal;
        telemetry.accruedInterest = accruedInterest;
        telemetry.nextDueAmount = minimumDue;
        telemetry.paymentCurrent = !_hasLivePaymentSchedule(line)
            || block.timestamp <= uint256(line.nextDueAt) + line.gracePeriodSecs;
        telemetry.drawsFrozen = line.status != LibEqualScaleAlphaStorage.CreditLineStatus.Active;
        telemetry.currentPeriodDrawn = _effectiveCurrentPeriodDrawn(line);
        telemetry.maxDrawPerPeriod = line.maxDrawPerPeriod;
        telemetry.status = line.status;
    }

    function getRefinanceStatus(uint256 lineId)
        external
        view
        returns (LibEqualScaleAlphaStorage.RefinanceStatusView memory view_)
    {
        LibEqualScaleAlphaStorage.CreditLine storage line = LibEqualScaleAlphaStorage.s().lines[lineId];

        view_.termEndAt = line.termEndAt;
        view_.refinanceEndAt = line.refinanceEndAt;
        view_.currentCommittedAmount = line.currentCommittedAmount;
        view_.activeLimit = line.activeLimit;
        view_.outstandingPrincipal = line.outstandingPrincipal;
        view_.refinanceWindowActive = line.termEndAt != 0 && block.timestamp >= line.termEndAt
            && block.timestamp < line.refinanceEndAt;
    }

    function getLineLossSummary(uint256 lineId) external view returns (LineLossSummaryView memory summary) {
        LibEqualScaleAlphaStorage.EqualScaleAlphaStorage storage store = LibEqualScaleAlphaStorage.s();
        uint256[] storage lenderPositionIds = store.lineCommitmentPositionIds[lineId];
        uint256 len = lenderPositionIds.length;

        summary.commitmentCount = len;
        for (uint256 i = 0; i < len; i++) {
            LibEqualScaleAlphaStorage.Commitment storage commitment =
                store.lineCommitments[lineId][lenderPositionIds[i]];
            summary.totalPrincipalExposed += commitment.principalExposed;
            summary.totalPrincipalRepaid += commitment.principalRepaid;
            summary.totalInterestReceived += commitment.interestReceived;
            summary.totalRecoveryReceived += commitment.recoveryReceived;
            summary.totalLossWrittenDown += commitment.lossWrittenDown;
        }
        summary.hasRecognizedLoss = summary.totalLossWrittenDown != 0;
    }

    function _fillLiveIdentity(BorrowerProfileView memory view_, uint256 positionId) internal view {
        LibPositionAgentStorage.AgentStorage storage wallet = LibPositionAgentStorage.s();

        view_.agentId = wallet.positionToAgentId[positionId];
        view_.registrationMode = uint8(wallet.positionRegistrationMode[positionId]);
        view_.externalAuthorizer = wallet.externalAgentAuthorizer[positionId];
        view_.canonicalLink =
            wallet.positionRegistrationMode[positionId] == LibPositionAgentStorage.AgentRegistrationMode.CanonicalOwned;
        view_.externalLink =
            wallet.positionRegistrationMode[positionId] == LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked;

        if (
            wallet.erc6551Registry == address(0) || wallet.erc6551Implementation == address(0)
                || wallet.erc6551Registry.code.length == 0
        ) {
            return;
        }

        view_.tbaAddress = IERC6551Registry(wallet.erc6551Registry).account(
            wallet.erc6551Implementation,
            wallet.tbaSalt,
            block.chainid,
            address(_positionNftContract()),
            positionId
        );

        if (view_.agentId == 0 || wallet.identityRegistry == address(0) || wallet.identityRegistry.code.length == 0) {
            return;
        }

        (bool ok, bytes memory data) = wallet.identityRegistry.staticcall(
            abi.encodeWithSelector(IERC8004IdentityRegistry.ownerOf.selector, view_.agentId)
        );
        if (!ok || data.length < 32) {
            return;
        }

        address registryOwner = abi.decode(data, (address));
        if (view_.canonicalLink) {
            view_.registrationComplete = registryOwner == view_.tbaAddress;
        } else if (view_.externalLink) {
            view_.registrationComplete = registryOwner == view_.externalAuthorizer;
        }
    }

    function _liveAccounting(LibEqualScaleAlphaStorage.CreditLine storage line)
        internal
        view
        returns (uint256 accruedInterest, uint256 accruedInterestSinceLastDue, uint256 minimumDue)
    {
        uint256 pendingInterest = _pendingInterest(line);
        accruedInterest = line.accruedInterest + pendingInterest;
        accruedInterestSinceLastDue = line.interestAccruedSinceLastDue + pendingInterest;
        minimumDue = _hasLivePaymentSchedule(line)
            ? _max(accruedInterestSinceLastDue, line.minimumPaymentPerPeriod)
            : 0;
    }

    function _pendingInterest(LibEqualScaleAlphaStorage.CreditLine storage line) internal view returns (uint256) {
        if (
            line.interestAccruedAt == 0 || line.outstandingPrincipal == 0
                || block.timestamp <= uint256(line.interestAccruedAt)
        ) {
            return 0;
        }

        uint256 elapsed = block.timestamp - uint256(line.interestAccruedAt);
        return Math.mulDiv(
            line.outstandingPrincipal, uint256(line.aprBps) * elapsed, VIEW_BPS_DENOMINATOR * VIEW_YEAR_SECS
        );
    }

    function _effectiveCurrentPeriodDrawn(LibEqualScaleAlphaStorage.CreditLine storage line)
        internal
        view
        returns (uint256)
    {
        if (
            line.currentPeriodStartedAt == 0 || line.paymentIntervalSecs == 0
                || block.timestamp < uint256(line.currentPeriodStartedAt) + line.paymentIntervalSecs
        ) {
            return line.currentPeriodDrawn;
        }

        return 0;
    }

    function _poolLiquidity(uint256 settlementPoolId) internal view returns (uint256) {
        Types.PoolData storage settlementPool = LibAppStorage.s().pools[settlementPoolId];
        return settlementPool.initialized ? settlementPool.trackedBalance : 0;
    }

    function _walletBalance(address underlying, address wallet, bool poolInitialized) internal view returns (uint256) {
        if (!poolInitialized || wallet == address(0)) {
            return 0;
        }
        if (LibCurrency.isNative(underlying)) {
            return wallet.balance;
        }
        if (underlying.code.length == 0) {
            return 0;
        }
        return IERC20(underlying).balanceOf(wallet);
    }

    function _hasLivePaymentSchedule(LibEqualScaleAlphaStorage.CreditLine storage line) internal view returns (bool) {
        if (line.nextDueAt == 0) {
            return false;
        }

        return line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active
            || line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing
            || line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff
            || line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent
            || line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen;
    }

    function _positionNftContract() internal view returns (PositionNFT positionNft) {
        address positionNftAddress = LibPositionNFT.s().positionNFTContract;
        if (positionNftAddress == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        positionNft = PositionNFT(positionNftAddress);
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
