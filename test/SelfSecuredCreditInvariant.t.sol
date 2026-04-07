// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {SelfSecuredCreditFacet} from "src/equallend/SelfSecuredCreditFacet.sol";
import {SelfSecuredCreditViewFacet} from "src/equallend/SelfSecuredCreditViewFacet.sol";
import {Types} from "src/libraries/Types.sol";

import {LaunchFixture, MockERC20Launch} from "test/utils/LaunchFixture.t.sol";
import {ProtocolTestSupportFacet} from "test/utils/ProtocolTestSupport.sol";

contract SelfSecuredCreditInvariantHandler is Test {
    uint256 internal constant POOL_ID = 1;
    uint16 internal constant LTV_BPS = 8_000;

    address public immutable diamond;
    address public immutable owner;
    address public immutable stranger;
    MockERC20Launch public immutable token;

    uint256 public immutable positionId;
    bytes32 public immutable positionKey;

    constructor(
        address diamond_,
        address owner_,
        address stranger_,
        MockERC20Launch token_,
        uint256 positionId_,
        bytes32 positionKey_
    ) {
        diamond = diamond_;
        owner = owner_;
        stranger = stranger_;
        token = token_;
        positionId = positionId_;
        positionKey = positionKey_;
    }

    function deposit(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1 ether, 50 ether);

        token.mint(owner, amount);
        vm.startPrank(owner);
        token.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(positionId, POOL_ID, amount, amount);
        vm.stopPrank();
    }

    function draw(uint256 amountSeed) external {
        uint256 maxDraw = SelfSecuredCreditViewFacet(diamond).maxAdditionalSscDraw(positionId, POOL_ID);
        if (maxDraw < 1 ether) {
            return;
        }

        uint256 amount = bound(amountSeed, 1 ether, maxDraw);
        vm.prank(owner);
        SelfSecuredCreditFacet(diamond).drawSelfSecuredCredit(positionId, POOL_ID, amount, amount);
    }

    function repay(uint256 amountSeed) external {
        Types.SscLineView memory lineView = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, POOL_ID);
        if (lineView.outstandingDebt == 0) {
            return;
        }

        uint256 amount = bound(amountSeed, 1 ether, lineView.outstandingDebt);
        token.mint(owner, amount);
        vm.startPrank(owner);
        token.approve(diamond, type(uint256).max);
        SelfSecuredCreditFacet(diamond).repaySelfSecuredCredit(positionId, POOL_ID, amount, amount);
        vm.stopPrank();
    }

    function toggleMode() external {
        Types.SscLineView memory lineView = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, POOL_ID);
        if (!lineView.active) {
            return;
        }

        Types.SscAciMode nextMode =
            lineView.aciMode == Types.SscAciMode.Yield ? Types.SscAciMode.SelfPay : Types.SscAciMode.Yield;
        vm.prank(owner);
        SelfSecuredCreditFacet(diamond).setSelfSecuredCreditAciMode(positionId, POOL_ID, nextMode);
    }

    function routeManagedYield(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1 ether, 10 ether);

        vm.warp(block.timestamp + 25 hours);
        token.mint(diamond, amount);
        ProtocolTestSupportFacet(diamond).routeManagedShareExternal(
            POOL_ID, amount, keccak256(abi.encodePacked("ssc.invariant.route", amountSeed, block.timestamp)), false, amount
        );
    }

    function service() external {
        Types.SscLineView memory lineView = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, POOL_ID);
        if (!lineView.active) {
            return;
        }

        vm.prank(owner);
        SelfSecuredCreditFacet(diamond).serviceSelfSecuredCredit(positionId, POOL_ID);
    }

    function withdrawFreeEquity(uint256 amountSeed) external {
        Types.SscLineView memory lineView = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, POOL_ID);
        if (lineView.freeEquity < 1 ether) {
            return;
        }

        uint256 amount = bound(amountSeed, 1 ether, lineView.freeEquity);
        vm.prank(owner);
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, POOL_ID, amount, amount);
    }

    function advanceTime(uint256 timeSeed) external {
        uint256 delta = bound(timeSeed, 1 hours, 45 days);
        vm.warp(block.timestamp + delta);
    }

    function terminalSettleIfUnsafe() external {
        Types.SscMaintenancePreview memory preview =
            SelfSecuredCreditFacet(diamond).previewSelfSecuredCreditMaintenance(positionId, POOL_ID);
        if (!preview.unsafeAfterMaintenance || preview.outstandingDebt == 0) {
            return;
        }

        vm.prank(stranger);
        SelfSecuredCreditFacet(diamond).selfSettleSelfSecuredCredit(positionId, POOL_ID);
    }

    function expectedRequiredLock() external view returns (uint256) {
        uint256 debt = SelfSecuredCreditViewFacet(diamond).getSscLine(positionId, POOL_ID).outstandingDebt;
        if (debt == 0) {
            return 0;
        }
        return Math.mulDiv(debt, 10_000, LTV_BPS, Math.Rounding.Ceil);
    }
}

contract SelfSecuredCreditInvariantTest is StdInvariant, LaunchFixture {
    uint256 internal constant POOL_ID = 1;

    SelfSecuredCreditInvariantHandler internal handler;
    uint256 internal positionId;
    bytes32 internal positionKey;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
        testSupport.setFoundationReceiver(treasury);
        testSupport.setTreasuryShareBps(1_000);
        testSupport.setActiveCreditShareBps(7_000);

        positionId = _mintPosition(alice, POOL_ID);
        positionKey = positionNft.getPositionKey(positionId);

        eve.mint(alice, 200 ether);
        vm.startPrank(alice);
        eve.approve(diamond, type(uint256).max);
        PositionManagementFacet(diamond).depositToPosition(positionId, POOL_ID, 200 ether, 200 ether);
        vm.stopPrank();

        handler = new SelfSecuredCreditInvariantHandler(diamond, alice, bob, eve, positionId, positionKey);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.draw.selector;
        selectors[2] = handler.repay.selector;
        selectors[3] = handler.toggleMode.selector;
        selectors[4] = handler.routeManagedYield.selector;
        selectors[5] = handler.service.selector;
        selectors[6] = handler.withdrawFreeEquity.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.terminalSettleIfUnsafe.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SameAssetDebtMatchesOutstandingDebtAcrossLifecycle() public view {
        Types.SscLine memory line = testSupport.sscLineOf(POOL_ID, positionKey);
        assertEq(testSupport.sameAssetDebtOf(POOL_ID, positionKey), line.outstandingDebt);
    }

    function invariant_RequiredLockMatchesConfiguredLtvFormulaAtEveryStep() public view {
        Types.SscLine memory line = testSupport.sscLineOf(POOL_ID, positionKey);
        uint256 expectedLock = handler.expectedRequiredLock();

        assertEq(line.requiredLockedCapital, expectedLock);
        assertEq(testSupport.lockedCapitalOf(positionKey, POOL_ID), expectedLock);
    }

    function invariant_CanonicalLockedCapitalRemainsTheWithdrawalSafetyRail() public view {
        Types.SscLine memory line = testSupport.sscLineOf(POOL_ID, positionKey);
        uint256 lockedCapital = testSupport.lockedCapitalOf(positionKey, POOL_ID);

        assertEq(lockedCapital, line.requiredLockedCapital);
        assertTrue(lockedCapital >= line.outstandingDebt);
    }
}
