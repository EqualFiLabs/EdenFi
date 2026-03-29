// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {InsufficientPoolLiquidity} from "src/libraries/Errors.sol";
import {Types} from "src/libraries/Types.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {MockERC6551RegistryLaunch, MockIdentityRegistryLaunch} from "test/utils/PositionAgentBootstrapMocks.sol";

contract EqualScaleAlphaMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualScaleAlphaFacetHarness is EqualScaleAlphaFacet, PositionAgentViewFacet {
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
        LibEqualScaleAlphaStorage.BorrowerProfile storage profile =
            LibEqualScaleAlphaStorage.s().borrowerProfiles[borrowerPositionKey];
        return (
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

    function setPoolInitialized(uint256 pid, bool initialized) external {
        LibAppStorage.s().pools[pid].initialized = initialized;
    }

    function setPoolUnderlying(uint256 pid, address underlying) external {
        LibAppStorage.s().pools[pid].underlying = underlying;
    }

    function setPoolTrackedBalance(uint256 pid, uint256 trackedBalance) external {
        LibAppStorage.s().pools[pid].trackedBalance = trackedBalance;
    }

    function seedPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = principal;
        LibAppStorage.s().pools[pid].userFeeIndex[positionKey] = LibAppStorage.s().pools[pid].feeIndex;
        LibAppStorage.s().pools[pid].userMaintenanceIndex[positionKey] = LibAppStorage.s().pools[pid].maintenanceIndex;
    }

    function settlementCommitmentModuleId(uint256 lineId) external pure returns (uint256) {
        return _settlementCommitmentModuleId(lineId);
    }

    function borrowerCollateralModuleId(uint256 lineId) external pure returns (uint256) {
        return _borrowerCollateralModuleId(lineId);
    }

    function moduleEncumbranceForLine(uint256 lineId, uint256 lenderPositionId) external view returns (uint256) {
        PositionNFT positionNft = _positionNft();
        bytes32 positionKey = positionNft.getPositionKey(lenderPositionId);
        uint256 pid = positionNft.getPoolId(lenderPositionId);
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, pid, _settlementCommitmentModuleId(lineId));
    }

    function moduleEncumbranceForBorrowerCollateral(uint256 lineId) external view returns (uint256) {
        LibEqualScaleAlphaStorage.CreditLine storage creditLine = LibEqualScaleAlphaStorage.s().lines[lineId];
        return LibEncumbrance.getModuleEncumberedForModule(
            creditLine.borrowerPositionKey, creditLine.borrowerCollateralPoolId, _borrowerCollateralModuleId(lineId)
        );
    }

    function setLineCurrentCommittedAmount(uint256 lineId, uint256 currentCommittedAmount) external {
        LibEqualScaleAlphaStorage.s().lines[lineId].currentCommittedAmount = currentCommittedAmount;
    }

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

    function poolActiveCreditPrincipalTotal(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditPrincipalTotal;
    }

    function previewLineInterest(uint256 lineId)
        external
        view
        returns (uint256 accruedInterest, uint256 accruedInterestSinceLastDue, uint256 requiredMinimumDue)
    {
        LibEqualScaleAlphaStorage.CreditLine storage creditLine = LibEqualScaleAlphaStorage.s().lines[lineId];

        uint256 pendingInterest;
        if (creditLine.interestAccruedAt != 0 && creditLine.outstandingPrincipal != 0 && block.timestamp > creditLine.interestAccruedAt) {
            uint256 elapsed = block.timestamp - uint256(creditLine.interestAccruedAt);
            pendingInterest =
                (creditLine.outstandingPrincipal * creditLine.aprBps * elapsed) / (10_000 * 365 days);
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
        LibEqualScaleAlphaStorage.PaymentRecord storage record = LibEqualScaleAlphaStorage.s().paymentRecords[lineId][index];
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

    EqualScaleAlphaFacetHarness internal facet;
    EqualScaleAlphaMockERC20 internal settlementToken;
    PositionNFT internal positionNft;
    MockERC6551RegistryLaunch internal registry;
    MockIdentityRegistryLaunch internal identityRegistry;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA11);
    address internal treasuryWallet = address(0xCAFE);
    address internal bankrToken = address(0xBEEF);

    function setUp() public {
        facet = new EqualScaleAlphaFacetHarness();
        settlementToken = new EqualScaleAlphaMockERC20("Settlement", "SET");
        positionNft = new PositionNFT();
        registry = new MockERC6551RegistryLaunch();
        identityRegistry = new MockIdentityRegistryLaunch();

        positionNft.setMinter(address(this));
        facet.setPositionNFT(address(positionNft));
        facet.setPositionAgentViews(address(registry), address(0x1234), address(identityRegistry));
        facet.setPoolUnderlying(SETTLEMENT_POOL_ID, address(settlementToken));
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

        (
            bytes32 storedKey,
            address storedTreasuryWallet,
            address storedBankrToken,
            ,
            bool active
        ) = facet.borrowerProfile(positionKey);

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

        (
            ,
            address storedTreasuryWallet,
            address storedBankrToken,
            bytes32 storedMetadataHash,
            bool active
        ) = facet.borrowerProfile(positionKey);

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
        require(
            line.collateralMode == LibEqualScaleAlphaStorage.CollateralMode.None, "collateral mode mismatch"
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(IEqualScaleAlphaErrors.BorrowerProfileNotActive.selector, positionKey)
        );
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
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "maxDrawPerPeriod > targetLimit")
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
        require(
            line.minimumPaymentPerPeriod == MINIMUM_PAYMENT_PER_PERIOD + 5e18, "minimum payment not updated"
        );
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
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "proposal has active commitments")
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
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "proposal has active commitments")
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
                IEqualScaleAlphaErrors.InvalidProposalTerms.selector,
                "proposal not mutable in status Active for line 1"
            )
        );
        facet.cancelLineProposal(lineId);
    }

    function test_commitSolo_encumbersFullTargetDuringSoloWindow() external {
        uint256 lineId = _createDefaultLine();
        uint256 lenderPositionId = _seedSettlementPosition(bob, TARGET_LIMIT);
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
        require(facet.moduleEncumbranceForLine(lineId, lenderPositionId) == TARGET_LIMIT, "encumbrance mismatch");
    }

    function test_commitSolo_revertsWhenAvailableSettlementPrincipalIsTooLow() external {
        uint256 lineId = _createDefaultLine();
        uint256 lenderPositionId = _seedSettlementPosition(bob, TARGET_LIMIT - 1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEqualScaleAlphaErrors.InsufficientLenderPrincipal.selector, lenderPositionId, TARGET_LIMIT, TARGET_LIMIT - 1
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
        require(
            line.status == LibEqualScaleAlphaStorage.CreditLineStatus.PooledOpen, "line did not enter pooled open"
        );
    }

    function test_commitPooled_tracksSeparateCommitmentsPerPositionNotWallet() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionOne = _seedSettlementPosition(bob, 700e18);
        uint256 lenderPositionTwo = _seedSettlementPosition(bob, 500e18);

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
        uint256 lenderPositionOne = _seedSettlementPosition(bob, 700e18);
        uint256 lenderPositionTwo = _seedSettlementPosition(carol, 500e18);

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
        uint256 lenderPositionId = _seedSettlementPosition(bob, 600e18);
        bytes32 lenderPositionKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(bob);
        facet.commitPooled(lineId, lenderPositionId, 400e18);

        vm.expectEmit(true, true, true, true, address(facet));
        emit CommitmentCancelled(lineId, lenderPositionId, lenderPositionKey, 400e18, 0);

        vm.prank(bob);
        facet.cancelCommitment(lineId, lenderPositionId);

        LibEqualScaleAlphaStorage.Commitment memory commitment = facet.commitment(lineId, lenderPositionId);
        require(commitment.committedAmount == 0, "commitment amount not cleared");
        require(
            commitment.status == LibEqualScaleAlphaStorage.CommitmentStatus.Canceled, "commitment not canceled"
        );
        require(facet.moduleEncumbranceForLine(lineId, lenderPositionId) == 0, "encumbrance not released");
        require(facet.line(lineId).currentCommittedAmount == 0, "line committed amount not reduced");
    }

    function test_lenderPositionTransfer_movesCommitmentRightsAndObligations() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionId = _seedSettlementPosition(bob, 600e18);

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
            commitment.status == LibEqualScaleAlphaStorage.CommitmentStatus.Canceled, "transferred commitment not cancelable"
        );
        require(facet.moduleEncumbranceForLine(lineId, lenderPositionId) == 0, "transferred encumbrance not released");
    }

    function test_activateLine_fullCommitActivatesUnsecuredLineAndInitializesLiveState() external {
        uint256 lineId = _createDefaultLine();
        uint256 lenderPositionId = _seedSettlementPosition(bob, TARGET_LIMIT);
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
        require(facet.moduleEncumbranceForLine(lineId, lenderPositionId) == TARGET_LIMIT, "lender encumbrance released");
        require(facet.moduleEncumbranceForBorrowerCollateral(lineId) == 0, "unexpected borrower collateral");
    }

    function test_activateLine_borrowerAcceptsResizedBorrowerCollateralizedActivation() external {
        uint256 borrowerPositionId = _registerBorrowerProfileForAlice();
        bytes32 borrowerPositionKey = positionNft.getPositionKey(borrowerPositionId);
        uint256 acceptedAmount = 700e18;
        uint40 activatedAt = uint40(block.timestamp + 3 days + 1);
        uint40 expectedNextDueAt = activatedAt + PAYMENT_INTERVAL_SECS;
        uint40 expectedTermEndAt = activatedAt + FACILITY_TERM_SECS;
        uint40 expectedRefinanceEndAt = expectedTermEndAt + REFINANCE_WINDOW_SECS;

        facet.setPoolInitialized(SETTLEMENT_POOL_ID, true);
        facet.setPoolInitialized(COLLATERAL_POOL_ID, true);
        facet.seedPrincipal(COLLATERAL_POOL_ID, borrowerPositionKey, COLLATERAL_AMOUNT);

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, _borrowerPostedProposalParams());

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionId = _seedSettlementPosition(bob, acceptedAmount);
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
            facet.moduleEncumbranceForLine(lineId, lenderPositionId) == acceptedAmount, "resized lender encumbrance released"
        );
        require(
            facet.moduleEncumbranceForBorrowerCollateral(lineId) == COLLATERAL_AMOUNT,
            "borrower collateral not encumbered"
        );
    }

    function test_activateLine_revertsWhenCommitmentsRemainBelowMinimumViableLine() external {
        uint256 lineId = _openLineToPool();
        uint256 lenderPositionId = _seedSettlementPosition(bob, MINIMUM_VIABLE_LINE - 1);

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
        uint256 lenderPositionId = _seedSettlementPosition(bob, 700e18);
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

        facet.setPoolInitialized(SETTLEMENT_POOL_ID, true);
        facet.setPoolTrackedBalance(SETTLEMENT_POOL_ID, TARGET_LIMIT);
        settlementToken.mint(address(facet), TARGET_LIMIT);

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, _defaultProposalParamsNone());

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionOne = _seedSettlementPosition(bob, 600e18);
        uint256 lenderPositionTwo = _seedSettlementPosition(carol, 400e18);
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
            facet.poolActiveCreditPrincipalTotal(SETTLEMENT_POOL_ID) == 250e18, "active credit principal mismatch"
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
                IEqualScaleAlphaErrors.InvalidDrawPacing.selector,
                1,
                MAX_DRAW_PER_PERIOD,
                MAX_DRAW_PER_PERIOD
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
            abi.encodeWithSelector(IEqualScaleAlphaErrors.InvalidProposalTerms.selector, "draw exceeds available capacity")
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
        facet.repay(lineId, expectedInterest);

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
            lineId,
            repayAmount,
            60e18,
            expectedInterest,
            240e18,
            0,
            nextDueAtBefore + PAYMENT_INTERVAL_SECS
        );

        vm.prank(alice);
        facet.repay(lineId, repayAmount);

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
        require(facet.sameAssetDebt(SETTLEMENT_POOL_ID, positionNft.getPositionKey(line.borrowerPositionId)) == 240e18, "same-asset debt mismatch");
        require(facet.poolActiveCreditPrincipalTotal(SETTLEMENT_POOL_ID) == 240e18, "active credit total mismatch");
        require(debtPrincipal == 240e18, "debt principal not reduced");
        require(debtIndexSnapshot == 0, "debt index snapshot mismatch");
        require(facet.poolTrackedBalance(SETTLEMENT_POOL_ID) == TARGET_LIMIT - 300e18 + repayAmount, "tracked balance mismatch");
        require(settlementToken.balanceOf(address(facet)) == TARGET_LIMIT - 300e18 + repayAmount, "facet balance mismatch");
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
        facet.setPoolInitialized(SETTLEMENT_POOL_ID, true);
        facet.setPoolTrackedBalance(SETTLEMENT_POOL_ID, TARGET_LIMIT);
        settlementToken.mint(address(facet), TARGET_LIMIT);

        vm.prank(alice);
        uint256 lineId = facet.createLineProposal(borrowerPositionId, params);

        vm.warp(block.timestamp + 3 days + 1);
        facet.transitionToPooledOpen(lineId);

        uint256 lenderPositionOne = _seedSettlementPosition(bob, 600e18);
        uint256 lenderPositionTwo = _seedSettlementPosition(carol, 400e18);

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
        facet.repay(lineId, repayAmount);

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
        facet.repay(delinquentLineId, 40e18);
        require(
            facet.line(delinquentLineId).status == LibEqualScaleAlphaStorage.CreditLineStatus.Delinquent,
            "insufficient payment should not cure delinquency"
        );

        vm.prank(alice);
        facet.repay(delinquentLineId, 10e18);

        LibEqualScaleAlphaStorage.CreditLine memory delinquentLine = facet.line(delinquentLineId);
        require(
            delinquentLine.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "delinquent line not cured"
        );
        require(delinquentLine.nextDueAt > uint40(block.timestamp), "cured delinquent line should advance due");

        uint256 runoffLineId = _createActivatedLine(params, TARGET_LIMIT, TARGET_LIMIT);

        vm.prank(alice);
        facet.draw(runoffLineId, 700e18);

        facet.setLineCurrentCommittedAmount(runoffLineId, 500e18);
        facet.setLineStatus(runoffLineId, uint256(LibEqualScaleAlphaStorage.CreditLineStatus.Runoff));

        uint40 restartTimestamp = uint40(block.timestamp);
        _mintAndApprove(alice, 200e18);

        vm.prank(alice);
        facet.repay(runoffLineId, 200e18);

        LibEqualScaleAlphaStorage.CreditLine memory runoffLine = facet.line(runoffLineId);
        require(runoffLine.status == LibEqualScaleAlphaStorage.CreditLineStatus.Active, "runoff line not cured");
        require(runoffLine.outstandingPrincipal == 500e18, "runoff outstanding mismatch");
        require(runoffLine.activeLimit == 500e18, "runoff active limit should resize to covered amount");
        require(runoffLine.currentPeriodStartedAt == restartTimestamp, "runoff period not restarted");
        require(runoffLine.termStartedAt == restartTimestamp, "runoff term not restarted");
        require(runoffLine.nextDueAt == restartTimestamp + PAYMENT_INTERVAL_SECS, "runoff due not reset");
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
        facet.setPoolInitialized(SETTLEMENT_POOL_ID, true);

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

        facet.setPoolInitialized(params.settlementPoolId, true);
        facet.setPoolUnderlying(params.settlementPoolId, address(settlementToken));
        facet.setPoolTrackedBalance(params.settlementPoolId, trackedBalance);
        settlementToken.mint(address(facet), trackedBalance);

        vm.prank(alice);
        lineId = facet.createLineProposal(borrowerPositionId, params);

        uint256 lenderPositionId = _seedSettlementPosition(bob, committedAmount);

        if (committedAmount == params.requestedTargetLimit) {
            vm.prank(bob);
            facet.commitSolo(lineId, lenderPositionId);
        } else {
            vm.warp(block.timestamp + 3 days + 1);
            facet.transitionToPooledOpen(lineId);
            vm.prank(bob);
            facet.commitPooled(lineId, lenderPositionId, committedAmount);
        }

        vm.prank(alice);
        facet.activateLine(lineId);
    }

    function _seedSettlementPosition(address owner, uint256 principal) internal returns (uint256 positionId) {
        positionId = positionNft.mint(owner, SETTLEMENT_POOL_ID);
        facet.seedPrincipal(SETTLEMENT_POOL_ID, positionNft.getPositionKey(positionId), principal);
    }

    function _mintAndApprove(address owner, uint256 amount) internal {
        settlementToken.mint(owner, amount);
        vm.prank(owner);
        settlementToken.approve(address(facet), amount);
    }

    function _expectedInterest(uint256 principal, uint256 elapsed) internal pure returns (uint256) {
        return (principal * APR_BPS * elapsed) / (10_000 * 365 days);
    }

    function _defaultProposalParamsNone() internal pure returns (EqualScaleAlphaFacet.LineProposalParams memory params) {
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
