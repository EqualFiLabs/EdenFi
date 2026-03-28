// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IERC6551Account} from "@agent-wallet-core/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "@agent-wallet-core/interfaces/IERC6551Executable.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {ERC721BoundMSCA} from "@agent-wallet-core/core/ERC721BoundMSCA.sol";
import {MSCAStorage} from "@agent-wallet-core/libraries/MSCAStorage.sol";

contract AgentWalletCoreDependencyTest {
    function test_agentWalletCoreSurfacesResolve() external {
        ERC721BoundMSCA account = new ERC721BoundMSCA(address(0x1234));

        require(
            keccak256(bytes(account.accountId())) == keccak256(bytes("agent.wallet.erc721-bound-msca.1.0.0")),
            "bad account id"
        );
        require(type(IERC6551Registry).interfaceId != bytes4(0), "missing IERC6551Registry");
        require(type(IERC6551Account).interfaceId != bytes4(0), "missing IERC6551Account");
        require(type(IERC6551Executable).interfaceId != bytes4(0), "missing IERC6551Executable");
        require(MSCAStorage.STORAGE_SLOT != bytes32(0), "missing MSCAStorage");
    }
}
