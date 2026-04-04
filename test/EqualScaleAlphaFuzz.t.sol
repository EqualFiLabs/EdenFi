// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";

import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

import {EqualScaleAlphaIntegrationTest} from "test/EqualScaleAlpha.t.sol";

contract EqualScaleAlphaFuzzInspector {
    function totalEncumbrance(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.total(positionKey, poolId);
    }

    function encumberedCapital(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, poolId).encumberedCapital;
    }

    function lockedCapital(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, poolId).lockedCapital;
    }
}

abstract contract EqualScaleAlphaFuzzBase is EqualScaleAlphaIntegrationTest {
    EqualScaleAlphaFuzzInspector internal inspector;

    function setUp() public virtual override {
        EqualScaleAlphaIntegrationTest.setUp();
        _installInspectorFacet();
    }

    function _installInspectorFacet() internal {
        EqualScaleAlphaFuzzInspector inspectorFacet = new EqualScaleAlphaFuzzInspector();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = EqualScaleAlphaFuzzInspector.totalEncumbrance.selector;
        selectors[1] = EqualScaleAlphaFuzzInspector.encumberedCapital.selector;
        selectors[2] = EqualScaleAlphaFuzzInspector.lockedCapital.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _cut(address(inspectorFacet), selectors);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        inspector = EqualScaleAlphaFuzzInspector(diamond);
    }

    function _boundUint(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        if (value < min) {
            value = min;
        }
        if (value > max) {
            uint256 size = max - min + 1;
            value = min + ((value - min) % size);
        }
        return value;
    }

    function _boundAmount(uint256 seed, uint256 minUnits, uint256 maxUnits) internal pure returns (uint256) {
        return _boundUint(seed, minUnits, maxUnits) * 1e18;
    }

    function _seededAddress(bytes32 label, uint256 seed) internal pure returns (address addr) {
        addr = address(uint160(uint256(keccak256(abi.encodePacked(label, seed)))));
        if (addr == address(0)) {
            addr = address(0xBEEF);
        }
    }

    function _distinctAddress(bytes32 label, uint256 seed, address forbiddenOne, address forbiddenTwo)
        internal
        pure
        returns (address addr)
    {
        addr = _seededAddress(label, seed);
        if (addr == forbiddenOne || addr == forbiddenTwo) {
            addr = address(uint160(uint256(keccak256(abi.encodePacked(label, seed, "fallback")))));
        }
        if (addr == address(0) || addr == forbiddenOne || addr == forbiddenTwo) {
            addr = address(0xA55A);
        }
    }

    function _createActiveSoloLine(uint256 borrowerPositionId, EqualScaleAlphaFacet.LineProposalParams memory params)
        internal
        returns (uint256 lineId, uint256 lenderPositionId)
    {
        vm.prank(alice);
        lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, params);

        lenderPositionId = _fundSettlementPosition(bob, params.requestedTargetLimit);
        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitSolo(lineId, lenderPositionId);

        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).activateLine(lineId);
    }

    function _createActiveFourLenderLine(uint256 borrowerPositionId, EqualScaleAlphaFacet.LineProposalParams memory params)
        internal
        returns (uint256 lineId, uint256[] memory lenderPositionIds)
    {
        uint256[] memory committedAmounts = new uint256[](4);
        committedAmounts[0] = 400e18;
        committedAmounts[1] = 300e18;
        committedAmounts[2] = 200e18;
        committedAmounts[3] = 100e18;

        address[] memory owners = new address[](4);
        owners[0] = bob;
        owners[1] = carol;
        owners[2] = dave;
        owners[3] = treasury;

        vm.prank(alice);
        lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, params);
        _openLineToPooled(lineId);

        lenderPositionIds = new uint256[](owners.length);
        for (uint256 i = 0; i < owners.length; i++) {
            lenderPositionIds[i] = _fundSettlementPosition(owners[i], committedAmounts[i]);
            vm.prank(owners[i]);
            EqualScaleAlphaFacet(diamond).commitPooled(lineId, lenderPositionIds[i], committedAmounts[i]);
        }

        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).activateLine(lineId);
    }

    function _sumCommittedAmount(LibEqualScaleAlphaStorage.Commitment[] memory commitments)
        internal
        pure
        returns (uint256 totalCommitted)
    {
        for (uint256 i = 0; i < commitments.length; i++) {
            totalCommitted += commitments[i].committedAmount;
        }
    }

    function _sumPrincipalExposed(LibEqualScaleAlphaStorage.Commitment[] memory commitments)
        internal
        pure
        returns (uint256 totalExposed)
    {
        for (uint256 i = 0; i < commitments.length; i++) {
            totalExposed += commitments[i].principalExposed;
        }
    }

    function _sumPrincipalRepaid(LibEqualScaleAlphaStorage.Commitment[] memory commitments)
        internal
        pure
        returns (uint256 totalPrincipalRepaid)
    {
        for (uint256 i = 0; i < commitments.length; i++) {
            totalPrincipalRepaid += commitments[i].principalRepaid;
        }
    }

    function _sumInterestReceived(LibEqualScaleAlphaStorage.Commitment[] memory commitments)
        internal
        pure
        returns (uint256 totalInterestReceived)
    {
        for (uint256 i = 0; i < commitments.length; i++) {
            totalInterestReceived += commitments[i].interestReceived;
        }
    }

    function _sumRecoveryReceived(LibEqualScaleAlphaStorage.Commitment[] memory commitments)
        internal
        pure
        returns (uint256 totalRecoveryReceived)
    {
        for (uint256 i = 0; i < commitments.length; i++) {
            totalRecoveryReceived += commitments[i].recoveryReceived;
        }
    }

    function _sumLossWrittenDown(LibEqualScaleAlphaStorage.Commitment[] memory commitments)
        internal
        pure
        returns (uint256 totalLossWrittenDown)
    {
        for (uint256 i = 0; i < commitments.length; i++) {
            totalLossWrittenDown += commitments[i].lossWrittenDown;
        }
    }

    function assertLe(uint256 left, uint256 right) internal pure {
        require(left <= right, "assertLe failed");
    }

    function assertGe(uint256 left, uint256 right) internal pure {
        require(left >= right, "assertGe failed");
    }
}

