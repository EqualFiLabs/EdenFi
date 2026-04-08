// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {InsufficientPoolLiquidity, InvalidParameterRange} from "src/libraries/Errors.sol";
import {Types} from "src/libraries/Types.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {MockERC6551RegistryLaunch, MockIdentityRegistryLaunch} from "test/utils/PositionAgentBootstrapMocks.sol";

contract EqualScaleAlphaMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualScaleAlphaReenteringTreasury {
    EqualScaleAlphaFacetHarness internal immutable facet;

    bool internal armed;
    bool internal reentered;
    uint256 internal targetLineId;
    uint256 internal reentryAmount;

    constructor(EqualScaleAlphaFacetHarness facet_) {
        facet = facet_;
    }

    receive() external payable {
        if (armed && !reentered) {
            reentered = true;
            facet.draw(targetLineId, reentryAmount);
        }
    }

    function registerBorrowerProfile(
        uint256 positionId,
        address treasuryWallet,
        address bankrToken,
        bytes32 metadataHash
    ) external {
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, metadataHash);
    }

    function createLineProposal(uint256 borrowerPositionId, EqualScaleAlphaFacet.LineProposalParams calldata params)
        external
        returns (uint256 lineId)
    {
        return facet.createLineProposal(borrowerPositionId, params);
    }

    function activateLine(uint256 lineId) external {
        facet.activateLine(lineId);
    }

    function drawWithReentry(uint256 lineId, uint256 amount, uint256 nextAmount) external {
        targetLineId = lineId;
        reentryAmount = nextAmount;
        armed = true;
        facet.draw(lineId, amount);
        armed = false;
    }

    function didReenter() external view returns (bool) {
        return reentered;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract EqualScaleAlphaFacetHarness is
    EqualScaleAlphaFacet,
    EqualScaleAlphaAdminFacet,
    EqualScaleAlphaViewFacet,
    PositionManagementFacet,
    PositionAgentViewFacet
{
    function setPositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ds = LibPositionNFT.s();
        ds.positionNFTContract = nft;
        ds.nftModeEnabled = true;
    }

    function setPositionAgentViews(address erc6551Registry, address erc6551Implementation, address identityRegistry)
        external
    {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        ds.erc6551Registry = erc6551Registry;
        ds.erc6551Implementation = erc6551Implementation;
        ds.identityRegistry = identityRegistry;
    }

    function setPositionAgentRegistration(
        uint256 positionId,
        uint256 agentId,
        uint256 registrationMode,
        address externalAuthorizer
    ) external {
        if (registrationMode > uint256(LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked)) {
            revert("invalid registration mode");
        }

        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        ds.positionToAgentId[positionId] = agentId;
        ds.positionRegistrationMode[positionId] = LibPositionAgentStorage.AgentRegistrationMode(registrationMode);
        ds.externalAgentAuthorizer[positionId] = externalAuthorizer;
    }

    function borrowerProfile(bytes32 borrowerPositionKey)
        external
        view
        returns (bytes32 storedKey, address treasuryWallet, address bankrToken, bytes32 metadataHash, bool active)
    {
        LibEqualScaleAlphaStorage.BorrowerProfile storage
            profile = LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];
        return
            (
                profile.borrowerPositionKey,
                profile.treasuryWallet,
                profile.bankrToken,
                profile.metadataHash,
                profile.active
            );
    }

    function line(uint256 lineId) external view returns (LibEqualScaleAlphaStorage.CreditLine memory) {
        return LibEqualScaleAlphaStorage.s().lines[lineId];
    }

    function borrowerLineIds(bytes32 borrowerPositionKey) external view returns (uint256[] memory) {
        return LibEqualScaleAlphaStorage.s().borrowerLineIds[borrowerPositionKey];
    }

    function commitment(uint256 lineId, uint256 lenderPositionId)
        external
        view
        returns (LibEqualScaleAlphaStorage.Commitment memory)
    {
        return LibEqualScaleAlphaStorage.s().lineCommitments[lineId][lenderPositionId];
    }

    function lineCommitmentPositionIds(uint256 lineId) external view returns (uint256[] memory) {
        return LibEqualScaleAlphaStorage.s().lineCommitmentPositionIds[lineId];
    }

    function lenderPositionLineIds(uint256 lenderPositionId) external view returns (uint256[] memory) {
        return LibEqualScaleAlphaStorage.s().lenderPositionLineIds[lenderPositionId];
    }

    function configurePoolForDeposits(uint256 pid, address underlying, uint256 minDepositAmount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = underlying;
        p.poolConfig.minDepositAmount = minDepositAmount;
        p.poolConfig.minLoanAmount = 1;
        p.poolConfig.minTopupAmount = 1;
    }

    // Retained for the one synthetic liquidity-drift branch where tracked balance must diverge from funded principal.
    function setPoolTrackedBalance(uint256 pid, uint256 trackedBalance) external {
        LibAppStorage.s().pools[pid].trackedBalance = trackedBalance;
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function encumberedCapitalOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).encumberedCapital;
    }

    function lockedCapitalOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, pid).lockedCapital;
    }

    // Retained for state-machine edge coverage where the protocol does not expose a natural setup transition.
    function setLineCurrentCommittedAmount(uint256 lineId, uint256 currentCommittedAmount) external {
        LibEqualScaleAlphaStorage.s().lines[lineId].currentCommittedAmount = currentCommittedAmount;
    }

    // Retained for status-gating tests that need to jump directly into terminal or blocked states.
    function setLineStatus(uint256 lineId, uint256 statusRaw) external {
        if (statusRaw > uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Closed)) {
            revert("invalid status");
        }
        LibEqualScaleAlphaStorage.s().lines[lineId].status = LibEqualScaleAlphaStorage.CreditLineStatus(statusRaw);
    }

    function sameAssetDebt(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userSameAssetDebt[positionKey];
    }

    function debtActiveCreditState(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 principal, uint40 startTime, uint256 indexSnapshot)
    {
        Types.ActiveCreditState storage state = LibAppStorage.s().pools[pid].userActiveCreditStateDebt[positionKey];
        return (state.principal, state.startTime, state.indexSnapshot);
    }

    function poolTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function poolPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function poolActiveCreditPrincipalTotal(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function setChargeOffThresholdForTest(uint256 chargeOffThresholdSecs) external {
        if (chargeOffThresholdSecs > type(uint40).max) {
            revert("chargeOffThresholdSecs overflow");
        }
        LibEqualScaleAlphaStorage.s().chargeOffThresholdSecs = uint40(chargeOffThresholdSecs);
    }

    function setLineMissedPayments(uint256 lineId, uint256 missedPayments) external {
        if (missedPayments > type(uint8).max) {
            revert("missedPayments overflow");
        }
        LibEqualScaleAlphaStorage.s().lines[lineId].missedPayments = uint8(missedPayments);
    }

    function storedChargeOffThresholdSecs() external view returns (uint40) {
        return LibEqualScaleAlphaStorage.s().chargeOffThresholdSecs;
    }

    function previewLineInterest(uint256 lineId)
        external
        view
        returns (uint256 accruedInterest, uint256 accruedInterestSinceLastDue, uint256 requiredMinimumDue)
    {
        LibEqualScaleAlphaStorage.CreditLine storage creditLine = LibEqualScaleAlphaStorage.s().lines[lineId];

        uint256 pendingInterest;
        if (
            creditLine.interestAccruedAt != 0 && creditLine.outstandingPrincipal != 0
                && block.timestamp > creditLine.interestAccruedAt
        ) {
            uint256 elapsed = block.timestamp - uint256(creditLine.interestAccruedAt);
            pendingInterest = (creditLine.outstandingPrincipal * creditLine.aprBps * elapsed) / (10_000 * 365 days);
        }

        accruedInterest = creditLine.accruedInterest + pendingInterest;
        accruedInterestSinceLastDue = creditLine.interestAccruedSinceLastDue + pendingInterest;
        requiredMinimumDue = accruedInterestSinceLastDue > creditLine.minimumPaymentPerPeriod
            ? accruedInterestSinceLastDue
            : creditLine.minimumPaymentPerPeriod;
    }

    function paymentRecordCount(uint256 lineId) external view returns (uint256) {
        return LibEqualScaleAlphaStorage.s().paymentRecords[lineId].length;
    }

    function paymentRecord(uint256 lineId, uint256 index)
        external
        view
        returns (uint40 paidAt, uint256 amount, uint256 principalComponent, uint256 interestComponent)
    {
        LibEqualScaleAlphaStorage.PaymentRecord storage record =
            LibEqualScaleAlphaStorage.s().paymentRecords[lineId][index];
        return (record.paidAt, record.amount, record.principalComponent, record.interestComponent);
    }
}

