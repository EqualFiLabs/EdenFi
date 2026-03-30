// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {IndexToken} from "src/equalindex/IndexToken.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEqualIndexLending} from "src/libraries/LibEqualIndexLending.sol";
import {LibModuleEncumbrance} from "src/libraries/LibModuleEncumbrance.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {InvalidArrayLength, InvalidParameterRange, Unauthorized} from "src/libraries/Errors.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";

contract LocalLendingMockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualIndexLendingHarness is EqualIndexAdminFacetV3, EqualIndexPositionFacet, EqualIndexLendingFacet {
    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setTimelock(address timelock) external {
        LibAppStorage.s().timelock = timelock;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setPositionNFT(address nft) external {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        ns.positionNFTContract = nft;
        ns.nftModeEnabled = true;
    }

    function setDefaultPoolConfig() external {
        Types.PoolConfig storage cfg = LibAppStorage.s().defaultPoolConfig;
        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 10_000;
        cfg.maintenanceRateBps = 50;
        cfg.flashLoanFeeBps = 10;
        cfg.minDepositAmount = 1;
        cfg.minLoanAmount = 1;
        cfg.minTopupAmount = 1;
        cfg.aumFeeMinBps = 100;
        cfg.aumFeeMaxBps = 500;
        LibAppStorage.s().defaultPoolConfigSet = true;
    }

    function seedPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        p.feeIndex = 1e18;
        p.maintenanceIndex = 1e18;
        p.activeCreditIndex = 1e18;
        p.poolConfig.depositorLTVBps = 10_000;
        p.poolConfig.minDepositAmount = 1;
        p.poolConfig.minLoanAmount = 1;
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        LocalLendingMockERC20(underlying).mint(address(this), totalDeposits);
    }

    function setAssetToPoolId(address asset, uint256 pid) external {
        LibAppStorage.s().assetToPoolId[asset] = pid;
    }

    function setPoolPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        uint256 prev = p.userPrincipal[positionKey];
        if (principal > prev) {
            uint256 add = principal - prev;
            p.totalDeposits += add;
            p.trackedBalance += add;
            if (prev == 0) p.userCount += 1;
        } else if (principal < prev) {
            uint256 sub = prev - principal;
            p.totalDeposits -= sub;
            p.trackedBalance -= sub;
            if (principal == 0 && p.userCount > 0) p.userCount -= 1;
        }
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function joinPool(bytes32 positionKey, uint256 pid) external {
        LibPoolMembership._joinPool(positionKey, pid);
    }

    function getPoolPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function lendingEncumbered(bytes32 positionKey, uint256 poolId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, poolId, this.lendingModuleId());
    }

    function getIndexTotalUnits(uint256 indexId) external view returns (uint256) {
        return s().indexes[indexId].totalUnits;
    }

    function setVaultBalance(uint256 indexId, address asset, uint256 amount) external {
        s().vaultBalances[indexId][asset] = amount;
    }
}

