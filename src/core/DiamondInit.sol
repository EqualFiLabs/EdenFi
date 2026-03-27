// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibTimelock} from "../libraries/LibTimelock.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";

contract DiamondInit {
    function init(address timelock_, address treasury_, address positionNFTContract_) external {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        if (timelock_ != address(0)) {
            LibTimelock.validateFixedDelayController(timelock_);
        }
        app.timelock = timelock_;
        app.treasury = treasury_;

        if (positionNFTContract_ != address(0)) {
            LibPositionNFT.PositionNFTStorage storage nftStorage = LibPositionNFT.s();
            nftStorage.positionNFTContract = positionNFTContract_;
            nftStorage.nftModeEnabled = true;

            PositionNFT(positionNFTContract_).setMinter(address(this));
            PositionNFT(positionNFTContract_).setDiamond(address(this));
        }
    }
}
