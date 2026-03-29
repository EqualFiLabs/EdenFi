// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILegacyEdenPositionFacet {
    function mintBasketFromPosition(uint256 positionId, uint256 basketId, uint256 units)
        external
        returns (uint256 minted);

    function burnBasketFromPosition(uint256 positionId, uint256 basketId, uint256 units)
        external
        returns (uint256[] memory assetsOut);
}
