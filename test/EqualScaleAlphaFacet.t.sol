// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {IEqualScaleAlphaErrors} from "src/equalscale/IEqualScaleAlphaErrors.sol";
import {IEqualScaleAlphaEvents} from "src/equalscale/IEqualScaleAlphaEvents.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {LibEqualScaleAlphaStorage} from "src/libraries/LibEqualScaleAlphaStorage.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {MockERC6551RegistryLaunch, MockIdentityRegistryLaunch} from "test/utils/PositionAgentBootstrapMocks.sol";

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
}

contract EqualScaleAlphaFacetTest is IEqualScaleAlphaEvents {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant REGISTRATION_MODE_CANONICAL_OWNED = 1;

    EqualScaleAlphaFacetHarness internal facet;
    PositionNFT internal positionNft;
    MockERC6551RegistryLaunch internal registry;
    MockIdentityRegistryLaunch internal identityRegistry;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal treasuryWallet = address(0xCAFE);
    address internal bankrToken = address(0xBEEF);

    function setUp() public {
        facet = new EqualScaleAlphaFacetHarness();
        positionNft = new PositionNFT();
        registry = new MockERC6551RegistryLaunch();
        identityRegistry = new MockIdentityRegistryLaunch();

        positionNft.setMinter(address(this));
        facet.setPositionNFT(address(positionNft));
        facet.setPositionAgentViews(address(registry), address(0x1234), address(identityRegistry));
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
}
