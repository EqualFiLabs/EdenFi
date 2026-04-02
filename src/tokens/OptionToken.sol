// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @notice ERC-1155 token for EqualFi option series, controlled by a designated manager.
contract OptionToken is ERC1155, Ownable {
    error OptionToken_InvalidManager(address manager);
    error OptionToken_NotManager(address caller);

    event OptionTokenManagerUpdated(address indexed previousManager, address indexed newManager);
    event OptionTokenBaseURIUpdated(string newBaseURI);
    event OptionTokenSeriesURIUpdated(uint256 indexed seriesId, string newSeriesURI);

    address public manager;

    string private _baseTokenURI;
    mapping(uint256 => string) private _seriesTokenURI;

    modifier onlyManager() {
        if (msg.sender != manager) {
            revert OptionToken_NotManager(msg.sender);
        }
        _;
    }

    constructor(string memory baseURI_, address owner_, address manager_) ERC1155("") Ownable(owner_) {
        if (manager_ == address(0)) {
            revert OptionToken_InvalidManager(manager_);
        }

        _baseTokenURI = baseURI_;
        manager = manager_;
    }

    function setManager(address manager_) external onlyOwner {
        if (manager_ == address(0)) {
            revert OptionToken_InvalidManager(manager_);
        }

        address previousManager = manager;
        manager = manager_;
        emit OptionTokenManagerUpdated(previousManager, manager_);
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        emit OptionTokenBaseURIUpdated(baseURI_);
    }

    function setSeriesURI(uint256 seriesId, string calldata uri_) external onlyManager {
        _seriesTokenURI[seriesId] = uri_;
        emit OptionTokenSeriesURIUpdated(seriesId, uri_);
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyManager {
        _mint(to, id, amount, data);
    }

    function burn(address from, uint256 id, uint256 amount) external onlyManager {
        _burn(from, id, amount);
    }

    function burnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external onlyManager {
        _burnBatch(from, ids, amounts);
    }

    function uri(uint256 id) public view override returns (string memory) {
        string memory seriesTokenURI = _seriesTokenURI[id];
        if (bytes(seriesTokenURI).length != 0) {
            return seriesTokenURI;
        }

        return _baseTokenURI;
    }
}