contract EqualScaleAlphaFuzzTest is EqualScaleAlphaFuzzBase {
    function testFuzz_BorrowerOwnershipGatingTracksCurrentPositionOwner(uint256 attackerSeed, uint96 drawSeed) external {
        address attacker = _distinctAddress(keccak256("borrower-attacker"), attackerSeed, alice, carol);
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, attacker, borrowerPositionId)
        );
        EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());

        (uint256 lineId,) = _createActiveSoloLine(borrowerPositionId, _defaultProposal());
        uint256 drawAmount = _boundAmount(drawSeed, 1, MAX_DRAW_PER_PERIOD / 1e18);

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, borrowerPositionId);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, alice, borrowerPositionId)
        );
        EqualScaleAlphaFacet(diamond).draw(lineId, drawAmount);

        vm.prank(carol);
        EqualScaleAlphaFacet(diamond).draw(lineId, drawAmount);

        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        EqualScaleAlphaViewFacet.BorrowerProfileView memory profile =
            EqualScaleAlphaViewFacet(diamond).getBorrowerProfile(borrowerPositionId);

        assertEq(line.outstandingPrincipal, drawAmount);
        assertEq(profile.owner, carol);
    }

    function testFuzz_LenderOwnershipGatingTracksCurrentPositionOwner(uint256 attackerSeed, uint96 commitSeed) external {
        address attacker = _distinctAddress(keccak256("lender-attacker"), attackerSeed, bob, carol);
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);

        vm.prank(alice);
        uint256 lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());
        _openLineToPooled(lineId);

        uint256 lenderPositionId = _fundSettlementPosition(bob, TARGET_LIMIT);
        uint256 commitAmount = _boundAmount(commitSeed, 1, TARGET_LIMIT / 1e18);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.LenderPositionNotOwned.selector, attacker, lenderPositionId)
        );
        EqualScaleAlphaFacet(diamond).commitPooled(lineId, lenderPositionId, commitAmount);

        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitPooled(lineId, lenderPositionId, commitAmount);

        vm.prank(bob);
        positionNft.transferFrom(bob, carol, lenderPositionId);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.LenderPositionNotOwned.selector, bob, lenderPositionId)
        );
        EqualScaleAlphaFacet(diamond).cancelCommitment(lineId, lenderPositionId);

        vm.prank(carol);
        EqualScaleAlphaFacet(diamond).cancelCommitment(lineId, lenderPositionId);

        LibEqualScaleAlphaStorage.Commitment[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);
        bytes32 lenderPositionKey = positionNft.getPositionKey(lenderPositionId);

        assertEq(commitments.length, 1);
        assertEq(commitments[0].committedAmount, 0);
        assertEq(uint256(commitments[0].status), uint256(LibEqualScaleAlphaStorage.CommitmentStatus.Canceled));
        assertEq(inspector.encumberedCapital(lenderPositionKey, SETTLEMENT_POOL_ID), 0);
    }

    function testFuzz_CommitmentEncumbranceNeverExceedsAvailableLenderPrincipal(
        uint96 principalSeed,
        uint96 firstCommitSeed,
        uint96 secondCommitSeed
    ) external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        uint256 principal = _boundAmount(principalSeed, 2, 2_000);
        uint256 lenderPositionId = _fundSettlementPosition(bob, principal);
        bytes32 lenderPositionKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(alice);
        uint256 lineOneId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());
        _openLineToPooled(lineOneId);

        vm.prank(alice);
        uint256 lineTwoId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());
        _openLineToPooled(lineTwoId);

        uint256 maxFirstCommit = principal < TARGET_LIMIT ? principal : TARGET_LIMIT;
        uint256 firstCommit = _boundUint(firstCommitSeed, 1e18, maxFirstCommit);

        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitPooled(lineOneId, lenderPositionId, firstCommit);

        uint256 remainingPrincipal = principal - firstCommit;
        uint256 secondCommit = _boundUint(secondCommitSeed, 1e18, TARGET_LIMIT);

        if (secondCommit > remainingPrincipal) {
            vm.prank(bob);
            vm.expectRevert();
            EqualScaleAlphaFacet(diamond).commitPooled(lineTwoId, lenderPositionId, secondCommit);
        } else {
            vm.prank(bob);
            EqualScaleAlphaFacet(diamond).commitPooled(lineTwoId, lenderPositionId, secondCommit);
        }

        LibEqualScaleAlphaStorage.CreditLine memory lineOne = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineOneId);
        LibEqualScaleAlphaStorage.CreditLine memory lineTwo = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineTwoId);
        uint256 totalEncumbrance = inspector.totalEncumbrance(lenderPositionKey, SETTLEMENT_POOL_ID);

        assertLe(totalEncumbrance, principal);
        assertLe(lineOne.currentCommittedAmount, TARGET_LIMIT);
        assertLe(lineTwo.currentCommittedAmount, TARGET_LIMIT);
        assertEq(inspector.encumberedCapital(lenderPositionKey, SETTLEMENT_POOL_ID), totalEncumbrance);
        assertEq(totalEncumbrance, lineOne.currentCommittedAmount + lineTwo.currentCommittedAmount);
    }

    function testFuzz_DrawCapacityAndPeriodCapRemainBounded(
        uint96 firstDrawSeed,
        uint96 secondDrawSeed,
        uint96 repaySeed,
        uint96 thirdDrawSeed
    ) external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.requestedTargetLimit = 800e18;
        params.minimumViableLine = 400e18;
        params.maxDrawPerPeriod = 300e18;

        (uint256 lineId,) = _createActiveSoloLine(borrowerPositionId, params);

        uint256 firstDraw = _boundAmount(firstDrawSeed, 1, params.maxDrawPerPeriod / 1e18);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, firstDraw);

        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertLe(line.outstandingPrincipal, line.activeLimit);
        assertLe(line.currentPeriodDrawn, line.maxDrawPerPeriod);

        uint256 secondDraw = _boundAmount(secondDrawSeed, 1, params.maxDrawPerPeriod / 1e18);
        EqualScaleAlphaViewFacet.DrawPreview memory secondPreview =
            EqualScaleAlphaViewFacet(diamond).previewDraw(lineId, secondDraw);
        if (secondPreview.eligible) {
            vm.prank(alice);
            EqualScaleAlphaFacet(diamond).draw(lineId, secondDraw);
        } else {
            vm.prank(alice);
            vm.expectRevert();
            EqualScaleAlphaFacet(diamond).draw(lineId, secondDraw);
        }

        line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertLe(line.outstandingPrincipal, line.activeLimit);
        assertLe(line.currentPeriodDrawn, line.maxDrawPerPeriod);

        EqualScaleAlphaViewFacet.RepayPreview memory repayPreview =
            EqualScaleAlphaViewFacet(diamond).previewLineRepay(lineId, type(uint256).max);
        uint256 repayAmount = repayPreview.effectiveAmount == 0 ? 0 : _boundUint(repaySeed, 1, repayPreview.effectiveAmount);
        if (repayAmount != 0) {
            alt.mint(alice, repayAmount);
            vm.startPrank(alice);
            alt.approve(diamond, repayAmount);
            EqualScaleAlphaFacet(diamond).repayLine(lineId, repayAmount);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + PAYMENT_INTERVAL_SECS + 1);

        EqualScaleAlphaViewFacet.DrawPreview memory thirdPreview =
            EqualScaleAlphaViewFacet(diamond).previewDraw(lineId, _boundAmount(thirdDrawSeed, 1, params.maxDrawPerPeriod / 1e18));
        if (thirdPreview.eligible) {
            vm.prank(alice);
            EqualScaleAlphaFacet(diamond).draw(lineId, thirdPreview.requestedAmount);
        }

        line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertLe(line.outstandingPrincipal, line.activeLimit);
        assertLe(line.currentPeriodDrawn, line.maxDrawPerPeriod);
    }

    function testFuzz_DrawRevertsWhenLineIsNotActive(uint8 statusSeed, uint96 drawSeed) external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        (uint256 lineId, uint256 lenderPositionId) = _createActiveSoloLine(borrowerPositionId, params);
        uint256 drawAmount = _boundAmount(drawSeed, 1, 100);

        uint256 branch = statusSeed % 3;
        if (branch == 0) {
            EqualScaleAlphaAdminFacet(diamond).freezeLine(lineId, keccak256("freeze"));
        } else if (branch == 1) {
            vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).termEndAt);
            EqualScaleAlphaFacet(diamond).enterRefinancing(lineId);
        } else {
            vm.prank(alice);
            EqualScaleAlphaFacet(diamond).closeLine(lineId);
        }

        vm.prank(alice);
        vm.expectRevert();
        EqualScaleAlphaFacet(diamond).draw(lineId, drawAmount);

        if (branch == 1) {
            vm.prank(bob);
            EqualScaleAlphaFacet(diamond).exitCommitment(lineId, lenderPositionId);
        }
    }

    function testFuzz_InterestAccrualAndPrincipalRepaymentRemainMonotonic(
        uint96 drawSeed,
        uint32 firstWarpSeed,
        uint96 firstRepaySeed,
        uint32 secondWarpSeed,
        uint96 secondRepaySeed
    ) external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        (uint256 lineId,) = _createActiveSoloLine(borrowerPositionId, _defaultProposal());

        uint256 drawAmount = _boundAmount(drawSeed, 100, MAX_DRAW_PER_PERIOD / 1e18);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, drawAmount);

        vm.warp(block.timestamp + _boundUint(firstWarpSeed, 1 days, 15 days));
        EqualScaleAlphaViewFacet.RepayPreview memory firstPreview =
            EqualScaleAlphaViewFacet(diamond).previewLineRepay(lineId, type(uint256).max);
        uint256 firstRepayAmount = _boundUint(firstRepaySeed, 1, firstPreview.effectiveAmount);
        alt.mint(alice, firstRepayAmount);
        vm.startPrank(alice);
        alt.approve(diamond, firstRepayAmount);
        EqualScaleAlphaFacet(diamond).repayLine(lineId, firstRepayAmount);
        vm.stopPrank();

        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        uint256 principalRepaidAfterFirst = line.totalPrincipalRepaid;
        assertLe(principalRepaidAfterFirst, drawAmount);

        vm.warp(block.timestamp + _boundUint(secondWarpSeed, 1 days, 15 days));
        EqualScaleAlphaViewFacet.RepayPreview memory secondPreview =
            EqualScaleAlphaViewFacet(diamond).previewLineRepay(lineId, type(uint256).max);
        if (secondPreview.effectiveAmount != 0) {
            uint256 secondRepayAmount = _boundUint(secondRepaySeed, 1, secondPreview.effectiveAmount);
            alt.mint(alice, secondRepayAmount);
            vm.startPrank(alice);
            alt.approve(diamond, secondRepayAmount);
            EqualScaleAlphaFacet(diamond).repayLine(lineId, secondRepayAmount);
            vm.stopPrank();
        }

        line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        LibEqualScaleAlphaStorage.Commitment[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);

        assertGe(line.totalPrincipalRepaid, principalRepaidAfterFirst);
        assertLe(line.totalPrincipalRepaid, drawAmount);
        assertEq(_sumPrincipalRepaid(commitments), line.totalPrincipalRepaid);
        assertEq(_sumInterestReceived(commitments), line.totalInterestRepaid);
    }

    function testFuzz_SatisfyingMinimumDueAdvancesNextDueExactlyOneInterval(uint96 drawSeed, uint32 warpSeed) external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        (uint256 lineId,) = _createActiveSoloLine(borrowerPositionId, _defaultProposal());

        uint256 drawAmount = _boundAmount(drawSeed, 100, MAX_DRAW_PER_PERIOD / 1e18);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, drawAmount);

        vm.warp(block.timestamp + _boundUint(warpSeed, 1 days, PAYMENT_INTERVAL_SECS - 1));

        LibEqualScaleAlphaStorage.CreditLine memory lineBefore = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        EqualScaleAlphaViewFacet.RepayPreview memory preview =
            EqualScaleAlphaViewFacet(diamond).previewLineRepay(lineId, type(uint256).max);

        alt.mint(alice, preview.currentMinimumDue);
        vm.startPrank(alice);
        alt.approve(diamond, preview.currentMinimumDue);
        EqualScaleAlphaFacet(diamond).repayLine(lineId, preview.currentMinimumDue);
        vm.stopPrank();

        LibEqualScaleAlphaStorage.CreditLine memory lineAfter = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertEq(lineAfter.nextDueAt, lineBefore.nextDueAt + PAYMENT_INTERVAL_SECS);
        assertEq(lineAfter.paidSinceLastDue, 0);
        assertEq(lineAfter.interestAccruedSinceLastDue, 0);
    }

    function testFuzz_ProRataRepaymentAndWriteDownConserveAcrossManyLenders(
        uint96 drawSeed,
        uint96 repaySeed
    ) external {
        EqualScaleAlphaAdminFacet(diamond).setChargeOffThreshold(1 days);

        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        (uint256 lineId,) = _createActiveFourLenderLine(borrowerPositionId, params);

        uint256 drawAmount = _boundAmount(drawSeed, 2, TARGET_LIMIT / 1e18);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, drawAmount);

        uint256 repayAmount = _boundUint(repaySeed, 1e18, drawAmount - 1);
        alt.mint(alice, repayAmount);
        vm.startPrank(alice);
        alt.approve(diamond, repayAmount);
        EqualScaleAlphaFacet(diamond).repayLine(lineId, repayAmount);
        vm.stopPrank();

        LibEqualScaleAlphaStorage.Commitment[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);
        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);

        assertEq(_sumPrincipalExposed(commitments), line.outstandingPrincipal);
        assertEq(_sumPrincipalRepaid(commitments), line.totalPrincipalRepaid);
        assertEq(_sumInterestReceived(commitments), 0);
        assertEq(line.outstandingPrincipal, drawAmount - repayAmount);

        uint256 outstandingBeforeChargeOff = line.outstandingPrincipal;
        vm.warp(uint256(line.nextDueAt) + GRACE_PERIOD_SECS + 1);
        EqualScaleAlphaFacet(diamond).markDelinquent(lineId);
        vm.warp(block.timestamp + 1 days);
        EqualScaleAlphaFacet(diamond).chargeOffLine(lineId);

        commitments = EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);
        line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);

        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Closed));
        assertEq(_sumPrincipalExposed(commitments), 0);
        assertEq(_sumPrincipalRepaid(commitments), repayAmount);
        assertEq(_sumRecoveryReceived(commitments), 0);
        assertEq(_sumLossWrittenDown(commitments), outstandingBeforeChargeOff);
    }

    function testFuzz_OptionalCollateralModesBehaveCorrectly(bool securedLine, uint96 drawSeed) external {
        EqualScaleAlphaAdminFacet(diamond).setChargeOffThreshold(1 days);

        uint256 borrowerPositionId =
            _createRegisteredBorrower(alice, borrowerTreasury, securedLine ? COLLATERAL_AMOUNT : 0);

        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;
        if (securedLine) {
            params.collateralMode = LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted;
            params.borrowerCollateralPoolId = SETTLEMENT_POOL_ID;
            params.borrowerCollateralAmount = COLLATERAL_AMOUNT;
        }

        (uint256 lineId,) = _createActiveFourLenderLine(borrowerPositionId, params);
        bytes32 borrowerPositionKey = positionNft.getPositionKey(borrowerPositionId);
        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);

        assertEq(
            inspector.lockedCapital(borrowerPositionKey, SETTLEMENT_POOL_ID),
            securedLine ? COLLATERAL_AMOUNT : 0
        );
        assertEq(line.lockedCollateralAmount, securedLine ? COLLATERAL_AMOUNT : 0);

        uint256 drawAmount = _boundAmount(drawSeed, 100, 500);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, drawAmount);

        line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        uint256 outstandingBeforeChargeOff = line.outstandingPrincipal;

        vm.warp(uint256(line.nextDueAt) + GRACE_PERIOD_SECS + 1);
        EqualScaleAlphaFacet(diamond).markDelinquent(lineId);
        vm.warp(block.timestamp + 1 days);
        EqualScaleAlphaFacet(diamond).chargeOffLine(lineId);

        LibEqualScaleAlphaStorage.Commitment[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);
        uint256 recoveryReceived = _sumRecoveryReceived(commitments);
        uint256 lossWrittenDown = _sumLossWrittenDown(commitments);

        if (securedLine) {
            uint256 expectedRecovery = outstandingBeforeChargeOff < COLLATERAL_AMOUNT
                ? outstandingBeforeChargeOff
                : COLLATERAL_AMOUNT;
            assertEq(recoveryReceived, expectedRecovery);
            assertEq(lossWrittenDown, outstandingBeforeChargeOff - expectedRecovery);
        } else {
            assertEq(recoveryReceived, 0);
            assertEq(lossWrittenDown, outstandingBeforeChargeOff);
        }

        assertEq(inspector.lockedCapital(borrowerPositionKey, SETTLEMENT_POOL_ID), 0);
        assertEq(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).lockedCollateralAmount, 0);
    }
}

contract EqualScaleAlphaOwnershipHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public immutable diamond;
    PositionNFT public immutable positionNft;
    uint256 public immutable borrowerPositionId;
    uint256 public immutable lenderPositionId;
    uint256 public immutable lineId;
    address public immutable bankrToken;

    address[] internal actors;

    uint256 public borrowerUnauthorizedSuccesses;
    uint256 public lenderUnauthorizedSuccesses;
    uint256 public borrowerOwnerSuccesses;
    uint256 public lenderOwnerSuccesses;

    constructor(
        address diamond_,
        PositionNFT positionNft_,
        uint256 borrowerPositionId_,
        uint256 lenderPositionId_,
        uint256 lineId_,
        address bankrToken_,
        address[] memory actors_
    ) {
        diamond = diamond_;
        positionNft = positionNft_;
        borrowerPositionId = borrowerPositionId_;
        lenderPositionId = lenderPositionId_;
        lineId = lineId_;
        bankrToken = bankrToken_;

        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
        }
    }

    function seedOwnerActions() external {
        _attemptBorrowerProfileUpdate(positionNft.ownerOf(borrowerPositionId), 1);
        _attemptLenderMutation(positionNft.ownerOf(lenderPositionId), 100e18);
        _attemptLenderMutation(positionNft.ownerOf(lenderPositionId), 100e18);
    }

    function transferBorrowerPosition(uint256 actorSeed) external {
        address currentOwner = positionNft.ownerOf(borrowerPositionId);
        address newOwner = _actor(actorSeed);
        if (newOwner == currentOwner) {
            return;
        }

        vm.prank(currentOwner);
        positionNft.transferFrom(currentOwner, newOwner, borrowerPositionId);
    }

    function transferLenderPosition(uint256 actorSeed) external {
        address currentOwner = positionNft.ownerOf(lenderPositionId);
        address newOwner = _actor(actorSeed);
        if (newOwner == currentOwner) {
            return;
        }

        vm.prank(currentOwner);
        positionNft.transferFrom(currentOwner, newOwner, lenderPositionId);
    }

    function attemptBorrowerProfileUpdate(uint256 actorSeed, uint256 metadataSeed) external {
        _attemptBorrowerProfileUpdate(_actor(actorSeed), metadataSeed);
    }

    function attemptLenderCommitmentMutation(uint256 actorSeed) external {
        _attemptLenderMutation(_actor(actorSeed), 100e18);
    }

    function _attemptBorrowerProfileUpdate(address actor, uint256 metadataSeed) internal {
        bool shouldSucceed = actor == positionNft.ownerOf(borrowerPositionId);
        bytes32 metadataHash = keccak256(abi.encodePacked("ownership-handler", metadataSeed));

        vm.prank(actor);
        (bool ok,) = diamond.call(
            abi.encodeWithSelector(
                EqualScaleAlphaFacet.updateBorrowerProfile.selector,
                borrowerPositionId,
                actor,
                bankrToken,
                metadataHash
            )
        );

        if (ok) {
            if (shouldSucceed) {
                borrowerOwnerSuccesses++;
            } else {
                borrowerUnauthorizedSuccesses++;
            }
        }
    }

    function _attemptLenderMutation(address actor, uint256 amount) internal {
        bool hasActiveCommitment = _hasActiveCommitment();
        bool shouldSucceed = actor == positionNft.ownerOf(lenderPositionId);

        bytes memory callData = hasActiveCommitment
            ? abi.encodeWithSelector(EqualScaleAlphaFacet.cancelCommitment.selector, lineId, lenderPositionId)
            : abi.encodeWithSelector(EqualScaleAlphaFacet.commitPooled.selector, lineId, lenderPositionId, amount);

        vm.prank(actor);
        (bool ok,) = diamond.call(callData);

        if (ok) {
            if (shouldSucceed) {
                lenderOwnerSuccesses++;
            } else {
                lenderUnauthorizedSuccesses++;
            }
        }
    }

    function _hasActiveCommitment() internal view returns (bool) {
        EqualScaleAlphaViewFacet.LenderPositionCommitmentView[] memory views =
            EqualScaleAlphaViewFacet(diamond).getLenderPositionCommitments(lenderPositionId);
        if (views.length == 0) {
            return false;
        }

        return views[0].commitment.committedAmount != 0
            && views[0].commitment.status == LibEqualScaleAlphaStorage.CommitmentStatus.Active;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

contract EqualScaleAlphaOwnershipInvariantTest is StdInvariant, EqualScaleAlphaFuzzBase {
    EqualScaleAlphaOwnershipHandler internal handler;

    function setUp() public override {
        EqualScaleAlphaFuzzBase.setUp();

        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);

        vm.prank(alice);
        uint256 lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());
        _openLineToPooled(lineId);

        uint256 lenderPositionId = _fundSettlementPosition(bob, 100e18);
        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitPooled(lineId, lenderPositionId, 100e18);

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;

        handler = new EqualScaleAlphaOwnershipHandler(
            diamond, positionNft, borrowerPositionId, lenderPositionId, lineId, address(eve), actors
        );
        handler.seedOwnerActions();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.transferBorrowerPosition.selector;
        selectors[1] = handler.transferLenderPosition.selector;
        selectors[2] = handler.attemptBorrowerProfileUpdate.selector;
        selectors[3] = handler.attemptLenderCommitmentMutation.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_BorrowerAndLenderMutationsStayPNFTOwned() public view {
        assertEq(handler.borrowerUnauthorizedSuccesses(), 0);
        assertEq(handler.lenderUnauthorizedSuccesses(), 0);
        assertGt(handler.borrowerOwnerSuccesses(), 0);
        assertGt(handler.lenderOwnerSuccesses(), 0);
    }
}
