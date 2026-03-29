// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "src/libraries/Errors.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

interface IPositionAgentIdentityRead {
    function getAgentId(uint256 positionTokenId) external view returns (uint256);
    function isRegistrationComplete(uint256 positionTokenId) external view returns (bool);
}

/// @notice Borrower-profile writes for EqualScale Alpha.
contract EqualScaleAlphaFacet is IEqualScaleAlphaEvents, IEqualScaleAlphaErrors {
    uint40 internal constant SOLO_WINDOW_DURATION = 3 days;
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

    function _requireBorrowerPositionOwner(uint256 positionId) internal view returns (bytes32 borrowerPositionKey) {
        PositionNFT positionNft = _positionNft();
        address owner = positionNft.ownerOf(positionId);
        if (owner != msg.sender) {
            revert BorrowerPositionNotOwned(msg.sender, positionId);
        }

        borrowerPositionKey = positionNft.getPositionKey(positionId);
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

    function _positionNft() internal view returns (PositionNFT positionNft) {
        address positionNftAddress = LibPositionNFT.s().positionNFTContract;
        if (positionNftAddress == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        positionNft = PositionNFT(positionNftAddress);
    }
}
