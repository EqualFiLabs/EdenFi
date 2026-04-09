// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Smoke coverage only: this suite intentionally boots EqualIndex through a synthetic harness.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {IndexToken} from "src/equalindex/IndexToken.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";
import {
    CanonicalPoolAlreadyInitialized,
    IndexPaused,
    InsufficientIndexTokens,
    InsufficientUnencumberedPrincipal,
    InvalidArrayLength,
    InvalidBundleDefinition,
    InvalidUnits,
    NoPoolForAsset
} from "src/libraries/Errors.sol";
import {LibCurrency} from "src/libraries/LibCurrency.sol";

contract MockERC20Index is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EqualIndexHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualIndexAdminFacetV3,
    EqualIndexActionsFacetV3,
    EqualIndexPositionFacet
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

    function setFoundationReceiver(address receiver_) external {
        LibAppStorage.s().foundationReceiver = receiver_;
    }

    function setFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = uint16(treasuryBps);
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
        store.activeCreditShareConfigured = true;
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

    function pendingFeeYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }

    function principalOf(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[user];
    }

    function trackedBalanceOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDepositsOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function indexEncumbranceOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.total(positionKey, pid);
    }

    function isPoolMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(positionKey, pid);
    }
}

contract EqualIndexLendingHarness is
    PoolManagementFacet,
    PositionManagementFacet,
    EqualIndexAdminFacetV3,
    EqualIndexLendingFacet,
    EqualIndexPositionFacet
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

    function setFoundationReceiver(address receiver_) external {
        LibAppStorage.s().foundationReceiver = receiver_;
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

    function setPositionNft(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function indexEncumbranceOf(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.total(positionKey, pid);
    }

    function settleFeeIndex(uint256 pid, bytes32 positionKey) external {
        LibFeeIndex.settle(pid, positionKey);
    }

    function principalOf(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }
}

interface Vm {
    function prank(address) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function warp(uint256) external;
}

contract EqualIndexPortSmokeTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EqualIndexHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20Index internal token;

    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal treasury = _addr("treasury");

    function setUp() public {
        harness = new EqualIndexHarness();
        harness.setOwner(address(this));
        harness.setTimelock(_addr("timelock"));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        token = new MockERC20Index("Mock", "MOCK");

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(token), cfg, actionFees);
        harness.setDefaultPoolConfig(cfg);
    }

    function test_WalletMode_MintBurnPreservesPoolBackedFeeRouting() public {
        token.mint(alice, 100e18);
        token.mint(bob, 20e18);

        vm.prank(alice);
        token.approve(address(harness), 100e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 100e18, 100e18);

        (uint256 indexId, address tokenAddr) = harness.createIndex(_singleAssetParams("EDEN Index", "EDENI", 1000, 1000));
        IndexToken indexToken = IndexToken(tokenAddr);

        vm.prank(bob);
        token.approve(address(harness), 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        vm.prank(bob);
        uint256 minted = harness.mint(indexId, 10e18, bob, maxInputs);

        _assertEq(minted, 10e18, "minted units");
        _assertEq(indexToken.balanceOf(bob), 10e18, "wallet index balance");
        _assertGt(harness.pendingFeeYield(1, positionKey), 0, "pool-backed fee yield accrues");
        _assertGt(token.balanceOf(treasury), 0, "treasury receives routed fee share");

        vm.prank(bob);
        harness.burn(indexId, 10e18, bob);

        _assertEq(indexToken.balanceOf(bob), 0, "wallet index balance after burn");
        _assertEq(harness.getIndex(indexId).totalUnits, 0, "total units after full burn");
        _assertGt(token.balanceOf(bob), 0, "burn returns underlying");
    }

    function test_PositionMode_MintBurnPreservesPrincipalAndMembership() public {
        token.mint(alice, 250e18);

        vm.prank(alice);
        token.approve(address(harness), 250e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 200e18, 200e18);

        (uint256 indexId,) = harness.createIndex(_singleAssetParams("Position Index", "PINDEX", 1000, 0));
        uint256 indexPoolId = harness.getIndexPoolId(indexId);

        vm.prank(alice);
        uint256 minted = harness.mintFromPosition(positionId, indexId, 50e18);
        _assertEq(minted, 50e18, "position minted units");
        _assertEq(harness.principalOf(indexPoolId, positionKey), 50e18, "index pool principal");
        _assertTrue(harness.isPoolMember(positionKey, indexPoolId), "index pool membership");
        _assertEq(harness.indexEncumbranceOf(positionKey, 1), 50e18, "base pool encumbrance");
        _assertGt(harness.pendingFeeYield(1, positionKey), 0, "fee routing still accrues through pool");

        vm.prank(alice);
        harness.burnFromPosition(positionId, indexId, 50e18);

        _assertEq(harness.principalOf(indexPoolId, positionKey), 0, "index pool principal after burn");
        _assertEq(harness.indexEncumbranceOf(positionKey, 1), 0, "encumbrance released after burn");
        _assertGt(harness.principalOf(1, positionKey), 0, "base pool principal remains");
    }

    function test_RevertWhen_PositionMintExceedsAvailablePrincipal() public {
        token.mint(alice, 10e18);

        vm.prank(alice);
        token.approve(address(harness), 10e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 10e18, 10e18);

        (uint256 indexId,) = harness.createIndex(_singleAssetParams("Insufficient Mint", "IMINT", 0, 0));

        vm.expectRevert(abi.encodeWithSelector(InsufficientUnencumberedPrincipal.selector, 11e18, 10e18));
        vm.prank(alice);
        harness.mintFromPosition(positionId, indexId, 11e18);
    }

    function test_RevertWhen_PositionBurnExceedsPositionIndexBalance() public {
        token.mint(alice, 20e18);
        token.mint(bob, 10e18);

        vm.prank(alice);
        token.approve(address(harness), 20e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 20e18, 20e18);

        (uint256 indexId,) = harness.createIndex(_singleAssetParams("Insufficient Burn", "IBURN", 0, 0));

        vm.prank(alice);
        harness.mintFromPosition(positionId, indexId, 5e18);

        vm.prank(bob);
        token.approve(address(harness), 10e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 5e18;
        vm.prank(bob);
        harness.mint(indexId, 5e18, bob, maxInputs);

        vm.expectRevert(abi.encodeWithSelector(InsufficientIndexTokens.selector, 6e18, 5e18));
        vm.prank(alice);
        harness.burnFromPosition(positionId, indexId, 6e18);
    }

    function test_BugCondition_BurnEncumbered_ShouldRejectBurnPastAvailablePrincipal() public {
        EqualIndexLendingHarness lendingHarness = new EqualIndexLendingHarness();
        lendingHarness.setOwner(address(this));
        lendingHarness.setTimelock(_addr("timelock"));
        lendingHarness.setTreasury(treasury);

        PositionNFT localNft = new PositionNFT();
        localNft.setMinter(address(lendingHarness));
        lendingHarness.setPositionNft(address(localNft));

        MockERC20Index localToken = new MockERC20Index("Borrow Mock", "BMOCK");
        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        lendingHarness.initPoolWithActionFees(1, address(localToken), cfg, actionFees);
        lendingHarness.setDefaultPoolConfig(cfg);

        localToken.mint(alice, 50e18);

        vm.prank(alice);
        localToken.approve(address(lendingHarness), 50e18);
        vm.prank(alice);
        uint256 positionId = lendingHarness.mintPosition(1);
        bytes32 positionKey = localNft.getPositionKey(positionId);
        vm.prank(alice);
        lendingHarness.depositToPosition(positionId, 1, 50e18, 50e18);

        EqualIndexBaseV3.CreateIndexParams memory params = _singleAssetParams("Bug Encumbered", "BENC", 0, 0);
        params.assets[0] = address(localToken);
        (uint256 indexId,) = lendingHarness.createIndex(params);
        uint256 indexPoolId = lendingHarness.getIndexPoolId(indexId);

        vm.prank(alice);
        lendingHarness.mintFromPosition(positionId, indexId, 2e18);

        vm.prank(_addr("timelock"));
        lendingHarness.configureLending(indexId, 10_000, 1 days, 30 days);

        vm.prank(alice);
        lendingHarness.borrowFromPosition(positionId, indexId, 1e18, 7 days);

        vm.expectRevert(abi.encodeWithSelector(InsufficientUnencumberedPrincipal.selector, 2e18, 1e18));
        vm.prank(alice);
        lendingHarness.burnFromPosition(positionId, indexId, 2e18);

        _assertEq(
            lendingHarness.indexEncumbranceOf(positionKey, indexPoolId), 1e18, "borrow encumbrance should remain"
        );
    }

    function test_BugCondition_PositionBurn_ShouldClearAllEncumbranceAfterFeeBearingExit() public {
        token.mint(alice, 20e18);

        vm.prank(alice);
        token.approve(address(harness), 20e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 20e18, 20e18);

        (uint256 indexId,) = harness.createIndex(_singleAssetParams("Leak Index", "LEAK", 0, 1000));

        vm.prank(alice);
        harness.mintFromPosition(positionId, indexId, 5e18);
        vm.prank(alice);
        harness.burnFromPosition(positionId, indexId, 5e18);

        _assertEq(harness.indexEncumbranceOf(positionKey, 1), 0, "full fee-bearing burn should clear encumbrance");
    }

    function test_BugCondition_PositionBurnFeeRounding_ShouldRoundUp() public {
        token.mint(alice, 2e18);

        vm.prank(alice);
        token.approve(address(harness), 2e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 2e18, 2e18);

        EqualIndexBaseV3.CreateIndexParams memory params = _singleAssetParams("Round Position", "RPOS", 0, 333);
        params.bundleAmounts[0] = 1;
        (uint256 indexId,) = harness.createIndex(params);

        vm.prank(alice);
        harness.mintFromPosition(positionId, indexId, 1e18);

        vm.prank(alice);
        uint256[] memory assetsOut = harness.burnFromPosition(positionId, indexId, 1e18);

        _assertEq(assetsOut[0], 0, "position burn fee should ceil one-unit gross to full fee");
    }

    function test_BugCondition_MaintenanceExemptLockedCollateral_ShouldPreserveLockedUnits() public {
        EqualIndexLendingHarness lendingHarness = new EqualIndexLendingHarness();
        lendingHarness.setOwner(address(this));
        lendingHarness.setTimelock(_addr("timelock"));
        lendingHarness.setTreasury(treasury);
        lendingHarness.setFoundationReceiver(treasury);

        PositionNFT localNft = new PositionNFT();
        localNft.setMinter(address(lendingHarness));
        lendingHarness.setPositionNft(address(localNft));

        MockERC20Index localToken = new MockERC20Index("Maintenance Mock", "MMOCK");
        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        lendingHarness.initPoolWithActionFees(1, address(localToken), cfg, actionFees);
        lendingHarness.setDefaultPoolConfig(cfg);

        localToken.mint(alice, 20e18);
        vm.prank(alice);
        localToken.approve(address(lendingHarness), 20e18);
        vm.prank(alice);
        uint256 positionId = lendingHarness.mintPosition(1);
        bytes32 positionKey = localNft.getPositionKey(positionId);
        vm.prank(alice);
        lendingHarness.depositToPosition(positionId, 1, 20e18, 20e18);

        EqualIndexBaseV3.CreateIndexParams memory params = _singleAssetParams("Maintenance Lead", "MLEAD", 0, 0);
        params.assets[0] = address(localToken);
        (uint256 indexId,) = lendingHarness.createIndex(params);
        uint256 indexPoolId = lendingHarness.getIndexPoolId(indexId);

        vm.prank(alice);
        lendingHarness.mintFromPosition(positionId, indexId, 2e18);

        vm.prank(_addr("timelock"));
        lendingHarness.configureLending(indexId, 10_000, 1 days, 30 days);

        vm.prank(alice);
        uint256 loanId = lendingHarness.borrowFromPosition(positionId, indexId, 1e18, 1 days);

        vm.warp(block.timestamp + 36500 days);
        lendingHarness.settleFeeIndex(indexPoolId, positionKey);

        uint256 principalAfterMaintenance = lendingHarness.principalOf(indexPoolId, positionKey);
        _assertTrue(principalAfterMaintenance >= 1e18, "locked collateral should remain intact");
        _assertLt(principalAfterMaintenance, 2e18, "unlocked principal should still decay under maintenance");

        vm.warp(block.timestamp + 2 days);
        lendingHarness.recoverExpiredIndexLoan(loanId);
    }

    function test_CreateIndex_RevertsForInvalidDefinitionsAndMissingPools() public {
        EqualIndexBaseV3.CreateIndexParams memory badLengths = _singleAssetParams("Bad", "BAD", 0, 0);
        badLengths.bundleAmounts = new uint256[](0);
        vm.expectRevert(InvalidArrayLength.selector);
        harness.createIndex(badLengths);

        EqualIndexBaseV3.CreateIndexParams memory duplicateAssets = _singleAssetParams("Dup", "DUP", 0, 0);
        duplicateAssets.assets = new address[](2);
        duplicateAssets.assets[0] = address(token);
        duplicateAssets.assets[1] = address(token);
        duplicateAssets.bundleAmounts = new uint256[](2);
        duplicateAssets.bundleAmounts[0] = 1e18;
        duplicateAssets.bundleAmounts[1] = 1e18;
        duplicateAssets.mintFeeBps = new uint16[](2);
        duplicateAssets.burnFeeBps = new uint16[](2);
        vm.expectRevert(InvalidBundleDefinition.selector);
        harness.createIndex(duplicateAssets);

        MockERC20Index missing = new MockERC20Index("Missing", "MISS");
        EqualIndexBaseV3.CreateIndexParams memory missingPool = _singleAssetParams("Missing", "MISS", 0, 0);
        missingPool.assets[0] = address(missing);
        vm.expectRevert(abi.encodeWithSelector(NoPoolForAsset.selector, address(missing)));
        harness.createIndex(missingPool);
    }

    function test_EqualIndex_RevertsForCanonicalDuplicatePausedIndexAndInvalidMintInputs() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalPoolAlreadyInitialized.selector, address(token), 1));
        harness.initPool(address(token));

        (uint256 indexId,) = harness.createIndex(_singleAssetParams("Guarded", "GRD", 1000, 0));

        token.mint(bob, 50e18);
        vm.prank(bob);
        token.approve(address(harness), 50e18);

        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;

        vm.expectRevert(InvalidUnits.selector);
        harness.mint(indexId, 0, bob, maxInputs);

        maxInputs[0] = 10e18;
        vm.expectRevert(abi.encodeWithSelector(LibCurrency.LibCurrency_InvalidMax.selector, 10e18, 11e18));
        harness.mint(indexId, 10e18, bob, maxInputs);

        vm.prank(_addr("timelock"));
        harness.setPaused(indexId, true);

        maxInputs[0] = 11e18;
        vm.expectRevert(abi.encodeWithSelector(IndexPaused.selector, indexId));
        harness.mint(indexId, 10e18, bob, maxInputs);
    }

    function _singleAssetParams(
        string memory name_,
        string memory symbol_,
        uint16 mintFeeBps,
        uint16 burnFeeBps
    ) internal view returns (EqualIndexBaseV3.CreateIndexParams memory p) {
        p.name = name_;
        p.symbol = symbol_;
        p.assets = new address[](1);
        p.assets[0] = address(token);
        p.bundleAmounts = new uint256[](1);
        p.bundleAmounts[0] = 1e18;
        p.mintFeeBps = new uint16[](1);
        p.mintFeeBps[0] = mintFeeBps;
        p.burnFeeBps = new uint16[](1);
        p.burnFeeBps[0] = burnFeeBps;
        p.flashFeeBps = 50;
    }

    function _poolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](1);
        fixedTerms[0] = Types.FixedTermConfig({durationSecs: 7 days, apyBps: 500});

        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 20;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1e18;
        cfg.minLoanAmount = 1e18;
        cfg.minTopupAmount = 1e18;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 10;
        cfg.aumFeeMaxBps = 100;
        cfg.fixedTermConfigs = fixedTerms;
    }

    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }

    function _assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function _assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function _assertGt(uint256 left, uint256 right, string memory message) internal pure {
        require(left > right, message);
    }

    function _assertLt(uint256 left, uint256 right, string memory message) internal pure {
        require(left < right, message);
    }
}
