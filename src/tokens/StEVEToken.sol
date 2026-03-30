// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {BasketToken} from "./BasketToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StEVEToken is BasketToken, ERC20Votes {
    constructor(string memory name_, string memory symbol_, address minter_)
        BasketToken(name_, symbol_, minter_)
    {}

    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