contract EqualScaleAlphaFacetTest is IEqualScaleAlphaEvents {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant REGISTRATION_MODE_CANONICAL_OWNED = 1;
    uint256 internal constant SETTLEMENT_POOL_ID = 17;
    uint256 internal constant TARGET_LIMIT = 1_000e18;
    uint256 internal constant MINIMUM_VIABLE_LINE = 400e18;
    uint16 internal constant APR_BPS = 1_250;
    uint256 internal constant MINIMUM_PAYMENT_PER_PERIOD = 50e18;
    uint256 internal constant MAX_DRAW_PER_PERIOD = 300e18;
    uint32 internal constant PAYMENT_INTERVAL_SECS = 30 days;
    uint32 internal constant GRACE_PERIOD_SECS = 5 days;
    uint40 internal constant FACILITY_TERM_SECS = 90 days;
    uint40 internal constant REFINANCE_WINDOW_SECS = 7 days;
    uint256 internal constant COLLATERAL_POOL_ID = 9;
    uint256 internal constant COLLATERAL_AMOUNT = 250e18;
    bytes32 internal constant OPS_FREEZE_REASON = keccak256("ops-freeze");

    EqualScaleAlphaFacetHarness internal facet;
    EqualScaleAlphaMockERC20 internal settlementToken;
    PositionNFT internal positionNft;
    MockERC6551RegistryLaunch internal registry;
    MockIdentityRegistryLaunch internal identityRegistry;
    FixedDelayTimelockController internal timelockController;
    uint256 internal timelockSaltNonce;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA11);
    address internal dave = address(0xDA7E);
    address internal treasuryWallet = address(0xCAFE);
    address internal bankrToken = address(0xBEEF);

    function setUp() public {
        facet = new EqualScaleAlphaFacetHarness();
        settlementToken = new EqualScaleAlphaMockERC20("Settlement", "SET");
        positionNft = new PositionNFT();
        registry = new MockERC6551RegistryLaunch();
        identityRegistry = new MockIdentityRegistryLaunch();
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        timelockController = new FixedDelayTimelockController(proposers, executors, address(this));

        positionNft.setMinter(address(this));
        facet.setPositionNFT(address(positionNft));
        facet.setPositionAgentViews(address(registry), address(0x1234), address(identityRegistry));
        facet.configurePoolForDeposits(SETTLEMENT_POOL_ID, address(settlementToken), 1);
        facet.setTimelock(address(timelockController));
    }

    function test_registerBorrowerProfile_recordsMetadataAndResolvedAgentId() external {
        uint256 positionId = positionNft.mint(alice, 7);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        bytes32 metadataHash = keccak256("profile-metadata");
        uint256 agentId = 17;
        address tba = facet.getTBAAddress(positionId);

        facet.setPositionAgentRegistration(positionId, agentId, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(agentId, tba);

        vm.expectEmit(true, true, false, true, address(facet));
        emit BorrowerProfileRegistered(positionKey, positionId, treasuryWallet, bankrToken, agentId, metadataHash);

        vm.prank(alice);
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, metadataHash);

        (
            bytes32 storedKey,
            address storedTreasuryWallet,
            address storedBankrToken,
            bytes32 storedMetadataHash,
            bool active
        ) = facet.borrowerProfile(positionKey);

        require(storedKey == positionKey, "stored key mismatch");
        require(storedTreasuryWallet == treasuryWallet, "treasury wallet mismatch");
        require(storedBankrToken == bankrToken, "bankr token mismatch");
        require(storedMetadataHash == metadataHash, "metadata hash mismatch");
        require(active, "profile should be active");
        require(facet.getAgentId(positionId) == agentId, "agent id mismatch");
        require(facet.isRegistrationComplete(positionId), "registration should be complete");
    }

    function test_registerBorrowerProfile_revertsForNonOwner() external {
        uint256 positionId = positionNft.mint(alice, 7);
        uint256 agentId = 17;
        address tba = facet.getTBAAddress(positionId);

        facet.setPositionAgentRegistration(positionId, agentId, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(agentId, tba);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, bob, positionId)
        );
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("metadata"));
    }

    function test_registerBorrowerProfile_revertsWithoutCompletedAgentLink() external {
        uint256 positionId = positionNft.mint(alice, 7);

        facet.setPositionAgentRegistration(positionId, 17, REGISTRATION_MODE_CANONICAL_OWNED, address(0));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerIdentityNotRegistered.selector, positionId)
        );
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("metadata"));
    }

    function test_registerBorrowerProfile_reusesLiveWalletIdentityInsteadOfAlphaRegistryTruth() external {
        uint256 positionId = positionNft.mint(alice, 7);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        address tba = facet.getTBAAddress(positionId);

        facet.setPositionAgentRegistration(positionId, 17, REGISTRATION_MODE_CANONICAL_OWNED, address(0));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerIdentityNotRegistered.selector, positionId)
        );
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("metadata"));

        identityRegistry.setOwner(17, tba);

        vm.prank(alice);
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("metadata"));

        (bytes32 storedKey, address storedTreasuryWallet, address storedBankrToken,, bool active) =
            facet.borrowerProfile(positionKey);

        require(storedKey == positionKey, "stored key mismatch");
        require(storedTreasuryWallet == treasuryWallet, "treasury wallet mismatch");
        require(storedBankrToken == bankrToken, "bankr token mismatch");
        require(active, "profile should be active");

        identityRegistry.setOwner(17, bob);

        require(facet.getAgentId(positionId) == 17, "agent id should stay live");
        require(!facet.isRegistrationComplete(positionId), "registration should become incomplete");
    }

    function test_registerBorrowerProfile_revertsWhenProfileAlreadyActive() external {
        uint256 positionId = positionNft.mint(alice, 7);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 agentId = 17;
        address tba = facet.getTBAAddress(positionId);

        facet.setPositionAgentRegistration(positionId, agentId, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(agentId, tba);

        vm.startPrank(alice);
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("metadata"));
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerProfileAlreadyActive.selector, positionKey)
        );
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("metadata-2"));
        vm.stopPrank();
    }

    function test_updateBorrowerProfile_updatesAllMutableFields() external {
        uint256 positionId = positionNft.mint(alice, 7);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 agentId = 17;
        address tba = facet.getTBAAddress(positionId);
        address newTreasuryWallet = address(0xD00D);
        address newBankrToken = address(0xF00D);
        bytes32 newMetadataHash = keccak256("updated");

        facet.setPositionAgentRegistration(positionId, agentId, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(agentId, tba);

        vm.prank(alice);
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("initial"));

        vm.expectEmit(true, true, false, true, address(facet));
        emit BorrowerProfileUpdated(positionKey, positionId, newTreasuryWallet, newBankrToken, newMetadataHash);

        vm.prank(alice);
        facet.updateBorrowerProfile(positionId, newTreasuryWallet, newBankrToken, newMetadataHash);

        (, address storedTreasuryWallet, address storedBankrToken, bytes32 storedMetadataHash, bool active) =
            facet.borrowerProfile(positionKey);

        require(storedTreasuryWallet == newTreasuryWallet, "treasury wallet mismatch");
        require(storedBankrToken == newBankrToken, "bankr token mismatch");
        require(storedMetadataHash == newMetadataHash, "metadata hash mismatch");
        require(active, "profile should stay active");
    }

    function test_updateBorrowerProfile_revertsForNonOwner() external {
        uint256 positionId = positionNft.mint(alice, 7);
        uint256 agentId = 17;
        address tba = facet.getTBAAddress(positionId);

        facet.setPositionAgentRegistration(positionId, agentId, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(agentId, tba);

        vm.prank(alice);
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("initial"));

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, bob, positionId)
        );
        facet.updateBorrowerProfile(positionId, address(0xD00D), address(0xF00D), keccak256("updated"));
    }

    function test_updateBorrowerProfile_revertsForZeroTreasuryWallet() external {
        uint256 positionId = positionNft.mint(alice, 7);
        uint256 agentId = 17;
        address tba = facet.getTBAAddress(positionId);

        facet.setPositionAgentRegistration(positionId, agentId, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(agentId, tba);

        vm.prank(alice);
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("initial"));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidTreasuryWallet.selector));
        facet.updateBorrowerProfile(positionId, address(0), bankrToken, keccak256("updated"));
    }

    function test_updateBorrowerProfile_revertsForZeroBankrToken() external {
        uint256 positionId = positionNft.mint(alice, 7);
        uint256 agentId = 17;
        address tba = facet.getTBAAddress(positionId);

        facet.setPositionAgentRegistration(positionId, agentId, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(agentId, tba);

        vm.prank(alice);
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("initial"));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidBankrToken.selector));
        facet.updateBorrowerProfile(positionId, treasuryWallet, address(0), keccak256("updated"));
    }

    function test_createLineProposal_recordsTermsAndEmitsSoloWindowEvents() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint40 expectedSoloExclusiveUntil = uint40(block.timestamp + 3 days);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();

        vm.expectEmit(true, true, true, true, address(facet));
        emit LineProposalCreated(
            1,
            positionId,
            positionKey,
            SETTLEMENT_POOL_ID,
            TARGET_LIMIT,
            MINIMUM_VIABLE_LINE,
            APR_BPS,
            MINIMUM_PAYMENT_PER_PERIOD,
            MAX_DRAW_PER_PERIOD,
            PAYMENT_INTERVAL_SECS,
            GRACE_PERIOD_SECS,
            FACILITY_TERM_SECS,
            REFINANCE_WINDOW_SECS,
            LibEqualScaleAlphaStorage.CollateralMode.None,
            0,
            0
        );
        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineEnteredSoloWindow(1, expectedSoloExclusiveUntil);

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(positionId, params);

        require(lineId == 1, "unexpected first line id");

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.borrowerPositionId == positionId, "borrower position mismatch");
        require(line.borrowerPositionKey == positionKey, "borrower key mismatch");
        require(line.settlementPoolId == SETTLEMENT_POOL_ID, "settlement pool mismatch");
        require(line.requestedTargetLimit == TARGET_LIMIT, "target limit mismatch");
        require(line.minimumViableLine == MINIMUM_VIABLE_LINE, "min viable mismatch");
        require(line.aprBps == APR_BPS, "apr mismatch");
        require(line.minimumPaymentPerPeriod == MINIMUM_PAYMENT_PER_PERIOD, "minimum payment mismatch");
        require(line.maxDrawPerPeriod == MAX_DRAW_PER_PERIOD, "max draw mismatch");
        require(line.paymentIntervalSecs == PAYMENT_INTERVAL_SECS, "payment interval mismatch");
        require(line.gracePeriodSecs == GRACE_PERIOD_SECS, "grace mismatch");
        require(line.facilityTermSecs == FACILITY_TERM_SECS, "facility term mismatch");
        require(line.refinanceWindowSecs == REFINANCE_WINDOW_SECS, "refinance window mismatch");
        require(line.collateralMode == LibEqualScaleAlphaStorage.CollateralMode.None, "collateral mode mismatch");
        require(line.borrowerCollateralPoolId == 0, "unexpected collateral pool");
        require(line.borrowerCollateralAmount == 0, "unexpected collateral amount");
        require(line.soloExclusiveUntil == expectedSoloExclusiveUntil, "solo window mismatch");
        require(
            line.status == LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow, "proposal should start in solo window"
        );

        uint256[] memory lineIds = facet.borrowerLineIds(positionKey);
        require(lineIds.length == 1, "borrower line count mismatch");
        require(lineIds[0] == lineId, "borrower line id mismatch");
    }

    function test_createLineProposal_assignsStrictlyMonotonicLineIds() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory firstParams = _defaultProposalParamsNone();
        EqualScaleAlphaFacet.LineProposalParams memory secondParams = _borrowerPostedProposalParams();
        secondParams.settlementPoolId = SETTLEMENT_POOL_ID + 1;
        secondParams.requestedTargetLimit = TARGET_LIMIT + 1;

        vm.startPrank(alice);
        uint256 firstLineId = facet.createLineProposal(positionId, firstParams);
        uint256 secondLineId = facet.createLineProposal(positionId, secondParams);
        vm.stopPrank();

        require(secondLineId > firstLineId, "line ids should be monotonic");
    }

    function test_createLineProposal_revertsWithoutActiveBorrowerProfile() external {
        uint256 positionId = positionNft.mint(alice, 7);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerProfileNotActive.selector, positionKey));
        facet.createLineProposal(positionId, params);
    }

    function test_createLineProposal_revertsWhenMinimumViableLineExceedsTargetLimit() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.minimumViableLine = TARGET_LIMIT + 1;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "minimumViableLine > targetLimit"
            )
        );
        facet.createLineProposal(positionId, params);
    }

    function test_createLineProposal_revertsWhenMaxDrawPerPeriodExceedsTargetLimit() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT + 1;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "maxDrawPerPeriod > targetLimit"
            )
        );
        facet.createLineProposal(positionId, params);
    }

    function test_createLineProposal_revertsWhenCollateralModeNoneHasCollateralFields() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.borrowerCollateralPoolId = COLLATERAL_POOL_ID;
        params.borrowerCollateralAmount = COLLATERAL_AMOUNT;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidCollateralMode.selector,
                LibEqualScaleAlphaStorage.CollateralMode.None,
                COLLATERAL_POOL_ID,
                COLLATERAL_AMOUNT
            )
        );
        facet.createLineProposal(positionId, params);
    }

    function test_createLineProposal_revertsWhenBorrowerPostedCollateralFieldsMissing() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _borrowerPostedProposalParams();
        params.borrowerCollateralPoolId = 0;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidCollateralMode.selector,
                LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted,
                0,
                COLLATERAL_AMOUNT
            )
        );
        facet.createLineProposal(positionId, params);
    }

    function test_updateLineProposal_allowsBorrowerToChangePrefundingTerms() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        EqualScaleAlphaFacet.LineProposalParams memory initialParams = _defaultProposalParamsNone();
        EqualScaleAlphaFacet.LineProposalParams memory updatedParams = _updatedProposalParams();

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(positionId, initialParams);

        vm.expectEmit(true, true, true, true, address(facet));
        emit LineProposalUpdated(
            lineId,
            positionId,
            positionKey,
            SETTLEMENT_POOL_ID + 3,
            TARGET_LIMIT + 50e18,
            MINIMUM_VIABLE_LINE + 25e18,
            APR_BPS + 100,
            MINIMUM_PAYMENT_PER_PERIOD + 5e18,
            MAX_DRAW_PER_PERIOD + 10e18,
            PAYMENT_INTERVAL_SECS + 1 days,
            GRACE_PERIOD_SECS + 1 days,
            FACILITY_TERM_SECS + 10 days,
            REFINANCE_WINDOW_SECS + 1 days,
            LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted,
            COLLATERAL_POOL_ID,
            COLLATERAL_AMOUNT
        );

        vm.prank(alice);
        facet.updateLineProposal(lineId, updatedParams);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.borrowerPositionId == positionId, "borrower position changed");
        require(line.borrowerPositionKey == positionKey, "borrower key changed");
        require(line.settlementPoolId == SETTLEMENT_POOL_ID + 3, "settlement pool not updated");
        require(line.requestedTargetLimit == TARGET_LIMIT + 50e18, "target limit not updated");
        require(line.minimumViableLine == MINIMUM_VIABLE_LINE + 25e18, "min viable not updated");
        require(line.aprBps == APR_BPS + 100, "apr not updated");
        require(line.minimumPaymentPerPeriod == MINIMUM_PAYMENT_PER_PERIOD + 5e18, "minimum payment not updated");
        require(line.maxDrawPerPeriod == MAX_DRAW_PER_PERIOD + 10e18, "max draw not updated");
        require(line.paymentIntervalSecs == PAYMENT_INTERVAL_SECS + 1 days, "payment interval not updated");
        require(line.gracePeriodSecs == GRACE_PERIOD_SECS + 1 days, "grace not updated");
        require(line.facilityTermSecs == FACILITY_TERM_SECS + 10 days, "facility term not updated");
        require(line.refinanceWindowSecs == REFINANCE_WINDOW_SECS + 1 days, "refinance window not updated");
        require(
            line.collateralMode == LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted,
            "collateral mode not updated"
        );
        require(line.borrowerCollateralPoolId == COLLATERAL_POOL_ID, "collateral pool not updated");
        require(line.borrowerCollateralAmount == COLLATERAL_AMOUNT, "collateral amount not updated");
        require(
            line.status == LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow, "status should stay pre-activation"
        );
    }

    function test_updateLineProposal_revertsForNonOwner() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(positionId, params);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, bob, positionId)
        );
        facet.updateLineProposal(lineId, params);
    }

    function test_updateLineProposal_revertsWhenActiveCommitmentsExist() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(positionId, params);

        facet.setLineCurrentCommittedAmount(lineId, 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "proposal has active commitments"
            )
        );
        facet.updateLineProposal(lineId, params);
    }

    function test_cancelLineProposal_closesPrefundingProposal() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(positionId, params);

        vm.expectEmit(true, true, true, true, address(facet));
        emit ProposalCancelled(lineId, positionId, positionKey);

        vm.prank(alice);
        facet.cancelLineProposal(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.borrowerPositionId == positionId, "borrower position changed");
        require(line.borrowerPositionKey == positionKey, "borrower key changed");
        require(line.currentCommittedAmount == 0, "commitments not cleared");
        require(line.soloExclusiveUntil == 0, "solo window not cleared");
        require(line.activeLimit == 0, "active limit not cleared");
        require(line.outstandingPrincipal == 0, "outstanding principal not cleared");
        require(
            line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Closed, "proposal should be terminal after cancel"
        );
    }

    function test_cancelLineProposal_revertsForNonOwner() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(positionId, params);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, bob, positionId)
        );
        facet.cancelLineProposal(lineId);
    }

    function test_cancelLineProposal_revertsWhenActiveCommitmentsExist() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(positionId, params);

        facet.setLineCurrentCommittedAmount(lineId, 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "proposal has active commitments"
            )
        );
        facet.cancelLineProposal(lineId);
    }

    function test_cancelLineProposal_revertsAfterActivationOrTerminalState() external {
        uint256 positionId = _registerBorrowerProfileForAlice();
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(positionId, params);

        facet.setLineStatus(lineId, uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Active));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "proposal not mutable in status Active for line 1"
            )
        );
        facet.cancelLineProposal(lineId);
    }

    function test_commitSolo_encumbersFullTargetDuringSoloWindow() external {
        uint256 lineId = _createDefaultLine();
        uint256 lenderPositionId = _fundSettlementPosition(bob, TARGET_LIMIT);
        bytes32 lenderPositionKey = positionNft.getPositionKey(lenderPositionId);

        vm.expectEmit(true, true, true, true, address(facet));
        emit CommitmentAdded(lineId, lenderPositionId, lenderPositionKey, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(bob);
        facet.commitSolo(lineId, lenderPositionId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        LibEqualScaleAlphaStorage.Commitment memory commitment = facet.commitment(lineId, lenderPositionId);
        require(line.currentCommittedAmount == TARGET_LIMIT, "line not fully committed");
        require(commitment.lenderPositionId == lenderPositionId, "lender position id mismatch");
        require(commitment.lenderPositionKey == lenderPositionKey, "lender position key mismatch");
        require(commitment.settlementPoolId == SETTLEMENT_POOL_ID, "commitment settlement pool mismatch");
        require(commitment.committedAmount == TARGET_LIMIT, "commitment amount mismatch");
        require(commitment.status == LibEqualScaleAlphaStorage.CommitmentStatus.Active, "commitment not active");
        require(
            facet.encumberedCapitalOf(lenderPositionKey, SETTLEMENT_POOL_ID) == TARGET_LIMIT, "encumbrance mismatch"
        );
    }

    function test_commitSolo_revertsWhenAvailableSettlementPrincipalIsTooLow() external {
        uint256 lineId = _createDefaultLine();
        uint256 lenderPositionId = _fundSettlementPosition(bob, TARGET_LIMIT - 1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InsufficientLenderPrincipal.selector,
                lenderPositionId,
                TARGET_LIMIT,
                TARGET_LIMIT - 1
            )
        );
        facet.commitSolo(lineId, lenderPositionId);
    }

    function test_transitionToPooledOpen_isPermissionlessOnlyAfterSoloExpiry() external {
        uint256 lineId = _createDefaultLine();

        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "solo window still active")
        );
        facet.transitionToPooledOpen(lineId);

        vm.warp(block.timestamp + 3 days + 1);
        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineOpenedToPool(lineId);

        vm.prank(carol);
        facet.transitionToPooledOpen(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen, "line did not enter pooled open");
    }

    function test_commitPooled_tracksSeparateCommitmentsPerPositionNotWallet() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionOne = _fundSettlementPosition(bob, 700e18);
        uint256 lenderPositionTwo = _fundSettlementPosition(bob, 500e18);

        vm.startPrank(bob);
        facet.commitPooled(lineId, lenderPositionOne, 400e18);
        facet.commitPooled(lineId, lenderPositionTwo, 300e18);
        vm.stopPrank();

        LibEqualScaleAlphaStorage.Commitment memory first = facet.commitment(lineId, lenderPositionOne);
        LibEqualScaleAlphaStorage.Commitment memory second = facet.commitment(lineId, lenderPositionTwo);
        uint256[] memory committedPositions = facet.lineCommitmentPositionIds(lineId);
        uint256[] memory firstLines = facet.lenderPositionLineIds(lenderPositionOne);
        uint256[] memory secondLines = facet.lenderPositionLineIds(lenderPositionTwo);

        require(first.lenderPositionId == lenderPositionOne, "first commitment position mismatch");
        require(second.lenderPositionId == lenderPositionTwo, "second commitment position mismatch");
        require(first.committedAmount == 400e18, "first commitment amount mismatch");
        require(second.committedAmount == 300e18, "second commitment amount mismatch");
        require(committedPositions.length == 2, "line should track two committed positions");
        require(committedPositions[0] == lenderPositionOne, "first committed position id mismatch");
        require(committedPositions[1] == lenderPositionTwo, "second committed position id mismatch");
        require(firstLines.length == 1 && firstLines[0] == lineId, "first lender reverse lookup mismatch");
        require(secondLines.length == 1 && secondLines[0] == lineId, "second lender reverse lookup mismatch");
        require(facet.line(lineId).currentCommittedAmount == 700e18, "aggregate commitment mismatch");
    }

    function test_commitPooled_revertsWhenCommitmentExceedsRemainingCapacity() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionOne = _fundSettlementPosition(bob, 700e18);
        uint256 lenderPositionTwo = _fundSettlementPosition(carol, 500e18);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionOne, 700e18);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "commitment exceeds remaining capacity"
            )
        );
        facet.commitPooled(lineId, lenderPositionTwo, 301e18);

        require(facet.line(lineId).currentCommittedAmount == 700e18, "committed amount should remain capped");
    }

    function test_cancelCommitment_releasesPooledEncumbrance() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionId = _fundSettlementPosition(bob, 600e18);
        bytes32 lenderPositionKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionId, 400e18);

        vm.expectEmit(true, true, true, true, address(facet));
        emit CommitmentCancelled(lineId, lenderPositionId, lenderPositionKey, 400e18, 0);

        vm.prank(bob);
        facet.cancelCommitment(lineId, lenderPositionId);

        LibEqualScaleAlphaStorage.Commitment memory commitment = facet.commitment(lineId, lenderPositionId);
        require(commitment.committedAmount == 0, "commitment amount not cleared");
        require(commitment.status == LibEqualScaleAlphaStorage.CommitmentStatus.Canceled, "commitment not canceled");
        require(
            facet.encumberedCapitalOf(lenderPositionKey, SETTLEMENT_POOL_ID) == 0, "encumbrance not released"
        );
        require(facet.line(lineId).currentCommittedAmount == 0, "line committed amount not reduced");
    }

    function test_lenderPositionTransfer_movesCommitmentRightsAndObligations() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionId = _fundSettlementPosition(bob, 600e18);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionId, 400e18);

        vm.prank(bob);
        positionNft.transferFrom(bob, carol, lenderPositionId);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.LenderPositionNotOwned.selector, bob, lenderPositionId)
        );
        facet.cancelCommitment(lineId, lenderPositionId);

        vm.prank(carol);
        facet.cancelCommitment(lineId, lenderPositionId);

        LibEqualScaleAlphaStorage.Commitment memory commitment = facet.commitment(lineId, lenderPositionId);
        require(
            commitment.status == LibEqualScaleAlphaStorage.CommitmentStatus.Canceled,
            "transferred commitment not cancelable"
        );
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionId), SETTLEMENT_POOL_ID) == 0,
            "transferred encumbrance not released"
        );
    }

    function test_activateLine_fullCommitActivatesUnsecuredLineAndInitializesLiveState() external {
        uint256 lineId = _createDefaultLine();
        uint256 lenderPositionId = _fundSettlementPosition(bob, TARGET_LIMIT);
        uint40 activatedAt = uint40(block.timestamp);
        uint40 expectedNextDueAt = activatedAt + PAYMENT_INTERVAL_SECS;
        uint40 expectedTermEndAt = activatedAt + FACILITY_TERM_SECS;
        uint40 expectedRefinanceEndAt = expectedTermEndAt + REFINANCE_WINDOW_SECS;

        vm.prank(bob);
        facet.commitSolo(lineId, lenderPositionId);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineActivated(
            lineId,
            TARGET_LIMIT,
            LibEqualScaleAlphaStorage.CollateralMode.None,
            expectedNextDueAt,
            expectedTermEndAt,
            expectedRefinanceEndAt
        );

        vm.prank(carol);
        facet.activateLine(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "line not active");
        require(line.activeLimit == TARGET_LIMIT, "active limit mismatch");
        require(line.currentCommittedAmount == TARGET_LIMIT, "committed amount changed");
        require(line.currentPeriodDrawn == 0, "current period drawn should reset");
        require(line.currentPeriodStartedAt == activatedAt, "period start mismatch");
        require(line.interestAccruedAt == activatedAt, "interest checkpoint mismatch");
        require(line.nextDueAt == expectedNextDueAt, "next due mismatch");
        require(line.termStartedAt == activatedAt, "term start mismatch");
        require(line.termEndAt == expectedTermEndAt, "term end mismatch");
        require(line.refinanceEndAt == expectedRefinanceEndAt, "refinance end mismatch");
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionId), SETTLEMENT_POOL_ID) == TARGET_LIMIT,
            "lender encumbrance released"
        );
        require(facet.lockedCapitalOf(line.borrowerPositionKey, line.borrowerCollateralPoolId) == 0, "unexpected borrower collateral");
    }

    function test_activateLine_borrowerAcceptsResizedBorrowerCollateralizedActivation() external {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        uint256 acceptedAmount = 700e18;
        uint40 activatedAt = uint40(block.timestamp + 3 days + 1);
        uint40 expectedNextDueAt = activatedAt + PAYMENT_INTERVAL_SECS;
        uint40 expectedTermEndAt = activatedAt + FACILITY_TERM_SECS;
        uint40 expectedRefinanceEndAt = expectedTermEndAt + REFINANCE_WINDOW_SECS;

        facet.configurePoolForDeposits(COLLATERAL_POOL_ID, address(settlementToken), 1);
        _depositToPosition(alice, borrowerPositionId, COLLATERAL_POOL_ID, COLLATERAL_AMOUNT);

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, _borrowerPostedProposalParams());

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionId = _fundSettlementPosition(bob, acceptedAmount);
        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionId, acceptedAmount);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineActivated(
            lineId,
            acceptedAmount,
            LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted,
            expectedNextDueAt,
            expectedTermEndAt,
            expectedRefinanceEndAt
        );

        vm.prank(alice);
        facet.activateLine(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "resized line not active");
        require(line.activeLimit == acceptedAmount, "resized active limit mismatch");
        require(line.currentCommittedAmount == acceptedAmount, "committed amount changed");
        require(line.currentPeriodStartedAt == activatedAt, "resized period start mismatch");
        require(line.interestAccruedAt == activatedAt, "resized interest checkpoint mismatch");
        require(line.nextDueAt == expectedNextDueAt, "resized next due mismatch");
        require(line.termStartedAt == activatedAt, "resized term start mismatch");
        require(line.termEndAt == expectedTermEndAt, "resized term end mismatch");
        require(line.refinanceEndAt == expectedRefinanceEndAt, "resized refinance end mismatch");
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionId), SETTLEMENT_POOL_ID) == acceptedAmount,
            "resized lender encumbrance released"
        );
        require(
            facet.lockedCapitalOf(line.borrowerPositionKey, line.borrowerCollateralPoolId) == COLLATERAL_AMOUNT,
            "borrower collateral not encumbered"
        );
    }

    function test_activateLine_revertsWhenCommitmentsRemainBelowMinimumViableLine() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionId = _fundSettlementPosition(bob, MINIMUM_VIABLE_LINE - 1);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionId, MINIMUM_VIABLE_LINE - 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "commitments below minimum viable line"
            )
        );
        facet.activateLine(lineId);
    }

    function test_activateLine_revertsWhenNonBorrowerAttemptsResizedActivation() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionId = _fundSettlementPosition(bob, 700e18);
        uint256 borrowerPositionId = facet.line(lineId).borrowerPositionId;

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionId, 700e18);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, bob, borrowerPositionId)
        );
        facet.activateLine(lineId);
    }

    function test_draw_updatesDebtTransfersToTreasuryAndAllocatesExposureProRata() external {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        bytes32 borrowerPositionKey = positionNft.getPositionKey(borrowerPositionId);
        bytes32 lenderOneKey;
        bytes32 lenderTwoKey;

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, _defaultProposalParamsNone());

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionOne = _fundSettlementPosition(bob, 600e18);
        uint256 lenderPositionTwo = _fundSettlementPosition(carol, 400e18);
        lenderOneKey = positionNft.getPositionKey(lenderPositionOne);
        lenderTwoKey = positionNft.getPositionKey(lenderPositionTwo);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionOne, 600e18);
        vm.prank(carol);
        facet.commitPooled(lineId, lenderPositionTwo, 400e18);

        vm.prank(alice);
        facet.activateLine(lineId);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditDrawn(lineId, 250e18, 250e18, 250e18);

        vm.prank(alice);
        facet.draw(lineId, 250e18);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        LibEqualScaleAlphaStorage.Commitment memory first = facet.commitment(lineId, lenderPositionOne);
        LibEqualScaleAlphaStorage.Commitment memory second = facet.commitment(lineId, lenderPositionTwo);
        (uint256 debtPrincipal, uint40 debtStartTime, uint256 debtIndexSnapshot) =
            facet.debtActiveCreditState(SETTLEMENT_POOL_ID, borrowerPositionKey);

        require(line.outstandingPrincipal == 250e18, "outstanding principal mismatch");
        require(line.currentPeriodDrawn == 250e18, "period draw mismatch");
        require(first.principalExposed == 150e18, "first exposure mismatch");
        require(second.principalExposed == 100e18, "second exposure mismatch");
        require(first.lenderPositionKey == lenderOneKey, "first lender key changed");
        require(second.lenderPositionKey == lenderTwoKey, "second lender key changed");
        require(facet.sameAssetDebt(SETTLEMENT_POOL_ID, borrowerPositionKey) == 250e18, "same-asset debt mismatch");
        require(
            facet.poolActiveCreditPrincipalTotal(SETTLEMENT_POOL_ID) == TARGET_LIMIT + 250e18,
            "active credit principal mismatch"
        );
        require(debtPrincipal == 250e18, "debt active credit principal mismatch");
        require(debtStartTime == uint40(block.timestamp), "debt start time mismatch");
        require(debtIndexSnapshot == 0, "debt index snapshot mismatch");
        require(facet.poolTrackedBalance(SETTLEMENT_POOL_ID) == TARGET_LIMIT - 250e18, "tracked balance mismatch");
        require(settlementToken.balanceOf(treasuryWallet) == 250e18, "treasury transfer mismatch");
    }

    function test_draw_resetsPeriodUsageWhenPaymentIntervalRolls() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = 450e18;

        uint256 lineId = _createActivatedLine(params, 1_000e18, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 200e18);

        uint40 firstPeriodStart = facet.line(lineId).currentPeriodStartedAt;

        vm.warp(block.timestamp + PAYMENT_INTERVAL_SECS + 1);

        vm.prank(alice);
        facet.draw(lineId, 200e18);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.outstandingPrincipal == 400e18, "outstanding principal after rollover mismatch");
        require(line.currentPeriodDrawn == 200e18, "period draw should reset on rollover");
        require(line.currentPeriodStartedAt == uint40(block.timestamp), "period start should roll forward");
        require(line.currentPeriodStartedAt > firstPeriodStart, "period start should advance");
    }

    function test_draw_revertsWhenPeriodCapExceeded() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, MAX_DRAW_PER_PERIOD);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidDrawPacing.selector, 1, MAX_DRAW_PER_PERIOD, MAX_DRAW_PER_PERIOD
            )
        );
        facet.draw(lineId, 1);
    }

    function test_draw_revertsWhenAvailableCapacityExceeded() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;

        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 700e18);

        vm.warp(block.timestamp + PAYMENT_INTERVAL_SECS + 1);

        vm.prank(alice);
        facet.draw(lineId, 300e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "draw exceeds available capacity"
            )
        );
        facet.draw(lineId, 1);
    }

    function test_draw_revertsWhenBorrowerDoesNotOwnPosition() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);
        uint256 borrowerPositionId = facet.line(lineId).borrowerPositionId;

        vm.prank(alice);
        positionNft.transferFrom(alice, bob, borrowerPositionId);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerPositionNotOwned.selector, alice, borrowerPositionId)
        );
        facet.draw(lineId, 1);
    }

    function test_draw_revertsWhenSettlementPoolLiquidityIsTooLow() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolLiquidity.selector, 150e18, 100e18));
        facet.draw(lineId, 150e18);
    }

    function test_draw_statusGatingAllowsOnlyActive() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 1);

        LibEqualScaleAlphaStorage.CreditLineStatus[6] memory blockedStatuses = [
            LibEqualScaleAlphaStorage.CreditLineStatus.Frozen,
            LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing,
            LibEqualScaleAlphaStorage.CreditLineStatus.Runoff,
            LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent,
            LibEqualScaleAlphaStorage.CreditLineStatus.ChargedOff,
            LibEqualScaleAlphaStorage.CreditLineStatus.Closed
        ];

        for (uint256 i = 0; i < blockedStatuses.length; i++) {
            uint256 blockedLineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);
            facet.setLineStatus(blockedLineId, uint256(blockedStatuses[i]));

            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "line not active for draw")
            );
            facet.draw(blockedLineId, 1);
        }
    }

    function test_freezeLine_isTimelockOnly_andBlocksOnlyDraws() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 200e18);
        _mintAndApprove(alice, 50e18);

        vm.expectRevert(bytes("LibAccess: not timelock"));
        facet.freezeLine(lineId, OPS_FREEZE_REASON);

        vm.recordLogs();
        _timelockCall(abi.encodeWithSelector(EqualScaleAlphaAdminFacet.freezeLine.selector, lineId, OPS_FREEZE_REASON));
        _assertIndexedEventEmitted(keccak256("CreditLineFreezeUpdated(uint256,bool,bytes32)"), bytes32(lineId));

        require(
            facet.line(lineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen,
            "line should be frozen"
        );

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "line not active for draw")
        );
        facet.draw(lineId, 1);

        vm.prank(alice);
        facet.repayLine(lineId, 50e18);

        LibEqualScaleAlphaStorage.CreditLine memory frozenLine = facet.line(lineId);
        require(
            frozenLine.status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen,
            "repayment should not require admin unfreeze"
        );
        require(frozenLine.outstandingPrincipal == 150e18, "repayment should reduce frozen principal");

        vm.recordLogs();
        _timelockCall(abi.encodeWithSelector(EqualScaleAlphaAdminFacet.unfreezeLine.selector, lineId));
        _assertIndexedEventEmitted(keccak256("CreditLineFreezeUpdated(uint256,bool,bytes32)"), bytes32(lineId));

        require(
            facet.line(lineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Active,
            "line should return to active"
        );

        vm.prank(alice);
        facet.draw(lineId, 50e18);

        LibEqualScaleAlphaStorage.CreditLine memory unfrozenLine = facet.line(lineId);
        require(unfrozenLine.outstandingPrincipal == 200e18, "draw should resume after unfreeze");
        require(unfrozenLine.currentPeriodDrawn == 250e18, "draw usage should resume without resetting term state");
    }

    function test_setChargeOffThreshold_isTimelockOnlyAndBounded() external {
        vm.expectRevert(bytes("LibAccess: not timelock"));
        facet.setChargeOffThreshold(7 days);

        vm.recordLogs();
        _timelockCall(abi.encodeWithSelector(EqualScaleAlphaAdminFacet.setChargeOffThreshold.selector, 7 days));
        _assertEventEmitted(keccak256("ChargeOffThresholdUpdated(uint40,uint40)"));

        require(facet.storedChargeOffThresholdSecs() == 7 days, "charge-off threshold not updated");

        bytes memory lowThresholdData =
            abi.encodeWithSelector(EqualScaleAlphaAdminFacet.setChargeOffThreshold.selector, 12 hours);
        bytes32 lowThresholdSalt = _scheduleTimelockCall(lowThresholdData);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "chargeOffThresholdSecs too low"));
        _executeTimelockCall(lowThresholdData, lowThresholdSalt);

        bytes memory highThresholdData =
            abi.encodeWithSelector(EqualScaleAlphaAdminFacet.setChargeOffThreshold.selector, 366 days);
        bytes32 highThresholdSalt = _scheduleTimelockCall(highThresholdData);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "chargeOffThresholdSecs too high"));
        _executeTimelockCall(highThresholdData, highThresholdSalt);

        require(facet.storedChargeOffThresholdSecs() == 7 days, "failed writes should not mutate threshold");
    }

    function test_repay_accruesInterestAcrossDrawCheckpoints() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 200e18);

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        facet.draw(lineId, 100e18);

        vm.warp(block.timestamp + 10 days);

        uint256 expectedFirstSlice = _expectedInterest(200e18, 10 days);
        uint256 expectedSecondSlice = _expectedInterest(300e18, 10 days);
        uint256 expectedInterest = expectedFirstSlice + expectedSecondSlice;
        (uint256 previewAccruedInterest, uint256 previewInterestSinceLastDue, uint256 previewRequiredMinimumDue) =
            facet.previewLineInterest(lineId);

        require(previewAccruedInterest == expectedInterest, "preview accrued interest mismatch");
        require(previewInterestSinceLastDue == expectedInterest, "preview period interest mismatch");
        require(previewRequiredMinimumDue == MINIMUM_PAYMENT_PER_PERIOD, "preview minimum due mismatch");

        _mintAndApprove(alice, expectedInterest);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditPaymentMade(lineId, expectedInterest, 0, expectedInterest, 300e18, 0, facet.line(lineId).nextDueAt);

        vm.prank(alice);
        facet.repayLine(lineId, expectedInterest);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.outstandingPrincipal == 300e18, "principal should remain after interest-only payment");
        require(line.accruedInterest == 0, "accrued interest not cleared");
        require(line.interestAccruedSinceLastDue == expectedInterest, "gross period interest should stay tracked");
        require(line.totalInterestRepaid == expectedInterest, "interest repaid mismatch");
        require(line.totalPrincipalRepaid == 0, "unexpected principal repaid");
    }

    function test_repay_appliesInterestFirstAdvancesDueAndRestoresCapacityOnlyByPrincipal() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 300e18);

        uint40 nextDueAtBefore = facet.line(lineId).nextDueAt;

        vm.warp(block.timestamp + PAYMENT_INTERVAL_SECS);

        uint256 expectedInterest = _expectedInterest(300e18, PAYMENT_INTERVAL_SECS);
        uint256 repayAmount = expectedInterest + 60e18;

        _mintAndApprove(alice, repayAmount);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditPaymentMade(
            lineId, repayAmount, 60e18, expectedInterest, 240e18, 0, nextDueAtBefore + PAYMENT_INTERVAL_SECS
        );

        vm.prank(alice);
        facet.repayLine(lineId, repayAmount);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        (uint256 debtPrincipal, uint40 debtStartTime, uint256 debtIndexSnapshot) =
            facet.debtActiveCreditState(SETTLEMENT_POOL_ID, positionNft.getPositionKey(line.borrowerPositionId));
        (uint40 paidAt, uint256 recordedAmount, uint256 recordedPrincipal, uint256 recordedInterest) =
            facet.paymentRecord(lineId, 0);

        require(line.outstandingPrincipal == 240e18, "outstanding principal mismatch");
        require(line.activeLimit == TARGET_LIMIT, "active limit should not shrink on repay");
        require(line.accruedInterest == 0, "accrued interest should be cleared");
        require(line.totalInterestRepaid == expectedInterest, "total interest repaid mismatch");
        require(line.totalPrincipalRepaid == 60e18, "total principal repaid mismatch");
        require(line.interestAccruedSinceLastDue == 0, "period interest should reset after due advancement");
        require(line.paidSinceLastDue == 0, "period payment should reset after due advancement");
        require(line.nextDueAt == nextDueAtBefore + PAYMENT_INTERVAL_SECS, "next due not advanced");
        require(
            facet.sameAssetDebt(SETTLEMENT_POOL_ID, positionNft.getPositionKey(line.borrowerPositionId)) == 240e18,
            "same-asset debt mismatch"
        );
        require(
            facet.poolActiveCreditPrincipalTotal(SETTLEMENT_POOL_ID) == TARGET_LIMIT + 240e18,
            "active credit total mismatch"
        );
        require(debtPrincipal == 240e18, "debt principal not reduced");
        require(debtIndexSnapshot == 0, "debt index snapshot mismatch");
        require(
            facet.poolTrackedBalance(SETTLEMENT_POOL_ID) == TARGET_LIMIT - 300e18 + repayAmount,
            "tracked balance mismatch"
        );
        require(
            settlementToken.balanceOf(address(facet)) == TARGET_LIMIT - 300e18 + repayAmount, "facet balance mismatch"
        );
        require(facet.paymentRecordCount(lineId) == 1, "payment record count mismatch");
        require(paidAt == uint40(block.timestamp), "payment timestamp mismatch");
        require(recordedAmount == repayAmount, "payment amount mismatch");
        require(recordedPrincipal == 60e18, "payment principal mismatch");
        require(recordedInterest == expectedInterest, "payment interest mismatch");
        require(debtStartTime != 0, "debt start time should remain populated");
    }

    function test_repay_distributesInterestAndPrincipalProRataAcrossLenders() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;

        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, params);

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionOne = _fundSettlementPosition(bob, 600e18);
        uint256 lenderPositionTwo = _fundSettlementPosition(carol, 400e18);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionOne, 600e18);
        vm.prank(carol);
        facet.commitPooled(lineId, lenderPositionTwo, 400e18);

        vm.prank(alice);
        facet.activateLine(lineId);

        vm.prank(alice);
        facet.draw(lineId, 500e18);

        vm.warp(block.timestamp + PAYMENT_INTERVAL_SECS);

        uint256 expectedInterest = _expectedInterest(500e18, PAYMENT_INTERVAL_SECS);
        uint256 repayAmount = expectedInterest + 100e18;
        uint256 firstInterestShare = (expectedInterest * 300e18) / 500e18;
        uint256 secondInterestShare = expectedInterest - firstInterestShare;

        _mintAndApprove(alice, repayAmount);

        vm.prank(alice);
        facet.repayLine(lineId, repayAmount);

        LibEqualScaleAlphaStorage.Commitment memory first = facet.commitment(lineId, lenderPositionOne);
        LibEqualScaleAlphaStorage.Commitment memory second = facet.commitment(lineId, lenderPositionTwo);
        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);

        require(line.outstandingPrincipal == 400e18, "line principal not reduced");
        require(first.principalExposed == 240e18, "first exposed principal mismatch");
        require(second.principalExposed == 160e18, "second exposed principal mismatch");
        require(first.principalRepaid == 60e18, "first principal repaid mismatch");
        require(second.principalRepaid == 40e18, "second principal repaid mismatch");
        require(first.interestReceived == firstInterestShare, "first interest share mismatch");
        require(second.interestReceived == secondInterestShare, "second interest share mismatch");
    }

    function test_repay_curesDelinquentAndRunoffLinesWhenCoverageIsRestored() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        uint256 delinquentLineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(delinquentLineId, 200e18);

        vm.warp(block.timestamp + PAYMENT_INTERVAL_SECS + GRACE_PERIOD_SECS + 1);
        facet.setLineStatus(delinquentLineId, uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent));

        _mintAndApprove(alice, 50e18);

        vm.prank(alice);
        facet.repayLine(delinquentLineId, 40e18);
        require(
            facet.line(delinquentLineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent,
            "insufficient payment should not cure delinquency"
        );

        vm.prank(alice);
        facet.repayLine(delinquentLineId, 10e18);

        LibEqualScaleAlphaStorage.CreditLine memory delinquentLine = facet.line(delinquentLineId);
        require(delinquentLine.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "delinquent line not cured");
        require(delinquentLine.nextDueAt > uint40(block.timestamp), "cured delinquent line should advance due");

        uint256 runoffLineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(runoffLineId, 700e18);

        facet.setLineCurrentCommittedAmount(runoffLineId, 500e18);
        facet.setLineStatus(runoffLineId, uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Runoff));

        uint40 restartTimestamp = uint40(block.timestamp);
        _mintAndApprove(alice, 200e18);

        vm.prank(alice);
        facet.repayLine(runoffLineId, 200e18);

        LibEqualScaleAlphaStorage.CreditLine memory runoffLine = facet.line(runoffLineId);
        require(runoffLine.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "runoff line not cured");
        require(runoffLine.outstandingPrincipal == 500e18, "runoff outstanding mismatch");
        require(runoffLine.activeLimit == 500e18, "runoff active limit should resize to covered amount");
        require(runoffLine.currentPeriodStartedAt == restartTimestamp, "runoff period not restarted");
        require(runoffLine.termStartedAt == restartTimestamp, "runoff term not restarted");
        require(runoffLine.nextDueAt == restartTimestamp + PAYMENT_INTERVAL_SECS, "runoff due not reset");
    }

    function test_markDelinquent_isPermissionlessOnlyAfterDuePlusGrace() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);
        uint40 nextDueAt = facet.line(lineId).nextDueAt;

        vm.prank(alice);
        facet.draw(lineId, 200e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.DelinquencyTooEarly.selector,
                lineId,
                nextDueAt,
                GRACE_PERIOD_SECS,
                uint40(block.timestamp)
            )
        );
        facet.markDelinquent(lineId);

        vm.warp(uint256(nextDueAt) + GRACE_PERIOD_SECS + 1);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineMarkedDelinquent(lineId, uint40(block.timestamp), MINIMUM_PAYMENT_PER_PERIOD, nextDueAt);

        vm.prank(dave);
        facet.markDelinquent(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent, "line should be delinquent");
        require(line.delinquentSince == uint40(block.timestamp), "delinquent timestamp mismatch");
        require(line.missedPayments == 1, "missed payment count mismatch");
    }

    function test_chargeOffLine_writesDownUnsecuredExposureProRata() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        facet.setChargeOffThresholdForTest(7 days);

        (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) =
            _createPooledActivatedLine(params, 600e18, 400e18);

        vm.prank(alice);
        facet.draw(lineId, 500e18);

        uint40 nextDueAt = facet.line(lineId).nextDueAt;
        vm.warp(uint256(nextDueAt) + GRACE_PERIOD_SECS + 1);
        facet.markDelinquent(lineId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.ChargeOffTooEarly.selector,
                lineId,
                uint40(block.timestamp),
                uint40(7 days),
                uint40(block.timestamp)
            )
        );
        facet.chargeOffLine(lineId);

        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineChargedOff(lineId, 0, 500e18);
        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineClosed(lineId, LibEqualScaleAlphaStorage.CreditLineStatus.ChargedOff, true);

        vm.prank(dave);
        facet.chargeOffLine(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        LibEqualScaleAlphaStorage.Commitment memory first = facet.commitment(lineId, lenderPositionOne);
        LibEqualScaleAlphaStorage.Commitment memory second = facet.commitment(lineId, lenderPositionTwo);

        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Closed, "line should close after charge-off");
        require(line.outstandingPrincipal == 0, "outstanding principal should clear");
        require(line.currentCommittedAmount == 0, "committed amount should clear");
        require(line.activeLimit == 0, "active limit should clear");
        require(first.recoveryReceived == 0, "unexpected first recovery");
        require(second.recoveryReceived == 0, "unexpected second recovery");
        require(first.lossWrittenDown == 300e18, "first loss mismatch");
        require(second.lossWrittenDown == 200e18, "second loss mismatch");
        require(first.principalExposed == 0, "first exposure should clear");
        require(second.principalExposed == 0, "second exposure should clear");
        require(first.committedAmount == 0, "first commitment amount should clear");
        require(second.committedAmount == 0, "second commitment amount should clear");
        require(
            first.status == LibEqualScaleAlphaStorage.CommitmentStatus.WrittenDown,
            "first status should be written down"
        );
        require(
            second.status == LibEqualScaleAlphaStorage.CommitmentStatus.WrittenDown,
            "second status should be written down"
        );
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionOne), SETTLEMENT_POOL_ID) == 0,
            "first encumbrance should release"
        );
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionTwo), SETTLEMENT_POOL_ID) == 0,
            "second encumbrance should release"
        );
        require(facet.poolTrackedBalance(SETTLEMENT_POOL_ID) == TARGET_LIMIT - 500e18, "unexpected backfill");
    }

    function test_chargeOffLine_recoversBorrowerCollateralBeforeWriteDown() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _borrowerPostedProposalParams();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        facet.setChargeOffThresholdForTest(7 days);

        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        bytes32 borrowerPositionKey = positionNft.getPositionKey(borrowerPositionId);
        facet.configurePoolForDeposits(COLLATERAL_POOL_ID, address(settlementToken), 1);
        _depositToPosition(alice, borrowerPositionId, COLLATERAL_POOL_ID, COLLATERAL_AMOUNT);

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, params);

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionOne = _fundSettlementPosition(bob, 600e18);
        uint256 lenderPositionTwo = _fundSettlementPosition(carol, 400e18);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionOne, 600e18);
        vm.prank(carol);
        facet.commitPooled(lineId, lenderPositionTwo, 400e18);

        vm.prank(alice);
        facet.activateLine(lineId);

        vm.prank(alice);
        facet.draw(lineId, 500e18);

        uint40 nextDueAt = facet.line(lineId).nextDueAt;
        vm.warp(uint256(nextDueAt) + GRACE_PERIOD_SECS + 1);
        facet.markDelinquent(lineId);

        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineChargedOff(lineId, COLLATERAL_AMOUNT, 250e18);
        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineClosed(lineId, LibEqualScaleAlphaStorage.CreditLineStatus.ChargedOff, true);

        vm.prank(dave);
        facet.chargeOffLine(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        LibEqualScaleAlphaStorage.Commitment memory first = facet.commitment(lineId, lenderPositionOne);
        LibEqualScaleAlphaStorage.Commitment memory second = facet.commitment(lineId, lenderPositionTwo);

        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Closed, "secured line should close");
        require(first.recoveryReceived == 150e18, "first recovery mismatch");
        require(second.recoveryReceived == 100e18, "second recovery mismatch");
        require(first.lossWrittenDown == 150e18, "first loss mismatch");
        require(second.lossWrittenDown == 100e18, "second loss mismatch");
        require(first.principalExposed == 0, "first exposure should clear");
        require(second.principalExposed == 0, "second exposure should clear");
        require(
            facet.lockedCapitalOf(borrowerPositionKey, COLLATERAL_POOL_ID) == 0,
            "collateral encumbrance should release"
        );
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionOne), SETTLEMENT_POOL_ID) == 0,
            "first encumbrance should release"
        );
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionTwo), SETTLEMENT_POOL_ID) == 0,
            "second encumbrance should release"
        );
        require(
            facet.poolTrackedBalance(SETTLEMENT_POOL_ID) == TARGET_LIMIT - 500e18 + COLLATERAL_AMOUNT,
            "settlement recovery mismatch"
        );
        require(facet.poolTrackedBalance(COLLATERAL_POOL_ID) == 0, "collateral pool tracked balance mismatch");
        require(
            facet.poolPrincipal(COLLATERAL_POOL_ID, borrowerPositionKey) == 0, "borrower collateral should be seized"
        );
    }

    function test_chargeOffLine_doesNotAssumeTreasuryBackstopOrInsuranceModule() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;
        facet.setChargeOffThresholdForTest(1 days);

        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);
        uint256[] memory lenderPositionIds = facet.lineCommitmentPositionIds(lineId);
        uint256 lenderPositionId = lenderPositionIds[0];

        vm.prank(alice);
        facet.draw(lineId, 300e18);

        uint40 nextDueAt = facet.line(lineId).nextDueAt;
        vm.warp(uint256(nextDueAt) + GRACE_PERIOD_SECS + 1);
        facet.markDelinquent(lineId);

        vm.warp(block.timestamp + 1 days);
        facet.chargeOffLine(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        LibEqualScaleAlphaStorage.Commitment memory commitment = facet.commitment(lineId, lenderPositionId);

        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Closed, "line should close without backstop");
        require(commitment.recoveryReceived == 0, "unexpected recovery");
        require(commitment.lossWrittenDown == 300e18, "loss should land on lender commitment");
        require(
            facet.poolTrackedBalance(SETTLEMENT_POOL_ID) == TARGET_LIMIT - 300e18, "tracked balance should not backfill"
        );
    }

    function test_frozenLine_stillAllowsPermissionlessDelinquencyAndChargeOff() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);
        uint256[] memory lenderPositionIds = facet.lineCommitmentPositionIds(lineId);
        uint256 lenderPositionId = lenderPositionIds[0];

        vm.prank(alice);
        facet.draw(lineId, 300e18);

        _timelockCall(abi.encodeWithSelector(EqualScaleAlphaAdminFacet.freezeLine.selector, lineId, OPS_FREEZE_REASON));
        _timelockCall(abi.encodeWithSelector(EqualScaleAlphaAdminFacet.setChargeOffThreshold.selector, 1 days));

        uint40 nextDueAt = facet.line(lineId).nextDueAt;
        vm.warp(uint256(nextDueAt) + GRACE_PERIOD_SECS + 1);

        vm.prank(dave);
        facet.markDelinquent(lineId);

        require(
            facet.line(lineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent,
            "frozen line should still become delinquent permissionlessly"
        );

        vm.warp(block.timestamp + 1 days);

        vm.prank(dave);
        facet.chargeOffLine(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        LibEqualScaleAlphaStorage.Commitment memory commitment = facet.commitment(lineId, lenderPositionId);

        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Closed, "line should close after charge-off");
        require(commitment.lossWrittenDown == 300e18, "charge-off should still allocate lender loss");
    }

    function test_enterRefinancing_isPermissionlessOnlyAtTermEnd() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);

        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "facility term still active")
        );
        facet.enterRefinancing(lineId);

        uint40 termEndAt = facet.line(lineId).termEndAt;
        uint40 refinanceEndAt = facet.line(lineId).refinanceEndAt;

        vm.warp(termEndAt);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineEnteredRefinancing(lineId, refinanceEndAt, TARGET_LIMIT, 0);

        vm.prank(dave);
        facet.enterRefinancing(lineId);

        require(
            facet.line(lineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Refinancing,
            "line should enter refinancing"
        );
    }

    function test_frozenLine_cannotEnterRefinancingAtTermEnd() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);

        _timelockCall(abi.encodeWithSelector(EqualScaleAlphaAdminFacet.freezeLine.selector, lineId, OPS_FREEZE_REASON));
        require(
            facet.line(lineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen,
            "line should be frozen before term end"
        );

        uint40 termEndAt = facet.line(lineId).termEndAt;
        vm.warp(termEndAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "line not active for refinancing"
            )
        );
        vm.prank(dave);
        facet.enterRefinancing(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Frozen, "frozen line should remain frozen");
        require(line.activeLimit == TARGET_LIMIT, "freeze should preserve active limit");
    }

    function test_refinancing_allowsFullRenewalWithRolledAndNewPooledCommitments() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) =
            _createPooledActivatedLine(params, 700e18, 300e18);
        uint256 lenderPositionThree = _fundSettlementPosition(dave, 300e18);
        bytes32 lenderOneKey = positionNft.getPositionKey(lenderPositionOne);
        bytes32 lenderTwoKey = positionNft.getPositionKey(lenderPositionTwo);
        bytes32 lenderThreeKey = positionNft.getPositionKey(lenderPositionThree);

        vm.warp(facet.line(lineId).termEndAt);
        facet.enterRefinancing(lineId);

        vm.expectEmit(true, true, true, true, address(facet));
        emit CommitmentRolled(lineId, lenderPositionOne, lenderOneKey, 700e18, TARGET_LIMIT);

        vm.prank(bob);
        facet.rollCommitment(lineId, lenderPositionOne);

        vm.expectEmit(true, true, true, true, address(facet));
        emit CommitmentExited(lineId, lenderPositionTwo, lenderTwoKey, 300e18, 700e18);

        vm.prank(carol);
        facet.exitCommitment(lineId, lenderPositionTwo);

        vm.expectEmit(true, true, true, true, address(facet));
        emit CommitmentAdded(lineId, lenderPositionThree, lenderThreeKey, 300e18, TARGET_LIMIT);

        vm.prank(dave);
        facet.commitPooled(lineId, lenderPositionThree, 300e18);

        vm.warp(facet.line(lineId).refinanceEndAt);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineRefinancingResolved(
            lineId, LibEqualScaleAlphaStorage.CreditLineStatus.Active, TARGET_LIMIT, TARGET_LIMIT
        );

        facet.resolveRefinancing(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        LibEqualScaleAlphaStorage.Commitment memory rolled = facet.commitment(lineId, lenderPositionOne);
        LibEqualScaleAlphaStorage.Commitment memory exited = facet.commitment(lineId, lenderPositionTwo);
        LibEqualScaleAlphaStorage.Commitment memory added = facet.commitment(lineId, lenderPositionThree);

        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "line should renew active");
        require(line.activeLimit == TARGET_LIMIT, "full renewal active limit mismatch");
        require(line.currentCommittedAmount == TARGET_LIMIT, "full renewal commitment mismatch");
        require(rolled.status == LibEqualScaleAlphaStorage.CommitmentStatus.Rolled, "rolled commitment status mismatch");
        require(exited.status == LibEqualScaleAlphaStorage.CommitmentStatus.Exited, "exited commitment status mismatch");
        require(added.status == LibEqualScaleAlphaStorage.CommitmentStatus.Active, "new commitment status mismatch");
        require(exited.committedAmount == 0, "exited commitment should release coverage");
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionOne), SETTLEMENT_POOL_ID) == 700e18,
            "rolled encumbrance mismatch"
        );
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionTwo), SETTLEMENT_POOL_ID) == 0,
            "exited encumbrance mismatch"
        );
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionThree), SETTLEMENT_POOL_ID) == 300e18,
            "new encumbrance mismatch"
        );
    }

    function test_resolveRefinancing_renewsAtResizedCoveredLimit() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        (uint256 lineId,, uint256 lenderPositionTwo) = _createPooledActivatedLine(params, 700e18, 300e18);

        vm.warp(facet.line(lineId).termEndAt);
        facet.enterRefinancing(lineId);

        vm.prank(carol);
        facet.exitCommitment(lineId, lenderPositionTwo);

        vm.warp(facet.line(lineId).refinanceEndAt);
        facet.resolveRefinancing(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "line should resize-renew");
        require(line.activeLimit == 700e18, "resized active limit mismatch");
        require(line.currentCommittedAmount == 700e18, "resized commitment mismatch");
        require(line.nextDueAt == uint40(block.timestamp) + PAYMENT_INTERVAL_SECS, "resized due mismatch");
    }

    function test_resolveRefinancing_entersRunoffWhenCoverageFallsBelowOutstandingPrincipal() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        (uint256 lineId, uint256 lenderPositionOne,) = _createPooledActivatedLine(params, 600e18, 400e18);

        vm.prank(alice);
        facet.draw(lineId, 500e18);

        vm.warp(facet.line(lineId).termEndAt);
        facet.enterRefinancing(lineId);

        vm.prank(bob);
        facet.exitCommitment(lineId, lenderPositionOne);

        vm.warp(facet.line(lineId).refinanceEndAt);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineEnteredRunoff(lineId, 500e18, 400e18);
        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineRefinancingResolved(lineId, LibEqualScaleAlphaStorage.CreditLineStatus.Runoff, 400e18, 400e18);

        facet.resolveRefinancing(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff, "line should enter runoff");
        require(line.activeLimit == 400e18, "runoff active limit mismatch");
        require(line.currentCommittedAmount == 400e18, "runoff commitment mismatch");
    }

    function test_repay_curesRunoffAfterRefinancingResolution() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        (uint256 lineId, uint256 lenderPositionOne,) = _createPooledActivatedLine(params, 600e18, 400e18);

        vm.prank(alice);
        facet.draw(lineId, 500e18);

        vm.warp(facet.line(lineId).termEndAt);
        facet.enterRefinancing(lineId);

        vm.prank(bob);
        facet.exitCommitment(lineId, lenderPositionOne);

        vm.warp(facet.line(lineId).refinanceEndAt);
        facet.resolveRefinancing(lineId);

        _mintAndApprove(alice, 100e18);
        uint40 cureTimestamp = uint40(block.timestamp);

        vm.prank(alice);
        facet.repayLine(lineId, 100e18);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "runoff cure should reactivate");
        require(line.outstandingPrincipal == 400e18, "runoff cure principal mismatch");
        require(line.activeLimit == 400e18, "runoff cure active limit mismatch");
        require(line.currentCommittedAmount == 400e18, "runoff cure committed amount mismatch");
        require(line.currentPeriodStartedAt == cureTimestamp, "runoff cure period mismatch");
        require(line.termStartedAt == cureTimestamp, "runoff cure term mismatch");
        require(line.nextDueAt == cureTimestamp + PAYMENT_INTERVAL_SECS, "runoff cure due mismatch");
    }

    function test_closeLine_finalizesFullyRepaidActiveLine() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);
        uint256 lenderPositionId = facet.lineCommitmentPositionIds(lineId)[0];

        vm.prank(alice);
        facet.draw(lineId, 200e18);

        _mintAndApprove(alice, 200e18);
        vm.prank(alice);
        facet.repayLine(lineId, 200e18);

        vm.expectEmit(true, false, false, true, address(facet));
        emit CreditLineClosed(lineId, LibEqualScaleAlphaStorage.CreditLineStatus.Active, false);

        vm.prank(alice);
        facet.closeLine(lineId);

        LibEqualScaleAlphaStorage.CreditLine memory line = facet.line(lineId);
        LibEqualScaleAlphaStorage.Commitment memory commitment = facet.commitment(lineId, lenderPositionId);

        require(line.status == LibEqualScaleAlphaStorage.CreditLineStatus.Closed, "line should be closed");
        require(line.outstandingPrincipal == 0, "principal should stay cleared");
        require(line.accruedInterest == 0, "interest should stay cleared");
        require(line.currentCommittedAmount == 0, "committed amount should clear");
        require(line.activeLimit == 0, "active limit should clear");
        require(commitment.committedAmount == 0, "commitment amount should clear");
        require(
            commitment.status == LibEqualScaleAlphaStorage.CommitmentStatus.Closed,
            "commitment should finalize as closed"
        );
        require(
            facet.encumberedCapitalOf(positionNft.getPositionKey(lenderPositionId), SETTLEMENT_POOL_ID) == 0,
            "lender encumbrance should release on close"
        );
    }

    function test_getBorrowerProfile_mergesStoredMetadataAndLiveIdentityState() external {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        bytes32 borrowerPositionKey = positionNft.getPositionKey(borrowerPositionId);

        EqualScaleAlphaViewFacet.BorrowerProfileView memory profileView = facet.getBorrowerProfile(borrowerPositionId);

        require(profileView.borrowerPositionKey == borrowerPositionKey, "borrower key mismatch");
        require(profileView.borrowerPositionId == borrowerPositionId, "borrower position mismatch");
        require(profileView.owner == alice, "borrower owner mismatch");
        require(profileView.treasuryWallet == treasuryWallet, "treasury wallet mismatch");
        require(profileView.bankrToken == bankrToken, "bankr token mismatch");
        require(profileView.metadataHash == keccak256("profile"), "metadata hash mismatch");
        require(profileView.active, "profile should be active");
        require(profileView.agentId == 17, "agent id mismatch");
        require(profileView.registrationMode == REGISTRATION_MODE_CANONICAL_OWNED, "registration mode mismatch");
        require(profileView.tbaAddress == facet.getTBAAddress(borrowerPositionId), "tba address mismatch");
        require(profileView.externalAuthorizer == address(0), "external authorizer mismatch");
        require(profileView.canonicalLink, "canonical link mismatch");
        require(!profileView.externalLink, "external link mismatch");
        require(profileView.registrationComplete, "registration should be complete");

        identityRegistry.setOwner(17, bob);

        profileView = facet.getBorrowerProfile(borrowerPositionId);
        require(!profileView.registrationComplete, "identity should stay live");
        require(profileView.treasuryWallet == treasuryWallet, "stored treasury wallet should remain unchanged");
    }

    function test_getBorrowerLineIds_preservesCanceledProposalHistory() external {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();

        vm.startPrank(alice);
        uint256 canceledLineId = facet.createLineProposal(borrowerPositionId, _defaultProposalParamsNone());
        uint256 activeLineId = facet.createLineProposal(borrowerPositionId, _defaultProposalParamsNone());
        vm.stopPrank();

        vm.prank(alice);
        facet.cancelLineProposal(canceledLineId);

        uint256[] memory borrowerLineIds = facet.getBorrowerLineIds(borrowerPositionId);

        require(borrowerLineIds.length == 2, "raw borrower line history should keep canceled proposals");
        require(borrowerLineIds[0] == canceledLineId, "first line id mismatch");
        require(borrowerLineIds[1] == activeLineId, "second line id mismatch");
        require(
            facet.line(canceledLineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Closed,
            "canceled line should remain closed in history"
        );
        require(
            facet.line(activeLineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.SoloWindow,
            "active proposal should remain in history"
        );
    }

    function test_updateBorrowerProfile_allowsBankrTokenAndMetadataWhileLineIsActive() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);
        uint256 borrowerPositionId = facet.line(lineId).borrowerPositionId;
        bytes32 borrowerPositionKey = facet.line(lineId).borrowerPositionKey;
        address newBankrToken = address(0xF00D);
        bytes32 newMetadataHash = keccak256("active-line-profile-update");

        vm.expectEmit(true, true, false, true, address(facet));
        emit BorrowerProfileUpdated(borrowerPositionKey, borrowerPositionId, treasuryWallet, newBankrToken, newMetadataHash);

        vm.prank(alice);
        facet.updateBorrowerProfile(borrowerPositionId, treasuryWallet, newBankrToken, newMetadataHash);

        (, address storedTreasuryWallet, address storedBankrToken, bytes32 storedMetadataHash, bool active) =
            facet.borrowerProfile(borrowerPositionKey);

        require(storedTreasuryWallet == treasuryWallet, "treasury wallet should stay fixed");
        require(storedBankrToken == newBankrToken, "bankr token should update");
        require(storedMetadataHash == newMetadataHash, "metadata should update");
        require(active, "profile should remain active");
    }

    function test_lineAndCommitmentViews_roundTripStoredStateAndLookups() external {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, _defaultProposalParamsNone());

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionOne = _fundSettlementPosition(bob, 400e18);
        uint256 lenderPositionTwo = _fundSettlementPosition(carol, 600e18);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionOne, 400e18);
        vm.prank(carol);
        facet.commitPooled(lineId, lenderPositionTwo, 600e18);

        LibEqualScaleAlphaStorage.CreditLine memory storedLine = facet.line(lineId);
        LibEqualScaleAlphaStorage.CreditLine memory viewedLine = facet.getCreditLine(lineId);
        require(keccak256(abi.encode(viewedLine)) == keccak256(abi.encode(storedLine)), "credit line mismatch");

        uint256[] memory borrowerLineIds = facet.getBorrowerLineIds(borrowerPositionId);
        require(borrowerLineIds.length == 1, "borrower line count mismatch");
        require(borrowerLineIds[0] == lineId, "borrower line id mismatch");

        LibEqualScaleAlphaStorage.Commitment[] memory commitments = facet.getLineCommitments(lineId);
        require(commitments.length == 2, "line commitment count mismatch");
        require(
            keccak256(abi.encode(commitments[0])) == keccak256(abi.encode(facet.commitment(lineId, lenderPositionOne))),
            "first commitment mismatch"
        );
        require(
            keccak256(abi.encode(commitments[1])) == keccak256(abi.encode(facet.commitment(lineId, lenderPositionTwo))),
            "second commitment mismatch"
        );

        EqualScaleAlphaViewFacet.LenderPositionCommitmentView[] memory lenderCommitments =
            facet.getLenderPositionCommitments(lenderPositionOne);
        require(lenderCommitments.length == 1, "lender commitment count mismatch");
        require(lenderCommitments[0].lineId == lineId, "lender line id mismatch");
        require(
            keccak256(abi.encode(lenderCommitments[0].commitment))
                == keccak256(abi.encode(facet.commitment(lineId, lenderPositionOne))),
            "lender commitment payload mismatch"
        );
    }

    function test_previewDraw_andTreasuryTelemetry_surfaceCurrentState() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 200e18);

        uint256 elapsed = 15 days;
        vm.warp(block.timestamp + elapsed);

        EqualScaleAlphaViewFacet.DrawPreview memory drawPreview = facet.previewDraw(lineId, 100e18);
        uint256 expectedInterest = _expectedInterest(200e18, elapsed);

        require(drawPreview.requestedAmount == 100e18, "draw request mismatch");
        require(drawPreview.maxDrawableAmount == 100e18, "max drawable mismatch");
        require(drawPreview.availableLineCapacity == 800e18, "available capacity mismatch");
        require(drawPreview.remainingPeriodCapacity == 100e18, "remaining period capacity mismatch");
        require(drawPreview.poolLiquidity == 800e18, "pool liquidity mismatch");
        require(drawPreview.currentPeriodDrawn == 200e18, "current period drawn mismatch");
        require(drawPreview.nextCurrentPeriodDrawn == 300e18, "next current period drawn mismatch");
        require(drawPreview.projectedOutstandingPrincipal == 300e18, "projected principal mismatch");
        require(drawPreview.eligible, "draw preview should be eligible");
        require(!drawPreview.drawsFrozen, "draws should not be frozen");
        require(drawPreview.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "draw status mismatch");
        require(facet.isLineDrawEligible(lineId, 100e18), "draw eligibility mismatch");
        require(!facet.isLineDrawEligible(lineId, 101e18), "draw ineligibility mismatch");

        LibEqualScaleAlphaStorage.TreasuryTelemetryView memory telemetry = facet.getTreasuryTelemetry(lineId);
        require(telemetry.treasuryBalance == 200e18, "treasury balance mismatch");
        require(telemetry.outstandingPrincipal == 200e18, "telemetry principal mismatch");
        require(telemetry.accruedInterest == expectedInterest, "telemetry interest mismatch");
        require(telemetry.nextDueAmount == MINIMUM_PAYMENT_PER_PERIOD, "telemetry minimum due mismatch");
        require(telemetry.paymentCurrent, "payment should be current");
        require(!telemetry.drawsFrozen, "telemetry draws frozen mismatch");
        require(telemetry.currentPeriodDrawn == 200e18, "telemetry current period mismatch");
        require(telemetry.maxDrawPerPeriod == MAX_DRAW_PER_PERIOD, "telemetry max draw mismatch");
        require(telemetry.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "telemetry status mismatch");
    }

    function test_previewLineRepay_currentMinimumDueAndRefinanceStatus_surfaceLiveState() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 300e18);

        uint256 elapsed = PAYMENT_INTERVAL_SECS / 2;
        vm.warp(block.timestamp + elapsed);

        EqualScaleAlphaViewFacet.RepayPreview memory repayPreview = facet.previewLineRepay(lineId, 120e18);
        uint256 expectedInterest = _expectedInterest(300e18, elapsed);

        require(repayPreview.requestedAmount == 120e18, "repay request mismatch");
        require(repayPreview.effectiveAmount == 120e18, "repay amount mismatch");
        require(repayPreview.totalOutstanding == 300e18 + expectedInterest, "total outstanding mismatch");
        require(repayPreview.outstandingPrincipal == 300e18, "principal outstanding mismatch");
        require(repayPreview.accruedInterest == expectedInterest, "repay interest mismatch");
        require(repayPreview.interestComponent == expectedInterest, "repay interest component mismatch");
        require(repayPreview.principalComponent == 120e18 - expectedInterest, "repay principal component mismatch");
        require(repayPreview.currentMinimumDue == MINIMUM_PAYMENT_PER_PERIOD, "repay minimum due mismatch");
        require(repayPreview.minimumDueSatisfied, "minimum due should be satisfied");
        require(
            repayPreview.remainingOutstandingPrincipal == 300e18 - (120e18 - expectedInterest),
            "remaining principal mismatch"
        );
        require(repayPreview.remainingAccruedInterest == 0, "remaining interest mismatch");
        require(repayPreview.nextDueAt == facet.line(lineId).nextDueAt, "repay next due mismatch");
        require(repayPreview.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "repay status mismatch");
        require(facet.currentMinimumDue(lineId) == MINIMUM_PAYMENT_PER_PERIOD, "current minimum due mismatch");

        uint40 termEndAt = facet.line(lineId).termEndAt;
        vm.warp(termEndAt);

        LibEqualScaleAlphaStorage.RefinanceStatusView memory refinanceStatus = facet.getRefinanceStatus(lineId);
        require(refinanceStatus.termEndAt == termEndAt, "term end mismatch");
        require(refinanceStatus.refinanceEndAt == facet.line(lineId).refinanceEndAt, "refinance end mismatch");
        require(refinanceStatus.currentCommittedAmount == TARGET_LIMIT, "refinance committed mismatch");
        require(refinanceStatus.activeLimit == TARGET_LIMIT, "refinance active limit mismatch");
        require(refinanceStatus.outstandingPrincipal == 300e18, "refinance principal mismatch");
        require(refinanceStatus.refinanceWindowActive, "refinance window should be active");
    }

    function test_lineLossSummary_surfacesAggregateAndPerCommitmentWriteDowns() external {
        (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) =
            _createPooledActivatedLine(_defaultProposalParamsNone(), 400e18, 600e18);

        vm.prank(alice);
        facet.draw(lineId, 300e18);

        vm.warp(facet.line(lineId).nextDueAt + GRACE_PERIOD_SECS + 1);
        facet.markDelinquent(lineId);

        facet.setChargeOffThresholdForTest(1 days);
        vm.warp(block.timestamp + 1 days);
        facet.chargeOffLine(lineId);

        EqualScaleAlphaViewFacet.LineLossSummaryView memory lossSummary = facet.getLineLossSummary(lineId);
        require(lossSummary.totalPrincipalExposed == 0, "loss summary exposed mismatch");
        require(lossSummary.totalPrincipalRepaid == 0, "loss summary principal repaid mismatch");
        require(lossSummary.totalInterestReceived == 0, "loss summary interest mismatch");
        require(lossSummary.totalRecoveryReceived == 0, "loss summary recovery mismatch");
        require(lossSummary.totalLossWrittenDown == 300e18, "loss summary write-down mismatch");
        require(lossSummary.commitmentCount == 2, "loss summary commitment count mismatch");
        require(lossSummary.hasRecognizedLoss, "loss summary should recognize loss");

        LibEqualScaleAlphaStorage.Commitment[] memory commitments = facet.getLineCommitments(lineId);
        require(commitments.length == 2, "loss commitment count mismatch");
        require(commitments[0].status == LibEqualScaleAlphaStorage.CommitmentStatus.WrittenDown, "first status mismatch");
        require(commitments[1].status == LibEqualScaleAlphaStorage.CommitmentStatus.WrittenDown, "second status mismatch");
        require(commitments[0].lossWrittenDown == 120e18, "first write-down mismatch");
        require(commitments[1].lossWrittenDown == 180e18, "second write-down mismatch");

        EqualScaleAlphaViewFacet.LenderPositionCommitmentView[] memory firstLenderCommitments =
            facet.getLenderPositionCommitments(lenderPositionOne);
        EqualScaleAlphaViewFacet.LenderPositionCommitmentView[] memory secondLenderCommitments =
            facet.getLenderPositionCommitments(lenderPositionTwo);
        require(firstLenderCommitments.length == 1, "first lender lookup length mismatch");
        require(secondLenderCommitments.length == 1, "second lender lookup length mismatch");
        require(firstLenderCommitments[0].commitment.lossWrittenDown == 120e18, "first lender lookup mismatch");
        require(secondLenderCommitments[0].commitment.lossWrittenDown == 180e18, "second lender lookup mismatch");
    }

    function _timelockCall(bytes memory data) internal {
        bytes32 salt = _scheduleTimelockCall(data);
        vm.warp(block.timestamp + 7 days + 1);
        _executeTimelockCall(data, salt);
    }

    function _scheduleTimelockCall(bytes memory data) internal returns (bytes32 salt) {
        salt = keccak256(abi.encodePacked("equalscale-alpha-admin", timelockSaltNonce++));
        timelockController.schedule(address(facet), 0, data, bytes32(0), salt, 7 days);
    }

    function _executeTimelockCall(bytes memory data, bytes32 salt) internal {
        timelockController.execute(address(facet), 0, data, bytes32(0), salt);
    }

    function _assertEventEmitted(bytes32 topic0) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(facet) && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return;
            }
        }
        revert("expected event not found");
    }

    function _assertIndexedEventEmitted(bytes32 topic0, bytes32 topic1) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(facet) && logs[i].topics.length > 1 && logs[i].topics[0] == topic0
                    && logs[i].topics[1] == topic1
            ) {
                return;
            }
        }
        revert("expected indexed event not found");
    }

    function _registerBorrowerProfileForAlice() internal returns (uint256 positionId) {
        positionId = positionNft.mint(alice, 7);
        uint256 agentId = 17;
        address tba = facet.getTBAAddress(positionId);

        facet.setPositionAgentRegistration(positionId, agentId, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(agentId, tba);

        vm.prank(alice);
        facet.registerBorrowerProfile(positionId, treasuryWallet, bankrToken, keccak256("profile"));
    }

    function _createDefaultLine() internal returns (uint256 lineId) {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        facet.configurePoolForDeposits(SETTLEMENT_POOL_ID, address(settlementToken), 1);

        vm.prank(alice);
        lineId = facet.createLineProposal(borrowerPositionId, _defaultProposalParamsNone());
    }

    function _openLineToPool() internal returns (uint256 lineId) {
        lineId = _createDefaultLine();
        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);
    }

    function _createActivatedLine(
        EqualScaleAlphaFacet.LineProposalParams memory params,
        uint256 committedAmount,
        uint256 trackedBalance
    ) internal returns (uint256 lineId) {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();

        facet.configurePoolForDeposits(params.settlementPoolId, address(settlementToken), 1);

        vm.prank(alice);
        lineId = facet.createLineProposal(borrowerPositionId, params);

        uint256 lenderPositionId = _fundSettlementPosition(bob, committedAmount);

        if (committedAmount == params.requestedTargetLimit) {
            vm.prank(bob);
            facet.commitSolo(lineId, lenderPositionId);
        } else {
            vm.warp(block.timestamp + 3 days + 1);
            facet.transitionToPooledOpen(lineId);
            vm.prank(bob);
            facet.commitPooled(lineId, lenderPositionId, committedAmount);
        }

        if (trackedBalance != committedAmount) {
            // Keep one explicit liquidity override for the otherwise unreachable "pool balance drifted below
            // funded principal" branch. Real funding still establishes the position and principal honestly.
            facet.setPoolTrackedBalance(params.settlementPoolId, trackedBalance);
        }

        vm.prank(alice);
        facet.activateLine(lineId);
    }

    function _createPooledActivatedLine(
        EqualScaleAlphaFacet.LineProposalParams memory params,
        uint256 firstCommittedAmount,
        uint256 secondCommittedAmount
    ) internal returns (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();

        facet.configurePoolForDeposits(params.settlementPoolId, address(settlementToken), 1);

        vm.prank(alice);
        lineId = facet.createLineProposal(borrowerPositionId, params);

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        lenderPositionOne = _fundSettlementPosition(bob, firstCommittedAmount);
        lenderPositionTwo = _fundSettlementPosition(carol, secondCommittedAmount);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionOne, firstCommittedAmount);
        vm.prank(carol);
        facet.commitPooled(lineId, lenderPositionTwo, secondCommittedAmount);

        vm.prank(alice);
        facet.activateLine(lineId);
    }

    function _fundSettlementPosition(address owner, uint256 principal) internal returns (uint256 positionId) {
        positionId = positionNft.mint(owner, SETTLEMENT_POOL_ID);
        _depositToPosition(owner, positionId, SETTLEMENT_POOL_ID, principal);
    }

    function _depositToPosition(address owner, uint256 positionId, uint256 pid, uint256 amount) internal {
        settlementToken.mint(owner, amount);
        vm.startPrank(owner);
        settlementToken.approve(address(facet), amount);
        facet.depositToPosition(positionId, pid, amount, amount);
        vm.stopPrank();
    }

    function _mintAndApprove(address owner, uint256 amount) internal {
        settlementToken.mint(owner, amount);
        vm.prank(owner);
        settlementToken.approve(address(facet), amount);
    }

    function _expectedInterest(uint256 principal, uint256 elapsed) internal pure returns (uint256) {
        return (principal * APR_BPS * elapsed) / (10_000 * 365 days);
    }

    function _defaultProposalParamsNone()
        internal
        pure
        returns (EqualScaleAlphaFacet.LineProposalParams memory params)
    {
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

    function _borrowerPostedProposalParams()
        internal
        pure
        returns (EqualScaleAlphaFacet.LineProposalParams memory params)
    {
        params = _defaultProposalParamsNone();
        params.collateralMode = LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted;
        params.borrowerCollateralPoolId = COLLATERAL_POOL_ID;
        params.borrowerCollateralAmount = COLLATERAL_AMOUNT;
    }

    function _updatedProposalParams() internal pure returns (EqualScaleAlphaFacet.LineProposalParams memory params) {
        params = EqualScaleAlphaFacet.LineProposalParams({
            settlementPoolId: SETTLEMENT_POOL_ID + 3,
            requestedTargetLimit: TARGET_LIMIT + 50e18,
            minimumViableLine: MINIMUM_VIABLE_LINE + 25e18,
            aprBps: APR_BPS + 100,
            minimumPaymentPerPeriod: MINIMUM_PAYMENT_PER_PERIOD + 5e18,
            maxDrawPerPeriod: MAX_DRAW_PER_PERIOD + 10e18,
            paymentIntervalSecs: PAYMENT_INTERVAL_SECS + 1 days,
            gracePeriodSecs: GRACE_PERIOD_SECS + 1 days,
            facilityTermSecs: FACILITY_TERM_SECS + 10 days,
            refinanceWindowSecs: REFINANCE_WINDOW_SECS + 1 days,
            collateralMode: LibEqualScaleAlphaStorage.CollateralMode.BorrowerPosted,
            borrowerCollateralPoolId: COLLATERAL_POOL_ID,
            borrowerCollateralAmount: COLLATERAL_AMOUNT
        });
    }
}

