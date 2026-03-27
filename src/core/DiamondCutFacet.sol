// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibAccess} from "../libraries/LibAccess.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

contract DiamondCutFacet is IDiamondCut {
    function diamondCut(FacetCut[] calldata diamondCut_, address init_, bytes calldata calldata_) external override {
        if (msg.sender != address(this)) {
            LibAccess.enforceTimelockOrOwnerIfUnset();
        }
        LibDiamond.addReplaceRemoveFacetSelectors(diamondCut_, init_, calldata_);
    }
}
