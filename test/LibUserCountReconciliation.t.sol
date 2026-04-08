// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualLendDirectAccountingHarness} from "test/utils/EqualLendDirectAccountingHarness.sol";
import {EqualLendDirectFixedAgreementFacet} from "src/equallend/EqualLendDirectFixedAgreementFacet.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectLifecycleFacet} from "src/equallend/EqualLendDirectLifecycleFacet.sol";
import {EqualLendDirectRollingAgreementFacet} from "src/equallend/EqualLendDirectRollingAgreementFacet.sol";
import {EqualLendDirectRollingLifecycleFacet} from "src/equallend/EqualLendDirectRollingLifecycleFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "src/equallend/EqualLendDirectRollingOfferFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "src/equallend/EqualLendDirectRollingPaymentFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {
    LibAppStorage
} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEqualLendDirectStorage} from "src/libraries/LibEqualLendDirectStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {MaxUserCountExceeded} from "src/libraries/Errors.sol";

contract MockERC20UserCount is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UserCountDirectLifecycleHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectFixedOfferFacet,
    EqualLendDirectFixedAgreementFacet,
    EqualLendDirectLifecycleFacet
{
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setTreasury(address treasury_) external {
        LibAppStorage.s().treasury = treasury_;
    }

    function setFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = uint16(treasuryBps);
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
        store.activeCreditShareConfigured = true;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function setDirectConfig(
        uint256 platformFeeBps,
        uint256 interestLenderBps,
        uint256 platformFeeLenderBps,
        uint256 defaultLenderBps,
        uint256 minInterestDuration
    ) external {
        if (
            platformFeeBps > type(uint16).max || interestLenderBps > type(uint16).max
                || platformFeeLenderBps > type(uint16).max || defaultLenderBps > type(uint16).max
                || minInterestDuration > type(uint40).max
        ) revert();

        LibEqualLendDirectStorage.DirectConfig memory cfg = LibEqualLendDirectStorage.DirectConfig({
            platformFeeBps: uint16(platformFeeBps),
            interestLenderBps: uint16(interestLenderBps),
            platformFeeLenderBps: uint16(platformFeeLenderBps),
            defaultLenderBps: uint16(defaultLenderBps),
            minInterestDuration: uint40(minInterestDuration)
        });
        LibEqualLendDirectStorage.validateDirectConfig(cfg);
        LibEqualLendDirectStorage.s().config = cfg;
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function userCountOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userCount;
    }
}

contract UserCountRollingLifecycleHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualLendDirectRollingOfferFacet,
    EqualLendDirectRollingAgreementFacet,
    EqualLendDirectRollingPaymentFacet,
    EqualLendDirectRollingLifecycleFacet
{
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setTreasury(address treasury_) external {
        LibAppStorage.s().treasury = treasury_;
    }

    function setFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = uint16(treasuryBps);
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
        store.activeCreditShareConfigured = true;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function setDirectConfig(
        uint256 platformFeeBps,
        uint256 interestLenderBps,
        uint256 platformFeeLenderBps,
        uint256 defaultLenderBps,
        uint256 minInterestDuration
    ) external {
        if (
            platformFeeBps > type(uint16).max || interestLenderBps > type(uint16).max
                || platformFeeLenderBps > type(uint16).max || defaultLenderBps > type(uint16).max
                || minInterestDuration > type(uint40).max
        ) revert();

        LibEqualLendDirectStorage.DirectConfig memory cfg = LibEqualLendDirectStorage.DirectConfig({
            platformFeeBps: uint16(platformFeeBps),
            interestLenderBps: uint16(interestLenderBps),
            platformFeeLenderBps: uint16(platformFeeLenderBps),
            defaultLenderBps: uint16(defaultLenderBps),
            minInterestDuration: uint40(minInterestDuration)
        });
        LibEqualLendDirectStorage.validateDirectConfig(cfg);
        LibEqualLendDirectStorage.s().config = cfg;
    }

    function setRollingConfig(
        uint256 minPaymentIntervalSeconds,
        uint256 maxPaymentCount,
        uint256 maxUpfrontPremiumBps,
        uint256 minRollingApyBps,
        uint256 maxRollingApyBps,
        uint256 defaultPenaltyBps,
        uint256 minPaymentBps
    ) external {
        if (
            minPaymentIntervalSeconds > type(uint32).max || maxPaymentCount > type(uint16).max
                || maxUpfrontPremiumBps > type(uint16).max || minRollingApyBps > type(uint16).max
                || maxRollingApyBps > type(uint16).max || defaultPenaltyBps > type(uint16).max
                || minPaymentBps > type(uint16).max
        ) revert();

        LibEqualLendDirectStorage.DirectRollingConfig memory cfg = LibEqualLendDirectStorage.DirectRollingConfig({
            minPaymentIntervalSeconds: uint32(minPaymentIntervalSeconds),
            maxPaymentCount: uint16(maxPaymentCount),
            maxUpfrontPremiumBps: uint16(maxUpfrontPremiumBps),
            minRollingApyBps: uint16(minRollingApyBps),
            maxRollingApyBps: uint16(maxRollingApyBps),
            defaultPenaltyBps: uint16(defaultPenaltyBps),
            minPaymentBps: uint16(minPaymentBps)
        });
        LibEqualLendDirectStorage.validateRollingConfig(cfg);
        LibEqualLendDirectStorage.s().rollingConfig = cfg;
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function userCountOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userCount;
    }
}

