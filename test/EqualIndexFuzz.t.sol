// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";

import {LaunchFixture} from "test/utils/LaunchFixture.t.sol";

contract EqualIndexFuzzTest is LaunchFixture {
    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        _installTestSupportFacet();
    }

    function testFuzz_EqualIndexWalletModeMintBurnRoutesFees(uint96 depositSeed, uint96 mintSeed) public {
        uint256 depositAmount = _boundUint(uint256(depositSeed), 50, 250) * 1e18;
        uint256 mintUnits = _boundUint(uint256(mintSeed), 1, 30) * 1e18;

        eve.mint(alice, depositAmount);
        eve.mint(bob, mintUnits * 3);

        uint256 positionId = _mintPosition(alice, 1);
        vm.startPrank(alice);
        eve.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, depositAmount, depositAmount);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Wallet Index", "WIDX", address(eve), 1000, 1000));

        vm.startPrank(bob);
        eve.approve(diamond, mintUnits * 3);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = mintUnits * 2;
        EqualIndexActionsFacetV3(diamond).mint(indexId, mintUnits, bob, maxInputs);
        assertEq(ERC20(indexToken).balanceOf(bob), mintUnits);
        EqualIndexActionsFacetV3(diamond).burn(indexId, mintUnits, bob);
        vm.stopPrank();

        assertEq(ERC20(indexToken).balanceOf(bob), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
        assertGt(PositionManagementFacet(diamond).previewPositionYield(positionId, 1), 0);
        assertGt(eve.balanceOf(treasury), 0);
    }

    function testFuzz_EqualIndexPositionModeMintBurnSettlesThroughPrincipal(
        uint96 depositSeed,
        uint96 mintSeed
    ) public {
        uint256 depositAmount = _boundUint(uint256(depositSeed), 20, 200) * 1e18;
        uint256 maxMintWholeUnits = (depositAmount / 1e18) * 10 / 11;
        if (maxMintWholeUnits == 0) {
            maxMintWholeUnits = 1;
        }
        uint256 mintUnits = _boundUint(uint256(mintSeed), 1, maxMintWholeUnits) * 1e18;

        eve.mint(alice, depositAmount);

        uint256 positionId = _mintPosition(alice, 1);
        vm.startPrank(alice);
        eve.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, depositAmount, depositAmount);
        vm.stopPrank();

        (uint256 indexId, address indexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Position Index", "PIDX", address(eve), 1000, 1000));

        vm.prank(alice);
        uint256 minted = EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, mintUnits);
        assertEq(minted, mintUnits);
        assertEq(ERC20(indexToken).balanceOf(diamond), mintUnits);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).burnFromPosition(positionId, indexId, mintUnits);

        assertEq(ERC20(indexToken).balanceOf(diamond), 0);
        assertEq(EqualIndexAdminFacetV3(diamond).getIndex(indexId).totalUnits, 0);
    }

    function testFuzz_EqualIndexLending_IndexEncumbranceRoundTrip(
        uint96 depositSeed,
        uint96 mintSeed,
        uint96 collateralSeed,
        bool recoverExpired
    ) public {
        uint256 depositAmount = _boundUint(uint256(depositSeed), 20, 250) * 1e18;
        uint256 mintedUnits = _boundUint(uint256(mintSeed), 2, depositAmount / 1e18) * 1e18;
        uint256 collateralUnits = _boundUint(uint256(collateralSeed), 1, mintedUnits / 1e18) * 1e18;

        eve.mint(alice, depositAmount);

        uint256 positionId = _mintPosition(alice, 1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        vm.startPrank(alice);
        eve.approve(diamond, depositAmount);
        PositionManagementFacet(diamond).depositToPosition(positionId, 1, depositAmount, depositAmount);
        vm.stopPrank();

        (uint256 indexId,) =
            _createIndexThroughTimelock(_singleAssetIndexParams("Lending Fuzz Index", "LFI", address(eve), 0, 0));
        uint256 indexPoolId = EqualIndexAdminFacetV3(diamond).getIndexPoolId(indexId);

        vm.prank(alice);
        EqualIndexPositionFacet(diamond).mintFromPosition(positionId, indexId, mintedUnits);

        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EqualIndexLendingFacet.configureLending.selector, indexId, 10_000, 1 days, 30 days
            )
        );

        vm.prank(alice);
        uint256 loanId = EqualIndexLendingFacet(diamond).borrowFromPosition(positionId, indexId, collateralUnits, 7 days);

        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, collateralUnits);
        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), collateralUnits);
        assertEq(testSupport.indexEncumberedOf(positionKey, indexPoolId), collateralUnits);
        assertEq(testSupport.indexEncumberedForIndex(positionKey, indexPoolId, indexId), collateralUnits);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, collateralUnits);

        if (recoverExpired) {
            vm.warp(block.timestamp + 8 days);
            EqualIndexLendingFacet(diamond).recoverExpiredIndexLoan(loanId);
        } else {
            vm.startPrank(alice);
            eve.approve(diamond, collateralUnits);
            EqualIndexLendingFacet(diamond).repayFromPosition(positionId, loanId);
            vm.stopPrank();
        }

        assertEq(EqualIndexLendingFacet(diamond).getLoan(loanId).collateralUnits, 0);
        assertEq(EqualIndexLendingFacet(diamond).getLockedCollateralUnits(indexId), 0);
        assertEq(testSupport.indexEncumberedOf(positionKey, indexPoolId), 0);
        assertEq(testSupport.indexEncumberedForIndex(positionKey, indexPoolId, indexId), 0);
        assertEq(testSupport.getPoolView(indexPoolId).indexEncumberedTotal, 0);
    }
}
