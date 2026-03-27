// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenBasketFacet} from "src/eden/EdenBasketFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {BasketToken} from "src/tokens/BasketToken.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEdenBasketStorage} from "src/libraries/LibEdenBasketStorage.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibModuleEncumbrance} from "src/libraries/LibModuleEncumbrance.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20Basket is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeOnTransferToken is ERC20 {
    uint256 internal constant BPS = 10_000;
    uint256 public feeBps = 1000;
    address public feeSink = address(0xdead);

    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / BPS;
        uint256 remainder = value - fee;
        super._update(from, feeSink, fee);
        super._update(from, to, remainder);
    }
}

contract EdenBasketHarness is PoolManagementFacet, PositionManagementFacet, EdenBasketFacet {
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

    function pendingFeeYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }

    function principalOf(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[user];
    }

    function isPoolMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey] > 0 || LibAppStorage.s().pools[pid].userFeeIndex[positionKey] > 0;
    }

    function basketEncumbranceOf(bytes32 positionKey, uint256 pid, uint256 basketId) external view returns (uint256) {
        return LibModuleEncumbrance.getEncumberedForModule(positionKey, pid, uint256(keccak256(abi.encodePacked("EDEN_BASKET_ENCUMBRANCE", basketId))));
    }
}

interface Vm {
    function prank(address) external;
}

