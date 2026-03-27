// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EdenAdminFacet} from "src/eden/EdenAdminFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20Admin is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EdenAdminHarness is PoolManagementFacet, EdenAdminFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setTreasury(address treasury_) external {
        LibAppStorage.s().treasury = treasury_;
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
    function expectEmit(bool, bool, bool, bool) external;
}

contract EdenAdminFacetTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EdenAdminHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20Admin internal eve;
    MockERC20Admin internal alt;

    address internal ownerAdmin = _addr("owner");

    event BasketMetadataUpdated(
        uint256 indexed basketId,
        string oldUri,
        string newUri,
        uint8 oldBasketType,
        uint8 newBasketType
    );
    event ProtocolURIUpdated(string oldUri, string newUri);
    event ContractVersionUpdated(string oldVersion, string newVersion);
    event FacetVersionUpdated(address indexed facet, string oldVersion, string newVersion);
    event BasketPausedUpdated(uint256 indexed basketId, bool paused);
    event BasketFeeConfigUpdated(
        uint256 indexed basketId,
        uint16[] mintFeeBps,
        uint16[] burnFeeBps,
        uint16 flashFeeBps
    );
    event PoolFeeShareUpdated(uint16 oldBps, uint16 newBps);
    event RewardConfigUpdated(address indexed rewardToken, uint256 rewardRatePerSecond, bool enabled);
    event LendingConfigUpdated(uint256 indexed basketId, uint40 minDuration, uint40 maxDuration, uint16 ltvBps);

    function setUp() public {
        harness = new EdenAdminHarness();
        harness.setOwner(ownerAdmin);
        harness.setTimelock(address(this));
        harness.setTreasury(_addr("treasury"));

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        eve = new MockERC20Admin("EVE", "EVE");
        alt = new MockERC20Admin("ALT", "ALT");

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(eve), cfg, actionFees);
        harness.initPoolWithActionFees(2, address(alt), cfg, actionFees);
        harness.setDefaultPoolConfig(cfg);
    }

    function test_AdminWrites_AreTimelockOnlyAndEmitEvents() public {
        (uint256 basketId,) =
            harness.createBasket(_singleAssetParams("ALT Basket", "ALTB", address(alt), "ipfs://alt", 2));

        vm.prank(ownerAdmin);
        (bool unauthorizedOk,) =
            address(harness).call(abi.encodeWithSelector(harness.setProtocolURI.selector, "ipfs://blocked"));
        _assertTrue(!unauthorizedOk, "owner should not bypass timelock once configured");

        vm.expectEmit(true, false, false, true);
        emit BasketMetadataUpdated(basketId, "ipfs://alt", "ipfs://alt-v2", 2, 5);
        harness.setBasketMetadata(basketId, "ipfs://alt-v2", 5);

        vm.expectEmit(false, false, false, true);
        emit ProtocolURIUpdated("", "ipfs://protocol");
        harness.setProtocolURI("ipfs://protocol");

        vm.expectEmit(false, false, false, true);
        emit ContractVersionUpdated("", "v1.0.0");
        harness.setContractVersion("v1.0.0");

        vm.expectEmit(true, false, false, true);
        emit FacetVersionUpdated(address(harness), "", "facet-v1");
        harness.setFacetVersion(address(harness), "facet-v1");

        vm.expectEmit(true, false, false, true);
        emit BasketPausedUpdated(basketId, true);
        harness.setBasketPaused(basketId, true);

        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = 25;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = 30;
        vm.expectEmit(true, false, false, true);
        emit BasketFeeConfigUpdated(basketId, mintFees, burnFees, 75);
        harness.setBasketFees(basketId, mintFees, burnFees, 75);

        vm.expectEmit(false, false, false, true);
        emit PoolFeeShareUpdated(1000, 1500);
        harness.setPoolFeeShareBps(1500);

        EdenAdminFacet.GovernanceConfigView memory governance = harness.getGovernanceConfig();
        _assertEq(uint256(uint160(governance.owner)), uint256(uint160(ownerAdmin)), "owner readback");
        _assertEq(uint256(uint160(governance.timelock)), uint256(uint160(address(this))), "timelock readback");
        _assertEq(governance.timelockDelaySeconds, 7 days, "delay readback");
        _assertEqBytes32(keccak256(bytes(governance.protocolURI)), keccak256(bytes("ipfs://protocol")), "protocol uri");
        _assertEqBytes32(keccak256(bytes(governance.contractVersion)), keccak256(bytes("v1.0.0")), "contract version");
        _assertEqBytes32(
            keccak256(bytes(harness.facetVersion(address(harness)))),
            keccak256(bytes("facet-v1")),
            "facet version"
        );
    }

    function test_ProductConfigWrites_FollowTimelockPath() public {
        (uint256 basketId,) =
            harness.createBasket(_singleAssetParams("Lend Basket", "LEND", address(alt), "ipfs://lend", 0));

        vm.prank(ownerAdmin);
        (bool rewardOk,) = address(harness).call(
            abi.encodeWithSelector(harness.configureRewards.selector, address(eve), 10e18, true)
        );
        _assertTrue(!rewardOk, "owner reward config should fail");

        vm.prank(ownerAdmin);
        (bool lendOk,) = address(harness).call(
            abi.encodeWithSelector(harness.configureLending.selector, basketId, uint40(1 days), uint40(14 days))
        );
        _assertTrue(!lendOk, "owner lending config should fail");

        vm.expectEmit(true, false, false, true);
        emit RewardConfigUpdated(address(eve), 10e18, true);
        harness.configureRewards(address(eve), 10e18, true);

        vm.expectEmit(true, false, false, true);
        emit LendingConfigUpdated(basketId, 1 days, 14 days, 10_000);
        harness.configureLending(basketId, 1 days, 14 days);

        EdenViewFacet.ProductConfigView memory config = harness.getProductConfig();
        _assertEq(config.timelockDelaySeconds, 7 days, "product config delay");
        _assertEq(uint256(uint160(config.timelock)), uint256(uint160(address(this))), "product config timelock");
        _assertEq(uint256(uint160(config.rewardToken)), uint256(uint160(address(eve))), "product config reward token");
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
