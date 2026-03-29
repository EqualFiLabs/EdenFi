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
    PositionAgent_InvalidConfigAddress,
    PositionAgent_ConfigLocked,
    PositionAgent_Unauthorized,
    PositionAgent_InvalidAgentId,
    PositionAgent_InvalidAgentOwner,
    PositionAgent_AlreadyRegistered
} from "src/libraries/PositionAgentErrors.sol";
import {IERC165} from "@agent-wallet-core/interfaces/IERC165.sol";
import {IERC6551Account} from "@agent-wallet-core/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "@agent-wallet-core/interfaces/IERC6551Executable.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract MockIdentityRegistry {
    mapping(uint256 => address) internal _owners;

    function setOwner(uint256 agentId, address owner) external {
        _owners[agentId] = owner;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return _owners[agentId];
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

    function setUp() public {
        facet = new PositionAgentFacetHarness();
        positionNft = new PositionNFT();
        registry = new MockERC6551Registry();
        identity = new MockIdentityRegistry();
        implementation = new Mock6551Account(address(positionNft), 0);

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

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PositionAgent_AlreadyRegistered.selector, tokenId));
        facet.recordAgentRegistration(tokenId, 7);
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
}
