// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EncumbranceUnderflow} from "src/libraries/Errors.sol";
import {EqualLendDirectAccountingHarness} from "test/utils/EqualLendDirectAccountingHarness.sol";

contract LibEqualLendDirectAccountingTest is Test {
    EqualLendDirectAccountingHarness internal harness;

    bytes32 internal constant LENDER_KEY = keccak256("direct-lender");
    bytes32 internal constant BORROWER_KEY = keccak256("direct-borrower");

    uint256 internal constant LENDER_POOL_ID = 11;
    uint256 internal constant COLLATERAL_POOL_ID = 22;
    uint256 internal constant NATIVE_POOL_ID = 33;
    uint256 internal constant BORROWER_POSITION_ID = 444;

    address internal constant ASSET_A = address(0xA11);
    address internal constant ASSET_B = address(0xB22);

    function setUp() public {
        harness = new EqualLendDirectAccountingHarness();
    }

    function test_lenderCapitalDepartureAndRestoration_areSymmetricForNativePools() external {
        harness.setPool(NATIVE_POOL_ID, address(0), 100 ether, 100 ether, 1);
        harness.setUserPrincipal(NATIVE_POOL_ID, LENDER_KEY, 100 ether);
        harness.setNativeTrackedTotal(100 ether);

        harness.departLenderCapital(LENDER_KEY, NATIVE_POOL_ID, 100 ether);

        (
            uint256 principalAfterDeparture,
            uint256 depositsAfterDeparture,
            uint256 trackedAfterDeparture,
            uint256 userCountAfterDeparture,
            ,
            ,
            ,
        ) = harness.poolState(NATIVE_POOL_ID, LENDER_KEY, BORROWER_POSITION_ID);

        assertEq(principalAfterDeparture, 0, "principal after departure");
        assertEq(depositsAfterDeparture, 0, "deposits after departure");
        assertEq(trackedAfterDeparture, 0, "tracked after departure");
        assertEq(userCountAfterDeparture, 0, "user count after departure");
        assertEq(harness.nativeTrackedTotal(), 0, "native tracked after departure");

        harness.restoreLenderCapital(LENDER_KEY, NATIVE_POOL_ID, 100 ether);

        (
            uint256 principalAfterRestore,
            uint256 depositsAfterRestore,
            uint256 trackedAfterRestore,
            uint256 userCountAfterRestore,
            ,
            ,
            ,
        ) = harness.poolState(NATIVE_POOL_ID, LENDER_KEY, BORROWER_POSITION_ID);

        assertEq(principalAfterRestore, 100 ether, "principal after restore");
        assertEq(depositsAfterRestore, 100 ether, "deposits after restore");
        assertEq(trackedAfterRestore, 100 ether, "tracked after restore");
        assertEq(userCountAfterRestore, 1, "user count after restore");
        assertEq(harness.nativeTrackedTotal(), 100 ether, "native tracked after restore");
    }

    function test_sameAssetOrigination_updatesSharedDirectAndActiveCreditDebt() external {
        _seedLenderPool(ASSET_A, 200 ether);
        harness.setPool(COLLATERAL_POOL_ID, ASSET_A, 0, 0, 0);
        harness.increaseOfferEscrow(LENDER_KEY, LENDER_POOL_ID, 80 ether);

        bool sameAsset = harness.originateFixed(
            LENDER_KEY,
            BORROWER_KEY,
            BORROWER_POSITION_ID,
            LENDER_POOL_ID,
            COLLATERAL_POOL_ID,
            ASSET_A,
            ASSET_A,
            80 ether,
            120 ether
        );

        assertTrue(sameAsset, "same asset flag");

        (
            uint256 lenderPrincipal,
            uint256 lenderDeposits,
            uint256 lenderTracked,
            uint256 lenderUserCount,
            ,
            ,
            ,
        ) = harness.poolState(LENDER_POOL_ID, LENDER_KEY, BORROWER_POSITION_ID);
        assertEq(lenderPrincipal, 120 ether, "lender principal");
        assertEq(lenderDeposits, 120 ether, "lender deposits");
        assertEq(lenderTracked, 120 ether, "lender tracked");
        assertEq(lenderUserCount, 1, "lender user count");

        (uint256 borrowerLocked, uint256 lenderEncumbered, uint256 lenderEscrow) =
            harness.encumbranceOf(LENDER_KEY, LENDER_POOL_ID);
        assertEq(borrowerLocked, 0, "lender locked");
        assertEq(lenderEncumbered, 80 ether, "lender encumbered");
        assertEq(lenderEscrow, 0, "lender escrow");

        (uint256 lockedCollateral,,) = harness.encumbranceOf(BORROWER_KEY, COLLATERAL_POOL_ID);
        assertEq(lockedCollateral, 120 ether, "borrower locked collateral");

        (
            ,
            ,
            ,
            ,
            uint256 activeCreditPrincipalTotal,
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 debtStatePrincipal
        ) = harness.poolState(COLLATERAL_POOL_ID, BORROWER_KEY, BORROWER_POSITION_ID);
        assertEq(activeCreditPrincipalTotal, 80 ether, "active credit principal");
        assertEq(userSameAssetDebt, 80 ether, "user same asset debt");
        assertEq(tokenSameAssetDebt, 80 ether, "token same asset debt");
        assertEq(debtStatePrincipal, 80 ether, "debt state principal");
        assertEq(harness.borrowedPrincipalOf(BORROWER_KEY, LENDER_POOL_ID), 80 ether, "direct borrowed principal");
        assertEq(harness.sameAssetDebtOf(BORROWER_KEY, ASSET_A), 80 ether, "direct same asset debt");
    }

    function test_crossAssetOrigination_skipsSameAssetHooks() external {
        _seedLenderPool(ASSET_A, 200 ether);
        harness.setPool(COLLATERAL_POOL_ID, ASSET_B, 0, 0, 0);
        harness.increaseOfferEscrow(LENDER_KEY, LENDER_POOL_ID, 70 ether);

        bool sameAsset = harness.originateRolling(
            LENDER_KEY,
            BORROWER_KEY,
            BORROWER_POSITION_ID,
            LENDER_POOL_ID,
            COLLATERAL_POOL_ID,
            ASSET_A,
            ASSET_B,
            70 ether,
            90 ether
        );

        assertFalse(sameAsset, "cross asset flag");
        assertEq(harness.borrowedPrincipalOf(BORROWER_KEY, LENDER_POOL_ID), 70 ether, "direct borrowed principal");
        assertEq(harness.sameAssetDebtOf(BORROWER_KEY, ASSET_B), 0, "direct same asset debt");

        (
            ,
            ,
            ,
            ,
            uint256 activeCreditPrincipalTotal,
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 debtStatePrincipal
        ) = harness.poolState(COLLATERAL_POOL_ID, BORROWER_KEY, BORROWER_POSITION_ID);
        assertEq(activeCreditPrincipalTotal, 0, "active credit total");
        assertEq(userSameAssetDebt, 0, "user same asset debt");
        assertEq(tokenSameAssetDebt, 0, "token same asset debt");
        assertEq(debtStatePrincipal, 0, "debt state principal");
    }

    function test_principalSettlement_restoresLenderAccountingAndReducesOnlyPrincipal() external {
        _seedSameAssetExposure(100 ether, 60 ether);

        bool sameAsset = harness.settleRollingPrincipal(
            LENDER_KEY,
            BORROWER_KEY,
            BORROWER_POSITION_ID,
            LENDER_POOL_ID,
            COLLATERAL_POOL_ID,
            ASSET_A,
            ASSET_A,
            40 ether,
            15 ether,
            true
        );

        assertTrue(sameAsset, "same asset settle flag");

        (
            uint256 lenderPrincipal,
            uint256 lenderDeposits,
            uint256 lenderTracked,
            ,
            ,
            ,
            ,
        ) = harness.poolState(LENDER_POOL_ID, LENDER_KEY, BORROWER_POSITION_ID);
        assertEq(lenderPrincipal, 140 ether, "restored principal");
        assertEq(lenderDeposits, 140 ether, "restored deposits");
        assertEq(lenderTracked, 140 ether, "restored tracked");

        (, uint256 lenderEncumbered,) = harness.encumbranceOf(LENDER_KEY, LENDER_POOL_ID);
        assertEq(lenderEncumbered, 60 ether, "remaining encumbered");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(BORROWER_KEY, COLLATERAL_POOL_ID);
        assertEq(borrowerLocked, 45 ether, "remaining borrower lock");
        assertEq(harness.borrowedPrincipalOf(BORROWER_KEY, LENDER_POOL_ID), 60 ether, "remaining borrowed principal");
        assertEq(harness.sameAssetDebtOf(BORROWER_KEY, ASSET_A), 60 ether, "remaining direct same asset debt");

        (
            ,
            ,
            ,
            ,
            uint256 activeCreditPrincipalTotal,
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 debtStatePrincipal
        ) = harness.poolState(COLLATERAL_POOL_ID, BORROWER_KEY, BORROWER_POSITION_ID);
        assertEq(activeCreditPrincipalTotal, 60 ether, "remaining active credit principal");
        assertEq(userSameAssetDebt, 60 ether, "remaining pool same asset debt");
        assertEq(tokenSameAssetDebt, 60 ether, "remaining token same asset debt");
        assertEq(debtStatePrincipal, 60 ether, "remaining debt state principal");
    }

    function test_terminalCleanup_clearsResidualExposureLocksAndDebtLedgers() external {
        _seedSameAssetExposure(90 ether, 45 ether);

        bool sameAsset = harness.cleanupRatio(
            LENDER_KEY,
            BORROWER_KEY,
            BORROWER_POSITION_ID,
            LENDER_POOL_ID,
            COLLATERAL_POOL_ID,
            ASSET_A,
            ASSET_A,
            90 ether,
            90 ether,
            45 ether
        );

        assertTrue(sameAsset, "same asset cleanup flag");

        (uint256 borrowerLocked,,) = harness.encumbranceOf(BORROWER_KEY, COLLATERAL_POOL_ID);
        (, uint256 lenderEncumbered, uint256 lenderEscrow) = harness.encumbranceOf(LENDER_KEY, LENDER_POOL_ID);
        assertEq(borrowerLocked, 0, "borrower lock cleared");
        assertEq(lenderEncumbered, 0, "lender exposure cleared");
        assertEq(lenderEscrow, 0, "lender escrow cleared");
        assertEq(harness.borrowedPrincipalOf(BORROWER_KEY, LENDER_POOL_ID), 0, "borrowed principal cleared");
        assertEq(harness.sameAssetDebtOf(BORROWER_KEY, ASSET_A), 0, "direct same asset debt cleared");

        (
            ,
            ,
            ,
            ,
            uint256 activeCreditPrincipalTotal,
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 debtStatePrincipal
        ) = harness.poolState(COLLATERAL_POOL_ID, BORROWER_KEY, BORROWER_POSITION_ID);
        assertEq(activeCreditPrincipalTotal, 0, "active credit principal cleared");
        assertEq(userSameAssetDebt, 0, "pool same asset debt cleared");
        assertEq(tokenSameAssetDebt, 0, "token same asset debt cleared");
        assertEq(debtStatePrincipal, 0, "debt state cleared");
    }

    function test_encumbranceBucketWrappers_useUnifiedPrimitiveAndProtectUnderflow() external {
        harness.increaseOfferEscrow(LENDER_KEY, LENDER_POOL_ID, 10 ether);
        harness.increaseLiveExposure(LENDER_KEY, LENDER_POOL_ID, 20 ether);
        harness.increaseLockedCapital(BORROWER_KEY, COLLATERAL_POOL_ID, 30 ether);

        (uint256 locked, uint256 encumbered, uint256 escrow) = harness.encumbranceOf(LENDER_KEY, LENDER_POOL_ID);
        assertEq(locked, 0, "lender locked bucket");
        assertEq(encumbered, 20 ether, "lender encumbered bucket");
        assertEq(escrow, 10 ether, "lender escrow bucket");

        (locked,,) = harness.encumbranceOf(BORROWER_KEY, COLLATERAL_POOL_ID);
        assertEq(locked, 30 ether, "borrower locked bucket");

        vm.expectRevert(abi.encodeWithSelector(EncumbranceUnderflow.selector, 11 ether, 10 ether));
        harness.decreaseOfferEscrow(LENDER_KEY, LENDER_POOL_ID, 11 ether);
    }

    function _seedLenderPool(address underlying, uint256 amount) internal {
        harness.setPool(LENDER_POOL_ID, underlying, amount, amount, 1);
        harness.setUserPrincipal(LENDER_POOL_ID, LENDER_KEY, amount);
    }

    function _seedSameAssetExposure(uint256 principal, uint256 collateralLock) internal {
        _seedLenderPool(ASSET_A, 200 ether);
        harness.setPool(COLLATERAL_POOL_ID, ASSET_A, 0, 0, 0);
        harness.increaseOfferEscrow(LENDER_KEY, LENDER_POOL_ID, principal);
        harness.originateFixed(
            LENDER_KEY,
            BORROWER_KEY,
            BORROWER_POSITION_ID,
            LENDER_POOL_ID,
            COLLATERAL_POOL_ID,
            ASSET_A,
            ASSET_A,
            principal,
            collateralLock
        );
    }
}
