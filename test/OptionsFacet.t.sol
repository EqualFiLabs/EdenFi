// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibOptionsStorage} from "src/libraries/LibOptionsStorage.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {PoolMembershipRequired} from "src/libraries/Errors.sol";
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
    uint256 internal constant STRIKE_PRICE = 2e18;
    uint256 internal constant BASE_CONTRACT_SIZE = 1;

    OptionToken internal optionToken;
    MockERC20Option internal sixDecStrike;
    address internal operator;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePoolsWithFoT();
        _installTestSupportFacet();

        sixDecStrike = new MockERC20Option("Strike Six", "SIX", 6);
        _initPoolWithActionFees(SIX_DEC_PID, address(sixDecStrike), _sixDecPoolConfig(), _actionFees());

        optionToken = OptionToken(OptionTokenViewFacet(diamond).getOptionToken());
        operator = _addr("operator");
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
}
