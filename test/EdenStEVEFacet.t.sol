// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenStEVEFacet} from "src/eden/EdenStEVEFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibModuleEncumbrance} from "src/libraries/LibModuleEncumbrance.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20StEVE is ERC20 {
    constructor() ERC20("EVE", "EVE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EdenStEVEHarness is PoolManagementFacet, EdenStEVEFacet {
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

    function principalOf(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[user];
    }

    function encumberForTest(bytes32 positionKey, uint256 pid, uint256 moduleId, uint256 amount) external {
        LibModuleEncumbrance.encumber(positionKey, pid, moduleId, amount);
    }
}

interface Vm {
    function prank(address) external;
}

contract EdenStEVEFacetTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EdenStEVEHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20StEVE internal eve;

    address internal alice = _addr("alice");
    address internal bob = _addr("bob");

    function setUp() public {
        harness = new EdenStEVEHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(_addr("treasury"));
        harness.setFeeSplits(1000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        eve = new MockERC20StEVE();

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(eve), cfg, actionFees);
        harness.setDefaultPoolConfig(cfg);
    }

    function test_CreateStEVE_WalletMintStaysNonEligible() public {
        eve.mint(bob, 20e18);

        (uint256 basketId,) = harness.createStEVE(_stEVEParams(address(eve)));
        vm.prank(bob);
        eve.approve(address(harness), 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;
        vm.prank(bob);
        harness.mintBasket(basketId, 10e18, bob, maxInputs);

        _assertEq(harness.eligibleSupply(), 0, "wallet-held stEVE should not be eligible");
    }

    function test_DepositWithdrawStEVE_TracksEligibleSupply() public {
        eve.mint(bob, 20e18);

        (uint256 basketId,) = harness.createStEVE(_stEVEParams(address(eve)));
        uint256 stevePoolId = harness.getBasketPoolId(basketId);

        vm.prank(bob);
        eve.approve(address(harness), 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;
        vm.prank(bob);
        harness.mintBasket(basketId, 10e18, bob, maxInputs);

        vm.prank(bob);
        uint256 positionId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        address steveToken = harness.getBasket(basketId).token;
        vm.prank(bob);
        ERC20(steveToken).approve(address(harness), 10e18);
        vm.prank(bob);
        uint256 deposited = harness.depositStEVEToPosition(positionId, 10e18, 10e18);

        _assertEq(deposited, 10e18, "deposit amount");
        _assertEq(harness.eligibleSupply(), 10e18, "eligible supply after deposit");
        _assertEq(harness.eligiblePrincipalOfPosition(positionId), 10e18, "eligible principal after deposit");
        _assertEq(harness.principalOf(stevePoolId, positionKey), 10e18, "stEVE pool principal");
        _assertEq(ERC20(steveToken).balanceOf(bob), 0, "wallet balance drained");

        vm.prank(bob);
        uint256 withdrawn = harness.withdrawStEVEFromPosition(positionId, 4e18, 4e18);

        _assertEq(withdrawn, 4e18, "withdraw amount");
        _assertEq(harness.eligibleSupply(), 6e18, "eligible supply after withdraw");
        _assertEq(harness.eligiblePrincipalOfPosition(positionId), 6e18, "eligible principal after withdraw");
        _assertEq(harness.principalOf(stevePoolId, positionKey), 6e18, "remaining stEVE pool principal");
        _assertEq(ERC20(steveToken).balanceOf(bob), 4e18, "wallet balance restored");
    }

    function test_PositionMintAndBurnStEVE_TrackEligibleSupply() public {
        eve.mint(alice, 100e18);

        (uint256 basketId,) = harness.createStEVE(_stEVEParams(address(eve)));

        vm.prank(alice);
        eve.approve(address(harness), 100e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);

        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 100e18, 100e18);

        vm.prank(alice);
        harness.mintBasketFromPosition(positionId, basketId, 50e18);
        _assertEq(harness.eligibleSupply(), 50e18, "eligible supply after position mint");
        _assertEq(harness.eligiblePrincipalOfPosition(positionId), 50e18, "eligible principal after position mint");

        vm.prank(alice);
        harness.burnBasketFromPosition(positionId, basketId, 20e18);
        _assertEq(harness.eligibleSupply(), 30e18, "eligible supply after position burn");
        _assertEq(harness.eligiblePrincipalOfPosition(positionId), 30e18, "eligible principal after position burn");
    }

    function test_WithdrawStEVE_RespectsEncumbrance() public {
        eve.mint(bob, 20e18);

        (uint256 basketId,) = harness.createStEVE(_stEVEParams(address(eve)));
        uint256 stevePoolId = harness.getBasketPoolId(basketId);

        vm.prank(bob);
        eve.approve(address(harness), 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;
        vm.prank(bob);
        harness.mintBasket(basketId, 10e18, bob, maxInputs);

        vm.prank(bob);
        uint256 positionId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        address steveToken = harness.getBasket(basketId).token;
        vm.prank(bob);
        ERC20(steveToken).approve(address(harness), 10e18);
        vm.prank(bob);
        harness.depositStEVEToPosition(positionId, 10e18, 10e18);

        harness.encumberForTest(positionKey, stevePoolId, 999, 8e18);

        vm.prank(bob);
        (bool ok,) = address(harness).call(
            abi.encodeWithSelector(harness.withdrawStEVEFromPosition.selector, positionId, 3e18, 3e18)
        );
        _assertTrue(!ok, "encumbered principal should block withdrawal");
        _assertEq(harness.eligibleSupply(), 10e18, "eligible supply unchanged on revert");
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
}