contract EqualScaleAlphaFacetBugConditionTest is EqualScaleAlphaFacetTest {
    uint256 internal constant NATIVE_SETTLEMENT_POOL_ID = 71;

    function test_BugCondition_ChargeOffDebt_ShouldClearBorrowerDebtAndAciPrincipal() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);
        bytes32 borrowerPositionKey = facet.line(lineId).borrowerPositionKey;

        vm.prank(alice);
        facet.draw(lineId, 300e18);

        vm.warp(uint256(facet.line(lineId).nextDueAt) + GRACE_PERIOD_SECS + 1);
        facet.markDelinquent(lineId);

        facet.setChargeOffThresholdForTest(1 days);
        vm.warp(block.timestamp + 1 days);
        facet.chargeOffLine(lineId);

        require(
            facet.sameAssetDebt(SETTLEMENT_POOL_ID, borrowerPositionKey) == 0,
            "charge-off should clear borrower same-asset debt"
        );
        require(
            facet.poolActiveCreditPrincipalTotal(SETTLEMENT_POOL_ID) == 0,
            "charge-off should reduce active credit principal total"
        );
    }

    function test_BugCondition_RepayLine_ShouldNotAdvanceDueCheckpointTwiceInSameBlock() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);
        uint40 originalNextDueAt = facet.line(lineId).nextDueAt;

        vm.prank(alice);
        facet.draw(lineId, 200e18);

        vm.warp(uint256(originalNextDueAt) + GRACE_PERIOD_SECS + 1);
        _mintAndApprove(alice, 100e18);

        vm.startPrank(alice);
        facet.repayLine(lineId, 50e18);
        uint40 nextDueAfterFirstPayment = facet.line(lineId).nextDueAt;
        facet.repayLine(lineId, 50e18);
        vm.stopPrank();

        require(
            nextDueAfterFirstPayment == originalNextDueAt + PAYMENT_INTERVAL_SECS,
            "first payment should advance exactly one checkpoint"
        );
        require(
            facet.line(lineId).nextDueAt <= originalNextDueAt + PAYMENT_INTERVAL_SECS,
            "same-block second payment should not advance another checkpoint"
        );
    }

    function test_BugCondition_RepayLine_ShouldCapDueCheckpointAtTermEnd() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;
        params.facilityTermSecs = 35 days;

        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 10e18);

        uint40 termEndAt = facet.line(lineId).termEndAt;
        vm.warp(uint256(termEndAt) - 1);

        _mintAndApprove(alice, 1);
        vm.prank(alice);
        facet.repayLine(lineId, 1);

        require(facet.line(lineId).nextDueAt <= termEndAt, "next due should not overshoot term end");
    }

    function test_BugCondition_InterestLoss_ShouldRecordChargeOffInterestLossInsteadOfDiscardingIt() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        facet.setChargeOffThresholdForTest(1 days);

        (uint256 lineId, uint256 lenderPositionOne, uint256 lenderPositionTwo) =
            _createPooledActivatedLine(params, 600e18, 400e18);

        vm.prank(alice);
        facet.draw(lineId, 500e18);

        vm.warp(uint256(facet.line(lineId).nextDueAt) + GRACE_PERIOD_SECS + 1);
        facet.markDelinquent(lineId);
        vm.warp(block.timestamp + 1 days);

        (uint256 accruedInterest,,) = facet.previewLineInterest(lineId);
        facet.chargeOffLine(lineId);

        LibEqualScaleAlphaStorage.Commitment memory first = facet.commitment(lineId, lenderPositionOne);
        LibEqualScaleAlphaStorage.Commitment memory second = facet.commitment(lineId, lenderPositionTwo);
        uint256 recordedInterestLoss = first.interestLossAllocated + second.interestLossAllocated;

        require(
            recordedInterestLoss == accruedInterest,
            "charge-off should record accrued interest as lender-side interest loss"
        );
        require(first.lossWrittenDown + second.lossWrittenDown == 500e18, "principal write-down should stay separate");
    }

    function test_BugCondition_RunoffCureFloor_ShouldNotRestartBelowMinimumViableLine() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = TARGET_LIMIT;

        (uint256 lineId, uint256 lenderPositionOne,) = _createPooledActivatedLine(params, 700e18, 300e18);

        vm.prank(alice);
        facet.draw(lineId, 500e18);

        vm.warp(facet.line(lineId).termEndAt);
        facet.enterRefinancing(lineId);

        vm.prank(bob);
        facet.exitCommitment(lineId, lenderPositionOne);

        vm.warp(facet.line(lineId).refinanceEndAt);
        facet.resolveRefinancing(lineId);

        _mintAndApprove(alice, 200e18);
        vm.prank(alice);
        facet.repayLine(lineId, 200e18);

        require(
            facet.line(lineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Runoff,
            "runoff cure should not restart below minimum viable line"
        );
    }

    function test_BugCondition_Draw_ShouldBlockNativeTreasuryReentrancy() external {
        facet.configurePoolForDeposits(NATIVE_SETTLEMENT_POOL_ID, address(0), 1);

        EqualScaleAlphaReenteringTreasury attacker = new EqualScaleAlphaReenteringTreasury(facet);
        uint256 borrowerPositionId = positionNft.mint(address(attacker), 7);
        address tba = facet.getTBAAddress(borrowerPositionId);

        facet.setPositionAgentRegistration(borrowerPositionId, 99, REGISTRATION_MODE_CANONICAL_OWNED, address(0));
        identityRegistry.setOwner(99, tba);

        attacker.registerBorrowerProfile(
            borrowerPositionId, address(attacker), bankrToken, keccak256("native-reentry-profile")
        );

        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.settlementPoolId = NATIVE_SETTLEMENT_POOL_ID;
        params.requestedTargetLimit = 2 ether;
        params.minimumViableLine = 1 ether;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = 2 ether;

        uint256 lineId = attacker.createLineProposal(borrowerPositionId, params);
        uint256 lenderPositionId = positionNft.mint(bob, NATIVE_SETTLEMENT_POOL_ID);
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        facet.depositToPosition{value: 2 ether}(lenderPositionId, NATIVE_SETTLEMENT_POOL_ID, 2 ether, 2 ether);

        vm.prank(bob);
        facet.commitSolo(lineId, lenderPositionId);

        attacker.activateLine(lineId);
        attacker.drawWithReentry(lineId, 1 ether, 1 ether);

        require(attacker.didReenter(), "treasury wallet should attempt reentry in the harness");
        require(facet.line(lineId).outstandingPrincipal == 1 ether, "reentrant native draw should be blocked");
    }

    function test_BugCondition_MarkDelinquent_ShouldRevertOnMissedPaymentsOverflow() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.maxDrawPerPeriod = TARGET_LIMIT;
        uint256 lineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(lineId, 100e18);

        facet.setLineMissedPayments(lineId, type(uint8).max);
        vm.warp(uint256(facet.line(lineId).nextDueAt) + GRACE_PERIOD_SECS + 1);

        vm.expectRevert();
        facet.markDelinquent(lineId);
    }

    function test_BugCondition_FreezeBypass_ShouldRejectFrozenLines() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);

        _timelockCall(abi.encodeWithSelector(EqualScaleAlphaAdminFacet.freezeLine.selector, lineId, OPS_FREEZE_REASON));
        vm.warp(facet.line(lineId).termEndAt);

        vm.expectRevert();
        facet.enterRefinancing(lineId);
    }

    function test_BugCondition_UpdateBorrowerProfile_ShouldLockTreasuryWalletAfterActivation() external {
        uint256 lineId = _createActivatedLine(_defaultProposalParamsNone(), TARGET_LIMIT, TARGET_LIMIT);
        uint256 borrowerPositionId = facet.line(lineId).borrowerPositionId;

        vm.prank(alice);
        vm.expectRevert();
        facet.updateBorrowerProfile(
            borrowerPositionId, address(0xD00D), address(0xF00D), keccak256("locked-after-activation")
        );
    }

    function test_BugCondition_RepayLine_ShouldNotAlwaysAssignDustToLastCommitment() external {
        EqualScaleAlphaFacet.LineProposalParams memory params = _defaultProposalParamsNone();
        params.aprBps = 0;
        params.requestedTargetLimit = 3e18;
        params.minimumViableLine = 1e18;
        params.minimumPaymentPerPeriod = 1;
        params.maxDrawPerPeriod = 3e18;

        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, params);

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionOne = _fundSettlementPosition(bob, 1e18);
        uint256 lenderPositionTwo = _fundSettlementPosition(carol, 1e18);
        uint256 lenderPositionThree = _fundSettlementPosition(dave, 1e18);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionOne, 1e18);
        vm.prank(carol);
        facet.commitPooled(lineId, lenderPositionTwo, 1e18);
        vm.prank(dave);
        facet.commitPooled(lineId, lenderPositionThree, 1e18);

        vm.prank(alice);
        facet.activateLine(lineId);

        vm.prank(alice);
        facet.draw(lineId, 3e18);

        _mintAndApprove(alice, 1e18);
        vm.prank(alice);
        facet.repayLine(lineId, 1e18);

        LibEqualScaleAlphaStorage.Commitment memory third = facet.commitment(lineId, lenderPositionThree);
        uint256 expectedFloorShare = uint256(1e18) / 3;
        require(
            third.principalRepaid == expectedFloorShare,
            "repayment dust should not deterministically favor the last lender"
        );
    }
}
