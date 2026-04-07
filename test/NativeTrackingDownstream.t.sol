// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {SelfSecuredCreditFacet} from "src/equallend/SelfSecuredCreditFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract NativeTrackingDownstreamTest is LaunchFixture {
    uint256 internal constant NATIVE_PID = 1;
    uint256 internal constant ALT_PID = 2;

    uint256 internal constant STRIKE_PRICE = 2e18;
    uint256 internal constant CONTRACT_SIZE = 1;

    uint256 internal constant TARGET_LIMIT = 1_000 ether;
    uint256 internal constant MINIMUM_VIABLE_LINE = 400 ether;
    uint16 internal constant APR_BPS = 1_200;
    uint256 internal constant MINIMUM_PAYMENT_PER_PERIOD = 50 ether;
    uint256 internal constant MAX_DRAW_PER_PERIOD = 300 ether;
    uint32 internal constant PAYMENT_INTERVAL_SECS = 30 days;
    uint32 internal constant GRACE_PERIOD_SECS = 5 days;
    uint40 internal constant FACILITY_TERM_SECS = 90 days;
    uint40 internal constant REFINANCE_WINDOW_SECS = 7 days;

    address internal borrowerTreasury = _addr("native-tracking-borrower-treasury");
    OptionToken internal optionToken;

    function setUp() public override {
        super.setUp();
        vm.txGasPrice(0);

        _setDefaultPoolConfig(_poolConfig());
        _initPoolWithActionFees(NATIVE_PID, address(0), _poolConfig(), _actionFees());
        _initPoolWithActionFees(ALT_PID, address(alt), _poolConfig(), _actionFees());
        _installTestSupportFacet();

        optionToken = OptionToken(OptionTokenViewFacet(diamond).getOptionToken());

        vm.deal(alice, 2_000 ether);
        vm.deal(bob, 2_000 ether);
        vm.deal(carol, 2_000 ether);
        vm.deal(borrowerTreasury, 0);
    }

    function test_PositionClaimYield_NativeTrackedTotalDecrementsExactlyOnce() external {
        (uint256 positionId, bytes32 positionKey) = _fundNativePosition(alice, 10 ether);

        testSupport.setPoolYieldReserve(NATIVE_PID, 1 ether);
        testSupport.setUserAccruedYield(NATIVE_PID, positionKey, 1 ether);

        uint256 trackedBefore = testSupport.nativeTrackedTotal();
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        uint256 claimed = PositionManagementFacet(diamond).claimPositionYield(positionId, NATIVE_PID, alice, 1 ether);

        assertEq(claimed, 1 ether);
        assertEq(testSupport.nativeTrackedTotal(), trackedBefore - claimed);
        assertEq(alice.balance - aliceBefore, claimed);
    }

    function test_PositionWithdraw_NativeTrackedTotalDecrementsExactlyOnce() external {
        (uint256 positionId,) = _fundNativePosition(alice, 10 ether);

        uint256 trackedBefore = testSupport.nativeTrackedTotal();
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, NATIVE_PID, 4 ether, 4 ether);

        assertEq(trackedBefore - testSupport.nativeTrackedTotal(), 4 ether);
        assertEq(alice.balance - aliceBefore, 4 ether);
    }

    function test_OptionsExcessRefund_NativeTrackedTotalDecrementsExactlyOnce() external {
        (uint256 makerPositionId,) = _fundTokenPosition(carol, ALT_PID, 10 ether);
        _joinPool(carol, makerPositionId, NATIVE_PID);

        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 seriesId = _createNativeUnderlyingPutSeries(carol, makerPositionId, 3 ether, expiry);

        vm.prank(carol);
        optionToken.safeTransferFrom(carol, bob, seriesId, 1 ether, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1 ether);
        uint256 trackedBefore = testSupport.nativeTrackedTotal();

        vm.prank(bob);
        uint256 paid = OptionsFacet(diamond).exerciseOptions{value: 2 ether}(seriesId, 1 ether, bob, 2 ether, 2 ether);

        assertEq(paid, payment);
        assertEq(testSupport.nativeTrackedTotal() - trackedBefore, payment);
    }

    function test_SelfSecuredCreditDraw_NativeTrackedTotalDecrementsExactlyOnce() external {
        (uint256 positionId,) = _fundNativePosition(alice, 10 ether);

        uint256 trackedBefore = testSupport.nativeTrackedTotal();
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        uint256 received = SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, NATIVE_PID, 6 ether, 6 ether);

        assertEq(received, 6 ether);
        assertEq(trackedBefore - testSupport.nativeTrackedTotal(), 6 ether);
        assertEq(alice.balance - aliceBefore, 6 ether);
    }

    function test_EqualScaleDraw_NativeTrackedTotalDecrementsExactlyOnce() external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury);
        uint256 lenderPositionId = _fundNativePositionOnly(bob, TARGET_LIMIT);

        vm.prank(alice);
        uint256 lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());

        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitSolo(lineId, lenderPositionId);

        vm.prank(carol);
        EqualScaleAlphaFacet(diamond).activateLine(lineId);

        uint256 trackedBefore = testSupport.nativeTrackedTotal();
        uint256 treasuryBefore = borrowerTreasury.balance;

        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, MAX_DRAW_PER_PERIOD);

        assertEq(trackedBefore - testSupport.nativeTrackedTotal(), MAX_DRAW_PER_PERIOD);
        assertEq(borrowerTreasury.balance - treasuryBefore, MAX_DRAW_PER_PERIOD);
        assertEq(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).outstandingPrincipal, MAX_DRAW_PER_PERIOD);
    }

    function _fundNativePosition(address user, uint256 amount) internal returns (uint256 positionId, bytes32 positionKey) {
        vm.startPrank(user);
        positionId = PositionManagementFacet(diamond).mintPosition(NATIVE_PID);
        PositionManagementFacet(diamond).depositToPosition{value: amount}(positionId, NATIVE_PID, amount, amount);
        vm.stopPrank();
        positionKey = positionNft.getPositionKey(positionId);
    }

    function _fundNativePositionOnly(address user, uint256 amount) internal returns (uint256 positionId) {
        vm.startPrank(user);
        positionId = PositionManagementFacet(diamond).mintPosition(NATIVE_PID);
        PositionManagementFacet(diamond).depositToPosition{value: amount}(positionId, NATIVE_PID, amount, amount);
        vm.stopPrank();
    }

    function _fundTokenPosition(address user, uint256 pid, uint256 amount) internal returns (uint256 positionId, bytes32 positionKey) {
        alt.mint(user, amount);

        vm.startPrank(user);
        positionId = PositionManagementFacet(diamond).mintPosition(pid);
        alt.approve(diamond, amount);
        PositionManagementFacet(diamond).depositToPosition(positionId, pid, amount, amount);
        vm.stopPrank();

        positionKey = positionNft.getPositionKey(positionId);
    }

    function _joinPool(address user, uint256 positionId, uint256 pid) internal {
        vm.prank(user);
        PositionManagementFacet(diamond).joinPositionPool(positionId, pid);
    }

    function _createNativeUnderlyingPutSeries(address maker, uint256 positionId, uint256 totalSize, uint64 expiry)
        internal
        returns (uint256 seriesId)
    {
        LibOptionsStorage.CreateOptionSeriesParams memory params = LibOptionsStorage.CreateOptionSeriesParams({
            positionId: positionId,
            underlyingPoolId: NATIVE_PID,
            strikePoolId: ALT_PID,
            strikePrice: STRIKE_PRICE,
            expiry: expiry,
            totalSize: totalSize,
            contractSize: CONTRACT_SIZE,
            isCall: false,
            isAmerican: true
        });

        vm.prank(maker);
        seriesId = OptionsFacet(diamond).createOptionSeries(params);
    }

    function _createRegisteredBorrower(address owner, address treasuryWallet) internal returns (uint256 borrowerPositionId) {
        vm.prank(owner);
        borrowerPositionId = PositionManagementFacet(diamond).mintPosition(NATIVE_PID);
        _recordCanonicalAgentRegistration(owner, borrowerPositionId);

        vm.prank(owner);
        EqualScaleAlphaFacet(diamond).registerBorrowerProfile(
            borrowerPositionId, treasuryWallet, address(alt), keccak256(abi.encodePacked(owner, borrowerPositionId))
        );
    }

    function _recordCanonicalAgentRegistration(address owner, uint256 positionId) internal returns (uint256 agentId) {
        agentId = 70_000 + positionId;
        address tba = PositionAgentViewFacet(diamond).getTBAAddress(positionId);
        identityRegistry.setOwner(agentId, tba);

        vm.prank(owner);
        PositionAgentRegistryFacet(diamond).recordAgentRegistration(positionId, agentId);
    }

    function _defaultProposal() internal pure returns (EqualScaleAlphaFacet.LineProposalParams memory params) {
        params = EqualScaleAlphaFacet.LineProposalParams({
            settlementPoolId: NATIVE_PID,
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
