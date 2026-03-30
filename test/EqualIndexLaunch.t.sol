// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";
import {
    CanonicalPoolAlreadyInitialized,
    IndexPaused,
    InvalidArrayLength,
    InvalidBundleDefinition,
    InvalidUnits,
    NoPoolForAsset
} from "src/libraries/Errors.sol";

import {EdenLaunchFixture, MockERC20Launch} from "test/utils/EdenLaunchFixture.t.sol";

contract EqualIndexLaunchTest is EdenLaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
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

    function test_NonEdenEqualIndexWalletAndPositionFlows_WorkAlongsideSingletonEden() public {
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(alt)));

        eve.mint(alice, 200e18);
        eve.mint(bob, 30e18);
        uint256 positionId = _mintPosition(alice, 1);

        vm.startPrank(alice);
        eve.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, 200e18, 200e18);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Equal EVE", "QEVE", address(eve), 1000, 1000));

        assertTrue(indexToken != steveToken);
        assertEq(EdenViewFacet(diamond).getProductConfig().token, steveToken);

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
        assertEq(EdenViewFacet(diamond).getProductConfig().token, steveToken);
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

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, 2e18);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 0, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(positionId, indexId, 1e18, 7 days);

        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(indexId, address(eve)), 1e18);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 1e18);

        vm.startPrank(alice);
        eve.approve(diamond, 1e18);
        EqualIndexLendingFacet(diamond).repayFromPosition(positionId, loanId);
        vm.stopPrank();

        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 0);
        assertEq(EqualIndexLendingFacet(diamond).getOutstandingPrincipal(indexId, address(eve)), 0);
        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
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
