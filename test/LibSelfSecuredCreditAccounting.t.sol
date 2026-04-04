// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibSelfSecuredCreditAccounting} from "src/libraries/LibSelfSecuredCreditAccounting.sol";
import {LibSelfSecuredCreditStorage} from "src/libraries/LibSelfSecuredCreditStorage.sol";
import {Types} from "src/libraries/Types.sol";

contract SelfSecuredCreditAccountingHarness {
    function setPool(uint256 pid, address underlying, uint16 depositorLtvBps) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.initialized = true;
        pool.underlying = underlying;
        pool.poolConfig.depositorLTVBps = depositorLtvBps;
    }

    function setLineMode(bytes32 positionKey, uint256 poolId, Types.SscAciMode aciMode) external {
        LibSelfSecuredCreditStorage.line(positionKey, poolId).aciMode = aciMode;
    }

    function increaseDebt(bytes32 positionKey, uint256 positionId, uint256 poolId, uint256 amount)
        external
        returns (LibSelfSecuredCreditAccounting.DebtAdjustment memory result)
    {
        result = LibSelfSecuredCreditAccounting.increaseDebt(positionKey, positionId, poolId, amount);
    }

    function decreaseDebt(bytes32 positionKey, uint256 positionId, uint256 poolId, uint256 amount)
        external
        returns (LibSelfSecuredCreditAccounting.DebtAdjustment memory result)
    {
        result = LibSelfSecuredCreditAccounting.decreaseDebt(positionKey, positionId, poolId, amount);
    }

    function requiredLockForDebt(uint256 debt, uint16 ltvBps) external pure returns (uint256) {
        return LibSelfSecuredCreditAccounting.requiredLockedCapitalForDebt(debt, ltvBps);
    }

    function lineState(bytes32 positionKey, uint256 poolId) external view returns (Types.SscLine memory) {
        Types.SscLine storage lineState_ = LibSelfSecuredCreditStorage.line(positionKey, poolId);
        return lineState_;
    }

    function poolDebtState(uint256 poolId, bytes32 positionKey, uint256 positionId)
        external
        view
        returns (
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 activeCreditPrincipalTotal,
            uint256 debtStatePrincipal,
            uint256 debtStateIndexSnapshot
        )
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];
        userSameAssetDebt = pool.userSameAssetDebt[positionKey];
        tokenSameAssetDebt = pool.sameAssetDebt[positionId];
        activeCreditPrincipalTotal = pool.activeCreditPrincipalTotal;
        debtStatePrincipal = pool.userActiveCreditStateDebt[positionKey].principal;
        debtStateIndexSnapshot = pool.userActiveCreditStateDebt[positionKey].indexSnapshot;
    }

    function lockedCapitalOf(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibEncumbrance.position(positionKey, poolId).lockedCapital;
    }
}

