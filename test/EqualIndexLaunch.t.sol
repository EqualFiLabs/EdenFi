// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {IEqualIndexFlashReceiver} from "src/interfaces/IEqualIndexFlashReceiver.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
import {LibEqualIndexLending} from "src/libraries/LibEqualIndexLending.sol";
import {Types} from "src/libraries/Types.sol";
import {
    CanonicalPoolAlreadyInitialized,
    IndexPaused,
    InvalidParameterRange,
    InvalidArrayLength,
    InvalidBundleDefinition,
    InsufficientUnencumberedPrincipal,
    InvalidUnits,
    NoPoolForAsset
} from "src/libraries/Errors.sol";

import {LaunchFixture, MockERC20Launch} from "test/utils/LaunchFixture.t.sol";

contract EqualIndexAdminHarness is PoolManagementFacet, EqualIndexAdminFacetV3 {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setPositionNft(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function setDefaultPoolConfig(Types.PoolConfig calldata config) external override {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.defaultPoolConfigSet = true;
        store.defaultPoolConfig.rollingApyBps = config.rollingApyBps;
        store.defaultPoolConfig.depositorLTVBps = config.depositorLTVBps;
        store.defaultPoolConfig.maintenanceRateBps = config.maintenanceRateBps;
        store.defaultPoolConfig.flashLoanFeeBps = config.flashLoanFeeBps;
        store.defaultPoolConfig.flashLoanAntiSplit = config.flashLoanAntiSplit;
        store.defaultPoolConfig.minDepositAmount = config.minDepositAmount;
        store.defaultPoolConfig.minLoanAmount = config.minLoanAmount;
        store.defaultPoolConfig.minTopupAmount = config.minTopupAmount;
        store.defaultPoolConfig.isCapped = config.isCapped;
        store.defaultPoolConfig.depositCap = config.depositCap;
        store.defaultPoolConfig.maxUserCount = config.maxUserCount;
        store.defaultPoolConfig.aumFeeMinBps = config.aumFeeMinBps;
        store.defaultPoolConfig.aumFeeMaxBps = config.aumFeeMaxBps;
        store.defaultPoolConfig.borrowFee = config.borrowFee;
        store.defaultPoolConfig.repayFee = config.repayFee;
        store.defaultPoolConfig.withdrawFee = config.withdrawFee;
        store.defaultPoolConfig.flashFee = config.flashFee;
        store.defaultPoolConfig.closeRollingFee = config.closeRollingFee;
        delete store.defaultPoolConfig.fixedTermConfigs;
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            store.defaultPoolConfig.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
    }

    function poolFeeShareBpsExternal() external view returns (uint16) {
        return s().poolFeeShareBps;
    }

    function mintBurnFeeIndexShareBpsExternal() external view returns (uint16) {
        return s().mintBurnFeeIndexShareBps;
    }
}

contract EqualIndexFlashLoanReceiverPreservation is IEqualIndexFlashReceiver {
    function onEqualIndexFlashLoan(
        uint256,
        uint256,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata
    ) external {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            IERC20(assets[i]).transfer(msg.sender, amounts[i] + feeAmounts[i]);
        }
    }
}

