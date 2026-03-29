// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DeployEdenByEqualFi} from "script/DeployEdenByEqualFi.s.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionMSCAImpl} from "src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {Types} from "src/libraries/Types.sol";
import {ProtocolTestSupportFacet} from "test/utils/ProtocolTestSupport.sol";
import {
    MockEntryPointLaunch,
    MockERC6551RegistryLaunch,
    MockIdentityRegistryLaunch
} from "test/utils/PositionAgentBootstrapMocks.sol";

contract MockERC20EqualScale is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PositionNFTTransferHookStub {
    function cancelOffersForPosition(bytes32) external pure {}

    function hasOpenOffers(bytes32) external pure returns (bool) {
        return false;
    }

    function getPositionTokenURI(uint256) external pure returns (string memory) {
        return "";
    }
}

contract EqualScaleAlphaIntegrationTest is DeployEdenByEqualFi {
    uint256 internal constant EVE_POOL_ID = 1;
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
    uint256 internal constant COLLATERAL_AMOUNT = 250e18;

    address internal treasury = _addr("treasury");
    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal carol = _addr("carol");
    address internal dave = _addr("dave");
    address internal borrowerTreasury = _addr("equalscale-borrower-treasury");

    address internal diamond;
    PositionNFT internal positionNft;
    ProtocolTestSupportFacet internal testSupport;

    MockERC20EqualScale internal eve;
    MockERC20EqualScale internal alt;
    MockEntryPointLaunch internal entryPoint;
    MockERC6551RegistryLaunch internal erc6551Registry;
    MockIdentityRegistryLaunch internal identityRegistry;
    PositionMSCAImpl internal positionMSCAImplementation;

    function setUp() public virtual {
        entryPoint = new MockEntryPointLaunch();
        erc6551Registry = new MockERC6551RegistryLaunch();
        identityRegistry = new MockIdentityRegistryLaunch();
        eve = new MockERC20EqualScale("EVE", "EVE");
        alt = new MockERC20EqualScale("ALT", "ALT");

        BaseDeployment memory deployment = deployBase(address(this), treasury);
        diamond = deployment.diamond;
        positionNft = PositionNFT(deployment.positionNFT);

        _installEqualScaleFixtureFacets();

        positionMSCAImplementation = new PositionMSCAImpl(address(entryPoint));
        PositionAgentConfigFacet(diamond).setERC6551Registry(address(erc6551Registry));
        PositionAgentConfigFacet(diamond).setERC6551Implementation(address(positionMSCAImplementation));
        PositionAgentConfigFacet(diamond).setIdentityRegistry(address(identityRegistry));

        Types.PoolConfig memory config = _poolConfig();
        Types.ActionFeeSet memory actionFees = _actionFees();
        PoolManagementFacet(diamond).setDefaultPoolConfig(config);
        PoolManagementFacet(diamond).initPoolWithActionFees(EVE_POOL_ID, address(eve), config, actionFees);
        PoolManagementFacet(diamond).initPoolWithActionFees(SETTLEMENT_POOL_ID, address(alt), config, actionFees);
    }

    function test_registerBorrowerProfile_usesExistingERC8004WalletRegistrationPath() external {
        uint256 borrowerPositionId = _mintPoolPosition(alice, SETTLEMENT_POOL_ID);

        assertTrue(!PositionAgentViewFacet(diamond).isRegistrationComplete(borrowerPositionId));

        uint256 agentId = _recordCanonicalAgentRegistration(alice, borrowerPositionId);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).registerBorrowerProfile(
            borrowerPositionId, borrowerTreasury, address(eve), keccak256("alice-profile")
        );

        EqualScaleAlphaViewFacet.BorrowerProfileView memory profile =
            EqualScaleAlphaViewFacet(diamond).getBorrowerProfile(borrowerPositionId);

        assertEq(profile.borrowerPositionId, borrowerPositionId);
        assertEq(profile.owner, alice);
        assertEq(profile.treasuryWallet, borrowerTreasury);
        assertEq(profile.bankrToken, address(eve));
        assertEq(profile.metadataHash, keccak256("alice-profile"));
        assertEq(profile.agentId, agentId);
        assertTrue(profile.active);
        assertTrue(profile.canonicalLink);
        assertTrue(profile.registrationComplete);
    }

    function test_unsecuredSoloLine_flowsFromRequestToDrawToRepayToClose() external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        uint256 lenderPositionId = _fundSettlementPosition(bob, TARGET_LIMIT);

        vm.prank(alice);
        uint256 lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());

        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitSolo(lineId, lenderPositionId);

        vm.prank(carol);
        EqualScaleAlphaFacet(diamond).activateLine(lineId);

        EqualScaleAlphaViewFacet.DrawPreview memory drawPreview =
            EqualScaleAlphaViewFacet(diamond).previewDraw(lineId, MAX_DRAW_PER_PERIOD);
        assertTrue(drawPreview.eligible);
        assertEq(drawPreview.maxDrawableAmount, MAX_DRAW_PER_PERIOD);

        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, MAX_DRAW_PER_PERIOD);

        assertEq(alt.balanceOf(borrowerTreasury), MAX_DRAW_PER_PERIOD);

        vm.warp(block.timestamp + 15 days);

        uint256 repayAmount = _fullRepayAmount(lineId);
        alt.mint(alice, repayAmount);
        vm.startPrank(alice);
        alt.approve(diamond, repayAmount);
        EqualScaleAlphaFacet(diamond).repayLine(lineId, repayAmount);
        EqualScaleAlphaFacet(diamond).closeLine(lineId);
        vm.stopPrank();

        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        LibEqualScaleAlphaStorage.Commitment[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);

        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Closed));
        assertEq(line.outstandingPrincipal, 0);
        assertEq(line.accruedInterest, 0);
        assertEq(line.currentCommittedAmount, 0);
        assertEq(line.activeLimit, 0);
        assertEq(commitments.length, 1);
        assertEq(commitments[0].principalRepaid, MAX_DRAW_PER_PERIOD);
        assertGt(commitments[0].interestReceived, 0);
        assertEq(uint256(commitments[0].status), uint256(LibEqualScaleAlphaStorage.CommitmentStatus.Closed));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "line not active for draw")
        );
        EqualScaleAlphaFacet(diamond).draw(lineId, 1);

        vm.prank(bob);
        PositionManagementFacet(diamond).withdrawFromPosition(
            lenderPositionId, SETTLEMENT_POOL_ID, TARGET_LIMIT, TARGET_LIMIT
        );
        assertEq(alt.balanceOf(bob), TARGET_LIMIT);
    }

    function test_pooledLine_usesRealMultipleLenderPositionsAndProRataAccounting() external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) =
            _createActivePooledLine(borrowerPositionId, params, 600e18, 400e18);

        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, 500e18);

        LibEqualScaleAlphaStorage.Commitment[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);
        EqualScaleAlphaViewFacet.LenderPositionCommitmentView[] memory lenderCommitments =
            EqualScaleAlphaViewFacet(diamond).getLenderPositionCommitments(lenderPositionOne);

        assertEq(commitments.length, 2);
        assertEq(commitments[0].lenderPositionId, lenderPositionOne);
        assertEq(commitments[0].principalExposed, 300e18);
        assertEq(commitments[1].lenderPositionId, lenderPositionTwo);
        assertEq(commitments[1].principalExposed, 200e18);
        assertEq(lenderCommitments.length, 1);
        assertEq(lenderCommitments[0].lineId, lineId);
        assertEq(lenderCommitments[0].commitment.principalExposed, 300e18);

        alt.mint(alice, 250e18);
        vm.startPrank(alice);
        alt.approve(diamond, 250e18);
        EqualScaleAlphaFacet(diamond).repayLine(lineId, 250e18);
        vm.stopPrank();

        commitments = EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);
        assertEq(commitments[0].principalRepaid, 150e18);
        assertEq(commitments[0].principalExposed, 150e18);
        assertEq(commitments[1].principalRepaid, 100e18);
        assertEq(commitments[1].principalExposed, 100e18);
        assertEq(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).outstandingPrincipal, 250e18);
    }

    function test_borrowerCollateralizedLine_supportsOptionalCollateralRecovery() external {
        EqualScaleAlphaAdminFacet(diamond).setChargeOffThreshold(1 days);

        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, COLLATERAL_AMOUNT);
        bytes32 borrowerPositionKey = positionNft.getPositionKey(borrowerPositionId);

        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;
        params.collateralMode = LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted;
        params.borrowerCollateralPoolId = SETTLEMENT_POOL_ID;
        params.borrowerCollateralAmount = COLLATERAL_AMOUNT;

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
        EqualScaleAlphaViewFacet.LineLossSummaryView memory lossSummary =
            EqualScaleAlphaViewFacet(diamond).getLineLossSummary(lineId);

        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Closed));
        assertEq(commitments[0].lenderPositionId, lenderPositionOne);
        assertEq(commitments[0].recoveryReceived, 150e18);
        assertEq(commitments[0].lossWrittenDown, 150e18);
        assertEq(commitments[1].lenderPositionId, lenderPositionTwo);
        assertEq(commitments[1].recoveryReceived, 100e18);
        assertEq(commitments[1].lossWrittenDown, 100e18);
        assertEq(testSupport.principalOf(SETTLEMENT_POOL_ID, borrowerPositionKey), 0);
        assertEq(lossSummary.totalRecoveryReceived, COLLATERAL_AMOUNT);
        assertEq(lossSummary.totalLossWrittenDown, 250e18);
    }

    function test_refinancing_handlesFullRenewalResizedRenewalRunoffAndRunoffCure() external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        {
            (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) =
                _createActivePooledLine(borrowerPositionId, params, 700e18, 300e18);
            uint256 lenderPositionThree = _fundSettlementPosition(dave, 300e18);

            vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).termEndAt);
            EqualScaleAlphaFacet(diamond).enterRefinancing(lineId);

            vm.prank(bob);
            EqualScaleAlphaFacet(diamond).rollCommitment(lineId, lenderPositionOne);
            vm.prank(carol);
            EqualScaleAlphaFacet(diamond).exitCommitment(lineId, lenderPositionTwo);
            vm.prank(dave);
            EqualScaleAlphaFacet(diamond).commitPooled(lineId, lenderPositionThree, 300e18);

            vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).refinanceEndAt);
            EqualScaleAlphaFacet(diamond).resolveRefinancing(lineId);

            LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
            assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Active));
            assertEq(line.activeLimit, TARGET_LIMIT);
            assertEq(line.currentCommittedAmount, TARGET_LIMIT);
        }

        {
            (uint256 lineId,, uint256 lenderPositionTwo) =
                _createActivePooledLine(borrowerPositionId, params, 700e18, 300e18);

            vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).termEndAt);
            EqualScaleAlphaFacet(diamond).enterRefinancing(lineId);

            vm.prank(carol);
            EqualScaleAlphaFacet(diamond).exitCommitment(lineId, lenderPositionTwo);

            vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).refinanceEndAt);
            EqualScaleAlphaFacet(diamond).resolveRefinancing(lineId);

            LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
            assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Active));
            assertEq(line.activeLimit, 700e18);
            assertEq(line.currentCommittedAmount, 700e18);
        }

        {
            (uint256 lineId, uint256 lenderPositionOne,) =
                _createActivePooledLine(borrowerPositionId, params, 600e18, 400e18);

            vm.prank(alice);
            EqualScaleAlphaFacet(diamond).draw(lineId, 500e18);

            vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).termEndAt);
            EqualScaleAlphaFacet(diamond).enterRefinancing(lineId);

            vm.prank(bob);
            EqualScaleAlphaFacet(diamond).exitCommitment(lineId, lenderPositionOne);

            vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).refinanceEndAt);
            EqualScaleAlphaFacet(diamond).resolveRefinancing(lineId);

            LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
            assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Runoff));
            assertEq(line.activeLimit, 400e18);

            alt.mint(alice, 100e18);
            vm.startPrank(alice);
            alt.approve(diamond, 100e18);
            EqualScaleAlphaFacet(diamond).repayLine(lineId, 100e18);
            vm.stopPrank();

            line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
            assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Active));
            assertEq(line.outstandingPrincipal, 400e18);
            assertEq(line.activeLimit, 400e18);
            assertEq(line.currentCommittedAmount, 400e18);
        }
    }

    function test_delinquencyChargeOffAndLossRecognition_arePermissionlessAndProRata() external {
        EqualScaleAlphaAdminFacet(diamond).setChargeOffThreshold(1 days);

        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposal();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        (uint256 lineId,,) = _createActivePooledLine(borrowerPositionId, params, 600e18, 400e18);

        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).draw(lineId, 500e18);

        vm.warp(uint256(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).nextDueAt) + GRACE_PERIOD_SECS + 1);
        vm.prank(dave);
        EqualScaleAlphaFacet(diamond).markDelinquent(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent));

        vm.warp(block.timestamp + 1 days);
        vm.prank(dave);
        EqualScaleAlphaFacet(diamond).chargeOffLine(lineId);

        LibEqualScaleAlphaStorage.Commitment[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLineCommitments(lineId);

        line = EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId);
        assertEq(uint256(line.status), uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Closed));
        assertEq(commitments[0].lossWrittenDown, 300e18);
        assertEq(commitments[1].lossWrittenDown, 200e18);
        assertEq(uint256(commitments[0].status), uint256(LibEqualScaleAlphaStorage.CommitmentStatus.WrittenDown));
        assertEq(uint256(commitments[1].status), uint256(LibEqualScaleAlphaStorage.CommitmentStatus.WrittenDown));
    }

    function test_positionNFTTransfers_moveBorrowerControlAndLenderCommitmentRightsOnActiveLines() external {
        uint256 borrowerPositionId = _createRegisteredBorrower(alice, borrowerTreasury, 0);
        uint256 lenderPositionId = _fundSettlementPosition(bob, TARGET_LIMIT);

        vm.prank(alice);
        uint256 lineId = EqualScaleAlphaFacet(diamond).createLineProposal(borrowerPositionId, _defaultProposal());

        vm.prank(bob);
        EqualScaleAlphaFacet(diamond).commitSolo(lineId, lenderPositionId);
        vm.prank(alice);
        EqualScaleAlphaFacet(diamond).activateLine(lineId);

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, borrowerPositionId);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, alice, borrowerPositionId)
        );
        EqualScaleAlphaFacet(diamond).draw(lineId, 1);

        vm.prank(carol);
        EqualScaleAlphaFacet(diamond).draw(lineId, 100e18);

        EqualScaleAlphaViewFacet.BorrowerProfileView memory profile =
            EqualScaleAlphaViewFacet(diamond).getBorrowerProfile(borrowerPositionId);
        assertEq(profile.owner, carol);

        vm.prank(bob);
        positionNft.transferFrom(bob, dave, lenderPositionId);

        vm.warp(EqualScaleAlphaViewFacet(diamond).getCreditLine(lineId).termEndAt);
        EqualScaleAlphaFacet(diamond).enterRefinancing(lineId);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.LenderPositionNotOwned.selector, bob, lenderPositionId)
        );
        EqualScaleAlphaFacet(diamond).exitCommitment(lineId, lenderPositionId);

        vm.prank(dave);
        EqualScaleAlphaFacet(diamond).exitCommitment(lineId, lenderPositionId);

        EqualScaleAlphaViewFacet.LenderPositionCommitmentView[] memory commitments =
            EqualScaleAlphaViewFacet(diamond).getLenderPositionCommitments(lenderPositionId);
        assertEq(commitments.length, 1);
        assertEq(uint256(commitments[0].commitment.status), uint256(LibEqualScaleAlphaStorage.CommitmentStatus.Exited));
        assertEq(commitments[0].commitment.committedAmount, 0);
    }

    function _installEqualScaleFixtureFacets() internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](8);
        uint256 i;

        cuts[i++] = _cut(address(new PoolManagementFacet()), _selectorsPoolManagement());
        cuts[i++] = _cut(address(new PositionManagementFacet()), _selectorsPositionManagement());
        cuts[i++] = _cut(address(new PositionAgentConfigFacet()), _selectorsPositionAgentConfig());
        cuts[i++] = _cut(address(new PositionAgentViewFacet()), _selectorsPositionAgentView());
        cuts[i++] = _cut(address(new PositionAgentRegistryFacet()), _selectorsPositionAgentRegistry());
        cuts[i++] = _cut(address(new EqualScaleAlphaFacet()), _selectorsEqualScaleAlpha());
        cuts[i++] = _cut(address(new EqualScaleAlphaAdminFacet()), _selectorsEqualScaleAlphaAdmin());
        cuts[i++] = _cut(address(new EqualScaleAlphaViewFacet()), _selectorsEqualScaleAlphaView());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        ProtocolTestSupportFacet supportFacet = new ProtocolTestSupportFacet();
        PositionNFTTransferHookStub transferHookStub = new PositionNFTTransferHookStub();

        bytes4[] memory supportSelectors = new bytes4[](2);
        supportSelectors[0] = ProtocolTestSupportFacet.getPoolView.selector;
        supportSelectors[1] = ProtocolTestSupportFacet.principalOf.selector;

        bytes4[] memory transferHookSelectors = new bytes4[](3);
        transferHookSelectors[0] = PositionNFTTransferHookStub.cancelOffersForPosition.selector;
        transferHookSelectors[1] = PositionNFTTransferHookStub.hasOpenOffers.selector;
        transferHookSelectors[2] = PositionNFTTransferHookStub.getPositionTokenURI.selector;

        IDiamondCut.FacetCut[] memory supportCuts = new IDiamondCut.FacetCut[](2);
        supportCuts[0] = _cut(address(supportFacet), supportSelectors);
        supportCuts[1] = _cut(address(transferHookStub), transferHookSelectors);
        IDiamondCut(diamond).diamondCut(supportCuts, address(0), "");

        testSupport = ProtocolTestSupportFacet(diamond);
    }

    function _createRegisteredBorrower(address owner, address treasuryWallet, uint256 principalDeposit)
        internal
        returns (uint256 borrowerPositionId)
    {
        borrowerPositionId = principalDeposit == 0
            ? _mintPoolPosition(owner, SETTLEMENT_POOL_ID)
            : _mintPositionWithDeposit(owner, SETTLEMENT_POOL_ID, principalDeposit);
        _recordCanonicalAgentRegistration(owner, borrowerPositionId);

        vm.prank(owner);
        EqualScaleAlphaFacet(diamond).registerBorrowerProfile(
            borrowerPositionId, treasuryWallet, address(eve), keccak256(abi.encodePacked(owner, borrowerPositionId))
        );
    }

    function _recordCanonicalAgentRegistration(address owner, uint256 positionId) internal returns (uint256 agentId) {
        agentId = 10_000 + positionId;
        address tba = PositionAgentViewFacet(diamond).getTBAAddress(positionId);
        identityRegistry.setOwner(agentId, tba);

        vm.prank(owner);
        PositionAgentRegistryFacet(diamond).recordAgentRegistration(positionId, agentId);
    }

    function _fundSettlementPosition(address owner, uint256 amount) internal returns (uint256 positionId) {
        positionId = _mintPositionWithDeposit(owner, SETTLEMENT_POOL_ID, amount);
    }

    function _mintPoolPosition(address owner, uint256 poolId) internal returns (uint256 positionId) {
        vm.prank(owner);
        positionId = PositionManagementFacet(diamond).mintPosition(poolId);
    }

    function _mintPositionWithDeposit(address owner, uint256 poolId, uint256 amount)
        internal
        returns (uint256 positionId)
    {
        _poolToken(poolId).mint(owner, amount);

        vm.startPrank(owner);
        positionId = PositionManagementFacet(diamond).mintPosition(poolId);
        _poolToken(poolId).approve(diamond, amount);
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

    function _poolToken(uint256 poolId) internal view returns (MockERC20EqualScale token) {
        if (poolId == EVE_POOL_ID) {
            return eve;
        }
        if (poolId == SETTLEMENT_POOL_ID) {
            return alt;
        }
        revert("unknown pool");
    }

    function _fullRepayAmount(uint256 lineId) internal view returns (uint256) {
        return EqualScaleAlphaViewFacet(diamond).previewLineRepay(lineId, type(uint256).max).effectiveAmount;
    }

    function _selectorsEqualScaleAlpha() internal pure override returns (bytes4[] memory s) {
        s = new bytes4[](19);
        s[0] = EqualScaleAlphaFacet.registerBorrowerProfile.selector;
        s[1] = EqualScaleAlphaFacet.updateBorrowerProfile.selector;
        s[2] = EqualScaleAlphaFacet.createLineProposal.selector;
        s[3] = EqualScaleAlphaFacet.updateLineProposal.selector;
        s[4] = EqualScaleAlphaFacet.cancelLineProposal.selector;
        s[5] = EqualScaleAlphaFacet.commitSolo.selector;
        s[6] = EqualScaleAlphaFacet.transitionToPooledOpen.selector;
        s[7] = EqualScaleAlphaFacet.commitPooled.selector;
        s[8] = EqualScaleAlphaFacet.cancelCommitment.selector;
        s[9] = EqualScaleAlphaFacet.activateLine.selector;
        s[10] = EqualScaleAlphaFacet.draw.selector;
        s[11] = EqualScaleAlphaFacet.repayLine.selector;
        s[12] = EqualScaleAlphaFacet.enterRefinancing.selector;
        s[13] = EqualScaleAlphaFacet.rollCommitment.selector;
        s[14] = EqualScaleAlphaFacet.exitCommitment.selector;
        s[15] = EqualScaleAlphaFacet.resolveRefinancing.selector;
        s[16] = EqualScaleAlphaFacet.markDelinquent.selector;
        s[17] = EqualScaleAlphaFacet.chargeOffLine.selector;
        s[18] = EqualScaleAlphaFacet.closeLine.selector;
    }

    function _selectorsEqualScaleAlphaAdmin() internal pure override returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualScaleAlphaAdminFacet.freezeLine.selector;
        s[1] = EqualScaleAlphaAdminFacet.unfreezeLine.selector;
        s[2] = EqualScaleAlphaAdminFacet.setChargeOffThreshold.selector;
    }

    function _selectorsEqualScaleAlphaView() internal pure override returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = EqualScaleAlphaViewFacet.getBorrowerProfile.selector;
        s[1] = EqualScaleAlphaViewFacet.getCreditLine.selector;
        s[2] = EqualScaleAlphaViewFacet.getBorrowerLineIds.selector;
        s[3] = EqualScaleAlphaViewFacet.getLineCommitments.selector;
        s[4] = EqualScaleAlphaViewFacet.getLenderPositionCommitments.selector;
        s[5] = EqualScaleAlphaViewFacet.previewDraw.selector;
        s[6] = EqualScaleAlphaViewFacet.previewLineRepay.selector;
        s[7] = EqualScaleAlphaViewFacet.isLineDrawEligible.selector;
        s[8] = EqualScaleAlphaViewFacet.currentMinimumDue.selector;
        s[9] = EqualScaleAlphaViewFacet.getTreasuryTelemetry.selector;
        s[10] = EqualScaleAlphaViewFacet.getRefinanceStatus.selector;
        s[11] = EqualScaleAlphaViewFacet.getLineLossSummary.selector;
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

    function _poolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](1);
        fixedTerms[0] = Types.FixedTermConfig({durationSecs: 7 days, apyBps: 500});

        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 20;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1e18;
        cfg.minLoanAmount = 1e18;
        cfg.minTopupAmount = 1e18;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 10;
        cfg.aumFeeMaxBps = 100;
        cfg.fixedTermConfigs = fixedTerms;
    }

    function _actionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        actionFees.borrowFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.repayFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.withdrawFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.flashFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.closeRollingFee = Types.ActionFeeConfig({amount: 0, enabled: false});
    }

    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }

    function assertTrue(bool condition) internal pure {
        require(condition, "assertTrue failed");
    }

    function assertEq(uint256 left, uint256 right) internal pure {
        require(left == right, "assertEq(uint256) failed");
    }

    function assertEq(address left, address right) internal pure {
        require(left == right, "assertEq(address) failed");
    }

    function assertEq(bytes32 left, bytes32 right) internal pure {
        require(left == right, "assertEq(bytes32) failed");
    }

    function assertGt(uint256 left, uint256 right) internal pure {
        require(left > right, "assertGt failed");
    }
}
