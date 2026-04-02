// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";

interface IEqualScaleAlphaErrors {
    error BorrowerPositionNotOwned(address caller, uint256 borrowerPositionId);
    error LenderPositionNotOwned(address caller, uint256 lenderPositionId);
    error BorrowerIdentityNotRegistered(uint256 borrowerPositionId);
    error BorrowerProfileAlreadyActive(bytes32 borrowerPositionKey);
    error BorrowerProfileNotActive(bytes32 borrowerPositionKey);
    error InvalidTreasuryWallet();
    error InvalidBankrToken();
    error InvalidProposalTerms(string reason);
    error InvalidCollateralMode(
        LibEqualScaleAlphaStorage.CollateralMode collateralMode,
        uint256 borrowerCollateralPoolId,
        uint256 borrowerCollateralAmount
    );
    error InsufficientLenderPrincipal(uint256 lenderPositionId, uint256 requested, uint256 available);
    error InvalidDrawPacing(uint256 requested, uint256 currentPeriodDrawn, uint256 maxDrawPerPeriod);
    error DelinquencyTooEarly(uint256 lineId, uint40 nextDueAt, uint32 gracePeriodSecs, uint40 currentTimestamp);
    error ChargeOffTooEarly(uint256 lineId, uint40 delinquentSince, uint40 chargeOffThresholdSecs, uint40 currentTimestamp);
    error InvalidWriteDownState(uint256 lineId, LibEqualScaleAlphaStorage.CreditLineStatus status);
    error NoExposedPrincipalToWriteDown(uint256 lineId);
    error WriteDownAlreadyApplied(uint256 lineId, uint256 lenderPositionId);
}
