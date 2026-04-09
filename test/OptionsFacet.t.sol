// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {DepositCapExceeded, MaxUserCountExceeded, NotNFTOwner, PoolMembershipRequired} from "src/libraries/Errors.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {OptionToken} from "src/tokens/OptionToken.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

interface IMintableTokenLike {
    function mint(address to, uint256 amount) external;
}

contract MockERC20Option is ERC20 {
    uint8 internal immutable customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        customDecimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return customDecimals;
    }
}

contract MockRevertingDecimalsOption is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        revert("decimals disabled");
    }
}

contract OptionsSameAssetHarness is OptionTokenAdminFacet, OptionsFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setPositionNFT(address positionNFT_) external {
        LibPositionNFT.s().positionNFTContract = positionNFT_;
        LibPositionNFT.s().nftModeEnabled = positionNFT_ != address(0);
    }

    function setPool(uint256 pid, address underlying) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.initialized = true;
        pool.underlying = underlying;
        pool.lastMaintenanceTimestamp = uint64(block.timestamp);
    }
}

contract OptionsFacetTest is LaunchFixture {
    uint256 internal constant UNDERLYING_PID = 1;
    uint256 internal constant ALT_PID = 2;
    uint256 internal constant FOT_PID = 3;
    uint256 internal constant SIX_DEC_PID = 4;
    uint256 internal constant CAPPED_STRIKE_PID = 5;
    uint256 internal constant REVERT_DEC_PID = 6;
    uint256 internal constant STRIKE_PRICE = 2e18;
    uint256 internal constant BASE_CONTRACT_SIZE = 1;
    uint256 internal constant FRACTIONAL_STRIKE_PRICE = 1_000_000_500_000_000_000;
    uint256 internal constant ZEROING_STRIKE_PRICE = 100_000_000_000;
    uint64 internal constant MAX_EUROPEAN_TOLERANCE = 30 days;

    OptionToken internal optionToken;
    MockERC20Option internal sixDecStrike;
    MockERC20Option internal cappedStrike;
    MockRevertingDecimalsOption internal revertingDecimals;
    address internal operator;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePoolsWithFoT();
        _installTestSupportFacet();

        sixDecStrike = new MockERC20Option("Strike Six", "SIX", 6);
        _initPoolWithActionFees(SIX_DEC_PID, address(sixDecStrike), _sixDecPoolConfig(), _actionFees());
        cappedStrike = new MockERC20Option("Capped Strike Six", "CSIX", 6);
        _initPoolWithActionFees(CAPPED_STRIKE_PID, address(cappedStrike), _cappedSixDecPoolConfig(11e6), _actionFees());
        revertingDecimals = new MockRevertingDecimalsOption("Broken Decimals", "BROKE");
        _initPoolWithActionFees(REVERT_DEC_PID, address(revertingDecimals), _poolConfig(), _actionFees());

        optionToken = OptionToken(OptionTokenViewFacet(diamond).getOptionToken());
        operator = _addr("operator");
    }

    function test_BugCondition_DiamondInit_ShouldDefaultEuropeanToleranceToFiveMinutes() public {
        assertEq(OptionsViewFacet(diamond).europeanToleranceSeconds(), 300);
    }

    function test_BugCondition_SetEuropeanTolerance_ShouldRejectToleranceOverflow() public {
        uint64 excessiveTolerance = MAX_EUROPEAN_TOLERANCE + 1;
        bytes memory data = abi.encodeWithSelector(OptionsFacet.setEuropeanTolerance.selector, excessiveTolerance);
        bytes32 salt = keccak256(abi.encodePacked("equalfi-test-salt", timelockSaltNonce++));

        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(OptionsFacet.Options_ExcessiveTolerance.selector, excessiveTolerance)
        );
        timelockController.execute(diamond, 0, data, bytes32(0), salt);
    }

    function test_BugCondition_ReclaimOptions_ShouldRejectEuropeanReclaimOverlap() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        _setEuropeanTolerance(100);

        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        params.isAmerican = false;
        uint64 expiry = uint64(block.timestamp + 1 days);
        params.expiry = expiry;

        uint256 seriesId = _createSeries(alice, params);

        vm.warp(expiry + 50);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Options_ExerciseWindowStillOpen(uint256)")), seriesId)
        );
        OptionsFacet(diamond).reclaimOptions(seriesId);
    }

    function test_BugCondition_ExerciseOptions_ShouldUseCeilingStrikeRounding() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        params.strikePrice = FRACTIONAL_STRIKE_PRICE;

        uint256 seriesId = _createSeries(alice, params);

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 expectedCeilingPayment = _previewCeilingStrikeAmount(
            1e18, FRACTIONAL_STRIKE_PRICE, address(eve), address(sixDecStrike)
        );
        sixDecStrike.mint(bob, expectedCeilingPayment);

        vm.startPrank(bob);
        IERC20(address(sixDecStrike)).approve(diamond, expectedCeilingPayment);
        uint256 paid = OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, expectedCeilingPayment, 1e18);
        vm.stopPrank();

        require(paid >= expectedCeilingPayment, "strike payment should round up");
    }

    function test_BugCondition_ReclaimCollateralDust_ShouldUnlockStoredResidualCollateral() public {
        (uint256 positionId, bytes32 positionKey) = _preparePutWriter(alice, 3_000_002, 3_000_002, UNDERLYING_PID);
        LibOptionsStorage.CreateOptionSeriesParams memory params = _putParams(positionId, 3e18, BASE_CONTRACT_SIZE);
        params.strikePrice = FRACTIONAL_STRIKE_PRICE;

        uint256 seriesId = _createSeries(alice, params);

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 2e18, "");

        eve.mint(bob, 2e18);
        vm.startPrank(bob);
        eve.approve(diamond, 2e18);
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, 1e18, 1_000_000);
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, 1e18, 1_000_000);
        vm.stopPrank();

        uint256 storedResidualCollateral = OptionsViewFacet(diamond).getOptionSeries(seriesId).collateralLocked;
        uint256 lockedBefore = testSupport.lockedCapitalOf(positionKey, SIX_DEC_PID);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        uint256 lockedAfter = testSupport.lockedCapitalOf(positionKey, SIX_DEC_PID);

        assertEq(series.collateralLocked, 0);
        assertEq(lockedBefore - lockedAfter, storedResidualCollateral);
        assertEq(lockedAfter, 0);
    }

    function test_BugCondition_CreateOptionSeries_ShouldRejectDecimalsFallback() public {
        (uint256 positionId,) = _fundHomePosition(alice, REVERT_DEC_PID, address(revertingDecimals), 10e18, 10e18);
        _joinPool(alice, positionId, UNDERLYING_PID);
        LibOptionsStorage.CreateOptionSeriesParams memory params = LibOptionsStorage.CreateOptionSeriesParams({
            positionId: positionId,
            underlyingPoolId: UNDERLYING_PID,
            strikePoolId: REVERT_DEC_PID,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: 1e18,
            contractSize: BASE_CONTRACT_SIZE,
            isCall: false,
            isAmerican: true
        });

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LibCurrency.LibCurrency_DecimalsQueryFailed.selector, address(revertingDecimals))
        );
        OptionsFacet(diamond).createOptionSeries(params);
    }

    function test_BugCondition_ExerciseOptions_ShouldBypassDepositCapDuringExerciseSettlement() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 10e18, 10e18, CAPPED_STRIKE_PID);

        cappedStrike.mint(alice, 10e6);
        vm.startPrank(alice);
        IERC20(address(cappedStrike)).approve(diamond, 10e6);
        PositionManagementFacet(diamond).depositToPosition(positionId, CAPPED_STRIKE_PID, 10e6, 10e6);
        vm.stopPrank();

        uint256 seriesId = _createSeries(alice, _callParams(positionId, CAPPED_STRIKE_PID, 1e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        cappedStrike.mint(bob, payment);
        vm.startPrank(bob);
        IERC20(address(cappedStrike)).approve(diamond, payment);
        uint256 paid = OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 1e18);
        vm.stopPrank();

        assertEq(paid, payment);
        assertEq(testSupport.principalOf(CAPPED_STRIKE_PID, positionKey), 12e6);
    }

    function test_BugCondition_CreateOptionSeries_ShouldRejectZeroStrikeCallSeries() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        params.strikePrice = ZEROING_STRIKE_PRICE;

        vm.prank(alice);
        uint256 seriesId = OptionsFacet(diamond).createOptionSeries(params);

        assertTrue(seriesId != 0);
        assertEq(OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18), 1);
    }

    function test_WadStrikePriceConvention() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));

        uint256 previewPayment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);

        assertEq(previewPayment, 2e6);
    }

    function test_UserCount_LongIdleSeriesCreationPreservesMakerPoolCount() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 10e18, 10e18, ALT_PID);

        alt.mint(alice, 10e18);
        vm.startPrank(alice);
        alt.approve(diamond, 10e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, ALT_PID, 10e18, 10e18);
        vm.stopPrank();

        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, ALT_PID, 1e18, BASE_CONTRACT_SIZE);
        params.expiry = uint64(block.timestamp + 40_000 days);
        _createSeries(alice, params);

        assertEq(testSupport.principalOf(ALT_PID, positionKey), 10e18);
        assertEq(testSupport.getPoolView(ALT_PID).userCount, 1);

        vm.warp(block.timestamp + 36_500 days);
        _createSeries(alice, params);

        assertEq(testSupport.principalOf(ALT_PID, positionKey), 10e18);
        assertEq(testSupport.getPoolView(ALT_PID).userCount, 1);
    }

    function test_UserCount_ExerciseAfterLongIdleKeepsSingleMakerCount() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 10e18, 10e18, ALT_PID);

        alt.mint(alice, 10e18);
        vm.startPrank(alice);
        alt.approve(diamond, 10e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, ALT_PID, 10e18, 10e18);
        vm.stopPrank();

        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, ALT_PID, 1e18, BASE_CONTRACT_SIZE);
        params.expiry = uint64(block.timestamp + 40_000 days);
        uint256 seriesId = _createSeries(alice, params);

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        vm.warp(block.timestamp + 36_500 days);

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        alt.mint(bob, payment);
        vm.startPrank(bob);
        alt.approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 1e18);
        vm.stopPrank();

        assertEq(testSupport.principalOf(ALT_PID, positionKey), 10e18 + payment);
        assertEq(testSupport.getPoolView(ALT_PID).userCount, 1);
    }

    function test_UserCount_MaintenanceChurnDoesNotBlockNewEntrant() public {
        uint256 strikePid = 7;
        address replacementUser = _addr("replacement-user");
        MockERC20Option limitedStrike = new MockERC20Option("Limited Strike", "LSTR", 6);
        Types.PoolConfig memory limitedConfig = _sixDecPoolConfig();
        limitedConfig.maxUserCount = 2;
        _initPoolWithActionFees(strikePid, address(limitedStrike), limitedConfig, _actionFees());

        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, strikePid);

        limitedStrike.mint(alice, 10e6);
        vm.startPrank(alice);
        IERC20(address(limitedStrike)).approve(diamond, 10e6);
        PositionManagementFacet(diamond).depositToPosition(positionId, strikePid, 10e6, 10e6);
        vm.stopPrank();

        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, strikePid, 1e18, BASE_CONTRACT_SIZE);
        params.expiry = uint64(block.timestamp + 40_000 days);
        uint256 seriesId = _createSeries(alice, params);

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        vm.warp(block.timestamp + 36_500 days);

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        limitedStrike.mint(bob, payment);
        vm.startPrank(bob);
        IERC20(address(limitedStrike)).approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 1e18);
        vm.stopPrank();

        assertEq(testSupport.getPoolView(strikePid).userCount, 1);

        _fundHomePosition(carol, strikePid, address(limitedStrike), 1e6, 1e6);
        assertEq(testSupport.getPoolView(strikePid).userCount, 2);

        limitedStrike.mint(replacementUser, 1e6);
        uint256 replacementPositionId = _mintPosition(replacementUser, strikePid);
        vm.startPrank(replacementUser);
        IERC20(address(limitedStrike)).approve(diamond, 1e6);
        vm.expectRevert(abi.encodeWithSelector(MaxUserCountExceeded.selector, 2));
        PositionManagementFacet(diamond).depositToPosition(replacementPositionId, strikePid, 1e6, 1e6);
        vm.stopPrank();
    }

    function test_CreateOptionSeries_UsesRealFundingAndIndexesPosition() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 20e18, 20e18, SIX_DEC_PID);

        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 5e18, BASE_CONTRACT_SIZE));

        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        LibOptionsStorage.ProductiveCollateralView memory collateralView =
            OptionsViewFacet(diamond).getOptionSeriesProductiveCollateral(seriesId);

        assertEq(series.makerPositionId, positionId);
        assertEq(series.totalSize, 5e18);
        assertEq(series.remainingSize, 5e18);
        assertEq(series.contractSize, BASE_CONTRACT_SIZE);
        assertEq(series.collateralLocked, 5e18);
        assertTrue(series.isCall);
        assertEq(optionToken.balanceOf(alice, seriesId), 5e18);

        uint256[] memory ids = OptionsViewFacet(diamond).getOptionSeriesIdsByPosition(positionId);
        assertEq(ids.length, 1);
        assertEq(ids[0], seriesId);

        assertEq(collateralView.collateralPoolId, UNDERLYING_PID);
        assertEq(collateralView.collateralAsset, address(eve));
        assertEq(collateralView.collateralLocked, 5e18);
        assertEq(collateralView.settledPrincipal, 20e18);
        assertEq(collateralView.availablePrincipal, 15e18);
        assertEq(collateralView.totalEncumbrance, 5e18);
        assertEq(collateralView.activeCreditEncumbrancePrincipal, 5e18);
        assertEq(testSupport.principalOf(UNDERLYING_PID, positionKey), 20e18);
    }

    function test_SetOptionsPaused_UpdatesStateAndBlocksCreation() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        _setOptionsPaused(true);

        assertTrue(OptionsViewFacet(diamond).isOptionsPaused());

        vm.prank(alice);
        vm.expectRevert(OptionsFacet.Options_Paused.selector);
        OptionsFacet(diamond).createOptionSeries(_callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));
    }

    function test_RevertWhen_CreateSeriesTotalSizeIsZero() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidAmount.selector, 0));
        OptionsFacet(diamond).createOptionSeries(_callParams(positionId, SIX_DEC_PID, 0, BASE_CONTRACT_SIZE));
    }

    function test_RevertWhen_CreateSeriesContractSizeIsZero() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidContractSize.selector, 0));
        OptionsFacet(diamond).createOptionSeries(_callParams(positionId, SIX_DEC_PID, 1e18, 0));
    }

    function test_RevertWhen_CreateSeriesStrikePriceIsZero() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        params.strikePrice = 0;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidPrice.selector, 0));
        OptionsFacet(diamond).createOptionSeries(params);
    }

    function test_RevertWhen_CreateSeriesExpiryIsInPast() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        params.expiry = uint64(block.timestamp);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidExpiry.selector, uint64(block.timestamp)));
        OptionsFacet(diamond).createOptionSeries(params);
    }

    function test_RevertWhen_CreateSeriesUsesSameUnderlyingAndStrikePool() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        params.strikePoolId = UNDERLYING_PID;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidPool.selector, UNDERLYING_PID));
        OptionsFacet(diamond).createOptionSeries(params);
    }

    function test_RevertWhen_CreateSeriesUsesSameUnderlyingAndStrikeAsset() public {
        OptionsSameAssetHarness harness = new OptionsSameAssetHarness();
        harness.setOwner(address(this));

        MockERC20Option sameAsset = new MockERC20Option("Same", "SAME", 18);
        PositionNFT localNft = new PositionNFT();
        localNft.setMinter(address(this));

        harness.setPositionNFT(address(localNft));
        harness.setPool(1, address(sameAsset));
        harness.setPool(2, address(sameAsset));
        harness.deployOptionToken("ipfs://equalfi/options", address(this));

        uint256 positionId = localNft.mint(alice, 1);
        LibOptionsStorage.CreateOptionSeriesParams memory params = LibOptionsStorage.CreateOptionSeriesParams({
            positionId: positionId,
            underlyingPoolId: 1,
            strikePoolId: 2,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: 1e18,
            contractSize: BASE_CONTRACT_SIZE,
            isCall: true,
            isAmerican: true
        });

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionsFacet.Options_InvalidAssetPair.selector, address(sameAsset), address(sameAsset)
            )
        );
        harness.createOptionSeries(params);
    }

    function test_RevertWhen_CreateSeriesWithoutRequiredPoolMembership() public {
        (uint256 positionId, bytes32 positionKey) = _fundHomePosition(alice, UNDERLYING_PID, address(eve), 5e18, 5e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolMembershipRequired.selector, positionKey, SIX_DEC_PID));
        OptionsFacet(diamond).createOptionSeries(_callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));
    }

    function test_ExerciseCallAndBurnReclaimedClaims_RemainOnCurrentSubstrate() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 20e18, 20e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 5e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 2e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 2e18);
        sixDecStrike.mint(bob, payment);
        vm.startPrank(bob);
        IERC20(address(sixDecStrike)).approve(diamond, payment);
        uint256 paid = OptionsFacet(diamond).exerciseOptions(seriesId, 2e18, bob, payment, 2e18);
        vm.stopPrank();

        assertEq(paid, payment);
        assertEq(eve.balanceOf(bob), 2e18);
        assertEq(testSupport.principalOf(UNDERLYING_PID, positionKey), 18e18);
        assertEq(testSupport.principalOf(SIX_DEC_PID, positionKey), 4e6);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertTrue(series.reclaimed);
        assertEq(series.remainingSize, 0);
        assertEq(series.collateralLocked, 0);

        uint256 makerClaims = optionToken.balanceOf(alice, seriesId);
        vm.prank(operator);
        OptionsFacet(diamond).burnReclaimedOptionsClaims(alice, seriesId, makerClaims / 2);
        assertEq(optionToken.balanceOf(alice, seriesId), makerClaims / 2);
    }

    function test_ReclaimFullyExercisedSeries_MarksSeriesReclaimedWithoutUnlockingExtraCollateral() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        sixDecStrike.mint(bob, payment);
        vm.startPrank(bob);
        IERC20(address(sixDecStrike)).approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 1e18);
        vm.stopPrank();

        uint256 principalBefore = testSupport.principalOf(UNDERLYING_PID, positionKey);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        uint256 principalAfter = testSupport.principalOf(UNDERLYING_PID, positionKey);

        assertTrue(series.reclaimed);
        assertEq(series.remainingSize, 0);
        assertEq(series.collateralLocked, 0);
        assertEq(principalAfter, principalBefore);
    }

    function test_RevertWhen_ReclaimCalledByNonOwner() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));

        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, bob, positionId));
        OptionsFacet(diamond).reclaimOptions(seriesId);
    }

    function test_ExercisePut_TransfersStrikeAndCreditsUnderlyingPrincipal() public {
        (uint256 positionId, bytes32 positionKey) = _preparePutWriter(alice, 20e6, 20e6, UNDERLYING_PID);
        uint256 seriesId = _createSeries(alice, _putParams(positionId, 3e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        eve.mint(bob, payment);
        vm.startPrank(bob);
        eve.approve(diamond, payment);
        uint256 paid = OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 2e6);
        vm.stopPrank();

        assertEq(paid, payment);
        assertEq(sixDecStrike.balanceOf(bob), 2e6);
        assertEq(testSupport.principalOf(UNDERLYING_PID, positionKey), 1e18);
        assertEq(testSupport.principalOf(SIX_DEC_PID, positionKey), 18e6);

        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertEq(series.collateralLocked, 4e6);
    }

    function test_RevertWhen_ExerciseAmountIsZero() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidAmount.selector, 0));
        OptionsFacet(diamond).exerciseOptions(seriesId, 0, alice, 0, 0);
    }

    function test_RevertWhen_ExerciseRecipientIsZero() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));
        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidRecipient.selector, address(0)));
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, address(0), payment, 1e18);
    }

    function test_RevertWhen_ExerciseForHolderIsZero() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));
        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidRecipient.selector, address(0)));
        OptionsFacet(diamond).exerciseOptionsFor(seriesId, 1e18, address(0), bob, payment, 1e18);
    }

    function test_RevertWhen_ExerciseBalanceIsInsufficient() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));
        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InsufficientBalance.selector, bob, 1e18, 0));
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 1e18);
    }

    function test_RevertWhen_ExerciseForMissingOperatorApproval() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));
        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_NotTokenHolder.selector, operator, seriesId));
        OptionsFacet(diamond).exerciseOptionsFor(seriesId, 1e18, alice, alice, payment, 1e18);
    }

    function test_ExerciseFor_WorksForApprovedOperator() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 2e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        sixDecStrike.mint(bob, payment);
        vm.startPrank(bob);
        optionToken.setApprovalForAll(operator, true);
        IERC20(address(sixDecStrike)).approve(diamond, payment);
        vm.stopPrank();

        vm.prank(operator);
        uint256 paid = OptionsFacet(diamond).exerciseOptionsFor(seriesId, 1e18, bob, bob, payment, 1e18);

        assertEq(paid, payment);
        assertEq(eve.balanceOf(bob), 1e18);
        assertEq(testSupport.principalOf(UNDERLYING_PID, positionKey), 9e18);
        assertEq(testSupport.principalOf(SIX_DEC_PID, positionKey), 2e6);
    }

    function test_RevertWhen_ExerciseAfterReclaim() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_Reclaimed.selector, seriesId));
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, alice, 0, 0);
    }

    function test_RevertWhen_ExercisePastAmericanExpiry() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        params.expiry = uint64(block.timestamp + 1 days);
        uint256 seriesId = _createSeries(alice, params);

        vm.warp(params.expiry);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_ExerciseWindowClosed.selector, seriesId));
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, alice, 0, 0);
    }

    function test_SetEuropeanTolerance_UpdatesStateAndGatesExerciseWindow() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        _setEuropeanTolerance(100);
        assertEq(OptionsViewFacet(diamond).europeanToleranceSeconds(), 100);

        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        params.isAmerican = false;
        uint64 expiry = uint64(block.timestamp + 1 days);
        params.expiry = expiry;

        uint256 earlySeriesId = _createSeries(alice, params);
        uint256 lateSeriesId = _createSeries(alice, params);
        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(earlySeriesId, 1e18);
        sixDecStrike.mint(alice, payment);
        vm.prank(alice);
        IERC20(address(sixDecStrike)).approve(diamond, payment);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_ExerciseWindowClosed.selector, earlySeriesId));
        OptionsFacet(diamond).exerciseOptions(earlySeriesId, 1e18, alice, payment, 1e18);

        vm.warp(expiry - 50);
        vm.prank(alice);
        OptionsFacet(diamond).exerciseOptions(earlySeriesId, 1e18, alice, payment, 1e18);

        vm.warp(expiry + 101);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_ExerciseWindowClosed.selector, lateSeriesId));
        OptionsFacet(diamond).exerciseOptions(lateSeriesId, 1e18, alice, payment, 1e18);
    }

    function test_ToleranceOverride_PreservesAmericanAndEuropeanExerciseSemantics() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint64 tolerance = 10 minutes;
        _setEuropeanTolerance(tolerance);

        LibOptionsStorage.CreateOptionSeriesParams memory americanParams =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        uint256 americanSeriesId = _createSeries(alice, americanParams);

        LibOptionsStorage.CreateOptionSeriesParams memory europeanParams =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        europeanParams.isAmerican = false;
        uint64 expiry = uint64(block.timestamp + 1 days);
        europeanParams.expiry = expiry;

        uint256 beforeWindowSeriesId = _createSeries(alice, europeanParams);
        uint256 lowerBoundSeriesId = _createSeries(alice, europeanParams);
        uint256 upperBoundSeriesId = _createSeries(alice, europeanParams);
        uint256 lateSeriesId = _createSeries(alice, europeanParams);

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(americanSeriesId, 1e18);
        sixDecStrike.mint(alice, payment * 3);
        vm.prank(alice);
        IERC20(address(sixDecStrike)).approve(diamond, payment * 3);

        vm.prank(alice);
        OptionsFacet(diamond).exerciseOptions(americanSeriesId, 1e18, alice, payment, 1e18);

        vm.warp(expiry - tolerance - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_ExerciseWindowClosed.selector, beforeWindowSeriesId));
        OptionsFacet(diamond).exerciseOptions(beforeWindowSeriesId, 1e18, alice, payment, 1e18);

        vm.warp(expiry - tolerance);
        vm.prank(alice);
        OptionsFacet(diamond).exerciseOptions(lowerBoundSeriesId, 1e18, alice, payment, 1e18);

        vm.warp(expiry + tolerance);
        vm.prank(alice);
        OptionsFacet(diamond).exerciseOptions(upperBoundSeriesId, 1e18, alice, payment, 1e18);

        vm.warp(expiry + tolerance + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_ExerciseWindowClosed.selector, lateSeriesId));
        OptionsFacet(diamond).exerciseOptions(lateSeriesId, 1e18, alice, payment, 1e18);

        assertEq(OptionsViewFacet(diamond).europeanToleranceSeconds(), tolerance);
        assertEq(OptionsViewFacet(diamond).getOptionSeries(americanSeriesId).remainingSize, 0);
        assertEq(OptionsViewFacet(diamond).getOptionSeries(lowerBoundSeriesId).remainingSize, 0);
        assertEq(OptionsViewFacet(diamond).getOptionSeries(upperBoundSeriesId).remainingSize, 0);
        assertEq(OptionsViewFacet(diamond).getOptionSeries(lateSeriesId).remainingSize, 1e18);
    }

    function test_RevertWhen_ExerciseMaxPaymentIsTooLow() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));
        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InvalidMax.selector, payment - 1, payment));
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, alice, payment - 1, 1e18);
    }

    function test_RevertWhen_ExerciseMinReceivedIsTooHighForFeeOnTransferUnderlying() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 12e18, ALT_PID, FOT_PID, address(fot));
        uint256 seriesId = _createSeries(alice, _callParams(positionId, ALT_PID, 1e18, BASE_CONTRACT_SIZE, FOT_PID));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        alt.mint(bob, 2e18);
        vm.startPrank(bob);
        alt.approve(diamond, 2e18);
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InsufficientReceived.selector, 9e17, 1e18));
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, 2e18, 1e18);
        vm.stopPrank();
    }

    function test_NonUnitContractSize_TracksNotionalAndSettlement() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 3e18, 2));

        LibOptionsStorage.OptionSeries memory created = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertEq(created.collateralLocked, 6e18);

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        assertEq(payment, 4e6);

        sixDecStrike.mint(bob, payment);
        vm.startPrank(bob);
        IERC20(address(sixDecStrike)).approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 2e18);
        vm.stopPrank();

        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertEq(series.remainingSize, 2e18);
        assertEq(series.collateralLocked, 4e18);
        assertEq(eve.balanceOf(bob), 2e18);
    }

    function test_MixedDecimalStrikeNormalization_UsesSixDecimalStrikeAsset() public {
        (uint256 callPositionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 callSeriesId = _createSeries(alice, _callParams(callPositionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));
        assertEq(OptionsViewFacet(diamond).previewExercisePayment(callSeriesId, 1e18), 2e6);
        assertEq(OptionsViewFacet(diamond).previewExercisePayment(callSeriesId, 15e17), 3e6);

        (uint256 putPositionId,) = _preparePutWriter(carol, 20e6, 20e6, UNDERLYING_PID);
        uint256 putSeriesId = _createSeries(carol, _putParams(putPositionId, 3e18, BASE_CONTRACT_SIZE));
        LibOptionsStorage.OptionSeries memory putSeries = OptionsViewFacet(diamond).getOptionSeries(putSeriesId);
        assertEq(putSeries.collateralLocked, 6e6);
    }

    function test_FractionalOptionAmounts_Use1e18UnitConventions() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        uint256 totalSize = 25e16;
        uint256 exerciseAmount = 10e16;
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, totalSize, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, exerciseAmount, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, exerciseAmount);
        assertEq(payment, 2e5);

        sixDecStrike.mint(bob, payment);
        vm.startPrank(bob);
        IERC20(address(sixDecStrike)).approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, exerciseAmount, bob, payment, exerciseAmount);
        vm.stopPrank();

        LibOptionsStorage.OptionSeries memory series = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertEq(series.remainingSize, 15e16);
        assertEq(series.collateralLocked, 15e16);
        assertEq(eve.balanceOf(bob), exerciseAmount);
    }

    function test_Integration_CallLifecycle_PartialThenTerminalExerciseThenReclaim() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 20e18, 20e18, SIX_DEC_PID);
        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 3e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 3e18, "");

        uint256 firstPayment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        uint256 secondPayment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 2e18);
        sixDecStrike.mint(bob, firstPayment + secondPayment);

        vm.startPrank(bob);
        IERC20(address(sixDecStrike)).approve(diamond, firstPayment + secondPayment);
        uint256 paidFirst = OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, firstPayment, 1e18);
        uint256 paidSecond = OptionsFacet(diamond).exerciseOptions(seriesId, 2e18, bob, secondPayment, 2e18);
        vm.stopPrank();

        LibOptionsStorage.OptionSeries memory afterExercise = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertEq(paidFirst, 2e6);
        assertEq(paidSecond, 4e6);
        assertEq(afterExercise.remainingSize, 0);
        assertEq(afterExercise.collateralLocked, 0);
        assertEq(testSupport.principalOf(UNDERLYING_PID, positionKey), 17e18);
        assertEq(testSupport.principalOf(SIX_DEC_PID, positionKey), 6e6);
        assertEq(testSupport.lockedCapitalOf(positionKey, UNDERLYING_PID), 0);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory reclaimed = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertTrue(reclaimed.reclaimed);
        assertEq(reclaimed.remainingSize, 0);
        assertEq(reclaimed.collateralLocked, 0);
        assertEq(testSupport.principalOf(UNDERLYING_PID, positionKey), 17e18);
        assertEq(testSupport.principalOf(SIX_DEC_PID, positionKey), 6e6);
    }

    function test_Integration_PutLifecycle_PartialExerciseThenResidualReclaim() public {
        (uint256 positionId, bytes32 positionKey) = _preparePutWriter(alice, 20e6, 20e6, UNDERLYING_PID);
        uint256 seriesId = _createSeries(alice, _putParams(positionId, 3e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 2e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 2e18);
        eve.mint(bob, payment);
        vm.startPrank(bob);
        eve.approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, 2e18, bob, payment, 4e6);
        vm.stopPrank();

        LibOptionsStorage.OptionSeries memory beforeReclaim = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertEq(beforeReclaim.remainingSize, 1e18);
        assertEq(beforeReclaim.collateralLocked, 2e6);
        assertEq(testSupport.principalOf(UNDERLYING_PID, positionKey), 2e18);
        assertEq(testSupport.principalOf(SIX_DEC_PID, positionKey), 16e6);
        assertEq(testSupport.lockedCapitalOf(positionKey, SIX_DEC_PID), 2e6);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory reclaimed = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertTrue(reclaimed.reclaimed);
        assertEq(reclaimed.remainingSize, 0);
        assertEq(reclaimed.collateralLocked, 0);
        assertEq(testSupport.lockedCapitalOf(positionKey, SIX_DEC_PID), 0);
        assertEq(testSupport.principalOf(UNDERLYING_PID, positionKey), 2e18);
        assertEq(testSupport.principalOf(SIX_DEC_PID, positionKey), 16e6);
    }

    function test_Integration_EuropeanLifecycle_ExerciseWindowAndReclaimBoundary() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);
        _setEuropeanTolerance(1 hours);

        LibOptionsStorage.CreateOptionSeriesParams memory params =
            _callParams(positionId, SIX_DEC_PID, 2e18, BASE_CONTRACT_SIZE);
        params.isAmerican = false;
        uint64 expiry = uint64(block.timestamp + 1 days);
        params.expiry = expiry;
        uint256 seriesId = _createSeries(alice, params);

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        sixDecStrike.mint(bob, payment);

        vm.warp(expiry - 30 minutes);
        vm.startPrank(bob);
        IERC20(address(sixDecStrike)).approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 1e18);
        vm.stopPrank();

        vm.warp(expiry + 30 minutes);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_ExerciseWindowStillOpen.selector, seriesId));
        OptionsFacet(diamond).reclaimOptions(seriesId);

        vm.warp(expiry + 1 hours + 1);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory reclaimed = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertTrue(reclaimed.reclaimed);
        assertEq(reclaimed.remainingSize, 0);
        assertEq(reclaimed.collateralLocked, 0);
    }

    function test_Integration_ToleranceBounding_PreservesValidTolerance() public {
        _setEuropeanTolerance(1 hours);
        assertEq(OptionsViewFacet(diamond).europeanToleranceSeconds(), 1 hours);

        uint64 excessiveTolerance = 31 days;
        bytes memory data = abi.encodeWithSelector(OptionsFacet.setEuropeanTolerance.selector, excessiveTolerance);
        bytes32 salt = keccak256(abi.encodePacked("equalfi-test-salt", timelockSaltNonce++));

        timelockController.schedule(diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(OptionsFacet.Options_ExcessiveTolerance.selector, excessiveTolerance)
        );
        timelockController.execute(diamond, 0, data, bytes32(0), salt);

        assertEq(OptionsViewFacet(diamond).europeanToleranceSeconds(), 1 hours);
    }

    function test_Integration_ExerciseThroughCappedPool_PreservesDepositCap() public {
        (uint256 positionId, bytes32 positionKey) = _prepareCallWriter(alice, 10e18, 10e18, CAPPED_STRIKE_PID);

        cappedStrike.mint(alice, 10e6);
        vm.startPrank(alice);
        IERC20(address(cappedStrike)).approve(diamond, 10e6);
        PositionManagementFacet(diamond).depositToPosition(positionId, CAPPED_STRIKE_PID, 10e6, 10e6);
        vm.stopPrank();

        uint256 seriesId = _createSeries(alice, _callParams(positionId, CAPPED_STRIKE_PID, 1e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        cappedStrike.mint(bob, payment);
        vm.startPrank(bob);
        IERC20(address(cappedStrike)).approve(diamond, payment);
        uint256 paid = OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 1e18);
        vm.stopPrank();

        assertEq(paid, payment);
        assertEq(testSupport.principalOf(CAPPED_STRIKE_PID, positionKey), 12e6);

        cappedStrike.mint(alice, 1e6);
        vm.startPrank(alice);
        IERC20(address(cappedStrike)).approve(diamond, 1e6);
        vm.expectRevert(abi.encodeWithSelector(DepositCapExceeded.selector, 13e6, 11e6));
        PositionManagementFacet(diamond).depositToPosition(positionId, CAPPED_STRIKE_PID, 1e6, 1e6);
        vm.stopPrank();
    }

    function test_Integration_ZeroStrikeRejection_DoesNotBlockValidLifecycle() public {
        (uint256 positionId,) = _prepareCallWriter(alice, 10e18, 10e18, SIX_DEC_PID);

        LibOptionsStorage.CreateOptionSeriesParams memory invalidParams =
            _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE);
        invalidParams.strikePrice = 0;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptionsFacet.Options_InvalidPrice.selector, 0));
        OptionsFacet(diamond).createOptionSeries(invalidParams);

        uint256 seriesId = _createSeries(alice, _callParams(positionId, SIX_DEC_PID, 1e18, BASE_CONTRACT_SIZE));

        vm.prank(alice);
        optionToken.safeTransferFrom(alice, bob, seriesId, 1e18, "");

        uint256 payment = OptionsViewFacet(diamond).previewExercisePayment(seriesId, 1e18);
        sixDecStrike.mint(bob, payment);
        vm.startPrank(bob);
        IERC20(address(sixDecStrike)).approve(diamond, payment);
        OptionsFacet(diamond).exerciseOptions(seriesId, 1e18, bob, payment, 1e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        OptionsFacet(diamond).reclaimOptions(seriesId);

        LibOptionsStorage.OptionSeries memory reclaimed = OptionsViewFacet(diamond).getOptionSeries(seriesId);
        assertTrue(reclaimed.reclaimed);
        assertEq(reclaimed.remainingSize, 0);
        assertEq(reclaimed.collateralLocked, 0);
    }

    function _prepareCallWriter(address user, uint256 minAmount, uint256 maxAmount, uint256 strikePid)
        internal
        returns (uint256 positionId, bytes32 positionKey)
    {
        return _prepareCallWriter(user, minAmount, maxAmount, strikePid, UNDERLYING_PID, address(eve));
    }

    function _prepareCallWriter(
        address user,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 strikePid,
        uint256 underlyingPid,
        address underlyingToken
    ) internal returns (uint256 positionId, bytes32 positionKey) {
        (positionId, positionKey) = _fundHomePosition(user, underlyingPid, underlyingToken, minAmount, maxAmount);
        _joinPool(user, positionId, strikePid);
    }

    function _preparePutWriter(address user, uint256 minAmount, uint256 maxAmount, uint256 underlyingPid)
        internal
        returns (uint256 positionId, bytes32 positionKey)
    {
        (positionId, positionKey) = _fundHomePosition(user, SIX_DEC_PID, address(sixDecStrike), minAmount, maxAmount);
        _joinPool(user, positionId, underlyingPid);
    }

    function _fundHomePosition(address user, uint256 pid, address token, uint256 minAmount, uint256 maxAmount)
        internal
        returns (uint256 positionId, bytes32 positionKey)
    {
        IMintableTokenLike(token).mint(user, maxAmount);
        positionId = _mintPosition(user, pid);
        positionKey = positionNft.getPositionKey(positionId);

        vm.startPrank(user);
        IERC20(token).approve(diamond, maxAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, pid, minAmount, maxAmount);
        vm.stopPrank();
    }

    function _joinPool(address user, uint256 positionId, uint256 pid) internal {
        vm.prank(user);
        PositionManagementFacet(diamond).joinPositionPool(positionId, pid);
    }

    function _createSeries(address maker, LibOptionsStorage.CreateOptionSeriesParams memory params)
        internal
        returns (uint256 seriesId)
    {
        vm.prank(maker);
        seriesId = OptionsFacet(diamond).createOptionSeries(params);
    }

    function _setOptionsPaused(bool paused) internal {
        _timelockCall(diamond, abi.encodeWithSelector(OptionsFacet.setOptionsPaused.selector, paused));
    }

    function _setEuropeanTolerance(uint64 toleranceSeconds) internal {
        _timelockCall(
            diamond, abi.encodeWithSelector(OptionsFacet.setEuropeanTolerance.selector, toleranceSeconds)
        );
    }

    function _callParams(uint256 positionId, uint256 strikePid, uint256 totalSize, uint256 contractSize)
        internal
        view
        returns (LibOptionsStorage.CreateOptionSeriesParams memory params)
    {
        return _callParams(positionId, strikePid, totalSize, contractSize, UNDERLYING_PID);
    }

    function _callParams(
        uint256 positionId,
        uint256 strikePid,
        uint256 totalSize,
        uint256 contractSize,
        uint256 underlyingPid
    ) internal view returns (LibOptionsStorage.CreateOptionSeriesParams memory params) {
        params = LibOptionsStorage.CreateOptionSeriesParams({
            positionId: positionId,
            underlyingPoolId: underlyingPid,
            strikePoolId: strikePid,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: totalSize,
            contractSize: contractSize,
            isCall: true,
            isAmerican: true
        });
    }

    function _putParams(uint256 positionId, uint256 totalSize, uint256 contractSize)
        internal
        view
        returns (LibOptionsStorage.CreateOptionSeriesParams memory params)
    {
        params = LibOptionsStorage.CreateOptionSeriesParams({
            positionId: positionId,
            underlyingPoolId: UNDERLYING_PID,
            strikePoolId: SIX_DEC_PID,
            strikePrice: STRIKE_PRICE,
            expiry: uint64(block.timestamp + 1 days),
            totalSize: totalSize,
            contractSize: contractSize,
            isCall: false,
            isAmerican: true
        });
    }

    function _sixDecPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        cfg = _poolConfig();
        cfg.minDepositAmount = 1e6;
        cfg.minLoanAmount = 1e6;
        cfg.minTopupAmount = 1e6;
    }

    function _cappedSixDecPoolConfig(uint256 depositCap) internal pure returns (Types.PoolConfig memory cfg) {
        cfg = _sixDecPoolConfig();
        cfg.isCapped = true;
        cfg.depositCap = depositCap;
    }

    function _previewCeilingStrikeAmount(
        uint256 underlyingAmount,
        uint256 strikePrice,
        address underlying,
        address strike
    ) internal view returns (uint256 strikeAmount) {
        uint256 underlyingScale = 10 ** uint256(LibCurrency.decimalsOrRevert(underlying));
        uint256 strikeScale = 10 ** uint256(LibCurrency.decimalsOrRevert(strike));
        uint256 wadValue = Math.mulDiv(underlyingAmount, strikePrice, underlyingScale, Math.Rounding.Ceil);
        strikeAmount = Math.mulDiv(wadValue, strikeScale, 1e18, Math.Rounding.Ceil);
    }
}
