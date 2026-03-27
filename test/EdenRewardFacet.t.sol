// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20Reward is ERC20 {
    constructor() ERC20("EVE", "EVE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EdenRewardHarness is PoolManagementFacet, EdenRewardFacet {
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

    function setDefaultPoolConfig(Types.PoolConfig calldata config) external {
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
}

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
}

contract EdenRewardFacetTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EdenRewardHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20Reward internal eve;

    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal carol = _addr("carol");

    function setUp() public {
        harness = new EdenRewardHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(_addr("treasury"));
        harness.setFeeSplits(1000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        eve = new MockERC20Reward();

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(eve), cfg, actionFees);
        harness.setDefaultPoolConfig(cfg);

        harness.createStEVE(_stEVEParams(address(eve)));
        harness.configureRewards(address(eve), 30e18, true);
    }

    function test_OnlyPnftHeldStEVEEarns() public {
        eve.mint(alice, 30e18);
        eve.mint(bob, 30e18);
        eve.mint(address(this), 1_000e18);

        _mintWalletStEVE(alice, 10e18);
        _mintWalletStEVE(bob, 10e18);

        vm.prank(alice);
        uint256 alicePositionId = harness.mintPosition(1);
        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);

        vm.prank(bob);
        uint256 bobPositionId = harness.mintPosition(1);

        eve.approve(address(harness), 1_000e18);
        harness.fundRewards(1_000e18, 1_000e18);

        vm.warp(block.timestamp + 10);

        _assertEq(harness.eligibleSupply(), 10e18, "only PNFT stEVE counted");
        _assertGt(harness.previewClaimRewards(alicePositionId), 0, "eligible position earns");
        _assertEq(harness.previewClaimRewards(bobPositionId), 0, "wallet-only holder earns nothing");
    }

    function test_RewardAccrualAndSettlementAcrossPrincipalChanges() public {
        eve.mint(alice, 40e18);
        eve.mint(bob, 20e18);
        eve.mint(address(this), 2_000e18);

        _mintWalletStEVE(alice, 20e18);
        _mintWalletStEVE(bob, 10e18);

        vm.prank(alice);
        uint256 alicePositionId = harness.mintPosition(1);
        vm.prank(bob);
        uint256 bobPositionId = harness.mintPosition(1);

        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);
        _depositWalletStEVEToPosition(bob, bobPositionId, 10e18);

        eve.approve(address(harness), 2_000e18);
        harness.fundRewards(2_000e18, 2_000e18);

        vm.warp(block.timestamp + 10);
        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);

        vm.warp(block.timestamp + 10);

        uint256 aliceClaimable = harness.previewClaimRewards(alicePositionId);
        uint256 bobClaimable = harness.previewClaimRewards(bobPositionId);

        _assertEq(aliceClaimable, 350e18, "alice accrual across two intervals");
        _assertEq(bobClaimable, 250e18, "bob accrual across two intervals");
    }

    function test_ClaimRewardsAndFundingCap() public {
        eve.mint(alice, 20e18);
        eve.mint(address(this), 50e18);

        _mintWalletStEVE(alice, 10e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        _depositWalletStEVEToPosition(alice, positionId, 10e18);

        eve.approve(address(harness), 50e18);
        harness.fundRewards(50e18, 50e18);

        vm.warp(block.timestamp + 10);

        uint256 preview = harness.previewClaimRewards(positionId);
        _assertEq(preview, 50e18, "claim capped by funded reserve");

        uint256 balanceBefore = eve.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = harness.claimRewards(positionId, alice);
        uint256 balanceAfter = eve.balanceOf(alice);

        _assertEq(claimed, 50e18, "claimed funded amount");
        _assertEq(balanceAfter - balanceBefore, 50e18, "reward token transferred");
        _assertEq(harness.previewClaimRewards(positionId), 0, "claim resets accrued state");
    }

    function test_PositionTransferPreservesRewardOwnership() public {
        eve.mint(alice, 20e18);
        eve.mint(address(this), 500e18);

        _mintWalletStEVE(alice, 10e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        _depositWalletStEVEToPosition(alice, positionId, 10e18);

        eve.approve(address(harness), 500e18);
        harness.fundRewards(500e18, 500e18);

        vm.warp(block.timestamp + 10);
        uint256 previewBeforeTransfer = harness.previewClaimRewards(positionId);
        _assertGt(previewBeforeTransfer, 0, "position accrued rewards before transfer");

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, positionId);

        uint256 carolBefore = eve.balanceOf(carol);
        vm.prank(carol);
        uint256 claimed = harness.claimRewards(positionId, carol);
        uint256 carolAfter = eve.balanceOf(carol);

        _assertEq(claimed, previewBeforeTransfer, "claim amount follows position");
        _assertEq(carolAfter - carolBefore, previewBeforeTransfer, "new owner receives rewards");
    }

    function _mintWalletStEVE(address user, uint256 units) internal {
        uint256 basketId = harness.steveBasketId();
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = units;
        vm.prank(user);
        eve.approve(address(harness), units);
        vm.prank(user);
        harness.mintBasket(basketId, units, user, maxInputs);
    }

    function _depositWalletStEVEToPosition(address user, uint256 positionId, uint256 amount) internal {
        uint256 basketId = harness.steveBasketId();
        address steveToken = harness.getBasket(basketId).token;
        vm.prank(user);
        ERC20(steveToken).approve(address(harness), amount);
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
}