contract LibUserCountReconciliationAccountingBugConditionTest is Test {
    EqualLendDirectAccountingHarness internal harness;

    bytes32 internal constant LENDER_A = keccak256("lender-a");
    bytes32 internal constant LENDER_B = keccak256("lender-b");
    bytes32 internal constant LENDER_C = keccak256("lender-c");
    bytes32 internal constant MAINT_USER = keccak256("maintenance-user");

    uint256 internal constant POOL_ID = 77;
    address internal constant ASSET = address(0xA11CE);

    function setUp() public {
        harness = new EqualLendDirectAccountingHarness();
    }

    function test_BugCondition_RestoreLenderCapital_ShouldEnforceMaxUserCount() external {
        harness.setPool(POOL_ID, ASSET, 300 ether, 300 ether, 2);
        harness.setMaxUserCount(POOL_ID, 2);
        harness.setUserPrincipal(POOL_ID, LENDER_A, 100 ether);
        harness.setUserPrincipal(POOL_ID, LENDER_B, 200 ether);

        harness.departLenderCapital(LENDER_A, POOL_ID, 100 ether);
        (, , , uint256 userCountAfterDeparture, , , ,) = harness.poolState(POOL_ID, LENDER_A, 0);
        assertEq(userCountAfterDeparture, 1, "departure did not decrement user count");

        harness.restoreLenderCapital(LENDER_A, POOL_ID, 100 ether);
        (, , , uint256 userCountAtCapacity, , , ,) = harness.poolState(POOL_ID, LENDER_A, 0);
        assertEq(userCountAtCapacity, 2, "restore did not refill capacity");

        vm.expectRevert(abi.encodeWithSelector(MaxUserCountExceeded.selector, 2));
        harness.restoreLenderCapital(LENDER_C, POOL_ID, 50 ether);
    }

    function test_BugCondition_MaintenanceSettle_ShouldDecrementUserCountWhenPrincipalZeros() external {
        _seedMaintenanceZeroingState();

        harness.settleFeeIndex(POOL_ID, MAINT_USER);

        (uint256 principalAfter, , , uint256 userCountAfter, , , ,) = harness.poolState(POOL_ID, MAINT_USER, 0);
        assertEq(principalAfter, 0, "maintenance did not zero principal");
        assertEq(userCountAfter, 0, "maintenance settle did not decrement user count");
    }

    function test_BugCondition_MaintenanceThenRestore_ShouldNotDoubleCountUser() external {
        _seedMaintenanceZeroingState();

        harness.settleFeeIndex(POOL_ID, MAINT_USER);
        harness.restoreLenderCapital(MAINT_USER, POOL_ID, 5 ether);

        (, , , uint256 userCountAfterRestore, , , ,) = harness.poolState(POOL_ID, MAINT_USER, 0);
        assertEq(userCountAfterRestore, 1, "maintenance then restore inflated user count");
    }

    function _seedMaintenanceZeroingState() internal {
        harness.setPool(POOL_ID, ASSET, 10 ether, 10 ether, 1);
        harness.setUserPrincipal(POOL_ID, MAINT_USER, 10 ether);
        harness.setMaintenanceIndex(POOL_ID, 2e18);
        harness.setUserMaintenanceIndex(POOL_ID, MAINT_USER, 0);
        harness.setUserFeeIndex(POOL_ID, MAINT_USER, 0);
    }
}

