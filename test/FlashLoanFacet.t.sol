// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlashLoanFacet} from "src/equallend/FlashLoanFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {IFlashLoanReceiver} from "src/interfaces/IFlashLoanReceiver.sol";
import {IEqualIndexFlashReceiver} from "src/interfaces/IEqualIndexFlashReceiver.sol";
import {FlashLoanUnderpaid} from "src/libraries/Errors.sol";

import {StEVELaunchFixture} from "test/utils/StEVELaunchFixture.t.sol";

contract PoolFlashLoanReceiverMock is IFlashLoanReceiver {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("IFlashLoanReceiver.onFlashLoan");

    function onFlashLoan(address, address token, uint256, bytes calldata data) external returns (bytes32) {
        uint256 repayAmount = abi.decode(data, (uint256));
        IERC20(token).approve(msg.sender, repayAmount);
        return CALLBACK_SUCCESS;
    }
}

contract IndexFlashLoanReceiverMock is IEqualIndexFlashReceiver {
    function onEqualIndexFlashLoan(
        uint256,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata data
    ) external {
        bool repayFees = abi.decode(data, (bool));
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 repayAmount = amounts[i];
            if (repayFees) {
                repayAmount += feeAmounts[i];
            }
            IERC20(assets[i]).transfer(msg.sender, repayAmount);
        }
    }
}

