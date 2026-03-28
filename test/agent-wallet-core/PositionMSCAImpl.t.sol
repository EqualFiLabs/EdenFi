// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {PositionMSCAImpl} from "src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {IERC165} from "@agent-wallet-core/interfaces/IERC165.sol";
import {IERC6551Account} from "@agent-wallet-core/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "@agent-wallet-core/interfaces/IERC6551Executable.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {IERC6900Account} from "@agent-wallet-core/interfaces/IERC6900Account.sol";
import {ValidationConfig} from "@agent-wallet-core/libraries/ModuleTypes.sol";
import {ValidationConfigLib} from "@agent-wallet-core/libraries/ValidationConfigLib.sol";
import {OwnerValidationModule} from "@agent-wallet-core/modules/validation/OwnerValidationModule.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

error UnauthorizedCaller(address caller);

contract MockERC6551Registry is IERC6551Registry {
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address,
        uint256
    ) external returns (address) {
        assembly {
            pop(chainId)
            calldatacopy(0x8c, 0x24, 0x80)
            mstore(0x6c, 0x5af43d82803e903d91602b57fd5bf3)
            mstore(0x5d, implementation)
            mstore(0x49, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73)

            mstore8(0x00, 0xff)
            mstore(0x35, keccak256(0x55, 0xb7))
            mstore(0x01, shl(96, address()))
            mstore(0x15, salt)

            let computed := keccak256(0x00, 0x55)

            if iszero(extcodesize(computed)) {
                let deployed := create2(0, 0x55, 0xb7, salt)
                if iszero(deployed) {
                    mstore(0x00, 0x20188a59)
                    revert(0x1c, 0x04)
                }
                mstore(0x6c, deployed)
                return(0x6c, 0x20)
            }

            mstore(0x00, shr(96, shl(96, computed)))
            return(0x00, 0x20)
        }
    }

    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address) {
        assembly {
            pop(chainId)
            pop(tokenContract)
            pop(tokenId)

            calldatacopy(0x8c, 0x24, 0x80)
            mstore(0x6c, 0x5af43d82803e903d91602b57fd5bf3)
            mstore(0x5d, implementation)
            mstore(0x49, 0x3d60ad80600a3d3981f3363d3d373d3d3d363d73)

            mstore8(0x00, 0xff)
            mstore(0x35, keccak256(0x55, 0xb7))
            mstore(0x01, shl(96, address()))
            mstore(0x15, salt)

            mstore(0x00, shr(96, shl(96, keccak256(0x00, 0x55))))
            return(0x00, 0x20)
        }
    }
}

contract MockEntryPoint {
    receive() external payable {}
}

contract CounterTarget {
    uint256 internal _value;

    function setValue(uint256 nextValue) external {
        _value = nextValue;
    }

    function value() external view returns (uint256) {
        return _value;
    }
}

contract PositionMSCAImplTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    PositionNFT internal positionNft;
    MockERC6551Registry internal registry;
    MockEntryPoint internal entryPoint;
    PositionMSCAImpl internal implementation;
    OwnerValidationModule internal ownerValidationModule;
    CounterTarget internal target;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        positionNft = new PositionNFT();
        registry = new MockERC6551Registry();
        entryPoint = new MockEntryPoint();
        implementation = new PositionMSCAImpl(address(entryPoint));
        ownerValidationModule = new OwnerValidationModule();
        target = new CounterTarget();

        positionNft.setMinter(address(this));
    }

    function _mintPosition(address to, uint256 poolId) internal returns (uint256) {
        return positionNft.mint(to, poolId);
    }

    function _createAccount(uint256 tokenId) internal returns (address) {
        return registry.createAccount(address(implementation), bytes32(0), block.chainid, address(positionNft), tokenId);
    }

    function test_accountIdAndInterfaces_matchEqualFiCanonicalShape() external {
        uint256 tokenId = _mintPosition(alice, 1);
        address account = _createAccount(tokenId);

        require(account.code.length > 0, "account not deployed");
        require(
            keccak256(bytes(IERC6900Account(account).accountId()))
                == keccak256(bytes("equallend.position-tba.1.0.0")),
            "bad account id"
        );

        (uint256 chainId, address tokenContract, uint256 boundTokenId) = IERC6551Account(account).token();
        require(chainId == block.chainid, "bad chain id");
        require(tokenContract == address(positionNft), "bad token contract");
        require(boundTokenId == tokenId, "bad token id");
        require(IERC6551Account(account).owner() == alice, "bad owner");

        require(IERC165(account).supportsInterface(type(IERC165).interfaceId), "missing IERC165");
        require(IERC165(account).supportsInterface(type(IERC6900Account).interfaceId), "missing IERC6900Account");
        require(IERC165(account).supportsInterface(type(IERC6551Account).interfaceId), "missing IERC6551Account");
        require(IERC165(account).supportsInterface(type(IERC6551Executable).interfaceId), "missing IERC6551Executable");
        require(IERC165(account).supportsInterface(type(IERC721Receiver).interfaceId), "missing IERC721Receiver");
        require(IERC165(account).supportsInterface(type(IERC1271).interfaceId), "missing IERC1271");
    }

    function test_ownershipTracksPNFTTransfer_andMovesExecutionAuthority() external {
        uint256 tokenId = _mintPosition(alice, 1);
        address account = _createAccount(tokenId);

        vm.prank(alice);
        IERC6900Account(account).execute(address(target), 0, abi.encodeCall(CounterTarget.setValue, (11)));
        require(target.value() == 11, "alice exec failed");

        vm.prank(alice);
        positionNft.transferFrom(alice, bob, tokenId);
        require(IERC6551Account(account).owner() == bob, "owner did not move");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, alice));
        IERC6900Account(account).execute(address(target), 0, abi.encodeCall(CounterTarget.setValue, (22)));

        vm.prank(bob);
        IERC6900Account(account).execute(address(target), 0, abi.encodeCall(CounterTarget.setValue, (33)));
        require(target.value() == 33, "bob exec failed");
    }

    function test_validationInstallationIsDiscoverable_onERC6551DeployedAccount() external {
        uint256 tokenId = _mintPosition(alice, 1);
        address account = _createAccount(tokenId);

        ValidationConfig config =
            ValidationConfigLib.pack(address(ownerValidationModule), 0, false, true, true);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC1271.isValidSignature.selector;
        bytes[] memory hooks = new bytes[](0);

        require(
            !PositionMSCAImpl(payable(account)).isValidationInstalled(ValidationConfig.unwrap(config)),
            "validation unexpectedly installed"
        );

        vm.prank(alice);
        IERC6900Account(account).installValidation(config, selectors, "", hooks);

        require(
            PositionMSCAImpl(payable(account)).isValidationInstalled(ValidationConfig.unwrap(config)),
            "validation not recorded"
        );
    }
}
