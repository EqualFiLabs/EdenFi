// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibSelfSecuredCreditViews} from "src/libraries/LibSelfSecuredCreditViews.sol";
import {Types} from "src/libraries/Types.sol";

/// @notice Read-only SSC-native view surface for line state and lifecycle previews.
contract SelfSecuredCreditViewFacet {
    function getSscLine(uint256 tokenId, uint256 pid) external view returns (Types.SscLineView memory view_) {
        view_ = LibSelfSecuredCreditViews.lineView(tokenId, pid);
    }

    function previewSscDraw(uint256 tokenId, uint256 pid, uint256 amount)
        external
        view
        returns (Types.SscDrawPreview memory preview)
    {
        preview = LibSelfSecuredCreditViews.drawPreview(tokenId, pid, amount);
    }

    function previewSscRepay(uint256 tokenId, uint256 pid, uint256 amount)
        external
        view
        returns (Types.SscRepayPreview memory preview)
    {
        preview = LibSelfSecuredCreditViews.repayPreview(tokenId, pid, amount);
    }

    function previewSscService(uint256 tokenId, uint256 pid)
        external
        view
        returns (Types.SscServicePreview memory preview)
    {
        preview = LibSelfSecuredCreditViews.servicePreview(tokenId, pid);
    }

    function previewSscTerminalSettlement(uint256 tokenId, uint256 pid)
        external
        view
        returns (Types.SscTerminalSettlementPreview memory preview)
    {
        preview = LibSelfSecuredCreditViews.terminalSettlementPreview(tokenId, pid);
    }

    function claimableSscFeeYield(uint256 tokenId, uint256 pid) external view returns (uint256) {
        return LibSelfSecuredCreditViews.claimableFeeYield(tokenId, pid);
    }

    function claimableSscAciYield(uint256 tokenId, uint256 pid) external view returns (uint256) {
        return LibSelfSecuredCreditViews.claimableAciYield(tokenId, pid);
    }

    function sscAciMode(uint256 tokenId, uint256 pid) external view returns (Types.SscAciMode) {
        return LibSelfSecuredCreditViews.aciMode(tokenId, pid);
    }

    function pendingSscSelfPayEffect(uint256 tokenId, uint256 pid) external view returns (uint256) {
        return LibSelfSecuredCreditViews.pendingSelfPayEffect(tokenId, pid);
    }

    function maxAdditionalSscDraw(uint256 tokenId, uint256 pid) external view returns (uint256) {
        return LibSelfSecuredCreditViews.maxAdditionalDraw(tokenId, pid);
    }
}
