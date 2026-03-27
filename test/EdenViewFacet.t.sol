// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BasketToken} from "src/tokens/BasketToken.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20View is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EdenViewHarness is PoolManagementFacet, EdenViewFacet {
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

    function setBasketPaused(uint256 basketId, bool paused) external {
        LibEdenBasketStorage.s().baskets[basketId].paused = paused;
    }
}

import {LibEdenBasketStorage} from "src/libraries/LibEdenBasketStorage.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
}

contract EdenViewFacetTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EdenViewHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20View internal eve;
    MockERC20View internal alt;

    address internal alice = _addr("alice");
    address internal bob = _addr("bob");

    uint256 internal steveBasketId;
    uint256 internal altBasketId;
    uint256 internal alicePositionId;
    uint256 internal aliceAltPositionId;
    uint256 internal bobPositionId;

    function setUp() public {
        harness = new EdenViewHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(_addr("treasury"));
        harness.setFeeSplits(1000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        eve = new MockERC20View("EVE", "EVE");
        alt = new MockERC20View("ALT", "ALT");

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(eve), cfg, actionFees);
        harness.initPoolWithActionFees(2, address(alt), cfg, actionFees);
        harness.setDefaultPoolConfig(cfg);

        (steveBasketId,) = harness.createStEVE(_stEVEParams(address(eve)));
        (altBasketId,) = harness.createBasket(_singleAssetParams("ALT Basket", "ALTB", address(alt), "ipfs://alt", 2));

        harness.configureRewards(address(eve), 10e18, true);
        harness.configureLending(altBasketId, 1 days, 14 days);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        harness.configureBorrowFeeTiers(altBasketId, mins, fees);

        eve.mint(alice, 200e18);
        alt.mint(alice, 200e18);
        eve.mint(address(this), 500e18);

        vm.prank(alice);
        alicePositionId = harness.mintPosition(1);
        vm.prank(alice);
        aliceAltPositionId = harness.mintPosition(2);
        vm.prank(bob);
        bobPositionId = harness.mintPosition(1);

        _mintWalletBasket(alice, steveBasketId, eve, 20e18);
        _mintWalletBasket(alice, altBasketId, alt, 10e18);

        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);

        vm.prank(alice);
        alt.approve(address(harness), 200e18);
        vm.prank(alice);
        harness.depositToPosition(aliceAltPositionId, 2, 100e18, 100e18);
        vm.prank(alice);
        harness.mintBasketFromPosition(aliceAltPositionId, altBasketId, 40e18);

        eve.approve(address(harness), 500e18);
        harness.fundRewards(500e18, 500e18);
        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        harness.borrow(aliceAltPositionId, altBasketId, 15e18, 7 days);
    }

    function test_MetadataAndProductConfigReads() public view {
        _assertEq(harness.basketCount(), 2, "basket count");

        uint256[] memory basketIds = harness.getBasketIds(0, 10);
        _assertEq(basketIds.length, 2, "basket ids length");
        _assertEq(basketIds[0], steveBasketId, "steve basket id");
        _assertEq(basketIds[1], altBasketId, "alt basket id");

        EdenViewFacet.BasketSummary memory steveSummary = harness.getBasketSummary(steveBasketId);
        _assertEqBytes32(keccak256(bytes(steveSummary.name)), keccak256(bytes("stEVE")), "steve name");
        _assertTrue(steveSummary.isStEVE, "steve summary tagged");

        EdenViewFacet.ProductConfigView memory config = harness.getProductConfig();
        _assertEq(config.basketCount, 2, "config basket count");
        _assertEq(config.steveBasketId, steveBasketId, "config steve id");
        _assertEq(uint256(uint160(config.rewardToken)), uint256(uint160(address(eve))), "reward token");
        _assertTrue(config.rewardsEnabled, "rewards enabled");
    }

    function test_PositionAwarePortfolioReads() public view {
        uint256[] memory alicePositionIds = harness.getUserPositionIds(alice);
        _assertEq(alicePositionIds.length, 2, "alice position count");
        _assertEq(alicePositionIds[0], alicePositionId, "alice position id");
        _assertEq(alicePositionIds[1], aliceAltPositionId, "alice alt position id");

        EdenViewFacet.PositionPortfolio memory portfolio = harness.getPositionPortfolio(alicePositionId);
        _assertEq(portfolio.positionId, alicePositionId, "portfolio position id");
        _assertEq(uint256(uint160(portfolio.owner)), uint256(uint160(alice)), "portfolio owner");
        _assertEq(portfolio.baskets.length, 1, "portfolio basket count");
        _assertEq(portfolio.loans.length, 0, "portfolio loan count");
        _assertEq(portfolio.rewards.eligiblePrincipal, 10e18, "eligible principal");
        _assertTrue(portfolio.rewards.claimableRewards > 0, "claimable rewards positive");

        EdenViewFacet.PositionPortfolio memory altPortfolio = harness.getPositionPortfolio(aliceAltPositionId);
        _assertEq(altPortfolio.baskets.length, 1, "alt portfolio basket count");
        _assertEq(altPortfolio.loans.length, 1, "alt portfolio loan count");

        EdenViewFacet.UserPortfolio memory userPortfolio = harness.getUserPortfolio(alice);
        _assertEq(userPortfolio.positionIds.length, 2, "user portfolio position ids");
        _assertEq(userPortfolio.positions.length, 2, "user portfolio positions");
        _assertEq(userPortfolio.positions[1].loans.length, 1, "user portfolio loan completeness");
    }

    function test_ActionChecksReflectState() public {
        EdenViewFacet.ActionCheck memory mintCheck = harness.canMint(altBasketId, 10e18);
        _assertTrue(mintCheck.ok, "valid mint check");

        harness.setBasketPaused(altBasketId, true);
        EdenViewFacet.ActionCheck memory pausedMint = harness.canMint(altBasketId, 10e18);
        _assertTrue(!pausedMint.ok, "paused mint fails");
        _assertEq(pausedMint.code, harness.ACTION_BASKET_PAUSED(), "paused code");
        harness.setBasketPaused(altBasketId, false);

        EdenViewFacet.ActionCheck memory burnCheck = harness.canBurn(alice, altBasketId, 100e18);
        _assertTrue(!burnCheck.ok, "burn check catches insufficient wallet balance");
        _assertEq(burnCheck.code, harness.ACTION_INSUFFICIENT_BALANCE(), "burn balance code");

        EdenViewFacet.ActionCheck memory borrowCheck = harness.canBorrow(aliceAltPositionId, altBasketId, 50e18, 7 days);
        _assertTrue(!borrowCheck.ok, "borrow check catches insufficient collateral");
        _assertEq(borrowCheck.code, harness.ACTION_INSUFFICIENT_COLLATERAL(), "borrow collateral code");

        EdenViewFacet.ActionCheck memory repayCheck = harness.canRepay(bobPositionId, 0);
        _assertTrue(!repayCheck.ok, "repay check catches mismatch");
        _assertEq(repayCheck.code, harness.ACTION_POSITION_MISMATCH(), "repay mismatch code");

        vm.warp(block.timestamp + 8 days);
        EdenViewFacet.ActionCheck memory extendCheck = harness.canExtend(aliceAltPositionId, 0, 1 days);
        _assertTrue(!extendCheck.ok, "extend check catches expiry");
        _assertEq(extendCheck.code, harness.ACTION_LOAN_EXPIRED(), "extend expired code");

        EdenViewFacet.ActionCheck memory claimCheck = harness.canClaimRewards(alicePositionId);
        _assertTrue(claimCheck.ok, "claim rewards check passes");
        EdenViewFacet.ActionCheck memory emptyClaimCheck = harness.canClaimRewards(bobPositionId);
        _assertTrue(!emptyClaimCheck.ok, "claim rewards check catches empty state");
    }

    function _mintWalletBasket(address user, uint256 basketId, MockERC20View asset, uint256 units) internal {
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = units;
        vm.prank(user);
        asset.approve(address(harness), units);
        vm.prank(user);
        harness.mintBasket(basketId, units, user, maxInputs);
    }

    function _depositWalletStEVEToPosition(address user, uint256 positionId, uint256 amount) internal {
        address steveToken = harness.getBasket(steveBasketId).token;
        vm.prank(user);
        BasketToken(steveToken).approve(address(harness), amount);
        vm.prank(user);
        harness.depositStEVEToPosition(positionId, amount, amount);
    }

    function _stEVEParams(address asset) internal pure returns (EdenBasketBase.CreateBasketParams memory p) {
        p.name = "stEVE";
        p.symbol = "stEVE";
        p.uri = "ipfs://steve";
        p.assets = new address[](1);
        p.assets[0] = asset;
        p.bundleAmounts = new uint256[](1);
        p.bundleAmounts[0] = 1e18;
        p.mintFeeBps = new uint16[](1);
        p.mintFeeBps[0] = 0;
        p.burnFeeBps = new uint16[](1);
        p.burnFeeBps[0] = 0;
        p.flashFeeBps = 50;
        p.basketType = 1;
    }

    function _singleAssetParams(
        string memory name_,
        string memory symbol_,
        address asset,
        string memory uri_,
        uint8 basketType
    ) internal pure returns (EdenBasketBase.CreateBasketParams memory p) {
        p.name = name_;
        p.symbol = symbol_;
        p.uri = uri_;
        p.assets = new address[](1);
        p.assets[0] = asset;
        p.bundleAmounts = new uint256[](1);
        p.bundleAmounts[0] = 1e18;
        p.mintFeeBps = new uint16[](1);
        p.mintFeeBps[0] = 0;
        p.burnFeeBps = new uint16[](1);
        p.burnFeeBps[0] = 0;
        p.flashFeeBps = 50;
        p.basketType = basketType;
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

    function _assertEqBytes32(bytes32 left, bytes32 right, string memory message) internal pure {
        require(left == right, message);
    }
}
