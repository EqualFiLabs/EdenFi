// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {LibPositionAgentStorage} from "src/libraries/LibPositionAgentStorage.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {
    PositionAgent_NotAdmin,
    PositionAgent_InvalidExternalLinkSignature,
    PositionAgent_InvalidConfigAddress,
    PositionAgent_ConfigLocked,
    PositionAgent_InvalidRegistrationMode,
    PositionAgent_Unauthorized,
    PositionAgent_InvalidAgentId,
    PositionAgent_InvalidAgentOwner,
    PositionAgent_AlreadyRegistered,
    PositionAgent_NotIdentityOwner,
    PositionAgent_RegistrationExpired
} from "src/libraries/PositionAgentErrors.sol";
import {IERC165} from "@agent-wallet-core/interfaces/IERC165.sol";
import {IERC6551Account} from "@agent-wallet-core/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "@agent-wallet-core/interfaces/IERC6551Executable.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MockIdentityRegistry {
    mapping(uint256 => address) internal _owners;

    function setOwner(uint256 agentId, address owner) external {
        _owners[agentId] = owner;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return _owners[agentId];
    }
}

contract Mock1271IdentityOwner is IERC1271 {
    using ECDSA for bytes32;

    address internal immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError error, ) = ECDSA.tryRecover(hash, signature);
        if (error == ECDSA.RecoverError.NoError && recovered == signer) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

contract Mock6551Account is IERC165, IERC6551Account, IERC6551Executable, IERC721Receiver, IERC1271 {
    address internal immutable tokenContract_;
    uint256 internal immutable tokenId_;
    uint256 internal immutable chainId_;

    constructor(address tokenContract__, uint256 tokenId__) payable {
        tokenContract_ = tokenContract__;
        tokenId_ = tokenId__;
        chainId_ = block.chainid;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC1271).interfaceId;
    }

    function token() external view returns (uint256, address, uint256) {
        return (chainId_, tokenContract_, tokenId_);
    }

    function owner() external view returns (address) {
        return PositionNFT(tokenContract_).ownerOf(tokenId_);
    }

    function nonce() external pure returns (uint256) {
        return 0;
    }

    function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
        return signer == PositionNFT(tokenContract_).ownerOf(tokenId_) ? bytes4(keccak256("VALID")) : bytes4(0);
    }

    function execute(address, uint256, bytes calldata, uint8) external payable returns (bytes memory result) {
        result = "";
    }

    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract MockERC6551Registry is IERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address deployedAccount) {
        bytes32 finalSalt = keccak256(abi.encode(implementation, salt, chainId, tokenContract, tokenId));
        deployedAccount = _compute(finalSalt, tokenContract, tokenId);
        if (deployedAccount.code.length == 0) {
            deployedAccount = address(new Mock6551Account{salt: finalSalt}(tokenContract, tokenId));
        }
    }

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address account_) {
        bytes32 finalSalt = keccak256(abi.encode(implementation, salt, chainId, tokenContract, tokenId));
        return _compute(finalSalt, tokenContract, tokenId);
    }

    function _compute(bytes32 finalSalt, address tokenContract, uint256 tokenId) internal view returns (address) {
        bytes memory initCode = abi.encodePacked(type(Mock6551Account).creationCode, abi.encode(tokenContract, tokenId));
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), finalSalt, keccak256(initCode))
        );
        return address(uint160(uint256(hash)));
    }
}

contract PositionAgentFacetHarness is
    PositionAgentConfigFacet,
    PositionAgentTBAFacet,
    PositionAgentRegistryFacet,
    PositionAgentViewFacet
{
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = true;
    }

    function getRegisteredAgentId(uint256 tokenId) external view returns (uint256) {
        return LibPositionAgentStorage.s().positionToAgentId[tokenId];
    }

    function getRegistrationMode(uint256 tokenId) external view returns (uint8) {
        return uint8(LibPositionAgentStorage.s().positionRegistrationMode[tokenId]);
    }

    function getStoredExternalAgentAuthorizer(uint256 tokenId) external view returns (address) {
        return LibPositionAgentStorage.s().externalAgentAuthorizer[tokenId];
    }

    function getExternalLinkNonce(uint256 tokenId) external view returns (uint256) {
        return LibPositionAgentStorage.s().externalLinkNonce[tokenId];
    }

    function useExternalLinkNonceExternal(uint256 tokenId) external returns (uint256) {
        return LibPositionAgentStorage.useExternalLinkNonce(tokenId);
    }

    function isConfigLocked() external view returns (bool) {
        return LibPositionAgentStorage.s().tbaConfigLocked;
    }

    function _positionNFTAddress()
        internal
        view
        override(PositionAgentTBAFacet, PositionAgentRegistryFacet, PositionAgentViewFacet)
        returns (address)
    {
        return LibPositionNFT.s().positionNFTContract;
    }
}