contract LibSelfSecuredCreditAccountingTest is Test {
    SelfSecuredCreditAccountingHarness internal harness;

    bytes32 internal constant POSITION_KEY = keccak256("ssc.accounting.position");
    uint256 internal constant POSITION_ID = 444;
    uint256 internal constant POOL_ID = 7;
    uint16 internal constant LTV_BPS = 9500;

    function setUp() public {
        harness = new SelfSecuredCreditAccountingHarness();
        harness.setPool(POOL_ID, address(0xA11CE), LTV_BPS);
    }

    function test_increaseDebt_updatesOutstandingDebtSameAssetDebtAciAndRequiredLock() external {
        harness.setLineMode(POSITION_KEY, POOL_ID, Types.SscAciMode.SelfPay);

        LibSelfSecuredCreditAccounting.DebtAdjustment memory result =
            harness.increaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, 95 ether);

        assertEq(result.appliedAmount, 95 ether, "applied amount");
        assertEq(result.outstandingDebtBefore, 0, "debt before");
        assertEq(result.outstandingDebtAfter, 95 ether, "debt after");
        assertEq(result.requiredLockedCapitalBefore, 0, "lock before");
        assertEq(result.requiredLockedCapitalAfter, 100 ether, "lock after");
        assertEq(result.lockedCapitalDelta, 100 ether, "lock delta");
        assertTrue(result.lineActiveAfter, "line active");

        Types.SscLine memory lineState = harness.lineState(POSITION_KEY, POOL_ID);
        assertEq(lineState.outstandingDebt, 95 ether, "line debt");
        assertEq(lineState.requiredLockedCapital, 100 ether, "line required lock");
        assertEq(uint8(lineState.aciMode), uint8(Types.SscAciMode.SelfPay), "mode preserved");
        assertTrue(lineState.active, "line active");

        (
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 activeCreditPrincipalTotal,
            uint256 debtStatePrincipal,
            uint256 debtStateIndexSnapshot
        ) = harness.poolDebtState(POOL_ID, POSITION_KEY, POSITION_ID);

        assertEq(userSameAssetDebt, 95 ether, "user same-asset debt");
        assertEq(tokenSameAssetDebt, 95 ether, "token same-asset debt");
        assertEq(activeCreditPrincipalTotal, 95 ether, "active credit total");
        assertEq(debtStatePrincipal, 95 ether, "debt state principal");
        assertEq(debtStateIndexSnapshot, 0, "debt index snapshot");
        assertEq(harness.lockedCapitalOf(POSITION_KEY, POOL_ID), 100 ether, "locked capital");
    }

    function test_decreaseDebt_reducesDebtStateAndReleasesOnlyRequiredLockDelta() external {
        harness.increaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, 95 ether);
        uint256 expectedLockAfter = harness.requiredLockForDebt(60 ether, LTV_BPS);
        uint256 expectedReleasedLock = 100 ether - expectedLockAfter;

        LibSelfSecuredCreditAccounting.DebtAdjustment memory result =
            harness.decreaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, 35 ether);

        assertEq(result.appliedAmount, 35 ether, "applied amount");
        assertEq(result.outstandingDebtBefore, 95 ether, "debt before");
        assertEq(result.outstandingDebtAfter, 60 ether, "debt after");
        assertEq(result.requiredLockedCapitalBefore, 100 ether, "lock before");
        assertEq(result.requiredLockedCapitalAfter, expectedLockAfter, "lock after");
        assertEq(result.lockedCapitalDelta, expectedReleasedLock, "released lock");
        assertTrue(result.lineActiveAfter, "line active");

        Types.SscLine memory lineState = harness.lineState(POSITION_KEY, POOL_ID);
        assertEq(lineState.outstandingDebt, 60 ether, "line debt");
        assertEq(lineState.requiredLockedCapital, expectedLockAfter, "line required lock");
        assertTrue(lineState.active, "line active");

        (
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 activeCreditPrincipalTotal,
            uint256 debtStatePrincipal
        ) = _poolDebtState();
        assertEq(userSameAssetDebt, 60 ether, "user same-asset debt");
        assertEq(tokenSameAssetDebt, 60 ether, "token same-asset debt");
        assertEq(activeCreditPrincipalTotal, 60 ether, "active credit total");
        assertEq(debtStatePrincipal, 60 ether, "debt state principal");
        assertEq(harness.lockedCapitalOf(POSITION_KEY, POOL_ID), expectedLockAfter, "locked capital");
    }

    function test_decreaseDebt_capsAtOutstandingAndFullyClearsAlignment() external {
        harness.increaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, 45 ether);
        uint256 initialLock = harness.requiredLockForDebt(45 ether, LTV_BPS);

        LibSelfSecuredCreditAccounting.DebtAdjustment memory result =
            harness.decreaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, 100 ether);

        assertEq(result.appliedAmount, 45 ether, "applied amount");
        assertEq(result.outstandingDebtAfter, 0, "debt after");
        assertEq(result.requiredLockedCapitalAfter, 0, "lock after");
        assertEq(result.lockedCapitalDelta, initialLock, "released lock");
        assertFalse(result.lineActiveAfter, "line inactive");

        Types.SscLine memory lineState = harness.lineState(POSITION_KEY, POOL_ID);
        assertEq(lineState.outstandingDebt, 0, "line debt");
        assertEq(lineState.requiredLockedCapital, 0, "line required lock");
        assertFalse(lineState.active, "line inactive");

        (
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 activeCreditPrincipalTotal,
            uint256 debtStatePrincipal
        ) = _poolDebtState();
        assertEq(userSameAssetDebt, 0, "user same-asset debt");
        assertEq(tokenSameAssetDebt, 0, "token same-asset debt");
        assertEq(activeCreditPrincipalTotal, 0, "active credit total");
        assertEq(debtStatePrincipal, 0, "debt state principal");
        assertEq(harness.lockedCapitalOf(POSITION_KEY, POOL_ID), 0, "locked capital");
    }

    function testFuzz_alignmentHoldsAcrossIncreaseAndDecrease(uint96 rawIncrease, uint96 rawDecrease) external {
        uint256 increaseAmount = bound(uint256(rawIncrease), 1, 1_000_000 ether);
        uint256 decreaseAmount = bound(uint256(rawDecrease), 0, 2_000_000 ether);

        harness.increaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, increaseAmount);
        harness.decreaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, decreaseAmount);

        Types.SscLine memory lineState = harness.lineState(POSITION_KEY, POOL_ID);
        (
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 activeCreditPrincipalTotal,
            uint256 debtStatePrincipal
        ) = _poolDebtState();

        uint256 expectedDebt = decreaseAmount >= increaseAmount ? 0 : increaseAmount - decreaseAmount;
        uint256 expectedLock = harness.requiredLockForDebt(expectedDebt, LTV_BPS);

        assertEq(lineState.outstandingDebt, expectedDebt, "line debt alignment");
        assertEq(userSameAssetDebt, expectedDebt, "user same-asset alignment");
        assertEq(tokenSameAssetDebt, expectedDebt, "token same-asset alignment");
        assertEq(activeCreditPrincipalTotal, expectedDebt, "active credit total alignment");
        assertEq(debtStatePrincipal, expectedDebt, "debt state alignment");
        assertEq(lineState.requiredLockedCapital, expectedLock, "required lock alignment");
        assertEq(harness.lockedCapitalOf(POSITION_KEY, POOL_ID), expectedLock, "locked capital alignment");
        assertEq(lineState.active, expectedDebt != 0, "active flag alignment");
    }

    function testFuzz_requiredLockFormulaMatchesStoredLockAfterMultipleIncreases(uint96 rawFirst, uint96 rawSecond) external {
        uint256 firstIncrease = bound(uint256(rawFirst), 1, 500_000 ether);
        uint256 secondIncrease = bound(uint256(rawSecond), 1, 500_000 ether);

        harness.increaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, firstIncrease);
        harness.increaseDebt(POSITION_KEY, POSITION_ID, POOL_ID, secondIncrease);

        Types.SscLine memory lineState = harness.lineState(POSITION_KEY, POOL_ID);
        uint256 expectedDebt = firstIncrease + secondIncrease;
        uint256 expectedLock = harness.requiredLockForDebt(expectedDebt, LTV_BPS);

        (
            uint256 userSameAssetDebt,
            uint256 tokenSameAssetDebt,
            uint256 activeCreditPrincipalTotal,
            uint256 debtStatePrincipal
        ) = _poolDebtState();

        assertEq(lineState.outstandingDebt, expectedDebt, "line debt");
        assertEq(userSameAssetDebt, expectedDebt, "user same-asset debt");
        assertEq(tokenSameAssetDebt, expectedDebt, "token same-asset debt");
        assertEq(activeCreditPrincipalTotal, expectedDebt, "active credit total");
        assertEq(debtStatePrincipal, expectedDebt, "debt state principal");
        assertEq(lineState.requiredLockedCapital, expectedLock, "line required lock");
        assertEq(harness.lockedCapitalOf(POSITION_KEY, POOL_ID), expectedLock, "locked capital");
    }

    function _poolDebtState()
        internal
        view
        returns (uint256 userSameAssetDebt, uint256 tokenSameAssetDebt, uint256 activeCreditPrincipalTotal, uint256 debtStatePrincipal)
    {
        uint256 debtStateIndexSnapshot;
        (userSameAssetDebt, tokenSameAssetDebt, activeCreditPrincipalTotal, debtStatePrincipal, debtStateIndexSnapshot) =
            harness.poolDebtState(POOL_ID, POSITION_KEY, POSITION_ID);
        debtStateIndexSnapshot;
    }
}
