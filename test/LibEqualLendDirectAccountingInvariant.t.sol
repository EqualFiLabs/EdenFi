// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {EqualLendDirectAccountingHarness} from "test/utils/EqualLendDirectAccountingHarness.sol";

contract EqualLendDirectAccountingInvariantHandler is Test {
    EqualLendDirectAccountingHarness public immutable harness;
    uint256 public constant INITIAL_LENDER_CAPITAL = 1_000 ether;

    bytes32 public constant FIXED_LENDER_KEY = keccak256("fixed-lender");
    bytes32 public constant FIXED_BORROWER_KEY = keccak256("fixed-borrower");
    bytes32 public constant ROLLING_LENDER_KEY = keccak256("rolling-lender");
    bytes32 public constant ROLLING_BORROWER_KEY = keccak256("rolling-borrower");
    bytes32 public constant RATIO_LENDER_KEY = keccak256("ratio-lender");
    bytes32 public constant RATIO_BORROWER_KEY = keccak256("ratio-borrower");

    uint256 public constant FIXED_LENDER_POOL = 101;
    uint256 public constant FIXED_COLLATERAL_POOL = 201;
    uint256 public constant ROLLING_LENDER_POOL = 102;
    uint256 public constant ROLLING_COLLATERAL_POOL = 202;
    uint256 public constant RATIO_LENDER_POOL = 103;
    uint256 public constant RATIO_COLLATERAL_POOL = 203;

    uint256 public constant FIXED_BORROWER_POSITION_ID = 1_001;
    uint256 public constant ROLLING_BORROWER_POSITION_ID = 1_002;
    uint256 public constant RATIO_BORROWER_POSITION_ID = 1_003;

    address public constant SAME_ASSET = address(0x1111);
    address public constant BORROW_ASSET = address(0x2222);
    address public constant COLLATERAL_ASSET = address(0x3333);

    bool public sameAssetMode;

    constructor(EqualLendDirectAccountingHarness harness_) {
        harness = harness_;
    }

    function seedInitialState() external {
        _seedVariant(FIXED_LENDER_POOL, FIXED_LENDER_KEY, FIXED_COLLATERAL_POOL);
        _seedVariant(ROLLING_LENDER_POOL, ROLLING_LENDER_KEY, ROLLING_COLLATERAL_POOL);
        _seedVariant(RATIO_LENDER_POOL, RATIO_LENDER_KEY, RATIO_COLLATERAL_POOL);
    }

    function mirrorOriginate(uint256 principalSeed, uint256 collateralSeed, bool sameAsset) external {
        uint256 outstanding = harness.borrowedPrincipalOf(FIXED_BORROWER_KEY, FIXED_LENDER_POOL);
        if (outstanding != 0 && sameAsset != sameAssetMode) return;

        uint256 maxPrincipal = _availablePrincipal(FIXED_LENDER_POOL, FIXED_LENDER_KEY);
        if (maxPrincipal == 0) return;

        uint256 principal = _boundAmount(principalSeed, maxPrincipal);
        uint256 collateralToLock = _boundAmount(collateralSeed, principal * 2);
        if (collateralToLock == 0) {
            collateralToLock = principal;
        }

        address borrowAsset = sameAsset ? SAME_ASSET : BORROW_ASSET;
        address collateralAsset = sameAsset ? SAME_ASSET : COLLATERAL_ASSET;
        sameAssetMode = sameAsset;

        harness.increaseOfferEscrow(FIXED_LENDER_KEY, FIXED_LENDER_POOL, principal);
        harness.increaseOfferEscrow(ROLLING_LENDER_KEY, ROLLING_LENDER_POOL, principal);
        harness.increaseOfferEscrow(RATIO_LENDER_KEY, RATIO_LENDER_POOL, principal);

        harness.originateFixed(
            FIXED_LENDER_KEY,
            FIXED_BORROWER_KEY,
            FIXED_BORROWER_POSITION_ID,
            FIXED_LENDER_POOL,
            FIXED_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            principal,
            collateralToLock
        );
        harness.originateRolling(
            ROLLING_LENDER_KEY,
            ROLLING_BORROWER_KEY,
            ROLLING_BORROWER_POSITION_ID,
            ROLLING_LENDER_POOL,
            ROLLING_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            principal,
            collateralToLock
        );
        harness.originateRatio(
            RATIO_LENDER_KEY,
            RATIO_BORROWER_KEY,
            RATIO_BORROWER_POSITION_ID,
            RATIO_LENDER_POOL,
            RATIO_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            principal,
            collateralToLock
        );
    }

    function mirrorRepay(uint256 principalSeed, uint256 collateralSeed) external {
        uint256 outstanding = harness.borrowedPrincipalOf(FIXED_BORROWER_KEY, FIXED_LENDER_POOL);
        if (outstanding == 0) return;

        uint256 principal = _boundAmount(principalSeed, outstanding);
        uint256 locked = _lockedCollateral(FIXED_BORROWER_KEY, FIXED_COLLATERAL_POOL);
        uint256 collateralDelta = locked == 0 ? 0 : _boundAmount(collateralSeed, locked);
        bool releaseLockedCollateral = collateralDelta != 0;

        address borrowAsset = sameAssetMode ? SAME_ASSET : BORROW_ASSET;
        address collateralAsset = sameAssetMode ? SAME_ASSET : COLLATERAL_ASSET;

        harness.settleFixedPrincipal(
            FIXED_LENDER_KEY,
            FIXED_BORROWER_KEY,
            FIXED_BORROWER_POSITION_ID,
            FIXED_LENDER_POOL,
            FIXED_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            principal,
            collateralDelta,
            releaseLockedCollateral
        );
        harness.settleRollingPrincipal(
            ROLLING_LENDER_KEY,
            ROLLING_BORROWER_KEY,
            ROLLING_BORROWER_POSITION_ID,
            ROLLING_LENDER_POOL,
            ROLLING_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            principal,
            collateralDelta,
            releaseLockedCollateral
        );
        harness.settleRatioPrincipal(
            RATIO_LENDER_KEY,
            RATIO_BORROWER_KEY,
            RATIO_BORROWER_POSITION_ID,
            RATIO_LENDER_POOL,
            RATIO_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            principal,
            collateralDelta,
            releaseLockedCollateral
        );
    }

    function mirrorCleanup() external {
        uint256 outstanding = harness.borrowedPrincipalOf(FIXED_BORROWER_KEY, FIXED_LENDER_POOL);
        if (outstanding == 0) return;

        (, uint256 exposureToClear,) = harness.encumbranceOf(FIXED_LENDER_KEY, FIXED_LENDER_POOL);
        (uint256 collateralToUnlock,,) = harness.encumbranceOf(FIXED_BORROWER_KEY, FIXED_COLLATERAL_POOL);

        address borrowAsset = sameAssetMode ? SAME_ASSET : BORROW_ASSET;
        address collateralAsset = sameAssetMode ? SAME_ASSET : COLLATERAL_ASSET;

        harness.cleanupFixed(
            FIXED_LENDER_KEY,
            FIXED_BORROWER_KEY,
            FIXED_BORROWER_POSITION_ID,
            FIXED_LENDER_POOL,
            FIXED_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            outstanding,
            exposureToClear,
            collateralToUnlock
        );
        harness.cleanupRolling(
            ROLLING_LENDER_KEY,
            ROLLING_BORROWER_KEY,
            ROLLING_BORROWER_POSITION_ID,
            ROLLING_LENDER_POOL,
            ROLLING_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            outstanding,
            exposureToClear,
            collateralToUnlock
        );
        harness.cleanupRatio(
            RATIO_LENDER_KEY,
            RATIO_BORROWER_KEY,
            RATIO_BORROWER_POSITION_ID,
            RATIO_LENDER_POOL,
            RATIO_COLLATERAL_POOL,
            borrowAsset,
            collateralAsset,
            outstanding,
            exposureToClear,
            collateralToUnlock
        );

        sameAssetMode = false;
    }

    function _availablePrincipal(uint256 lenderPoolId, bytes32 lenderKey) private view returns (uint256 principal) {
        (principal,,,,,,,) = harness.poolState(lenderPoolId, lenderKey, 0);
    }

    function _lockedCollateral(bytes32 borrowerKey, uint256 collateralPoolId) private view returns (uint256 locked) {
        (locked,,) = harness.encumbranceOf(borrowerKey, collateralPoolId);
    }

    function _boundAmount(uint256 seed, uint256 max) private pure returns (uint256 amount) {
        if (max == 0) return 0;
        if (max == 1) return 1;
        amount = bound(seed, 1, max);
    }

    function _seedVariant(uint256 lenderPoolId, bytes32 lenderKey, uint256 collateralPoolId) private {
        harness.setPool(lenderPoolId, BORROW_ASSET, INITIAL_LENDER_CAPITAL, INITIAL_LENDER_CAPITAL, 1);
        harness.setUserPrincipal(lenderPoolId, lenderKey, INITIAL_LENDER_CAPITAL);
        harness.setPool(collateralPoolId, COLLATERAL_ASSET, 0, 0, 0);
    }
}