contract PositionAgentFacetTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint8 internal constant REGISTRATION_MODE_NONE = 0;
    uint8 internal constant REGISTRATION_MODE_CANONICAL_OWNED = 1;
    uint8 internal constant REGISTRATION_MODE_EXTERNAL_LINKED = 2;

    event ERC6551RegistryUpdated(address indexed previous, address indexed current);
    event ERC6551ImplementationUpdated(address indexed previous, address indexed current);
    event IdentityRegistryUpdated(address indexed previous, address indexed current);
    event TBADeployed(uint256 indexed positionTokenId, address indexed tbaAddress);
    event AgentRegistered(uint256 indexed positionTokenId, address indexed tbaAddress, uint256 indexed agentId);

    PositionAgentFacetHarness internal facet;
    PositionNFT internal positionNft;
    MockERC6551Registry internal registry;
    MockIdentityRegistry internal identity;
    Mock6551Account internal implementation;

    address internal owner = address(0xA11CE);
    address internal timelock = address(0xBEEF);
    address internal alice = address(0xCAFE);
    address internal bob = address(0xB0B);
    uint256 internal externalOwnerPk = uint256(0xA71CE);
    address internal externalOwner;

    function setUp() public {
        facet = new PositionAgentFacetHarness();
        positionNft = new PositionNFT();
        registry = new MockERC6551Registry();
        identity = new MockIdentityRegistry();
        implementation = new Mock6551Account(address(positionNft), 0);
        externalOwner = vm.addr(externalOwnerPk);

        positionNft.setMinter(address(this));

        facet.setOwner(owner);
        facet.setPositionNFT(address(positionNft));
    }

    function _tokenIdFor(address account, uint256 poolId) internal returns (uint256) {
        return positionNft.mint(account, poolId);
    }

    function _configure(address caller) internal {
        vm.prank(caller);
        facet.setERC6551Registry(address(registry));
        vm.prank(caller);
        facet.setERC6551Implementation(address(implementation));
        vm.prank(caller);
        facet.setIdentityRegistry(address(identity));
    }

    function _externalLinkDigest(uint256 tokenId, uint256 agentId, address positionOwner, address tba, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256(
                    "EqualFiExternalAgentLink(uint256 chainId,address diamond,uint256 positionTokenId,uint256 agentId,address positionOwner,address tbaAddress,uint256 nonce,uint256 deadline)"
                ),
                block.chainid,
                address(facet),
                tokenId,
                agentId,
                positionOwner,
                tba,
                nonce,
                deadline
            )
        );
    }

    function _signDigest(uint256 signerPk, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_configFacet_isAdminOnly_andValidatesCode() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_NotAdmin.selector, alice));
        facet.setERC6551Registry(address(registry));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidConfigAddress.selector, address(0)));
        facet.setERC6551Registry(address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidConfigAddress.selector, alice));
        facet.setERC6551Implementation(alice);
    }

    function test_configFacet_allowsOwnerAndTimelock_andEmits() external {
        vm.recordLogs();
        _configure(owner);

        (address configuredRegistry, address configuredImplementation, address configuredIdentity) =
            facet.getCanonicalRegistries();
        require(configuredRegistry == address(registry), "bad registry");
        require(configuredImplementation == address(implementation), "bad implementation");
        require(configuredIdentity == address(identity), "bad identity");

        facet.setTimelock(timelock);

        MockIdentityRegistry identity2 = new MockIdentityRegistry();
        vm.prank(timelock);
        facet.setIdentityRegistry(address(identity2));

        (, , configuredIdentity) = facet.getCanonicalRegistries();
        require(configuredIdentity == address(identity2), "timelock update failed");
    }

    function test_tbaFacet_deploysIdempotently_andLocksConfig() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        address predicted = facet.getTBAAddress(tokenId);
        require(predicted != address(0), "predicted zero");
        require(!facet.isTBADeployed(tokenId), "unexpected deployed");

        vm.expectEmit(true, true, false, true);
        emit TBADeployed(tokenId, predicted);
        vm.prank(owner);
        address deployed = facet.deployTBA(tokenId);

        require(deployed == predicted, "deployed mismatch");
        require(facet.isTBADeployed(tokenId), "deploy flag missing");
        require(facet.isConfigLocked(), "config not locked");

        (bool supportsAccount, bool supportsExecutable, bool supportsReceiver, bool supports1271) =
            facet.getTBAInterfaceSupport(tokenId);
        require(supportsAccount, "missing account iface");
        require(supportsExecutable, "missing executable iface");
        require(supportsReceiver, "missing receiver iface");
        require(supports1271, "missing 1271 iface");

        vm.prank(owner);
        address deployedAgain = facet.deployTBA(tokenId);
        require(deployedAgain == deployed, "non-idempotent deploy");

        vm.prank(owner);
        vm.expectRevert(PositionAgent_ConfigLocked.selector);
        facet.setERC6551Registry(address(registry));
    }

    function test_tbaFacet_rejectsNonOwnerDeployment() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_Unauthorized.selector, alice, tokenId));
        facet.deployTBA(tokenId);
    }

    function test_storageTracksRegistrationModeAuthorizerAndReplayNonce() external {
        uint256 tokenId = _tokenIdFor(owner, 1);

        require(facet.getRegistrationMode(tokenId) == REGISTRATION_MODE_NONE, "unexpected default mode");
        require(facet.getExternalAgentAuthorizer(tokenId) == address(0), "unexpected default authorizer");
        require(facet.getExternalLinkNonce(tokenId) == 0, "unexpected default nonce");

        uint256 firstNonce = facet.useExternalLinkNonceExternal(tokenId);
        require(firstNonce == 0, "bad first nonce");
        require(facet.getExternalLinkNonce(tokenId) == 1, "nonce not incremented");

        uint256 secondNonce = facet.useExternalLinkNonceExternal(tokenId);
        require(secondNonce == 1, "bad second nonce");
        require(facet.getExternalLinkNonce(tokenId) == 2, "second nonce not incremented");
    }

    function test_registryFacet_recordsAgentRegistration_andRejectsBadStates() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidAgentId.selector, 0));
        facet.recordAgentRegistration(tokenId, 0);

        identity.setOwner(7, bob);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_InvalidAgentOwner.selector, tba, bob));
        facet.recordAgentRegistration(tokenId, 7);

        identity.setOwner(7, tba);
        vm.expectEmit(true, true, true, true);
        emit AgentRegistered(tokenId, tba, 7);
        vm.prank(owner);
        facet.recordAgentRegistration(tokenId, 7);

        require(facet.getAgentId(tokenId) == 7, "agent id missing");
        require(facet.isAgentRegistered(tokenId), "registration missing");
        require(facet.isCanonicalAgentLink(tokenId), "canonical link missing");
        require(facet.isRegistrationComplete(tokenId), "registration incomplete");
        require(facet.getRegisteredAgentId(tokenId) == 7, "storage mapping missing");
        require(
            facet.getRegistrationMode(tokenId) == REGISTRATION_MODE_CANONICAL_OWNED, "canonical mode not recorded"
        );
        require(facet.getExternalAgentAuthorizer(tokenId) == address(0), "external authorizer unexpectedly set");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_AlreadyRegistered.selector, tokenId));
        facet.recordAgentRegistration(tokenId, 7);
    }

    function test_externalLink_succeedsForEOA_andTracksAuthorizerAndMode() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);

        uint256 agentId = 88;
        uint256 deadline = block.timestamp + 1 days;
        identity.setOwner(agentId, externalOwner);

        bytes32 digest = _externalLinkDigest(tokenId, agentId, owner, tba, facet.getExternalLinkNonce(tokenId), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(externalOwnerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(owner);
        facet.linkExternalAgentRegistration(tokenId, agentId, deadline, signature);

        require(facet.getAgentId(tokenId) == agentId, "agent id missing");
        require(facet.getRegistrationMode(tokenId) == REGISTRATION_MODE_EXTERNAL_LINKED, "bad mode");
        require(facet.getExternalAgentAuthorizer(tokenId) == externalOwner, "bad external authorizer");
        require(facet.getExternalLinkNonce(tokenId) == 1, "nonce not consumed");
        require(!facet.isCanonicalAgentLink(tokenId), "external link marked canonical");
        require(facet.isExternalAgentLink(tokenId), "external link not active");
        require(facet.isRegistrationComplete(tokenId), "external registration incomplete");
    }

    function test_externalLink_supportsEIP1271_andFailsClosedOnIdentityOwnerDrift() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);

        uint256 agentId = 89;
        uint256 deadline = block.timestamp + 1 days;
        Mock1271IdentityOwner contractOwner = new Mock1271IdentityOwner(externalOwner);
        identity.setOwner(agentId, address(contractOwner));

        bytes32 digest = _externalLinkDigest(
            tokenId, agentId, owner, tba, facet.getExternalLinkNonce(tokenId), deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(externalOwnerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(owner);
        facet.linkExternalAgentRegistration(tokenId, agentId, deadline, signature);

        require(facet.isExternalAgentLink(tokenId), "1271 external link inactive");
        require(facet.isRegistrationComplete(tokenId), "1271 registration incomplete");

        identity.setOwner(agentId, bob);
        require(!facet.isExternalAgentLink(tokenId), "stale external link still active");
        require(!facet.isRegistrationComplete(tokenId), "stale registration still complete");
    }

    function test_externalLink_rejectsBadSignerAndReplay() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);

        uint256 agentId = 90;
        identity.setOwner(agentId, externalOwner);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _externalLinkDigest(tokenId, agentId, owner, tba, facet.getExternalLinkNonce(tokenId), deadline);
        bytes memory signature = _signDigest(externalOwnerPk, digest);

        vm.prank(owner);
        facet.linkExternalAgentRegistration(tokenId, agentId, deadline, signature);

        uint256 replayTokenId = _tokenIdFor(owner, 1);
        vm.prank(owner);
        address replayTba = facet.deployTBA(replayTokenId);
        bytes32 wrongDigest =
            _externalLinkDigest(replayTokenId, agentId, owner, replayTba, facet.getExternalLinkNonce(replayTokenId), deadline);
        bytes memory badSignature = _signDigest(uint256(0xBEEFCAFE), wrongDigest);

        identity.setOwner(agentId + 1, externalOwner);
        vm.prank(owner);
        vm.expectRevert(PositionAgent_InvalidExternalLinkSignature.selector);
        facet.linkExternalAgentRegistration(replayTokenId, agentId + 1, deadline, badSignature);
    }

    function test_externalLink_rejectsExpiredApproval() external {
        _configure(owner);
        uint256 expiredTokenId = _tokenIdFor(owner, 1);
        vm.prank(owner);
        address expiredTba = facet.deployTBA(expiredTokenId);
        uint256 agentId = 91;
        identity.setOwner(agentId, externalOwner);
        uint256 expiredDeadline = block.timestamp;
        bytes32 expiredDigest = _externalLinkDigest(
            expiredTokenId, agentId, owner, expiredTba, facet.getExternalLinkNonce(expiredTokenId), expiredDeadline
        );
        bytes memory expiredSignature = _signDigest(externalOwnerPk, expiredDigest);
        vm.warp(block.timestamp + 1);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PositionAgent_RegistrationExpired.selector, expiredDeadline, block.timestamp)
        );
        facet.linkExternalAgentRegistration(expiredTokenId, agentId, expiredDeadline, expiredSignature);
    }

    function test_externalLink_rejectsWhenIdentityOwnerDriftsBeforeSubmission() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);

        uint256 agentId = 96;
        uint256 deadline = block.timestamp + 1 days;
        identity.setOwner(agentId, externalOwner);

        bytes32 digest = _externalLinkDigest(tokenId, agentId, owner, tba, facet.getExternalLinkNonce(tokenId), deadline);
        bytes memory signature = _signDigest(externalOwnerPk, digest);

        identity.setOwner(agentId, bob);

        vm.prank(owner);
        vm.expectRevert(PositionAgent_InvalidExternalLinkSignature.selector);
        facet.linkExternalAgentRegistration(tokenId, agentId, deadline, signature);
    }

    function test_externalLink_rejectsSignatureBoundToDifferentPositionContext() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);

        uint256 agentId = 91;
        uint256 deadline = block.timestamp + 1 days;
        identity.setOwner(agentId, externalOwner);

        bytes32 digest = _externalLinkDigest(tokenId, agentId, owner, tba, facet.getExternalLinkNonce(tokenId), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(externalOwnerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(owner);
        positionNft.transferFrom(owner, bob, tokenId);

        vm.prank(bob);
        vm.expectRevert(PositionAgent_InvalidExternalLinkSignature.selector);
        facet.linkExternalAgentRegistration(tokenId, agentId, deadline, signature);
    }

    function test_externalLink_supportsUnlinkAndIdentityOwnerRevoke() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);

        uint256 agentId = 92;
        uint256 deadline = block.timestamp + 1 days;
        identity.setOwner(agentId, externalOwner);
        bytes32 digest = _externalLinkDigest(tokenId, agentId, owner, tba, facet.getExternalLinkNonce(tokenId), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(externalOwnerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(owner);
        facet.linkExternalAgentRegistration(tokenId, agentId, deadline, signature);

        vm.prank(owner);
        facet.unlinkExternalAgentRegistration(tokenId);

        require(facet.getAgentId(tokenId) == 0, "unlink did not clear agent");
        require(facet.getRegistrationMode(tokenId) == REGISTRATION_MODE_NONE, "unlink did not reset mode");
        require(facet.getExternalAgentAuthorizer(tokenId) == address(0), "unlink did not clear authorizer");
        require(!facet.isRegistrationComplete(tokenId), "unlink left registration complete");

        uint256 tokenId2 = _tokenIdFor(owner, 1);
        vm.prank(owner);
        address tba2 = facet.deployTBA(tokenId2);
        uint256 agentId2 = 93;
        identity.setOwner(agentId2, externalOwner);
        bytes32 digest2 =
            _externalLinkDigest(tokenId2, agentId2, owner, tba2, facet.getExternalLinkNonce(tokenId2), deadline);
        (v, r, s) = vm.sign(externalOwnerPk, digest2);
        bytes memory signature2 = abi.encodePacked(r, s, v);

        vm.prank(owner);
        facet.linkExternalAgentRegistration(tokenId2, agentId2, deadline, signature2);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_NotIdentityOwner.selector, bob, externalOwner));
        facet.revokeExternalAgentRegistration(tokenId2);

        vm.prank(externalOwner);
        facet.revokeExternalAgentRegistration(tokenId2);

        require(facet.getAgentId(tokenId2) == 0, "revoke did not clear agent");
        require(facet.getRegistrationMode(tokenId2) == REGISTRATION_MODE_NONE, "revoke did not reset mode");
        require(facet.getExternalAgentAuthorizer(tokenId2) == address(0), "revoke did not clear authorizer");
    }

    function test_viewFacet_reportsCanonicalState() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        address predicted = facet.getTBAAddress(tokenId);
        require(predicted != address(0), "no tba address");
        require(!facet.isTBADeployed(tokenId), "should be undeployed");

        (bool supportsAccount, bool supportsExecutable, bool supportsReceiver, bool supports1271) =
            facet.getTBAInterfaceSupport(tokenId);
        require(!supportsAccount && !supportsExecutable && !supportsReceiver && !supports1271, "unexpected support");

        require(facet.getAgentId(tokenId) == 0, "unexpected agent id");
        require(!facet.isAgentRegistered(tokenId), "unexpected registration");
        require(!facet.isCanonicalAgentLink(tokenId), "unexpected canonical link");
        require(!facet.isExternalAgentLink(tokenId), "unexpected external link");
        require(!facet.isRegistrationComplete(tokenId), "unexpected registration complete");

        vm.prank(owner);
        address deployed = facet.deployTBA(tokenId);
        require(deployed == predicted, "deploy mismatch");
        require(!facet.isRegistrationComplete(tokenId), "deployment should not imply registration");

        address implementationAddr = facet.getTBAImplementation();
        address registryAddr = facet.getERC6551Registry();
        require(implementationAddr == address(implementation), "bad implementation getter");
        require(registryAddr == address(registry), "bad registry getter");
    }

    function test_registrationStaysAttachedToTBA_afterPNFTTransfer() external {
        _configure(owner);
        uint256 tokenId = _tokenIdFor(owner, 1);

        vm.prank(owner);
        address tba = facet.deployTBA(tokenId);

        identity.setOwner(7, tba);
        vm.prank(owner);
        facet.recordAgentRegistration(tokenId, 7);

        vm.prank(owner);
        positionNft.transferFrom(owner, bob, tokenId);

        require(positionNft.ownerOf(tokenId) == bob, "token owner did not move");
        require(facet.getTBAAddress(tokenId) == tba, "tba address changed");
        require(facet.getAgentId(tokenId) == 7, "agent id changed");
        require(facet.isAgentRegistered(tokenId), "registration lost");
        require(facet.isCanonicalAgentLink(tokenId), "canonical link lost");
        require(!facet.isExternalAgentLink(tokenId), "canonical link flipped external");
        require(facet.isRegistrationComplete(tokenId), "registration no longer complete");

        vm.prank(bob);
        address deployedAgain = facet.deployTBA(tokenId);
        require(deployedAgain == tba, "new owner lost wallet control");
    }
}