contract EqualIndexLaunchTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function test_WalletMode_MintBurn_RoutesFeesOnLiveDiamond() public {
        eve.mint(alice, 100e18);
        eve.mint(bob, 30e18);

        uint256 depositorPositionId = _mintPosition(alice, 1);
        vm.startPrank(alice);
        eve.approve(diamond, 100e18);
        PositionManagementFacet(diamond).depositToPosition(depositorPositionId, 1, 100e18, 100e18);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Wallet Index", "WIDX", address(eve), 1000, 1000));

        vm.startPrank(bob);
        eve.approve(diamond, 30e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        EqualIndexActionsFacetV3(diamond).burn(indexId, 10e18, bob);
        vm.stopPrank();

        assertEq(ERC20(indexToken).balanceOf(bob), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
        assertGt(PositionManagementFacet(diamond).previewPositionYield(depositorPositionId, 1), 0);
        assertGt(eve.balanceOf(treasury), 0);
    }

    function test_PositionMode_MintBurn_PreservesLivePositionAccounting() public {
        eve.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Position Index", "PIDX", address(eve), 1000, 1000));

        vm.prank(alice);
        uint256 minted = EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 50e18);
        assertEq(minted, 50e18);
        assertEq(ERC20(indexToken).balanceOf(diamond), 50e18);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(positionId, indexId, 50e18);

        assertEq(ERC20(indexToken).balanceOf(diamond), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
    }

    function test_WalletMode_MintPreservesExactInputPull() public {
        eve.mint(bob, 10e18);

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Exact Wallet", "EWLT", address(eve), 0, 0));

        uint256 bobBefore = eve.balanceOf(bob);
        uint256 diamondBefore = eve.balanceOf(diamond);

        vm.startPrank(bob);
        eve.approve(diamond, 10e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();

        assertEq(eve.balanceOf(bob), bobBefore - 10e18);
        assertEq(eve.balanceOf(diamond), diamondBefore + 10e18);
        assertEq(ERC20(EqualIndexAdminFacetV3(diamond).getIndex(indexId).token).balanceOf(bob), 10e18);
    }

    function test_AdminPausePreservesAuthorizedTimelockAccess() public {
        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Pauseable", "PAUSE", address(eve), 0, 0));

        _timelockCall(diamond, abi.encodeWithSelector(EqualIndexAdminFacetV3.setPaused.selector, indexId, true));
        assertTrue(EqualIndexAdminFacetV3(diamond).getIndex(indexId).paused);

        _timelockCall(diamond, abi.encodeWithSelector(EqualIndexAdminFacetV3.setPaused.selector, indexId, false));
        assertTrue(!EqualIndexAdminFacetV3(diamond).getIndex(indexId).paused);
    }

    function test_IndexFlashLoanPreservesVaultAndFeePotAccounting() public {
        EqualIndexBaseV3.CreateIndexParams memory params;
        params.name = "Flash Preserve";
        params.symbol = "FPRE";
        params.assets = new address[](2);
        params.assets[0] = address(eve);
        params.assets[1] = address(alt);
        params.bundleAmounts = new uint256[](2);
        params.bundleAmounts[0] = 1e18;
        params.bundleAmounts[1] = 2e18;
        params.mintFeeBps = new uint16[](2);
        params.burnFeeBps = new uint16[](2);
        params.flashFeeBps = 50;

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

        (uint256 indexId,) = _createIndexThroughTimelock(params);

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

        uint256 eveVaultBefore = EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(eve));
        uint256 altVaultBefore = EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(alt));
        uint256 evePotBefore = EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(eve));
        uint256 altPotBefore = EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(alt));

        uint256 eveFee = Math.mulDiv(5e18, params.flashFeeBps, 10_000);
        uint256 altFee = Math.mulDiv(10e18, params.flashFeeBps, 10_000);
        uint256 evePotFee = eveFee - Math.mulDiv(eveFee, 1000, 10_000);
        uint256 altPotFee = altFee - Math.mulDiv(altFee, 1000, 10_000);

        EqualIndexFlashLoanReceiverPreservation receiver = new EqualIndexFlashLoanReceiverPreservation();
        eve.mint(address(receiver), eveFee);
        alt.mint(address(receiver), altFee);

        vm.prank(carol);
        EqualIndexActionsFacetV3(diamond).flashLoan(indexId, 5e18, address(receiver), bytes(""));

        assertEq(EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(eve)), eveVaultBefore);
        assertEq(EqualIndexAdminFacetV3(diamond).getVaultBalance(indexId, address(alt)), altVaultBefore);
        assertEq(EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(eve)), evePotBefore + evePotFee);
        assertEq(EqualIndexAdminFacetV3(diamond).getFeePot(indexId, address(alt)), altPotBefore + altPotFee);
    }

    function test_BugCondition_WalletBurnFeeRounding_ShouldRoundUp() public {
        eve.mint(bob, 1);
        EqualIndexBaseV3.CreateIndexParams memory params =
            _singleAssetIndexParams("Round Wallet", "RWLT", address(eve), 0, 333);
        params.bundleAmounts[0] = 1;
        (uint256 indexId,) = _createIndexThroughTimelock(params);

        vm.startPrank(bob);
        eve.approve(diamond, 1);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 1;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 1e18, bob, maxInputs);
        uint256[] memory assetsOut = EqualIndexActionsFacetV3(diamond).burn(indexId, 1e18, bob);
        vm.stopPrank();

        assertEq(assetsOut[0], 0);
    }

    function test_BugCondition_FeeShareSetter_ShouldUpdateConfiguredValues() public {
        EqualIndexAdminHarness harness = new EqualIndexAdminHarness();
        harness.setOwner(address(this));
        address timelock = _addr("timelock");
        harness.setTimelock(timelock);

        vm.prank(timelock);
        (bool poolOk,) = address(harness).call(
            abi.encodeWithSignature("setEqualIndexPoolFeeShareBps(uint16)", uint16(2000))
        );
        assertTrue(poolOk);
        assertEq(uint256(harness.poolFeeShareBpsExternal()), 2000);

        vm.prank(timelock);
        (bool indexOk,) = address(harness).call(
            abi.encodeWithSignature("setEqualIndexMintBurnFeeIndexShareBps(uint16)", uint16(5000))
        );
        assertTrue(indexOk);
        assertEq(uint256(harness.mintBurnFeeIndexShareBpsExternal()), 5000);
    }

    function test_BugCondition_TimelockFallback_ShouldAllowOwnerWhenUnset() public {
        EqualIndexAdminHarness harness = new EqualIndexAdminHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(0));

        MockERC20Launch local = new MockERC20Launch("Local EVE", "LEVE");
        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees = _actionFees();
        harness.setDefaultPoolConfig(cfg);
        harness.initPoolWithActionFees(1, address(local), cfg, actionFees);

        EqualIndexBaseV3.CreateIndexParams memory params =
            _singleAssetIndexParams("Fallback", "FALL", address(local), 0, 0);
        (uint256 indexId,) = harness.createIndex(params);

        harness.setPaused(indexId, true);

        assertTrue(harness.getIndex(indexId).paused);
    }

    function test_BugCondition_RecoveryGrace_ShouldBlockImmediateRecovery() public {
        eve.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Grace Index", "GRACE", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 2e18);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(positionId, indexId, 1e18, 1 days);
        uint40 maturity = EqualIndexLendingFacet(diamond).getLoan(loanId).maturity;

        vm.warp(uint256(maturity) + 1);
        vm.expectRevert(abi.encodeWithSelector(LibEqualIndexLending.LoanNotExpired.selector, loanId, maturity));
        EqualIndexLendingFacet(diamond).recoverExpiredIndexLoan(loanId);

        vm.warp(uint256(maturity) + 1 hours + 1);
        EqualIndexLendingFacet(diamond).recoverExpiredIndexLoan(loanId);

        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
    }

    function test_MaintenanceExemptLockedCollateral_RecoveryExplorationBaseline() public {
        eve.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId,) = _createIndexThroughTimelock(
            _singleAssetIndexParams("Maintenance Index", "MAIN", address(eve), 0, 0)
        );
        uint256 indexPoolId = EqualIndexAdminFacetV3(diamond).getIndexPoolId(indexId);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 2e18);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(positionId, indexId, 1e18, 1 days);

        vm.warp(block.timestamp + 36500 days);
        EqualIndexLendingFacet(diamond).recoverExpiredIndexLoan(loanId);

        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, 0);
    }

    function test_BugCondition_ExactPullMint_ShouldOnlyTransferQuotedInput() public {
        MockERC20Launch exact = new MockERC20Launch("Exact", "EXACT");
        _initPoolWithActionFees(7, address(exact), _poolConfig(), _actionFees());

        EqualIndexBaseV3.CreateIndexParams memory params =
            _singleAssetIndexParams("Exact Pull", "XPULL", address(exact), 0, 0);
        params.bundleAmounts[0] = 1;
        (uint256 indexId,) = _createIndexThroughTimelock(params);

        exact.mint(bob, 2);
        uint256 diamondBefore = exact.balanceOf(diamond);

        vm.startPrank(bob);
        exact.approve(diamond, 2);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 2;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 1e18, bob, maxInputs);
        vm.stopPrank();

        assertEq(exact.balanceOf(diamond) - diamondBefore, 1);
    }

    function test_BugCondition_PositionMintFeeRouting_ShouldSucceedWithLowTrackedBalance() public {
        eve.mint(alice, 2e18);
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        vm.startPrank(alice);
        eve.approve(diamond, 2e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 2e18, 2e18);
        vm.stopPrank();

        EqualIndexBaseV3.CreateIndexParams memory params =
            _singleAssetIndexParams("Fee Route", "FROUTE", address(eve), 1000, 0);
        _createIndexThroughTimelock(params);

        testSupport.setPoolTrackedBalance(1, 0);
        assertEq(testSupport.principalOf(1, positionKey), 2e18);

        vm.prank(alice);
        uint256 minted = EqualIndexPositionFacet(diamond).mintFromPosition(positionId, 0, 1e18);

        assertEq(minted, 1e18);
    }

    function test_EqualIndexWalletAndPositionFlows_RunWithoutSingletonProductBundle() public {
        eve.mint(alice, 200e18);
        eve.mint(bob, 30e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Equal EVE", "QEVE", address(eve), 1000, 1000));

        assertTrue(indexToken != address(0));

        vm.startPrank(bob);
        eve.approve(diamond, 30e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        EqualIndexActionsFacetV3(diamond).burn(indexId, 10e18, bob);
        vm.stopPrank();

        vm.prank(alice);
        uint256 minted = EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 50e18);
        assertEq(minted, 50e18);
        assertEq(ERC20(indexToken).balanceOf(diamond), 50e18);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(positionId, indexId, 50e18);

        assertEq(ERC20(indexToken).balanceOf(bob), 0);
        assertEq(ERC20(indexToken).balanceOf(diamond), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
    }

    function test_EqualIndexLending_BorrowAndRepay_WorksOnLiveDiamond() public {
        eve.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Lending Index", "LIDX", address(eve), 0, 0));
        uint256 indexPoolId = EqualIndexAdminFacetV3(diamond).getIndexPoolId(indexId);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 2e18);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(positionId, indexId, 1e18, 7 days);

        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(indexId, address(eve)), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 1e18);
        assertEq(testSupport.indexEncumberedOf(positionNft.getPositionKey(positionId), indexPoolId), 1e18);
        assertEq(testSupport.indexEncumberedForIndex(positionNft.getPositionKey(positionId), indexPoolId, indexId), 1e18);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, 1e18);

        vm.startPrank(alice);
        eve.approve(diamond, 1e18);
        EqualIndexLendingFacet(diamond).repayFromPosition(positionId, loanId);
        vm.stopPrank();

        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 0);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(indexId, address(eve)), 0);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
        assertEq(testSupport.indexEncumberedOf(positionNft.getPositionKey(positionId), indexPoolId), 0);
        assertEq(testSupport.indexEncumberedForIndex(positionNft.getPositionKey(positionId), indexPoolId, indexId), 0);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, 0);
    }

    function test_EqualIndexLending_ExpiredRecovery_ClearsNativeIndexEncumbrance_OnLiveDiamond() public {
        eve.mint(alice, 200e18);
        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Recover Lending Index", "RLX", address(eve), 0, 0));
        uint256 indexPoolId = EqualIndexAdminFacetV3(diamond).getIndexPoolId(indexId);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 2e18);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(positionId, indexId, 1e18, 1 days);

        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 1e18);
        assertEq(testSupport.indexEncumberedOf(positionKey, indexPoolId), 1e18);
        assertEq(testSupport.indexEncumberedForIndex(positionKey, indexPoolId, indexId), 1e18);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, 1e18);

        vm.warp(block.timestamp + 2 days);
        EqualIndexLendingFacet(diamond).recoverExpiredIndexLoan(loanId);

        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 0);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(indexId, address(eve)), 0);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 1e18);
        assertEq(testSupport.indexEncumberedOf(positionKey, indexPoolId), 0);
        assertEq(testSupport.indexEncumberedForIndex(positionKey, indexPoolId, indexId), 0);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, 0);
    }

    function test_EqualIndexRewards_WalletHeldUnitsDoNotEarnButPositionHeldUnitsDo() public {
        eve.mint(alice, 40e18);
        eve.mint(bob, 20e18);

        uint256 bobEmptyPositionId = _mintPosition(bob, 1);
        uint256 alicePositionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 40e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 40e18, 40e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Reward Index", "RIDX", address(eve), 0, 0));

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 10e18, 0, 0, true);
        alt.mint(address(this), 200e18);
        _fundRewardProgram(address(this), programId, alt, 100e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 0);

        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "nothing claimable"));
        EdenRewardsFacet(diamond).claimRewardProgram(programId, bobEmptyPositionId, bob);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        (, state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 10e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);

        assertEq(claimed, 100e18);
        assertEq(alt.balanceOf(alice), 100e18);
        assertEq(ERC20(EqualIndexAdminFacetV3(diamond).getIndex(indexId).token).balanceOf(bob), 10e18);
    }

    function test_EqualIndexRewards_MintFromPositionSettlesBeforeBalanceIncrease() public {
        eve.mint(alice, 20e18);
        eve.mint(bob, 20e18);
        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Mint Reward Index", "MRI", address(eve), 0, 0));

        vm.prank(bob);
        EqualIndexPositionFacet(diamond).mintFromPosition(bobPositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 20e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);

        assertEq(aliceClaimed, 150e18);
        assertEq(bobClaimed, 450e18);
    }

    function test_EqualIndexRewards_BurnFromPositionSettlesBeforeBalanceDecrease() public {
        eve.mint(alice, 20e18);
        eve.mint(bob, 20e18);
        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Burn Reward Index", "BRI", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 10e18);
        vm.prank(bob);
        EqualIndexPositionFacet(diamond).mintFromPosition(bobPositionId, indexId, 10e18);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(alicePositionId, indexId, 5e18);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 15e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);

        assertEq(aliceClaimed, 250e18);
        assertEq(bobClaimed, 350e18);
    }

    function test_EqualIndexRewards_RecoverySettlesBeforePrincipalWriteDown() public {
        eve.mint(alice, 20e18);
        eve.mint(bob, 10e18);
        uint256 alicePositionId = _mintPosition(alice, 1);
        uint256 bobPositionId = _mintPosition(bob, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 20e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 20e18, 20e18);
        vm.stopPrank();

        vm.startPrank(bob);
        eve.approve(diamond, 10e18);
        PositionManagementFacet(diamond).depositToPosition(bobPositionId, 1, 10e18, 10e18);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Recover Reward Index", "RRI", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, indexId, 2e18);
        vm.prank(bob);
        EqualIndexPositionFacet(diamond).mintFromPosition(bobPositionId, indexId, 1e18);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 0, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(alicePositionId, indexId, 1e18, 1 days);

        uint256 programId = _createEqualIndexRewardProgram(indexId, address(alt), address(this), 30e18, 0, 0, true);
        alt.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), programId, alt, 1_000e18);

        vm.warp(block.timestamp + 10);
        EqualIndexLendingFacet(diamond).recoverExpiredIndexLoan(loanId);

        (, LibEdenRewardsStorage.RewardProgramState memory state) = EdenRewardsFacet(diamond).getRewardProgram(programId);
        assertEq(state.eligibleSupply, 2e18);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 aliceClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, alicePositionId, alice);
        vm.prank(bob);
        uint256 bobClaimed = EdenRewardsFacet(diamond).claimRewardProgram(programId, bobPositionId, bob);

        assertEq(aliceClaimed, 350e18);
        assertEq(bobClaimed, 250e18);
    }

    function test_EqualIndexRewards_TargetScopedDiscoveryAndPreviewMatchClaims() public {
        eve.mint(alice, 40e18);
        uint256 alicePositionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 40e18);
        PositionManagementFacet(diamond).depositToPosition(alicePositionId, 1, 40e18, 40e18);
        vm.stopPrank();

        (uint256 targetIndexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Target Reward Index", "TRI", address(eve), 0, 0));
        (uint256 otherIndexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Other Reward Index", "ORI", address(eve), 0, 0));

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(alicePositionId, targetIndexId, 10e18);

        uint256 targetProgramA =
            _createEqualIndexRewardProgram(targetIndexId, address(alt), address(this), 10e18, 0, 0, true);
        uint256 targetProgramB =
            _createEqualIndexRewardProgram(targetIndexId, address(eve), address(this), 20e18, 0, 0, true);
        uint256 otherProgram =
            _createEqualIndexRewardProgram(otherIndexId, address(alt), address(this), 30e18, 0, 0, true);

        alt.mint(address(this), 1_000e18);
        eve.mint(address(this), 1_000e18);
        _fundRewardProgram(address(this), targetProgramA, alt, 500e18);
        _fundRewardProgram(address(this), targetProgramB, eve, 500e18);
        _fundRewardProgram(address(this), otherProgram, alt, 500e18);

        vm.warp(block.timestamp + 10);

        uint256[] memory targetProgramIds = EdenRewardsFacet(diamond).getRewardProgramIdsByTarget(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, targetIndexId
        );
        assertEq(targetProgramIds.length, 2);
        assertEq(targetProgramIds[0], targetProgramA);
        assertEq(targetProgramIds[1], targetProgramB);

        uint256[] memory otherProgramIds = EdenRewardsFacet(diamond).getRewardProgramIdsByTarget(
            LibEdenRewardsStorage.RewardTargetType.EQUAL_INDEX_POSITION, otherIndexId
        );
        assertEq(otherProgramIds.length, 1);
        assertEq(otherProgramIds[0], otherProgram);

        (EdenRewardsFacet.RewardProgramClaimPreview[] memory previews, uint256 totalClaimable) =
            EdenRewardsFacet(diamond).previewRewardProgramsForPosition(alicePositionId, targetProgramIds);

        assertEq(previews.length, 2);
        assertEq(previews[0].programId, targetProgramA);
        assertEq(previews[0].rewardToken, address(alt));
        assertEq(previews[0].claimableRewards, 100e18);
        assertEq(previews[1].programId, targetProgramB);
        assertEq(previews[1].rewardToken, address(eve));
        assertEq(previews[1].claimableRewards, 200e18);
        assertEq(totalClaimable, 300e18);

        vm.startPrank(alice);
        uint256 claimedA = EdenRewardsFacet(diamond).claimRewardProgram(targetProgramA, alicePositionId, alice);
        uint256 claimedB = EdenRewardsFacet(diamond).claimRewardProgram(targetProgramB, alicePositionId, alice);
        vm.stopPrank();

        assertEq(claimedA + claimedB, totalClaimable);
        assertEq(alt.balanceOf(alice), claimedA);
        assertEq(eve.balanceOf(alice), claimedB);
    }

    function test_CreateIndex_RevertsForInvalidDefinitionsAndMissingPoolsOnLiveDiamond() public {
        EqualIndexBaseV3.CreateIndexParams memory badLengths = _singleAssetIndexParams("Bad", "BAD", address(eve), 0, 0);
        badLengths.bundleAmounts = new uint256[](0);
        _scheduleCreateIndexExpectRevert(
            badLengths, keccak256("bad-length-index"), abi.encodeWithSelector(InvalidArrayLength.selector)
        );

        EqualIndexBaseV3.CreateIndexParams memory duplicateAssets =
            _singleAssetIndexParams("Dup", "DUP", address(eve), 0, 0);
        duplicateAssets.assets = new address[](2);
        duplicateAssets.assets[0] = address(eve);
        duplicateAssets.assets[1] = address(eve);
        duplicateAssets.bundleAmounts = new uint256[](2);
        duplicateAssets.bundleAmounts[0] = 1e18;
        duplicateAssets.bundleAmounts[1] = 1e18;
        duplicateAssets.mintFeeBps = new uint16[](2);
        duplicateAssets.burnFeeBps = new uint16[](2);
        _scheduleCreateIndexExpectRevert(
            duplicateAssets,
            keccak256("duplicate-assets-index"),
            abi.encodeWithSelector(InvalidBundleDefinition.selector)
        );

        MockERC20Launch missing = new MockERC20Launch("Missing", "MISS");
        EqualIndexBaseV3.CreateIndexParams memory missingPool =
            _singleAssetIndexParams("Missing", "MISS", address(missing), 0, 0);
        _scheduleCreateIndexExpectRevert(
            missingPool,
            keccak256("missing-pool-index"),
            abi.encodeWithSelector(NoPoolForAsset.selector, address(missing))
        );
    }

    function test_EqualIndex_RevertsForCanonicalDuplicatePausedIndexAndInvalidMintInputsOnLiveDiamond() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalPoolAlreadyInitialized.selector, address(eve), 1));
        PoolManagementFacet(diamond).initPool(address(eve));

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Guarded", "GRD", address(eve), 1000, 0));

        eve.mint(bob, 50e18);
        vm.startPrank(bob);
        eve.approve(diamond, 50e18);

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        vm.expectRevert(abi.encodeWithSelector(InvalidUnits.selector));
        EqualIndexActionsFacetV3(diamond).mint(indexId, 0, bob, maxInputs);

        maxInputs[0] = 10e18;
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InvalidMax.selector, 10e18, 11e18));
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();

        _timelockCall(diamond, abi.encodeWithSelector(EqualIndexAdminFacetV3.setPaused.selector, indexId, true));

        vm.startPrank(bob);
        maxInputs[0] = 11e18;
        vm.expectRevert(abi.encodeWithSelector(IndexPaused.selector, indexId));
        EqualIndexActionsFacetV3(diamond).mint(indexId, 10e18, bob, maxInputs);
        vm.stopPrank();
    }

    function _scheduleCreateIndexExpectRevert(
        EqualIndexBaseV3.CreateIndexParams memory params,
        bytes32 salt,
        bytes memory expectedRevert
    ) internal {
        bytes memory data = abi.encodeWithSelector(EqualIndexAdminFacetV3.createIndex.selector, params);
        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(expectedRevert);
        timelockController.execute(diamond, 0, data, bytes32(0), salt);
    }
}
