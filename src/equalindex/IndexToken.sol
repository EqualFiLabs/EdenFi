// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "../libraries/Errors.sol";

/// @notice ERC20 IndexToken with restricted mint/burn and basic bundle introspection.
contract IndexToken is ERC20, ERC20Permit {
    address public immutable minter;
    uint256 public immutable indexId;

    address[] internal _assets;
    uint256[] internal _bundleAmounts;
    uint256 public flashFeeBps;
    uint256 public bundleCount;
    bytes32 public bundleHash;

    uint256 public totalMintFeesCollected;
    uint256 public totalBurnFeesCollected;

    event MintDetails(
        address indexed user,
        uint256 units,
        address[] assets,
        uint256[] assetAmounts,
        uint256[] feeAmounts
    );
    event BurnDetails(
        address indexed user,
        uint256 units,
        address[] assets,
        uint256[] assetAmounts,
        uint256[] feeAmounts
    );

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address minter_,
        address[] memory assets_,
        uint256[] memory bundleAmounts_,
        uint256 flashFeeBps_,
        uint256 indexId_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (minter_ == address(0)) revert InvalidMinter();
        if (assets_.length == 0 || assets_.length != bundleAmounts_.length) {
            revert InvalidArrayLength();
        }

        minter = minter_;
        indexId = indexId_;
        _assets = assets_;
        _bundleAmounts = bundleAmounts_;
        bundleCount = assets_.length;
        flashFeeBps = flashFeeBps_;
        bundleHash = keccak256(abi.encode(assets_, bundleAmounts_));
    }

    function mintIndexUnits(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burnIndexUnits(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }

    function recordMintDetails(
        address user,
        uint256 units,
        address[] calldata assets_,
        uint256[] calldata assetAmounts,
        uint256[] calldata feeAmounts,
        uint256 feeUnits
    ) external onlyMinter {
        if (feeUnits != 0) {
            totalMintFeesCollected += feeUnits;
        }
        emit MintDetails(user, units, assets_, assetAmounts, feeAmounts);
    }

    function recordBurnDetails(
        address user,
        uint256 units,
        address[] calldata assets_,
        uint256[] calldata assetAmounts,
        uint256[] calldata feeAmounts,
        uint256 feeUnits
    ) external onlyMinter {
        if (feeUnits != 0) {
            totalBurnFeesCollected += feeUnits;
        }
        emit BurnDetails(user, units, assets_, assetAmounts, feeAmounts);
    }

    function setFlashFeeBps(uint256 newFlashFeeBps) external onlyMinter {
        flashFeeBps = newFlashFeeBps;
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function bundleAmounts() external view returns (uint256[] memory) {
        return _bundleAmounts;
    }
}
