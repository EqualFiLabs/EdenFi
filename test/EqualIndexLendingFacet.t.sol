// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibEqualIndexLending} from "src/libraries/LibEqualIndexLending.sol";
import {
    InsufficientPoolLiquidity,
    InsufficientUnencumberedPrincipal,
    InvalidArrayLength,
    InvalidParameterRange,
    PoolMembershipRequired,
    Unauthorized,
    UnexpectedMsgValue
} from "src/libraries/Errors.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract EqualIndexLendingFacetTest is LaunchFixture {
    struct BorrowCtx {
        uint256 indexId;
        uint256 positionId;
        bytes32 positionKey;
        uint256 indexPoolId;
        address token;
    }

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_configureLending_onlyTimelock() public {
        BorrowCtx memory ctx = _readyBorrowContext();

        vm.expectRevert(Unauthorized.selector);
        EqualIndexLendingFacet(diamond).configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        LibEqualIndexLending.LendingConfig memory cfg = EqualIndexLendingFacet(diamond).getLendingConfig(ctx.indexId);
        assertEq(cfg.ltvBps, 10_000);
        assertEq(uint256(cfg.minDuration), 1 days);
        assertEq(uint256(cfg.maxDuration), 30 days);
    }

    function test_borrowAndRepay_fromPosition() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 1e18, 7 days);

        LibEqualIndexLending.IndexLoan memory loan = EqualIndexLendingFacet(diamond).getLoan(loanId);
        assertEq(loan.positionKey, ctx.positionKey);
        assertEq(loan.indexId, ctx.indexId);
        assertEq(loan.collateralUnits, 1e18);
        assertEq(loan.ltvBps, 10_000);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(ctx.indexId, address(eve)), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(ctx.indexId, address(alt)), 2e18);
        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(ctx.indexId), 1e18);
        assertEq(testSupport.indexEncumberedOf(ctx.positionKey, ctx.indexPoolId), 1e18);
        assertEq(testSupport.indexEncumberedForIndex(ctx.positionKey, ctx.indexPoolId, ctx.indexId), 1e18);
        assertEq(testSupport.getPoolView(ctx.indexPoolId).indexEncumberedTotal, 1e18);

        vm.startPrank(alice);
        eve.approve(diamond, 1e18);
        alt.approve(diamond, 2e18);
        EqualIndexLendingFacet(diamond).repayFromPosition(ctx.positionId, loanId);
        vm.stopPrank();

        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(ctx.indexId, address(eve)), 0);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(ctx.indexId, address(alt)), 0);
        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(ctx.indexId), 0);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
        assertEq(testSupport.indexEncumberedOf(ctx.positionKey, ctx.indexPoolId), 0);
        assertEq(testSupport.indexEncumberedForIndex(ctx.positionKey, ctx.indexPoolId, ctx.indexId), 0);
        assertEq(testSupport.getPoolView(ctx.indexPoolId).indexEncumberedTotal, 0);
    }

    function test_extendFromPosition_updatesMaturity_andChargesFlatFee() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);
        _configureSingleTierFee(ctx.indexId, 1e18, 0.02 ether);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        uint256 loanId =
            EqualIndexLendingFacet(diamond).borrowFromPosition{value: 0.02 ether}(ctx.positionId, ctx.indexId, 1e18, 7 days);
        uint40 initialMaturity = EqualIndexLendingFacet(diamond).getLoan(loanId).maturity;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibEqualIndexLending.FlatFeePaymentMismatch.selector, 0.02 ether, 0)
        );
        EqualIndexLendingFacet(diamond).extendFromPosition(ctx.positionId, loanId, 3 days);

        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        EqualIndexLendingFacet(diamond).extendFromPosition{value: 0.02 ether}(ctx.positionId, loanId, 3 days);

        LibEqualIndexLending.IndexLoan memory extendedLoan = EqualIndexLendingFacet(diamond).getLoan(loanId);
        assertEq(uint256(extendedLoan.maturity), uint256(initialMaturity) + 3 days);
        assertEq(treasury.balance - treasuryBefore, 0.02 ether);
    }

    function test_borrow_revertsWhenDurationBelowMinimum() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibEqualIndexLending.InvalidDuration.selector, uint40(12 hours), uint40(1 days), uint40(30 days))
        );
        EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 1e18, 12 hours);
    }

    function test_borrow_revertsWhenDurationAboveMaximum() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibEqualIndexLending.InvalidDuration.selector, uint40(31 days), uint40(1 days), uint40(30 days))
        );
        EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 1e18, 31 days);
    }

    function test_borrow_revertsWithoutMintedIndexCollateralUnits() public {
        BorrowCtx memory ctx = _readyDepositedContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, ctx.positionKey, ctx.indexPoolId));
        EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 1e18, 7 days);
    }

    function test_borrow_revertsWhenCollateralUnitsExceedAvailableIndexPrincipal() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientUnencumberedPrincipal.selector, 3e18, 2e18));
        EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 3e18, 7 days);
    }

    function test_borrow_revertsWhenVaultLiquidityIsMutatedBelowQuote() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        testSupport.setVaultBalance(ctx.indexId, address(alt), 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolLiquidity.selector, 2e18, 1e18));
        EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 1e18, 7 days);
    }

    function test_flatFeeBorrow_revertsForWrongFeeValue() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);
        _configureSingleTierFee(ctx.indexId, 1e18, 0.02 ether);

        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibEqualIndexLending.FlatFeePaymentMismatch.selector, 0.02 ether, 0.03 ether)
        );
        EqualIndexLendingFacet(diamond).borrowFromPosition{value: 0.03 ether}(ctx.positionId, ctx.indexId, 1e18, 7 days);
    }

    function test_recoverExpired_clearsLoanAndCollateral() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        uint256 principalBefore = testSupport.principalOf(ctx.indexPoolId, ctx.positionKey);
        uint256 trackedBefore = testSupport.getPoolView(ctx.indexPoolId).trackedBalance;
        uint256 depositsBefore = testSupport.getPoolView(ctx.indexPoolId).totalDeposits;

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 1e18, 1 days);
        assertEq(testSupport.indexEncumberedOf(ctx.positionKey, ctx.indexPoolId), 1e18);
        assertEq(testSupport.indexEncumberedForIndex(ctx.positionKey, ctx.indexPoolId, ctx.indexId), 1e18);
        assertEq(testSupport.getPoolView(ctx.indexPoolId).indexEncumberedTotal, 1e18);

        vm.warp(block.timestamp + 2 days);
        EqualIndexLendingFacet(diamond).recoverExpiredIndexLoan(loanId);

        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(ctx.indexId, address(eve)), 0);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(ctx.indexId, address(alt)), 0);
        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(ctx.indexId), 0);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(ctx.indexId).totalUnits, 1e18);
        assertEq(testSupport.principalOf(ctx.indexPoolId, ctx.positionKey), 1e18);
        assertEq(testSupport.principalOf(ctx.indexPoolId, ctx.positionKey), principalBefore - 1e18);
        assertEq(testSupport.getPoolView(ctx.indexPoolId).trackedBalance, trackedBefore - 1e18);
        assertEq(testSupport.getPoolView(ctx.indexPoolId).totalDeposits, depositsBefore - 1e18);
        assertEq(testSupport.indexEncumberedOf(ctx.positionKey, ctx.indexPoolId), 0);
        assertEq(testSupport.indexEncumberedForIndex(ctx.positionKey, ctx.indexPoolId, ctx.indexId), 0);
        assertEq(testSupport.getPoolView(ctx.indexPoolId).indexEncumberedTotal, 0);
        assertEq(ERC20(ctx.token).totalSupply(), 1e18);
    }

    function test_configureBorrowFeeTiers_and_quoteViews() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        uint256[] memory minUnits = new uint256[](2);
        minUnits[0] = 1e18;
        minUnits[1] = 2e18;
        uint256[] memory flatFees = new uint256[](2);
        flatFees[0] = 0.01 ether;
        flatFees[1] = 0.03 ether;

        _configureBorrowFeeTiers(ctx.indexId, minUnits, flatFees);

        (uint256[] memory gotMin, uint256[] memory gotFees) = EqualIndexLendingFacet(diamond).getBorrowFeeTiers(ctx.indexId);
        assertEq(gotMin.length, 2);
        assertEq(gotFees.length, 2);
        assertEq(gotMin[0], 1e18);
        assertEq(gotMin[1], 2e18);
        assertEq(gotFees[0], 0.01 ether);
        assertEq(gotFees[1], 0.03 ether);
        assertEq(EqualIndexLendingFacet(diamond).maxBorrowable(ctx.indexId, address(eve), 1e18), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).maxBorrowable(ctx.indexId, address(alt), 1e18), 2e18);
        assertEq(EqualIndexLendingFacet(diamond).quoteBorrowFee(ctx.indexId, 1e18), 0.01 ether);
        assertEq(EqualIndexLendingFacet(diamond).quoteBorrowFee(ctx.indexId, 2e18), 0.03 ether);

        (address[] memory assets, uint256[] memory principals) =
            EqualIndexLendingFacet(diamond).quoteBorrowBasket(ctx.indexId, 1e18);
        assertEq(assets.length, 2);
        assertEq(principals.length, 2);
        assertEq(assets[0], address(eve));
        assertEq(assets[1], address(alt));
        assertEq(principals[0], 1e18);
        assertEq(principals[1], 2e18);
    }

    function test_flatFeeBorrow_requiresExactMsgValue_andPaysTreasury() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);
        _configureSingleTierFee(ctx.indexId, 1e18, 0.02 ether);

        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibEqualIndexLending.FlatFeePaymentMismatch.selector, 0.02 ether, 0)
        );
        EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 1e18, 7 days);

        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        EqualIndexLendingFacet(diamond).borrowFromPosition{value: 0.02 ether}(ctx.positionId, ctx.indexId, 1e18, 7 days);
        assertEq(treasury.balance - treasuryBefore, 0.02 ether);
    }

    function test_repay_revertsOnUnexpectedMsgValue_forExactOnlyRepayFlow() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(ctx.positionId, ctx.indexId, 1e18, 7 days);

        vm.startPrank(alice);
        eve.approve(diamond, 1e18);
        alt.approve(diamond, 2e18);
        vm.stopPrank();
        vm.deal(alice, 1);

        (bool ok, bytes memory revertData) = _callAsValue(
            alice,
            1,
            abi.encodeWithSelector(EqualIndexLendingFacet.repayFromPosition.selector, ctx.positionId, loanId)
        );
        assertTrue(!ok);
        assertEq(bytes32(_revertSelector(revertData)), bytes32(UnexpectedMsgValue.selector));
    }

    function test_quoteHelpers_matchLiveExecution() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        _configureLending(ctx.indexId, 10_000, 1 days, 30 days);
        _configureSingleTierFee(ctx.indexId, 1e18, 0.02 ether);
        vm.deal(alice, 1 ether);

        uint256 eveMaxBorrowable = EqualIndexLendingFacet(diamond).maxBorrowable(ctx.indexId, address(eve), 1e18);
        uint256 altMaxBorrowable = EqualIndexLendingFacet(diamond).maxBorrowable(ctx.indexId, address(alt), 1e18);
        uint256 quotedFee = EqualIndexLendingFacet(diamond).quoteBorrowFee(ctx.indexId, 1e18);
        (address[] memory assets, uint256[] memory principals) =
            EqualIndexLendingFacet(diamond).quoteBorrowBasket(ctx.indexId, 1e18);

        uint256 eveBefore = eve.balanceOf(alice);
        uint256 altBefore = alt.balanceOf(alice);
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        EqualIndexLendingFacet(diamond).borrowFromPosition{value: quotedFee}(ctx.positionId, ctx.indexId, 1e18, 7 days);

        assertEq(eveMaxBorrowable, principals[0]);
        assertEq(altMaxBorrowable, principals[1]);
        assertEq(quotedFee, 0.02 ether);
        assertEq(assets[0], address(eve));
        assertEq(assets[1], address(alt));
        assertEq(eve.balanceOf(alice) - eveBefore, principals[0]);
        assertEq(alt.balanceOf(alice) - altBefore, principals[1]);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(ctx.indexId, address(eve)), principals[0]);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(ctx.indexId, address(alt)), principals[1]);
        assertEq(treasury.balance - treasuryBefore, quotedFee);
    }

    function test_configureBorrowFeeTiers_revertsOnEmptyMismatchAndOrdering() public {
        BorrowCtx memory ctx = _readyBorrowContext();

        uint256[] memory empty;
        _scheduleTimelockRevert(
            diamond,
            abi.encodeWithSelector(EqualIndexLendingFacet.configureBorrowFeeTiers.selector, ctx.indexId, empty, empty),
            abi.encodeWithSelector(InvalidArrayLength.selector)
        );

        uint256[] memory minUnits = new uint256[](2);
        minUnits[0] = 2e18;
        minUnits[1] = 1e18;
        uint256[] memory flatFees = new uint256[](2);
        flatFees[0] = 0.01 ether;
        flatFees[1] = 0.02 ether;

        _scheduleTimelockRevert(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureBorrowFeeTiers.selector, ctx.indexId, minUnits, flatFees
            ),
            abi.encodeWithSelector(InvalidParameterRange.selector, "tierOrder")
        );
    }

    function _configureLending(uint256 indexId, uint16 ltvBps, uint40 minDuration, uint40 maxDuration) internal {
        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, ltvBps, minDuration, maxDuration
            )
        );
    }

    function _configureSingleTierFee(uint256 indexId, uint256 minCollateralUnits, uint256 flatFeeNative) internal {
        uint256[] memory minUnits = new uint256[](1);
        minUnits[0] = minCollateralUnits;
        uint256[] memory flatFees = new uint256[](1);
        flatFees[0] = flatFeeNative;
        _configureBorrowFeeTiers(indexId, minUnits, flatFees);
    }

    function _configureBorrowFeeTiers(uint256 indexId, uint256[] memory minUnits, uint256[] memory flatFees) internal {
        _timelockCall(
            diamond,
            abi.encodeWithSelector(EqualIndexLendingFacet.configureBorrowFeeTiers.selector, indexId, minUnits, flatFees)
        );
    }

    function _scheduleTimelockRevert(address target, bytes memory data, bytes memory expectedRevert) internal {
        bytes32 salt = keccak256(abi.encodePacked("equalfi-lending-revert", block.timestamp, data));
        timelockController.schedule(target, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(expectedRevert);
        timelockController.execute(target, 0, data, bytes32(0), salt);
    }

    function _callAsValue(address caller, uint256 value, bytes memory data) internal returns (bool ok, bytes memory result) {
        vm.prank(caller);
        (ok, result) = diamond.call{value: value}(data);
    }

    function _revertSelector(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) {
            return bytes4(0);
        }
        assembly {
            selector := mload(add(revertData, 0x20))
        }
    }

    function _readyBorrowContext() internal returns (BorrowCtx memory ctx) {
        ctx = _readyDepositedContext();

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(ctx.positionId, ctx.indexId, 2e18);

        assertEq(testSupport.principalOf(ctx.indexPoolId, ctx.positionKey), 2e18);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(ctx.indexId).totalUnits, 2e18);
    }

    function _readyDepositedContext() internal returns (BorrowCtx memory ctx) {
        eve.mint(alice, 1_000e18);
        alt.mint(alice, 1_000e18);

        (ctx.indexId, ctx.token) = _createIndexThroughTimelock(_dualAssetIndexParams("IDX", "IDX"));
        ctx.indexPoolId = EqualIndexAdminFacetV3(diamond).getIndexPoolId(ctx.indexId);

        ctx.positionId = _mintPosition(alice, 1);
        ctx.positionKey = positionNft.getPositionKey(ctx.positionId);

        vm.startPrank(alice);
        eve.approve(diamond, 1_000e18);
        alt.approve(diamond, 1_000e18);
        PositionManagementFacet(diamond).depositToPosition(ctx.positionId, 1, 1_000e18, 1_000e18);
        PositionManagementFacet(diamond).depositToPosition(ctx.positionId, 2, 1_000e18, 1_000e18);
        vm.stopPrank();

        assertEq(testSupport.principalOf(1, ctx.positionKey), 1_000e18);
        assertEq(testSupport.principalOf(2, ctx.positionKey), 1_000e18);
    }

    function _dualAssetIndexParams(string memory name_, string memory symbol_)
        internal
        view
        returns (EqualIndexBaseV3.CreateIndexParams memory p)
    {
        p.name = name_;
        p.symbol = symbol_;
        p.assets = new address[](2);
        p.assets[0] = address(eve);
        p.assets[1] = address(alt);
        p.bundleAmounts = new uint256[](2);
        p.bundleAmounts[0] = 1e18;
        p.bundleAmounts[1] = 2e18;
        p.mintFeeBps = new uint16[](2);
        p.burnFeeBps = new uint16[](2);
        p.flashFeeBps = 0;
    }
}
