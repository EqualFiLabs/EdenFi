// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DeployEdenByEqualFi} from "script/DeployEdenByEqualFi.s.sol";
import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EdenAdminFacet} from "src/eden/EdenAdminFacet.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenStEVEActionFacet} from "src/eden/EdenStEVEActionFacet.sol";
import {EdenStEVEWalletFacet} from "src/eden/EdenStEVEWalletFacet.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {BasketToken} from "src/tokens/BasketToken.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {Types} from "src/libraries/Types.sol";
import {ProtocolTestSupportFacet} from "test/utils/ProtocolTestSupport.sol";
import {
    MockEntryPointLaunch,
    MockERC6551RegistryLaunch,
    MockIdentityRegistryLaunch
} from "test/utils/PositionAgentBootstrapMocks.sol";

contract MockERC20Launch is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeOnTransferLaunch is ERC20 {
    uint256 internal constant BPS = 10_000;

    uint256 public feeBps = 1000;
    address public feeSink = address(0xdead);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

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

abstract contract EdenLaunchFixture is DeployEdenByEqualFi {
    address internal treasury = _addr("treasury");
    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal carol = _addr("carol");

    address internal diamond;
    PositionNFT internal positionNft;
    FixedDelayTimelockController internal timelockController;
    ProtocolTestSupportFacet internal testSupport;

    MockERC20Launch internal eve;
    MockERC20Launch internal alt;
    MockFeeOnTransferLaunch internal fot;
    MockEntryPointLaunch internal entryPoint;
    MockERC6551RegistryLaunch internal erc6551Registry;
    MockIdentityRegistryLaunch internal identityRegistry;

    uint256 internal steveBasketId;
    address internal steveToken;
    uint256 internal altBasketId;
    address internal altBasketToken;
    uint256 internal timelockSaltNonce;

    function setUp() public virtual {
        entryPoint = new MockEntryPointLaunch();
        erc6551Registry = new MockERC6551RegistryLaunch();
        identityRegistry = new MockIdentityRegistryLaunch();

        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );
        diamond = deployment.diamond;
        positionNft = PositionNFT(deployment.positionNFT);
        timelockController = FixedDelayTimelockController(payable(deployment.timelockController));

        eve = new MockERC20Launch("EVE", "EVE");
        alt = new MockERC20Launch("ALT", "ALT");
        fot = new MockFeeOnTransferLaunch("FoT", "FOT");
    }

    function _bootstrapCorePools() internal {
        _setDefaultPoolConfig(_poolConfig());
        _initPoolWithActionFees(1, address(eve), _poolConfig(), _actionFees());
        _initPoolWithActionFees(2, address(alt), _poolConfig(), _actionFees());
    }

    function _bootstrapCorePoolsWithFoT() internal {
        _setDefaultPoolConfig(_poolConfig());
        _initPoolWithActionFees(1, address(eve), _poolConfig(), _actionFees());
        _initPoolWithActionFees(2, address(alt), _poolConfig(), _actionFees());
        _initPoolWithActionFees(3, address(fot), _poolConfig(), _actionFees());
    }

    function _bootstrapEdenProduct() internal pure {
        revert("legacy EDEN bootstrap removed");
    }

    function _timelockCall(address target, bytes memory data) internal returns (bytes memory result) {
        bytes32 salt = keccak256(abi.encodePacked("edenfi-test-salt", timelockSaltNonce++));
        timelockController.schedule(target, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        timelockController.execute(target, 0, data, bytes32(0), salt);
        result = "";
    }

    function _setDefaultPoolConfig(Types.PoolConfig memory config) internal {
        _timelockCall(diamond, abi.encodeWithSelector(PoolManagementFacet.setDefaultPoolConfig.selector, config));
    }

    function _initPoolWithActionFees(
        uint256 pid,
        address underlying,
        Types.PoolConfig memory config,
        Types.ActionFeeSet memory actionFees
    ) internal {
        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                PoolManagementFacet.initPoolWithActionFees.selector, pid, underlying, config, actionFees
            )
        );
    }

    function _createBasket(EdenBasketBase.CreateBasketParams memory params)
        internal
        pure
        returns (uint256 basketId, address basketToken)
    {
        params;
        basketId = 0;
        basketToken = address(0);
        revert("generic EDEN basket creation removed");
    }

    function _createStEVE(EdenBasketBase.CreateBasketParams memory params)
        internal
        returns (uint256 basketId, address basketToken)
    {
        _timelockCall(diamond, abi.encodeWithSelector(EdenStEVEActionFacet.createStEVE.selector, params));
        basketId = EdenStEVEActionFacet(diamond).steveBasketId();
        basketToken = EdenViewFacet(diamond).getProductConfig().token;
    }

    function _createIndex(EqualIndexBaseV3.CreateIndexParams memory params)
        internal
        returns (uint256 indexId, address indexToken)
    {
        (indexId, indexToken) = EqualIndexAdminFacetV3(diamond).createIndex(params);
    }

    function _createIndexThroughTimelock(EqualIndexBaseV3.CreateIndexParams memory params)
        internal
        returns (uint256 indexId, address indexToken)
    {
        indexId = _nextIndexId();
        _timelockCall(diamond, abi.encodeWithSelector(EqualIndexAdminFacetV3.createIndex.selector, params));
        indexToken = EqualIndexAdminFacetV3(diamond).getIndex(indexId).token;
    }

    function _configureRewards(address rewardToken, uint256 rewardRatePerSecond, bool enabled) internal {
        _timelockCall(
            diamond,
            abi.encodeWithSelector(EdenRewardFacet.configureRewards.selector, rewardToken, rewardRatePerSecond, enabled)
        );
    }

    function _configureLending(uint256 basketId, uint40 minDuration, uint40 maxDuration) internal {
        _timelockCall(
            diamond,
            abi.encodeWithSelector(EdenLendingFacet.configureLending.selector, basketId, minDuration, maxDuration)
        );
    }

    function _configureBorrowFeeTiers(
        uint256 basketId,
        uint256[] memory minCollateralUnits,
        uint256[] memory flatFeeNative
    ) internal {
        _timelockCall(
            diamond,
            abi.encodeWithSelector(
                EdenLendingFacet.configureBorrowFeeTiers.selector, basketId, minCollateralUnits, flatFeeNative
            )
        );
    }

    function _setBasketMetadata(uint256 basketId, string memory uri, uint8 basketType) internal {
        _timelockCall(
            diamond, abi.encodeWithSelector(EdenAdminFacet.setBasketMetadata.selector, basketId, uri, basketType)
        );
    }

    function _setProtocolURI(string memory uri) internal {
        _timelockCall(diamond, abi.encodeWithSelector(EdenAdminFacet.setProtocolURI.selector, uri));
    }

    function _setContractVersion(string memory version_) internal {
        _timelockCall(diamond, abi.encodeWithSelector(EdenAdminFacet.setContractVersion.selector, version_));
    }

    function _setFacetVersion(address facet, string memory version_) internal {
        _timelockCall(diamond, abi.encodeWithSelector(EdenAdminFacet.setFacetVersion.selector, facet, version_));
    }

    function _setBasketPaused(uint256 basketId, bool paused) internal {
        _timelockCall(diamond, abi.encodeWithSelector(EdenAdminFacet.setBasketPaused.selector, basketId, paused));
    }

    function _setBasketFees(
        uint256 basketId,
        uint16[] memory mintFeeBps,
        uint16[] memory burnFeeBps,
        uint16 flashFeeBps
    ) internal {
        _timelockCall(
            diamond,
            abi.encodeWithSelector(EdenAdminFacet.setBasketFees.selector, basketId, mintFeeBps, burnFeeBps, flashFeeBps)
        );
    }

    function _setPoolFeeShareBps(uint16 poolFeeShareBps) internal {
        _timelockCall(diamond, abi.encodeWithSelector(EdenAdminFacet.setPoolFeeShareBps.selector, poolFeeShareBps));
    }

    function _setTimelockController(address newController) internal {
        _timelockCall(diamond, abi.encodeWithSelector(EdenAdminFacet.setTimelockController.selector, newController));
        timelockController = FixedDelayTimelockController(payable(newController));
    }

    function _mintPosition(address user, uint256 homePoolId) internal returns (uint256 positionId) {
        vm.prank(user);
        positionId = PositionManagementFacet(diamond).mintPosition(homePoolId);
    }

    function _installTestSupportFacet() internal {
        ProtocolTestSupportFacet facet = new ProtocolTestSupportFacet();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = ProtocolTestSupportFacet.setManagedPoolCreationFee.selector;
        selectors[1] = ProtocolTestSupportFacet.setManagedPoolSystemShareBps.selector;
        selectors[2] = ProtocolTestSupportFacet.setTreasuryShareBps.selector;
        selectors[3] = ProtocolTestSupportFacet.setActiveCreditShareBps.selector;
        selectors[4] = ProtocolTestSupportFacet.setFoundationReceiver.selector;
        selectors[5] = ProtocolTestSupportFacet.assetToPoolId.selector;
        selectors[6] = ProtocolTestSupportFacet.permissionlessPoolForToken.selector;
        selectors[7] = ProtocolTestSupportFacet.getPoolView.selector;
        selectors[8] = ProtocolTestSupportFacet.isWhitelisted.selector;
        selectors[9] = ProtocolTestSupportFacet.principalOf.selector;
        selectors[10] = ProtocolTestSupportFacet.canClearMembership.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        _timelockCall(diamond, abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts, address(0), bytes("")));

        bytes4[] memory routeSelectors = new bytes4[](1);
        routeSelectors[0] = ProtocolTestSupportFacet.routeManagedShareExternal.selector;
        IDiamondCut.FacetCut[] memory routeCut = new IDiamondCut.FacetCut[](1);
        routeCut[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: routeSelectors
        });
        _timelockCall(diamond, abi.encodeWithSelector(IDiamondCut.diamondCut.selector, routeCut, address(0), bytes("")));

        testSupport = ProtocolTestSupportFacet(diamond);
    }

    function _mintWalletBasket(address user, uint256 basketId, ERC20 asset, uint256 units) internal {
        require(basketId == steveBasketId, "wallet mint only supports stEVE");
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = units;
        vm.startPrank(user);
        asset.approve(diamond, units);
        EdenStEVEWalletFacet(diamond).mintStEVE(units, user, maxInputs);
        vm.stopPrank();
    }

    function _depositWalletStEVEToPosition(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        BasketToken(steveToken).approve(diamond, amount);
        EdenStEVEActionFacet(diamond).depositStEVEToPosition(positionId, amount, amount);
        vm.stopPrank();
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

    function _actionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        actionFees.borrowFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.repayFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.withdrawFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.flashFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.closeRollingFee = Types.ActionFeeConfig({amount: 0, enabled: false});
    }

    function _singleAssetParams(
        string memory name_,
        string memory symbol_,
        address asset,
        string memory uri_,
        uint8 basketType,
        uint16 mintFee,
        uint16 burnFee
    ) internal pure returns (EdenBasketBase.CreateBasketParams memory p) {
        p.name = name_;
        p.symbol = symbol_;
        p.uri = uri_;
        p.assets = new address[](1);
        p.assets[0] = asset;
        p.bundleAmounts = new uint256[](1);
        p.bundleAmounts[0] = 1e18;
        p.mintFeeBps = new uint16[](1);
        p.mintFeeBps[0] = mintFee;
        p.burnFeeBps = new uint16[](1);
        p.burnFeeBps[0] = burnFee;
        p.flashFeeBps = 50;
        p.basketType = basketType;
    }

    function _stEveParams(address asset) internal pure returns (EdenBasketBase.CreateBasketParams memory p) {
        p = _singleAssetParams("stEVE", "stEVE", asset, "ipfs://steve", 1, 0, 0);
    }

    function _singleAssetIndexParams(
        string memory name_,
        string memory symbol_,
        address asset,
        uint16 mintFee,
        uint16 burnFee
    ) internal pure returns (EqualIndexBaseV3.CreateIndexParams memory p) {
        p.name = name_;
        p.symbol = symbol_;
        p.assets = new address[](1);
        p.assets[0] = asset;
        p.bundleAmounts = new uint256[](1);
        p.bundleAmounts[0] = 1e18;
        p.mintFeeBps = new uint16[](1);
        p.mintFeeBps[0] = mintFee;
        p.burnFeeBps = new uint16[](1);
        p.burnFeeBps[0] = burnFee;
        p.flashFeeBps = 50;
    }

    function _boundUint(uint256 value, uint256 min, uint256 max) internal pure returns (uint256 bounded) {
        require(max >= min, "invalid bound");
        if (min == max) return min;
        uint256 size = max - min + 1;
        bounded = min + (value % size);
    }

    function _nextIndexId() internal view returns (uint256 indexId) {
        while (true) {
            try EqualIndexAdminFacetV3(diamond).getIndex(indexId) returns (EqualIndexBaseV3.IndexView memory) {
                indexId++;
            } catch {
                return indexId;
            }
        }
        return indexId;
    }

    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }

    function assertTrue(bool condition) internal pure {
        require(condition, "assertTrue failed");
    }

    function assertEq(uint256 left, uint256 right) internal pure {
        require(left == right, "assertEq(uint256) failed");
    }

    function assertEq(address left, address right) internal pure {
        require(left == right, "assertEq(address) failed");
    }

    function assertEq(bytes32 left, bytes32 right) internal pure {
        require(left == right, "assertEq(bytes32) failed");
    }

    function assertEq(string memory left, string memory right) internal pure {
        require(keccak256(bytes(left)) == keccak256(bytes(right)), "assertEq(string) failed");
    }

    function assertGt(uint256 left, uint256 right) internal pure {
        require(left > right, "assertGt failed");
    }
}