contract EdenBasketFacetTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EdenBasketHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20Basket internal token;
    MockFeeOnTransferToken internal feeToken;

    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal treasury = _addr("treasury");

    function setUp() public {
        harness = new EdenBasketHarness();
        harness.setOwner(address(this));
        harness.setTimelock(address(this));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        token = new MockERC20Basket("Mock", "MOCK");
        feeToken = new MockFeeOnTransferToken();

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(token), cfg, actionFees);
        harness.initPoolWithActionFees(2, address(feeToken), cfg, actionFees);
        harness.setDefaultPoolConfig(cfg);
    }

    function test_CreateBasket_WalletMintBurnAndMetadata() public {
        token.mint(bob, 20e18);

        (uint256 basketId, address basketTokenAddr) =
            harness.createBasket(_singleAssetParams("EDEN Basket", "EDEN", address(token), "ipfs://eden", 7, 1000, 1000));
        BasketToken basketToken = BasketToken(basketTokenAddr);

        EdenBasketBase.BasketView memory basket = harness.getBasket(basketId);
        _assertEq(basket.poolId > 0 ? 1 : 0, 1, "basket pool initialized");
        _assertEq(basket.flashFeeBps, 50, "flash fee stored");

        (
            string memory name_,
            string memory symbol_,
            string memory uri_,
            address creator_,
            uint64 createdAt_,
            uint8 basketType_
        ) = _metadata(harness, basketId);
        _assertEq(keccak256(bytes(name_)), keccak256(bytes("EDEN Basket")), "metadata name");
        _assertEq(keccak256(bytes(symbol_)), keccak256(bytes("EDEN")), "metadata symbol");
        _assertEq(keccak256(bytes(uri_)), keccak256(bytes("ipfs://eden")), "metadata uri");
        _assertEq(uint256(uint160(creator_)), uint256(uint160(address(this))), "metadata creator");
        _assertEq(uint256(createdAt_ > 0 ? 1 : 0), 1, "metadata createdAt");
        _assertEq(basketType_, 7, "metadata basket type");

        vm.prank(bob);
        token.approve(address(harness), 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 11e18;
        vm.prank(bob);
        uint256 minted = harness.mintBasket(basketId, 10e18, bob, maxInputs);

        _assertEq(minted, 10e18, "wallet basket minted");
        _assertEq(basketToken.balanceOf(bob), 10e18, "wallet basket balance");
        _assertGt(token.balanceOf(treasury), 0, "treasury receives routed share");
        _assertGt(harness.getBasketVaultBalance(basketId, address(token)), 0, "vault funded");

        vm.prank(bob);
        harness.burnBasket(basketId, 10e18, bob);

        _assertEq(basketToken.balanceOf(bob), 0, "wallet basket burned");
        _assertEq(harness.getBasket(basketId).totalUnits, 0, "basket supply reset");
        _assertGt(token.balanceOf(bob), 0, "underlying returned to wallet");
    }

    function test_PositionMode_MintBurnPreservesPrincipalAndEncumbrance() public {
        token.mint(alice, 250e18);

        vm.prank(alice);
        token.approve(address(harness), 250e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 200e18, 200e18);

        (uint256 basketId,) =
            harness.createBasket(_singleAssetParams("Position Basket", "PBASK", address(token), "ipfs://pb", 0, 1000, 0));
        uint256 basketPoolId = harness.getBasketPoolId(basketId);

        vm.prank(alice);
        uint256 minted = harness.mintBasketFromPosition(positionId, basketId, 50e18);

        _assertEq(minted, 50e18, "position basket minted");
        _assertEq(harness.principalOf(basketPoolId, positionKey), 50e18, "basket pool principal");
        _assertEq(harness.basketEncumbranceOf(positionKey, 1, basketId), 50e18, "base pool encumbrance");
        _assertGt(harness.pendingFeeYield(1, positionKey), 0, "base pool fee routing accrues");

        vm.prank(alice);
        harness.burnBasketFromPosition(positionId, basketId, 50e18);

        _assertEq(harness.principalOf(basketPoolId, positionKey), 0, "basket pool principal after burn");
        _assertEq(harness.basketEncumbranceOf(positionKey, 1, basketId), 0, "encumbrance released");
        _assertGt(harness.principalOf(1, positionKey), 0, "base pool principal remains");
    }

    function test_MintBasket_RevertsWhenFoTDeltaIsInsufficient() public {
        feeToken.mint(bob, 20e18);

        (uint256 basketId,) =
            harness.createBasket(_singleAssetParams("FoT Basket", "FBASK", address(feeToken), "ipfs://fot", 0, 0, 0));

        vm.prank(bob);
        feeToken.approve(address(harness), 20e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 10e18;

        vm.prank(bob);
        (bool ok,) =
            address(harness).call(abi.encodeWithSelector(harness.mintBasket.selector, basketId, 10e18, bob, maxInputs));
        _assertTrue(!ok, "fee-on-transfer underreceipt must revert");
    }

    function _singleAssetParams(
        string memory name_,
        string memory symbol_,
        address asset,
        string memory uri_,
        uint8 basketType,
        uint16 mintFeeBps,
        uint16 burnFeeBps
    ) internal pure returns (EdenBasketBase.CreateBasketParams memory p) {
        p.name = name_;
        p.symbol = symbol_;
        p.uri = uri_;
        p.assets = new address[](1);
        p.assets[0] = asset;
        p.bundleAmounts = new uint256[](1);
        p.bundleAmounts[0] = 1e18;
        p.mintFeeBps = new uint16[](1);
        p.mintFeeBps[0] = mintFeeBps;
        p.burnFeeBps = new uint16[](1);
        p.burnFeeBps[0] = burnFeeBps;
        p.flashFeeBps = 50;
        p.basketType = basketType;
    }

    function _metadata(EdenBasketHarness target, uint256 basketId)
        internal
        view
        returns (string memory, string memory, string memory, address, uint64, uint8)
    {
        LibEdenBasketStorage.BasketMetadata memory metadata = target.getBasketMetadata(basketId);
        return (metadata.name, metadata.symbol, metadata.uri, metadata.creator, metadata.createdAt, metadata.basketType);
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

    function _assertEq(bytes32 left, bytes32 right, string memory message) internal pure {
        require(left == right, message);
    }

    function _assertGt(uint256 left, uint256 right, string memory message) internal pure {
        require(left > right, message);
    }
}