contract LibUserCountReconciliationDirectBugConditionTest is Test {
    UserCountDirectLifecycleHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20UserCount internal sameAssetToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        harness = new UserCountDirectLifecycleHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1_000, 0);
        harness.setDirectConfig(100, 6_000, 2_500, 8_000, 1 days);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        sameAssetToken = new MockERC20UserCount("Same Asset", "SAM");
        _initPool(3, address(sameAssetToken), 2);
    }

    function test_BugCondition_CreditPrincipalDirect_ShouldEnforceMaxUserCountAtRecovery() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 60 ether);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 150 ether);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postFixedBorrowerOffer(
            EqualLendDirectFixedOfferFacet.FixedBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                principal: 60 ether,
                collateralLocked: 100 ether,
                aprBps: 700,
                durationSeconds: 10 days,
                allowEarlyRepay: true,
                allowEarlyExercise: false,
                allowLenderCall: false
            })
        );

        vm.prank(alice);
        uint256 agreementId = harness.acceptFixedBorrowerOffer(offerId, lenderPositionId, _borrowerNetFor(60 ether, 700, 10 days));

        assertEq(harness.principalOf(3, lenderKey), 0, "lender principal should be fully departed");
        assertEq(harness.userCountOf(3), 1, "pool should have one active user after origination");

        _mintAndDeposit(carol, 3, 1 ether);
        assertEq(harness.userCountOf(3), 2, "pool should be back at max user count");

        vm.warp(block.timestamp + 11 days);

        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(MaxUserCountExceeded.selector, 2));
        harness.recover(agreementId);
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount) internal returns (uint256 positionId) {
        sameAssetToken.mint(user, amount);

        vm.prank(user);
        sameAssetToken.approve(address(harness), amount);

        vm.prank(user);
        positionId = harness.mintPosition(homePoolId);

        vm.prank(user);
        harness.depositToPosition(positionId, homePoolId, amount, amount);
    }

    function _initPool(uint256 pid, address underlying, uint256 maxUserCount) internal {
        harness.initPoolWithActionFees(pid, underlying, _poolConfig(maxUserCount), _actionFees());
    }

    function _poolConfig(uint256 maxUserCount) internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8_000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 30;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 1_000;
        cfg.maxUserCount = maxUserCount;
    }

    function _actionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        return actionFees;
    }

    function _borrowerNetFor(uint256 principal, uint16 aprBps, uint64 duration) internal pure returns (uint256) {
        uint256 platformFee = (principal * 100) / 10_000;
        uint256 effectiveDuration = duration < 1 days ? 1 days : duration;
        uint256 interestAmount = (principal * uint256(aprBps) * effectiveDuration) / (365 days * 10_000);
        return principal - platformFee - interestAmount;
    }
}

contract LibUserCountReconciliationRollingBugConditionTest is Test {
    UserCountRollingLifecycleHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20UserCount internal sameAssetToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        harness = new UserCountRollingLifecycleHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1_000, 0);
        harness.setDirectConfig(100, 10_000, 10_000, 8_000, 1 days);
        harness.setRollingConfig(1 days, 24, 2_500, 300, 2_000, 500, 1);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        positionNft.setDiamond(address(harness));
        harness.setPositionNFT(address(positionNft));

        sameAssetToken = new MockERC20UserCount("Same Asset", "SAM");
        _initPool(3, address(sameAssetToken), 2);
    }

    function test_BugCondition_CreditPrincipalRolling_ShouldEnforceMaxUserCountAtRecovery() external {
        uint256 lenderPositionId = _mintAndDeposit(alice, 3, 40 ether);
        uint256 borrowerPositionId = _mintAndDeposit(bob, 3, 150 ether);
        bytes32 lenderKey = positionNft.getPositionKey(lenderPositionId);

        vm.prank(bob);
        uint256 offerId = harness.postRollingBorrowerOffer(
            EqualLendDirectRollingOfferFacet.RollingBorrowerOfferParams({
                borrowerPositionId: borrowerPositionId,
                lenderPoolId: 3,
                collateralPoolId: 3,
                borrowAsset: address(sameAssetToken),
                collateralAsset: address(sameAssetToken),
                principal: 40 ether,
                collateralLocked: 80 ether,
                paymentIntervalSeconds: 7 days,
                rollingApyBps: 850,
                gracePeriodSeconds: 2 days,
                maxPaymentCount: 10,
                upfrontPremium: 0,
                allowAmortization: true,
                allowEarlyRepay: true,
                allowEarlyExercise: true
            })
        );

        vm.prank(alice);
        uint256 agreementId = harness.acceptRollingBorrowerOffer(offerId, lenderPositionId, 0, 40 ether);

        assertEq(harness.principalOf(3, lenderKey), 0, "lender principal should be fully departed");
        assertEq(harness.userCountOf(3), 1, "pool should have one active user after origination");

        _mintAndDeposit(carol, 3, 1 ether);
        assertEq(harness.userCountOf(3), 2, "pool should be back at max user count");

        vm.warp(block.timestamp + 10 days);

        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(MaxUserCountExceeded.selector, 2));
        harness.recoverRolling(agreementId);
    }

    function _mintAndDeposit(address user, uint256 homePoolId, uint256 amount) internal returns (uint256 positionId) {
        sameAssetToken.mint(user, amount);

        vm.prank(user);
        sameAssetToken.approve(address(harness), amount);

        vm.prank(user);
        positionId = harness.mintPosition(homePoolId);

        vm.prank(user);
        harness.depositToPosition(positionId, homePoolId, amount, amount);
    }

    function _initPool(uint256 pid, address underlying, uint256 maxUserCount) internal {
        harness.initPoolWithActionFees(pid, underlying, _poolConfig(maxUserCount), _actionFees());
    }

    function _poolConfig(uint256 maxUserCount) internal pure returns (Types.PoolConfig memory cfg) {
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8_000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 30;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMinBps = 0;
        cfg.aumFeeMaxBps = 1_000;
        cfg.maxUserCount = maxUserCount;
    }

    function _actionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        return actionFees;
    }
}
