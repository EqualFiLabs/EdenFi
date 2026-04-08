// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract EqualScaleAlphaLaunchTest is LaunchFixture {
    uint256 internal constant SETTLEMENT_POOL_ID = 2;
    uint256 internal constant TARGET_LIMIT = 1_000e18;
    uint256 internal constant MINIMUM_VIABLE_LINE = 400e18;
    uint16 internal constant APR_BPS = 1_200;
    uint256 internal constant MINIMUM_PAYMENT_PER_PERIOD = 50e18;
    uint256 internal constant MAX_DRAW_PER_PERIOD = 300e18;
    uint32 internal constant PAYMENT_INTERVAL_SECS = 30 days;
    uint32 internal constant GRACE_PERIOD_SECS = 5 days;
    uint40 internal constant FACILITY_TERM_SECS = 90 days;
    uint40 internal constant REFINANCE_WINDOW_SECS = 7 days;
    uint40 internal constant SOLO_WINDOW_DURATION = 3 days;

    address internal borrowerTreasury = _addr("equalscale-launch-borrower-treasury");
    address internal dave = _addr("equalscale-launch-dave");

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_LiveLaunch_EqualScaleAlpha_SoloLifecycleSupportsTimelockFreezeAndUserExit() external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        uint256 lenderPositionId = _fundSettlementPosition(bob, TARGET_LIMIT);
        bytes32 lenderPositionKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(alice);
        uint256 lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());

        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitSolo(lineId, lenderPositionId);
        assertEq(testSupport.encumberedCapitalOf(lenderPositionKey, SETTLEMENT_POOL_ID), TARGET_LIMIT);

        vm.prank(carol);
        EqualScaleAlphaFacet(diamond).activateLine(lineId);

        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, MAX_DRAW_PER_PERIOD);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(EqualScaleAlphaAdminFacet.freezeLine.selector, lineId, keccak256("ops-freeze"))
        );

        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Frozen));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "line not active for draw")
        );
        EqualScaleAlphaFacet(diamond).draw(lineId, 1);

        _timelockCall(diamond, abi.encodeWithSelector(EqualScaleAlphaAdminFacet.unfreezeLine.selector, lineId));

        line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Active));

        uint256 repayAmount = _fullRepayAmount(lineId);
        alt.mint(alice, repayAmount);
        vm.startPrank(alice);
        alt.approve(diamond, repayAmount);
        EqualScaleAlphaFacet(diamond).repayLine(lineId, repayAmount);
        EqualScaleAlphaFacet(diamond).closeLine(lineId);
        vm.stopPrank();

        line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Closed));
        assertEq(line.outstandingPrincipal, 0);
        assertEq(testSupport.encumberedCapitalOf(lenderPositionKey, SETTLEMENT_POOL_ID), 0);

        vm.prank(bob);
        PositionManagementFacet(diamond).withdrawFromPosition(
            lenderPositionId, SETTLEMENT_POOL_ID, TARGET_LIMIT, TARGET_LIMIT
        );
        assertEq(alt.balanceOf(bob), TARGET_LIMIT);
    }

    function test_LiveLaunch_EqualScaleAlpha_TimelockChargeOffThresholdControlsResolution() external {
        _timelockCall(diamond, abi.encodeWithSelector(EqualScaleAlphaAdminFacet.setChargeOffThreshold.selector, 1 days));

        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) =
            _createActivePooledLine(borrowerPositionId, params, 600e18, 400e18);

        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, 500e18);

        vm.warp(uint256(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).nextDueAt) + GRACE_PERIOD_SECS + 1);
        vm.prank(dave);
        EqualScaleAlphaFacet(diamond).markDelinquent(lineId);

        vm.warp(block.timestamp + 1 days);
        vm.prank(dave);
        EqualScaleAlphaFacet(diamond).chargeOffLine(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        LibEqualScaleAlphaStorage.Commitment[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);

        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Closed));
        assertEq(commitments.length, 2);
        assertEq(commitments[0].lossWrittenDown, 300e18);
        assertEq(commitments[1].lossWrittenDown, 200e18);
        assertEq(testSupport.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionOne), SETTLEMENT_POOL_ID), 0);
        assertEq(testSupport.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionTwo), SETTLEMENT_POOL_ID), 0);
    }

    function test_LiveLaunch_EqualScaleAlpha_FreezeIntegrityBlocksRefinancingUntilUnfreeze() external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        uint256 lenderPositionId = _fundSettlementPosition(bob, TARGET_LIMIT);

        vm.prank(alice);
        uint256 lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());

        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitSolo(lineId, lenderPositionId);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).activateLine(lineId);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(EqualScaleAlphaAdminFacet.freezeLine.selector, lineId, keccak256("ops-freeze"))
        );

        vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).termEndAt);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "line not active for refinancing")
        );
        EqualScaleAlphaFacet(diamond).enterRefinancing(lineId);

        _timelockCall(diamond, abi.encodeWithSelector(EqualScaleAlphaAdminFacet.unfreezeLine.selector, lineId));
        EqualScaleAlphaFacet(diamond).enterRefinancing(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing));
    }

    function _createRegisteredBorrower(address owner, address treasuryWallet, uint256 principalDeposit)
        internal
        returns (uint256 borrowerPositionId)
    {
        borrowerPositionId = principalDeposit == 0
            ? _mintPosition(owner, SETTLEMENT_POOL_ID)
            : _mintPositionWithDeposit(owner, SETTLEMENT_POOL_ID, principalDeposit);
        _recordCanonicalAgentRegistration(owner, borrowerPositionId);

        vm.prank(owner);
        EqualScaleAlphaFacet(diamond).registerBorrowerProfile(
            borrowerPositionId, treasuryWallet, address(eve), keccak256(abi.encodePacked(owner, borrowerPositionId))
        );
    }

    function _recordCanonicalAgentRegistration(address owner, uint256 positionId) internal returns (uint256 agentId) {
        agentId = 50_000 + positionId;
        address tba = PositionAgentViewFacet(diamond).getTBAAddress(positionId);
        identityRegistry.setOwner(agentId, tba);

        vm.prank(owner);
        PositionAgentRegistryFacet(diamond).recordAgentRegistration(positionId, agentId);
    }

    function _fundSettlementPosition(address owner, uint256 amount) internal returns (uint256 positionId) {
        positionId = _mintPositionWithDeposit(owner, SETTLEMENT_POOL_ID, amount);
    }

    function _mintPositionWithDeposit(address owner, uint256 poolId, uint256 amount)
        internal
        returns (uint256 positionId)
    {
        alt.mint(owner, amount);

        vm.startPrank(owner);
        positionId = PositionManagementFacet(diamond).mintPosition(poolId);
        alt.approve(diamond, amount);
        PositionManagementFacet(diamond).depositToPosition(positionId, poolId, amount, amount);
        vm.stopPrank();
    }

    function _createActivePooledLine(
        uint256 borrowerPositionId,
        EqualScaleAlphaFacet.LineProposalParams memory params,
        uint256 firstCommittedAmount,
        uint256 secondCommittedAmount
    ) internal returns (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) {
        vm.prank(alice);
        lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, params);

        _openLineToPooled(lineId);

        lenderPositionOne = _fundSettlementPosition(bob, firstCommittedAmount);
        lenderPositionTwo = _fundSettlementPosition(carol, secondCommittedAmount);

        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitPooled(lineId, lenderPositionOne, firstCommittedAmount);
        vm.prank(carol);
        EqualScaleAlphaFacet(diamond).commitPooled(lineId, lenderPositionTwo, secondCommittedAmount);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).activateLine(lineId);
    }

    function _openLineToPooled(uint256 lineId) internal {
        vm.warp(block.timestamp + SOLO_WINDOW_DURATION + 1);
        EqualScaleAlphaFacet(diamond).transitionToPooledOpen(lineId);
    }

    function _fullRepayAmount(uint256 lineId) internal view returns (uint256) {
        return EqualScaleAlphaViewFacet(diamond).previewLineRepay(lineId, type(uint256).max).effectiveAmount;
    }

    function _defaultProposal() internal pure returns (EqualScaleAlphaFacet.LineProposalParams memory params) {
        params = EqualScaleAlphaFacet.LineProposalParams({
            settlementPoolId: SETTLEMENT_POOL_ID,
            requestedTargetLimit: TARGET_LIMIT,
            minimumViableLine: MINIMUM_VIABLE_LINE,
            aprBps: APR_BPS,
            minimumPaymentPerPeriod: MINIMUM_PAYMENT_PER_PERIOD,
            maxDrawPerPeriod: MAX_DRAW_PER_PERIOD,
            paymentIntervalSecs: PAYMENT_INTERVAL_SECS,
            gracePeriodSecs: GRACE_PERIOD_SECS,
            facilityTermSecs: FACILITY_TERM_SECS,
            refinanceWindowSecs: REFINANCE_WINDOW_SECS,
            collateralMode: LibEqualScaleAlphaStorage.CollateralMode.None,
            borrowerCollateralPoolId: 0,
            borrowerCollateralAmount: 0
        });
    }
}
