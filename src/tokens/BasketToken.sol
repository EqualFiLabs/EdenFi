// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "../libraries/Errors.sol";

contract BasketToken is ERC20, ERC20Permit {
    address public immutable minter;

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(string memory name_, string memory symbol_, address minter_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (minter_ == address(0)) revert InvalidMinter();
        minter = minter_;
    }

    function mintIndexUnits(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burnIndexUnits(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}