contract FlashLoanFacetTest is StEVELaunchFixture {
    struct IndexFlashExpectation {
        uint256 eveFee;
        uint256 altFee;
        uint256 evePotFee;
        uint256 altPotFee;
        uint256 eveVaultBefore;
        uint256 altVaultBefore;
        uint256 evePotBefore;
        uint256 altPotBefore;
    }

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function test_PoolFlashLoan_PullsRepaymentAndRoutesFee() public {
        uint256 positionId = _mintPosition(alice, 1);
        eve.mint(alice, 100e18);

        vm.startPrank(alice);
        eve.approve(diamond, 100e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 100e18, 100e18);
        vm.stopPrank();

        uint256 amount = 10e18;
        uint256 repayment = FlashLoanFacet(diamond).previewFlashLoanRepayment(1, amount);
        uint256 fee = repayment - amount;
        uint256 treasuryShare = fee / 10;

        PoolFlashLoanReceiverMock receiver = new PoolFlashLoanReceiverMock();
        eve.mint(address(receiver), fee);

        uint256 trackedBefore = PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance;
        uint256 treasuryBefore = eve.balanceOf(treasury);

        vm.prank(bob);
        FlashLoanFacet(diamond).flashLoan(1, address(receiver), amount, abi.encode(repayment), repayment);

        uint256 trackedAfter = PoolManagementFacet(diamond).getPoolInfoView(1).trackedBalance;
        assertEq(trackedAfter, trackedBefore + fee - treasuryShare);
        assertEq(eve.balanceOf(treasury), treasuryBefore + treasuryShare);
        assertGt(PositionManagementFacet(diamond).previewPositionYield(positionId, 1), 0);
        assertEq(eve.balanceOf(address(receiver)), 0);
    }

    function test_PoolFlashLoan_RevertsWhenRepaymentCapTooLow() public {
        uint256 positionId = _mintPosition(alice, 1);
        eve.mint(alice, 50e18);

        vm.startPrank(alice);
        eve.approve(diamond, 50e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 50e18, 50e18);
        vm.stopPrank();

        PoolFlashLoanReceiverMock receiver = new PoolFlashLoanReceiverMock();

        vm.prank(bob);
        vm.expectRevert();
        FlashLoanFacet(diamond).flashLoan(1, address(receiver), 10e18, abi.encode(10e18), 10e18);
    }

    function test_IndexFlashLoan_RestoresVaultsAndSplitsFees() public {
        uint256 indexId = _seedDualIndex(true);
        IndexFlashExpectation memory expected = _snapshotDualIndexFlash(indexId);

        IndexFlashLoanReceiverMock receiver = new IndexFlashLoanReceiverMock();
        eve.mint(address(receiver), expected.eveFee);
        alt.mint(address(receiver), expected.altFee);

        vm.prank(carol);
        EqualIndexActionsFacetV3(diamond).flashLoan(indexId, 5e18, address(receiver), abi.encode(true));

        assertEq(EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(eve)), expected.eveVaultBefore);
        assertEq(EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(alt)), expected.altVaultBefore);
        assertEq(EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(eve)), expected.evePotBefore + expected.evePotFee);
        assertEq(EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(alt)), expected.altPotBefore + expected.altPotFee);
        assertEq(eve.balanceOf(address(receiver)), 0);
        assertEq(alt.balanceOf(address(receiver)), 0);
    }

    function test_IndexFlashLoan_StillWorksAfterBootstrappingSingletonEden() public {
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(alt)));

        uint256 indexId = _seedDualIndex(true);
        address indexToken = EqualIndexAdminFacetV3(diamond).getIndex(indexId).token;
        assertTrue(indexToken != steveToken);

        IndexFlashExpectation memory expected = _snapshotDualIndexFlash(indexId);
        IndexFlashLoanReceiverMock receiver = new IndexFlashLoanReceiverMock();
        eve.mint(address(receiver), expected.eveFee);
        alt.mint(address(receiver), expected.altFee);

        vm.prank(carol);
        EqualIndexActionsFacetV3(diamond).flashLoan(indexId, 5e18, address(receiver), abi.encode(true));

        assertEq(EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(eve)), expected.eveVaultBefore);
        assertEq(EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(alt)), expected.altVaultBefore);
        assertEq(EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(eve)), expected.evePotBefore + expected.evePotFee);
        assertEq(EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(alt)), expected.altPotBefore + expected.altPotFee);
        assertEq(eve.balanceOf(address(receiver)), 0);
        assertEq(alt.balanceOf(address(receiver)), 0);
    }

    function test_IndexFlashLoan_RevertsWhenFeesAreNotReturned() public {
        uint256 indexId = _seedDualIndex(false);
        IndexFlashExpectation memory expected = _snapshotDualIndexFlash(indexId);
        uint256 eveBalanceBefore = eve.balanceOf(diamond);

        IndexFlashLoanReceiverMock receiver = new IndexFlashLoanReceiverMock();

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                FlashLoanUnderpaid.selector, indexId, address(eve), eveBalanceBefore + expected.eveFee, eveBalanceBefore
            )
        );
        EqualIndexActionsFacetV3(diamond).flashLoan(indexId, 5e18, address(receiver), abi.encode(false));
    }

    function _dualAssetIndexParams() internal view returns (EqualIndexBaseV3.CreateIndexParams memory p) {
        p.name = "Dual Index";
        p.symbol = "DIDX";
        p.assets = new address[](2);
        p.assets[0] = address(eve);
        p.assets[1] = address(alt);
        p.bundleAmounts = new uint256[](2);
        p.bundleAmounts[0] = 1e18;
        p.bundleAmounts[1] = 2e18;
        p.mintFeeBps = new uint16[](2);
        p.burnFeeBps = new uint16[](2);
        p.flashFeeBps = 50;
    }

    function _seedDualIndex(bool fundPools) internal returns (uint256 indexId) {
        if (fundPools) {
            uint256 evePositionId = _mintPosition(alice, 1);
            uint256 altPositionId = _mintPosition(alice, 2);

            eve.mint(alice, 200e18);
            alt.mint(alice, 200e18);

            vm.startPrank(alice);
            eve.approve(diamond, 200e18);
            PositionManagementFacet(diamond).depositToPosition(evePositionId, 1, 100e18, 100e18);
            alt.approve(diamond, 200e18);
            PositionManagementFacet(diamond).depositToPosition(altPositionId, 2, 100e18, 100e18);
            vm.stopPrank();
        }

        (indexId,) = _createIndexThroughTimelock(_dualAssetIndexParams());

        eve.mint(bob, 20e18);
        alt.mint(bob, 40e18);

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        alt.approve(diamond, 40e18);
        uint256[] memory maxInputs = new uint256[](2);
        maxInputs[0] = 10e18;
        maxInputs[1] = 20e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();
    }

    function _snapshotDualIndexFlash(uint256 indexId) internal view returns (IndexFlashExpectation memory expected) {
        expected.eveFee = (5e18 * 50) / 10_000;
        expected.altFee = (10e18 * 50) / 10_000;
        expected.evePotFee = expected.eveFee - ((expected.eveFee * 1000) / 10_000);
        expected.altPotFee = expected.altFee - ((expected.altFee * 1000) / 10_000);
        expected.eveVaultBefore = EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(eve));
        expected.altVaultBefore = EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(alt));
        expected.evePotBefore = EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(eve));
        expected.altPotBefore = EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(alt));
    }
}