contract LibEqualLendDirectAccountingInvariantTest is StdInvariant, Test {
    EqualLendDirectAccountingHarness internal harness;
    EqualLendDirectAccountingInvariantHandler internal handler;

    function setUp() public {
        harness = new EqualLendDirectAccountingHarness();
        handler = new EqualLendDirectAccountingInvariantHandler(harness);
        handler.seedInitialState();
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.mirrorOriginate.selector;
        selectors[1] = handler.mirrorRepay.selector;
        selectors[2] = handler.mirrorCleanup.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_LenderPoolAccountingStaysAlignedAcrossVariants() public view {
        _assertPoolStatesEqual(
            handler.FIXED_LENDER_POOL(),
            handler.FIXED_LENDER_KEY(),
            handler.FIXED_BORROWER_POSITION_ID(),
            handler.ROLLING_LENDER_POOL(),
            handler.ROLLING_LENDER_KEY(),
            handler.ROLLING_BORROWER_POSITION_ID()
        );
        _assertPoolStatesEqual(
            handler.FIXED_LENDER_POOL(),
            handler.FIXED_LENDER_KEY(),
            handler.FIXED_BORROWER_POSITION_ID(),
            handler.RATIO_LENDER_POOL(),
            handler.RATIO_LENDER_KEY(),
            handler.RATIO_BORROWER_POSITION_ID()
        );
    }

    function invariant_LenderCapitalCompositionStaysAlignedAndBoundedAcrossVariants() public view {
        uint256 fixedCapital = _lenderCapitalComposition(handler.FIXED_LENDER_POOL(), handler.FIXED_LENDER_KEY());
        uint256 rollingCapital = _lenderCapitalComposition(handler.ROLLING_LENDER_POOL(), handler.ROLLING_LENDER_KEY());
        uint256 ratioCapital = _lenderCapitalComposition(handler.RATIO_LENDER_POOL(), handler.RATIO_LENDER_KEY());

        assertEq(fixedCapital, rollingCapital, "fixed vs rolling lender capital composition");
        assertEq(fixedCapital, ratioCapital, "fixed vs ratio lender capital composition");
        assertLe(fixedCapital, handler.INITIAL_LENDER_CAPITAL(), "lender capital composition exceeds initial capital");
    }

    function invariant_DirectDebtAndEncumbranceTransitionsStayAlignedAcrossVariants() public view {
        assertEq(
            harness.borrowedPrincipalOf(handler.FIXED_BORROWER_KEY(), handler.FIXED_LENDER_POOL()),
            harness.borrowedPrincipalOf(handler.ROLLING_BORROWER_KEY(), handler.ROLLING_LENDER_POOL()),
            "fixed vs rolling borrowed principal"
        );
        assertEq(
            harness.borrowedPrincipalOf(handler.FIXED_BORROWER_KEY(), handler.FIXED_LENDER_POOL()),
            harness.borrowedPrincipalOf(handler.RATIO_BORROWER_KEY(), handler.RATIO_LENDER_POOL()),
            "fixed vs ratio borrowed principal"
        );

        (, uint256 fixedExposure, uint256 fixedEscrow) =
            harness.encumbranceOf(handler.FIXED_LENDER_KEY(), handler.FIXED_LENDER_POOL());
        (, uint256 rollingExposure, uint256 rollingEscrow) =
            harness.encumbranceOf(handler.ROLLING_LENDER_KEY(), handler.ROLLING_LENDER_POOL());
        (, uint256 ratioExposure, uint256 ratioEscrow) =
            harness.encumbranceOf(handler.RATIO_LENDER_KEY(), handler.RATIO_LENDER_POOL());

        assertEq(fixedExposure, rollingExposure, "fixed vs rolling exposure");
        assertEq(fixedExposure, ratioExposure, "fixed vs ratio exposure");
        assertEq(fixedEscrow, rollingEscrow, "fixed vs rolling escrow");
        assertEq(fixedEscrow, ratioEscrow, "fixed vs ratio escrow");

        (uint256 fixedLocked,,) = harness.encumbranceOf(handler.FIXED_BORROWER_KEY(), handler.FIXED_COLLATERAL_POOL());
        (uint256 rollingLocked,,) =
            harness.encumbranceOf(handler.ROLLING_BORROWER_KEY(), handler.ROLLING_COLLATERAL_POOL());
        (uint256 ratioLocked,,) = harness.encumbranceOf(handler.RATIO_BORROWER_KEY(), handler.RATIO_COLLATERAL_POOL());

        assertEq(fixedLocked, rollingLocked, "fixed vs rolling locked collateral");
        assertEq(fixedLocked, ratioLocked, "fixed vs ratio locked collateral");
    }

    function invariant_SameAssetDebtAndActiveCreditStayAlignedAcrossVariants() public view {
        assertEq(
            harness.sameAssetDebtOf(handler.FIXED_BORROWER_KEY(), handler.SAME_ASSET()),
            harness.sameAssetDebtOf(handler.ROLLING_BORROWER_KEY(), handler.SAME_ASSET()),
            "fixed vs rolling direct same asset debt"
        );
        assertEq(
            harness.sameAssetDebtOf(handler.FIXED_BORROWER_KEY(), handler.SAME_ASSET()),
            harness.sameAssetDebtOf(handler.RATIO_BORROWER_KEY(), handler.SAME_ASSET()),
            "fixed vs ratio direct same asset debt"
        );

        _assertBorrowerDebtPoolsEqual(
            handler.FIXED_COLLATERAL_POOL(),
            handler.FIXED_BORROWER_KEY(),
            handler.FIXED_BORROWER_POSITION_ID(),
            handler.ROLLING_COLLATERAL_POOL(),
            handler.ROLLING_BORROWER_KEY(),
            handler.ROLLING_BORROWER_POSITION_ID()
        );
        _assertBorrowerDebtPoolsEqual(
            handler.FIXED_COLLATERAL_POOL(),
            handler.FIXED_BORROWER_KEY(),
            handler.FIXED_BORROWER_POSITION_ID(),
            handler.RATIO_COLLATERAL_POOL(),
            handler.RATIO_BORROWER_KEY(),
            handler.RATIO_BORROWER_POSITION_ID()
        );
    }

    function _assertPoolStatesEqual(
        uint256 leftPoolId,
        bytes32 leftPositionKey,
        uint256 leftBorrowerPositionId,
        uint256 rightPoolId,
        bytes32 rightPositionKey,
        uint256 rightBorrowerPositionId
    ) private view {
        (
            uint256 leftPrincipal,
            uint256 leftDeposits,
            uint256 leftTracked,
            uint256 leftUserCount,
            ,
            ,
            ,
        ) = harness.poolState(leftPoolId, leftPositionKey, leftBorrowerPositionId);
        (
            uint256 rightPrincipal,
            uint256 rightDeposits,
            uint256 rightTracked,
            uint256 rightUserCount,
            ,
            ,
            ,
        ) = harness.poolState(rightPoolId, rightPositionKey, rightBorrowerPositionId);

        assertEq(leftPrincipal, rightPrincipal, "principal mismatch");
        assertEq(leftDeposits, rightDeposits, "deposits mismatch");
        assertEq(leftTracked, rightTracked, "tracked mismatch");
        assertEq(leftUserCount, rightUserCount, "user count mismatch");
    }

    function _assertBorrowerDebtPoolsEqual(
        uint256 leftPoolId,
        bytes32 leftBorrowerKey,
        uint256 leftBorrowerPositionId,
        uint256 rightPoolId,
        bytes32 rightBorrowerKey,
        uint256 rightBorrowerPositionId
    ) private view {
        (
            ,
            ,
            ,
            ,
            uint256 leftActiveCredit,
            uint256 leftUserSameAssetDebt,
            uint256 leftTokenSameAssetDebt,
            uint256 leftDebtState
        ) = harness.poolState(leftPoolId, leftBorrowerKey, leftBorrowerPositionId);
        (
            ,
            ,
            ,
            ,
            uint256 rightActiveCredit,
            uint256 rightUserSameAssetDebt,
            uint256 rightTokenSameAssetDebt,
            uint256 rightDebtState
        ) = harness.poolState(rightPoolId, rightBorrowerKey, rightBorrowerPositionId);

        assertEq(leftActiveCredit, rightActiveCredit, "active credit mismatch");
        assertEq(leftUserSameAssetDebt, rightUserSameAssetDebt, "user same asset mismatch");
        assertEq(leftTokenSameAssetDebt, rightTokenSameAssetDebt, "token same asset mismatch");
        assertEq(leftDebtState, rightDebtState, "debt state mismatch");
    }

    function _lenderCapitalComposition(uint256 poolId, bytes32 lenderKey) private view returns (uint256 total) {
        (uint256 principal,,,,,,,) = harness.poolState(poolId, lenderKey, 0);
        (, uint256 exposure, uint256 escrow) = harness.encumbranceOf(lenderKey, poolId);
        return principal + exposure + escrow;
    }
}