contract EqualIndexLendingFacetTest is Test {
    address internal constant BORROWER = address(0xB22);
    address internal constant TIMELOCK = address(0xBEEF);
    address internal constant TREASURY = address(0xFEE);

    EqualIndexLendingHarness internal harness;
    PositionNFT internal nft;
    LocalLendingMockERC20 internal assetA;
    LocalLendingMockERC20 internal assetB;

    struct BorrowCtx {
        uint256 indexId;
        uint256 positionId;
        bytes32 positionKey;
        uint256 indexPoolId;
        address token;
    }

    function setUp() public {
        harness = new EqualIndexLendingHarness();
        harness.setOwner(address(this));
        harness.setTimelock(TIMELOCK);
        harness.setTreasury(TREASURY);
        harness.setDefaultPoolConfig();

        nft = new PositionNFT();
        nft.setMinter(address(this));
        harness.setPositionNFT(address(nft));

        assetA = new LocalLendingMockERC20("AssetA", "ASTA", 18);
        assetB = new LocalLendingMockERC20("AssetB", "ASTB", 18);

        harness.seedPool(1, address(assetA), 1_000_000 ether);
        harness.seedPool(2, address(assetB), 1_000_000 ether);
        harness.setAssetToPoolId(address(assetA), 1);
        harness.setAssetToPoolId(address(assetB), 2);

        vm.startPrank(BORROWER);
        assetA.approve(address(harness), type(uint256).max);
        assetB.approve(address(harness), type(uint256).max);
        vm.stopPrank();
    }

    function test_configureLending_onlyTimelock() public {
        BorrowCtx memory ctx = _readyBorrowContext();

        vm.expectRevert(Unauthorized.selector);
        harness.configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(TIMELOCK);
        harness.configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        LibEqualIndexLending.LendingConfig memory cfg = harness.getLendingConfig(ctx.indexId);
        assertEq(cfg.ltvBps, 10_000);
        assertEq(cfg.minDuration, 1 days);
        assertEq(cfg.maxDuration, 30 days);
    }

    function test_borrowAndRepay_fromPosition() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        vm.prank(TIMELOCK);
        harness.configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(BORROWER);
        uint256 loanId = harness.borrowFromPosition(ctx.positionId, ctx.indexId, 1 ether, 7 days);

        LibEqualIndexLending.IndexLoan memory loan = harness.getLoan(loanId);
        assertEq(loan.positionKey, ctx.positionKey);
        assertEq(loan.indexId, ctx.indexId);
        assertEq(loan.collateralUnits, 1 ether);
        assertEq(loan.ltvBps, 10_000);
        assertEq(harness.getOutstandingPrincipal(ctx.indexId, address(assetA)), 1 ether);
        assertEq(harness.getOutstandingPrincipal(ctx.indexId, address(assetB)), 2 ether);
        assertEq(harness.getLockedCollateralUnits(ctx.indexId), 1 ether);
        assertEq(harness.lendingEncumbered(ctx.positionKey, ctx.indexPoolId), 1 ether);

        vm.prank(BORROWER);
        harness.repayFromPosition(ctx.positionId, loanId);

        assertEq(harness.getOutstandingPrincipal(ctx.indexId, address(assetA)), 0);
        assertEq(harness.getOutstandingPrincipal(ctx.indexId, address(assetB)), 0);
        assertEq(harness.getLockedCollateralUnits(ctx.indexId), 0);
        assertEq(harness.lendingEncumbered(ctx.positionKey, ctx.indexPoolId), 0);
        assertEq(harness.getLoan(loanId).collateralUnits, 0);
    }

    function test_recoverExpired_clearsLoanAndCollateral() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        vm.prank(TIMELOCK);
        harness.configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        vm.prank(BORROWER);
        uint256 loanId = harness.borrowFromPosition(ctx.positionId, ctx.indexId, 1 ether, 1 days);

        vm.warp(block.timestamp + 2 days);
        harness.recoverExpiredIndexLoan(loanId);

        assertEq(harness.getOutstandingPrincipal(ctx.indexId, address(assetA)), 0);
        assertEq(harness.getOutstandingPrincipal(ctx.indexId, address(assetB)), 0);
        assertEq(harness.getLockedCollateralUnits(ctx.indexId), 0);
        assertEq(harness.lendingEncumbered(ctx.positionKey, ctx.indexPoolId), 0);
        assertEq(harness.getLoan(loanId).collateralUnits, 0);
        assertEq(harness.getIndexTotalUnits(ctx.indexId), 1 ether);
        assertEq(harness.getPoolPrincipal(ctx.indexPoolId, ctx.positionKey), 1 ether);
        assertEq(IndexToken(ctx.token).totalSupply(), 1 ether);
    }

    function test_configureBorrowFeeTiers_and_quoteViews() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        vm.prank(TIMELOCK);
        harness.configureLending(ctx.indexId, 10_000, 1 days, 30 days);

        uint256[] memory minUnits = new uint256[](2);
        minUnits[0] = 1 ether;
        minUnits[1] = 2 ether;
        uint256[] memory flatFees = new uint256[](2);
        flatFees[0] = 0.01 ether;
        flatFees[1] = 0.03 ether;

        vm.prank(TIMELOCK);
        harness.configureBorrowFeeTiers(ctx.indexId, minUnits, flatFees);

        (uint256[] memory gotMin, uint256[] memory gotFees) = harness.getBorrowFeeTiers(ctx.indexId);
        assertEq(gotMin.length, 2);
        assertEq(gotFees.length, 2);
        assertEq(gotMin[0], 1 ether);
        assertEq(gotMin[1], 2 ether);
        assertEq(gotFees[0], 0.01 ether);
        assertEq(gotFees[1], 0.03 ether);
        assertEq(harness.maxBorrowable(ctx.indexId, address(assetA), 1 ether), 1 ether);
        assertEq(harness.maxBorrowable(ctx.indexId, address(assetB), 1 ether), 2 ether);
        assertEq(harness.quoteBorrowFee(ctx.indexId, 1 ether), 0.01 ether);
        assertEq(harness.quoteBorrowFee(ctx.indexId, 2 ether), 0.03 ether);

        (address[] memory assets, uint256[] memory principals) = harness.quoteBorrowBasket(ctx.indexId, 1 ether);
        assertEq(assets.length, 2);
        assertEq(principals.length, 2);
        assertEq(assets[0], address(assetA));
        assertEq(assets[1], address(assetB));
        assertEq(principals[0], 1 ether);
        assertEq(principals[1], 2 ether);
    }

    function test_flatFeeBorrow_requiresExactMsgValue_andPaysTreasury() public {
        BorrowCtx memory ctx = _readyBorrowContext();
        vm.prank(TIMELOCK);
        harness.configureLending(ctx.indexId, 10_000, 1 days, 30 days);
        _configureSingleTierFee(ctx.indexId, 1 ether, 0.02 ether);

        vm.deal(BORROWER, 1 ether);

        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(LibEqualIndexLending.FlatFeePaymentMismatch.selector, 0.02 ether, 0));
        harness.borrowFromPosition(ctx.positionId, ctx.indexId, 1 ether, 7 days);

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(BORROWER);
        harness.borrowFromPosition{value: 0.02 ether}(ctx.positionId, ctx.indexId, 1 ether, 7 days);
        assertEq(TREASURY.balance - treasuryBefore, 0.02 ether);
    }

    function test_configureBorrowFeeTiers_revertsOnEmptyMismatchAndOrdering() public {
        BorrowCtx memory ctx = _readyBorrowContext();

        uint256[] memory empty;
        vm.prank(TIMELOCK);
        vm.expectRevert(InvalidArrayLength.selector);
        harness.configureBorrowFeeTiers(ctx.indexId, empty, empty);

        uint256[] memory minUnits = new uint256[](2);
        minUnits[0] = 2 ether;
        minUnits[1] = 1 ether;
        uint256[] memory flatFees = new uint256[](2);
        flatFees[0] = 0.01 ether;
        flatFees[1] = 0.02 ether;
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameterRange.selector, "tierOrder"));
        harness.configureBorrowFeeTiers(ctx.indexId, minUnits, flatFees);
    }

    function _configureSingleTierFee(uint256 indexId, uint256 minCollateralUnits, uint256 flatFeeNative) internal {
        uint256[] memory minUnits = new uint256[](1);
        minUnits[0] = minCollateralUnits;
        uint256[] memory flatFees = new uint256[](1);
        flatFees[0] = flatFeeNative;
        vm.prank(TIMELOCK);
        harness.configureBorrowFeeTiers(indexId, minUnits, flatFees);
    }

    function _readyBorrowContext() internal returns (BorrowCtx memory ctx) {
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory bundle = new uint256[](2);
        bundle[0] = 1 ether;
        bundle[1] = 2 ether;
        uint16[] memory mintFees = new uint16[](2);
        uint16[] memory burnFees = new uint16[](2);

        (ctx.indexId, ctx.token) = harness.createIndex(
            EqualIndexBaseV3.CreateIndexParams({
                name: "IDX",
                symbol: "IDX",
                assets: assets,
                bundleAmounts: bundle,
                mintFeeBps: mintFees,
                burnFeeBps: burnFees,
                flashFeeBps: 0
            })
        );
        ctx.indexPoolId = harness.getIndexPoolId(ctx.indexId);

        ctx.positionId = nft.mint(BORROWER, 1);
        ctx.positionKey = nft.getPositionKey(ctx.positionId);
        harness.setPoolPrincipal(1, ctx.positionKey, 1000 ether);
        harness.setPoolPrincipal(2, ctx.positionKey, 1000 ether);
        harness.joinPool(ctx.positionKey, 1);
        harness.joinPool(ctx.positionKey, 2);

        vm.prank(BORROWER);
        harness.mintFromPosition(ctx.positionId, ctx.indexId, 2 ether);
        assertEq(harness.getPoolPrincipal(ctx.indexPoolId, ctx.positionKey), 2 ether);
        assertEq(harness.getIndexTotalUnits(ctx.indexId), 2 ether);
    }
}
