// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {DeployEdenByEqualFi} from "script/DeployEdenByEqualFi.s.sol";
import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {OwnershipFacet} from "src/core/OwnershipFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {FlashLoanFacet} from "src/equallend/FlashLoanFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {PositionAgent_ConfigLocked} from "src/libraries/PositionAgentErrors.sol";
import {EdenAdminFacet} from "src/eden/EdenAdminFacet.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenBasketPositionFacet} from "src/eden/EdenBasketPositionFacet.sol";
import {EdenStEVEActionFacet} from "src/eden/EdenStEVEActionFacet.sol";
import {EdenStEVEWalletFacet} from "src/eden/EdenStEVEWalletFacet.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {Types} from "src/libraries/Types.sol";
import {
    MockEntryPointLaunch,
    MockERC6551RegistryLaunch,
    MockIdentityRegistryLaunch
} from "test/utils/PositionAgentBootstrapMocks.sol";
import {ILegacyEdenPositionFacet} from "test/utils/LegacyEdenPositionFacet.sol";
import {ILegacyEdenWalletFacet} from "test/utils/LegacyEdenWalletFacet.sol";

contract MockERC20Deploy is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployEdenByEqualFiTest is DeployEdenByEqualFi {
    uint256 internal constant EIP170_RUNTIME_CODE_SIZE_LIMIT = 24_576;
    bytes4 internal constant LEGACY_SET_BASKET_METADATA_SELECTOR =
        bytes4(keccak256("setBasketMetadata(uint256,string,uint8)"));

    struct EdenDeploymentState {
        uint256 steveBasketId;
        address steveToken;
        uint256 altBasketId;
        address altBasketToken;
    }

    address internal treasury = _addr("treasury");
    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal carol = _addr("carol");
    uint256 internal externalOwnerPk = uint256(0xA71CE);
    address internal externalOwner = vm.addr(externalOwnerPk);
    uint256 internal timelockSaltNonce;

    MockERC20Deploy internal eve;
    MockERC20Deploy internal alt;
    MockEntryPointLaunch internal entryPoint;
    MockERC6551RegistryLaunch internal erc6551Registry;
    MockIdentityRegistryLaunch internal identityRegistry;

    PositionNFT internal positionNft;
    address internal diamond;

    function setUp() public {
        eve = new MockERC20Deploy("EVE", "EVE");
        alt = new MockERC20Deploy("ALT", "ALT");
        entryPoint = new MockEntryPointLaunch();
        erc6551Registry = new MockERC6551RegistryLaunch();
        identityRegistry = new MockIdentityRegistryLaunch();

        BaseDeployment memory deployment = deployBase(address(this), treasury);
        diamond = deployment.diamond;
        positionNft = PositionNFT(deployment.positionNFT);
        _installLaunchFacets(diamond);
    }

    function test_DeployLaunch_WiresDiamondCoreAndMinimalFacetSet() public view {
        _assertEqAddress(OwnershipFacet(diamond).owner(), address(this), "owner wired");
        _assertEqAddress(positionNft.minter(), diamond, "position nft minter");
        _assertEqAddress(positionNft.diamond(), diamond, "position nft diamond");

        address[] memory facetAddresses = IDiamondLoupe(diamond).facetAddresses();
        _assertEq(facetAddresses.length, 23, "facet count");

        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionManagementFacet.mintPosition.selector) != address(0),
            "position facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(FlashLoanFacet.flashLoan.selector) != address(0), "pool flash facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EqualIndexAdminFacetV3.createIndex.selector) != address(0),
            "equalindex facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EqualIndexActionsFacetV3.flashLoan.selector) != address(0),
            "index flash action cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionAgentConfigFacet.setERC6551Registry.selector) != address(0),
            "position agent config facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionAgentTBAFacet.deployTBA.selector) != address(0),
            "position agent tba facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionAgentViewFacet.getTBAInterfaceSupport.selector) != address(0),
            "position agent view facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionAgentViewFacet.isCanonicalAgentLink.selector) != address(0),
            "position agent canonical link view cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionAgentViewFacet.isExternalAgentLink.selector) != address(0),
            "position agent external link view cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionAgentViewFacet.isRegistrationComplete.selector) != address(0),
            "position agent registration complete view cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionAgentRegistryFacet.recordAgentRegistration.selector)
                != address(0),
            "position agent registry facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EqualScaleAlphaFacet.registerBorrowerProfile.selector) != address(0),
            "equalscale alpha facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EqualScaleAlphaAdminFacet.freezeLine.selector) != address(0),
            "equalscale alpha admin facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EqualScaleAlphaViewFacet.getBorrowerProfile.selector) != address(0),
            "equalscale alpha view facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EdenStEVEWalletFacet.mintStEVE.selector) != address(0),
            "eden stEVE wallet facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EdenBasketPositionFacet.mintStEVEFromPosition.selector) != address(0),
            "eden stEVE position facet cut"
        );
        _assertEqAddress(
            IDiamondLoupe(diamond).facetAddress(ILegacyEdenPositionFacet.mintBasketFromPosition.selector),
            address(0),
            "legacy eden position mint removed"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EdenViewFacet.getPositionTokenURI.selector) != address(0),
            "position metadata hook cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EdenViewFacet.getPositionAgentView.selector) != address(0),
            "position agent aggregate view cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EdenAdminFacet.setProductMetadata.selector) != address(0),
            "eden product admin facet cut"
        );
        _assertEqAddress(
            IDiamondLoupe(diamond).facetAddress(LEGACY_SET_BASKET_METADATA_SELECTOR),
            address(0),
            "legacy eden basket metadata selector removed"
        );
    }

    function test_DeployLaunch_WiresEqualScaleAlphaSelectorGroupsIntoLiveDiamond() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);

        _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlpha());
        _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlphaAdmin());
        _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlphaView());
    }

    function test_DeployLaunch_KeepsCanonicalNonEdenSelectorsInSubstrateAndEqualIndex() public view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        address poolFlashFacet = loupe.facetAddress(FlashLoanFacet.flashLoan.selector);
        _assertTrue(poolFlashFacet != address(0), "pool flash selector installed");
        _assertEqAddress(
            poolFlashFacet,
            loupe.facetAddress(FlashLoanFacet.previewFlashLoanRepayment.selector),
            "pool flash selectors stay together"
        );

        address equalIndexActionsFacet = loupe.facetAddress(EqualIndexActionsFacetV3.flashLoan.selector);
        _assertTrue(equalIndexActionsFacet != address(0), "index flash selector installed");
        _assertEqAddress(
            equalIndexActionsFacet,
            loupe.facetAddress(EqualIndexActionsFacetV3.mint.selector),
            "wallet-mode generic mint stays in EqualIndex"
        );
        _assertEqAddress(
            equalIndexActionsFacet,
            loupe.facetAddress(EqualIndexActionsFacetV3.burn.selector),
            "wallet-mode generic burn stays in EqualIndex"
        );

        address equalIndexPositionFacet = loupe.facetAddress(EqualIndexPositionFacet.mintFromPosition.selector);
        _assertTrue(equalIndexPositionFacet != address(0), "position-mode EqualIndex selector installed");
        _assertEqAddress(
            equalIndexPositionFacet,
            loupe.facetAddress(EqualIndexPositionFacet.burnFromPosition.selector),
            "position-mode generic burn stays in EqualIndex"
        );

        _assertTrue(poolFlashFacet != equalIndexActionsFacet, "pool and index flash lanes stay separate");
        _assertTrue(equalIndexActionsFacet != equalIndexPositionFacet, "EqualIndex action and position lanes stay explicit");
        _assertTrue(
            loupe.facetAddress(EdenStEVEWalletFacet.mintStEVE.selector) != equalIndexActionsFacet,
            "EDEN wallet selector does not own generic EqualIndex wallet flows"
        );
        _assertTrue(
            loupe.facetAddress(EdenBasketPositionFacet.mintStEVEFromPosition.selector) != equalIndexPositionFacet,
            "EDEN position selector does not own generic EqualIndex position flows"
        );
    }

    function test_DeployLaunch_KeepsEqualScaleAlphaFacetsWithinEip170RuntimeLimit() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);

        address alphaFacet = _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlpha());
        address alphaAdminFacet = _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlphaAdmin());
        address alphaViewFacet = _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlphaView());

        _assertCodeSizeLe(alphaFacet, EIP170_RUNTIME_CODE_SIZE_LIMIT, "alpha facet too large");
        _assertCodeSizeLe(alphaAdminFacet, EIP170_RUNTIME_CODE_SIZE_LIMIT, "alpha admin facet too large");
        _assertCodeSizeLe(alphaViewFacet, EIP170_RUNTIME_CODE_SIZE_LIMIT, "alpha view facet too large");
    }

    function test_DeployLaunch_HandsOffGovernanceToFixedDelayTimelock() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );
        address launchedDiamond = deployment.diamond;
        FixedDelayTimelockController controller = FixedDelayTimelockController(payable(deployment.timelockController));

        _assertEqAddress(OwnershipFacet(launchedDiamond).owner(), address(controller), "owner handed to controller");
        _assertEq(controller.getMinDelay(), 7 days, "controller delay");

        EdenViewFacet.ProductConfigView memory product = EdenViewFacet(launchedDiamond).getProductConfig();
        _assertEqAddress(product.timelock, address(controller), "product timelock");

        vm.expectRevert(bytes("LibAccess: not timelock"));
        EdenAdminFacet(launchedDiamond).setProtocolURI("ipfs://blocked");

        _timelockCall(
            controller,
            launchedDiamond,
            abi.encodeWithSelector(EdenAdminFacet.setProtocolURI.selector, "ipfs://timelocked")
        );

        _assertEqBytes32(
            keccak256(bytes(EdenAdminFacet(launchedDiamond).protocolURI())),
            keccak256(bytes("ipfs://timelocked")),
            "timelock admin call succeeds"
        );
    }

    function test_DeployLaunch_TimelockRejectsInvalidDelayMutation() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );
        FixedDelayTimelockController controller = FixedDelayTimelockController(payable(deployment.timelockController));

        bytes memory data = abi.encodeWithSelector(FixedDelayTimelockController.updateDelay.selector, 1 days);
        bytes32 salt = keccak256("invalid-delay");

        controller.schedule(address(controller), 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                FixedDelayTimelockController.FixedDelayTimelockController_InvalidDelay.selector, 1 days, 7 days
            )
        );
        controller.execute(address(controller), 0, data, bytes32(0), salt);
    }

    function test_DeployLaunch_SupportsWalletFlowsAndAdminReads() public {
        EdenDeploymentState memory state = _bootstrapEdenProduct();

        alt.mint(bob, 200e18);
        vm.startPrank(bob);
        alt.approve(diamond, 200e18);
        uint256[] memory maxAltInputs = new uint256[](1);
        maxAltInputs[0] = 50e18;
        ILegacyEdenWalletFacet(diamond).mintBasket(state.altBasketId, 50e18, bob, maxAltInputs);
        ILegacyEdenWalletFacet(diamond).burnBasket(state.altBasketId, 50e18, bob);
        vm.stopPrank();
        _assertEq(ERC20(state.altBasketToken).balanceOf(bob), 0, "wallet basket burned");

        EdenAdminFacet(diamond).setProtocolURI("ipfs://eden-by-equalfi");
        EdenAdminFacet(diamond).setContractVersion("launch-v1");

        EdenViewFacet.ProductConfigView memory product = EdenViewFacet(diamond).getProductConfig();
        _assertEqAddress(product.timelock, address(0), "timelock unset before launch handoff");
        _assertEqAddress(product.treasury, treasury, "treasury set");
        _assertEq(product.steveBasketId, state.steveBasketId, "stEVE basket id");
        _assertEqAddress(product.rewardToken, address(eve), "reward token");
    }

    function test_DeployLaunch_SupportsPositionRewardsAndLending() public {
        EdenDeploymentState memory state = _bootstrapEdenProduct();

        eve.mint(alice, 500e18);
        alt.mint(alice, 500e18);

        vm.startPrank(alice);
        eve.approve(diamond, 500e18);
        alt.approve(diamond, 500e18);

        uint256[] memory maxSteveInputs = new uint256[](1);
        maxSteveInputs[0] = 100e18;
        EdenStEVEWalletFacet(diamond).mintStEVE(100e18, alice, maxSteveInputs);

        uint256 stevePositionId = PositionManagementFacet(diamond).mintPosition(1);
        ERC20(state.steveToken).approve(diamond, 100e18);
        EdenStEVEActionFacet(diamond).depositStEVEToPosition(stevePositionId, 100e18, 100e18);

        uint256 altPositionId = PositionManagementFacet(diamond).mintPosition(2);
        PositionManagementFacet(diamond).depositToPosition(altPositionId, 2, 200e18, 200e18);
        ILegacyEdenPositionFacet(diamond).mintBasketFromPosition(altPositionId, state.altBasketId, 100e18);
        vm.stopPrank();

        EdenViewFacet.ActionCheck memory borrowCheck =
            EdenViewFacet(diamond).canBorrow(altPositionId, 30e18, 7 days);
        _assertTrue(borrowCheck.ok, "borrow check");

        vm.prank(alice);
        uint256 loanId = EdenLendingFacet(diamond).borrow(altPositionId, 30e18, 7 days);
        _assertEq(EdenLendingFacet(diamond).loanCount(), 1, "loan created");

        vm.prank(alice);
        EdenLendingFacet(diamond).repay(altPositionId, loanId);

        eve.mint(address(this), 500e18);
        eve.approve(diamond, 500e18);
        EdenRewardFacet(diamond).fundRewards(500e18, 500e18);

        vm.warp(block.timestamp + 1 days);

        _assertGt(EdenRewardFacet(diamond).previewClaimRewards(stevePositionId), 0, "claim preview positive");
        _assertGt(bytes(positionNft.tokenURI(stevePositionId)).length, 0, "token uri available");

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, stevePositionId);
        _assertEqAddress(positionNft.ownerOf(stevePositionId), carol, "position transferred");

        EdenViewFacet.PositionPortfolio memory positionPortfolioBeforeClaim =
            EdenViewFacet(diamond).getPositionPortfolio(stevePositionId);
        _assertEqAddress(positionPortfolioBeforeClaim.owner, carol, "portfolio owner");
        _assertGt(positionPortfolioBeforeClaim.rewards.claimableRewards, 0, "portfolio rewards visible");

        uint256 before = eve.balanceOf(carol);
        vm.prank(carol);
        uint256 claimed = EdenRewardFacet(diamond).claimRewards(stevePositionId, carol);
        _assertGt(claimed, 0, "rewards claimed");
        _assertEq(eve.balanceOf(carol), before + claimed, "reward balance increased");
    }

    function _bootstrapEdenProduct() internal returns (EdenDeploymentState memory state) {
        PoolManagementFacet pools = PoolManagementFacet(diamond);

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        pools.setDefaultPoolConfig(cfg);
        pools.initPoolWithActionFees(1, address(eve), cfg, actionFees);
        pools.initPoolWithActionFees(2, address(alt), cfg, actionFees);

        (state.steveBasketId, state.steveToken) = EdenStEVEActionFacet(diamond).createStEVE(_stEveParams(address(eve)));
        (state.altBasketId, state.altBasketToken) = ILegacyEdenWalletFacet(diamond)
            .createBasket(_singleAssetParams("ALT Basket", "ALTB", address(alt), "ipfs://alt"));

        EdenRewardFacet(diamond).configureRewards(address(eve), 1e18, true);
        EdenLendingFacet(diamond).configureLending(1 days, 14 days);

        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        EdenLendingFacet(diamond).configureBorrowFeeTiers(mins, fees);
    }

    function _timelockCall(FixedDelayTimelockController controller, address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encodePacked("edenfi-timelock", timelockSaltNonce++));
        controller.schedule(target, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        controller.execute(target, 0, data, bytes32(0), salt);
    }

    function _singleAssetParams(string memory name_, string memory symbol_, address asset, string memory uri_)
        internal
        pure
        returns (EdenBasketBase.CreateBasketParams memory p)
    {
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
        p.basketType = 0;
    }

    function _stEveParams(address eveToken) internal pure returns (EdenBasketBase.CreateBasketParams memory p) {
        p = _singleAssetParams("stEVE", "stEVE", eveToken, "ipfs://steve");
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

    function _assertEqAddress(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function _assertEqBytes32(bytes32 left, bytes32 right, string memory message) internal pure {
        require(left == right, message);
    }

    function _assertGt(uint256 left, uint256 right, string memory message) internal pure {
        require(left > right, message);
    }

    function _assertSelectorGroupInstalled(IDiamondLoupe loupe, bytes4[] memory expectedSelectors)
        internal
        view
        returns (address facet)
    {
        facet = loupe.facetAddress(expectedSelectors[0]);
        _assertTrue(facet != address(0), "selector group missing");

        bytes4[] memory actualSelectors = loupe.facetFunctionSelectors(facet);
        _assertEq(actualSelectors.length, expectedSelectors.length, "selector group length");

        for (uint256 i = 0; i < expectedSelectors.length; i++) {
            _assertEqAddress(loupe.facetAddress(expectedSelectors[i]), facet, "selector routed to wrong facet");
            _assertTrue(_containsSelector(actualSelectors, expectedSelectors[i]), "selector missing from facet");
        }
    }

    function _assertCodeSizeLe(address account, uint256 limit, string memory message) internal view {
        _assertTrue(account.code.length <= limit, message);
    }

    function _containsSelector(bytes4[] memory selectors, bytes4 target) internal pure returns (bool) {
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] == target) {
                return true;
            }
        }
        return false;
    }

    function test_DeployLaunch_BootstrapsWalletConfig_AndLocksAfterFirstTBA() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );

        (address configuredRegistry, address configuredImplementation, address configuredIdentity) =
            PositionAgentViewFacet(deployment.diamond).getCanonicalRegistries();
        _assertEqAddress(configuredRegistry, address(erc6551Registry), "wallet registry set");
        _assertEqAddress(configuredIdentity, address(identityRegistry), "identity registry set");
        _assertEqAddress(configuredImplementation, deployment.positionMSCAImplementation, "wallet implementation set");

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        FixedDelayTimelockController controller = FixedDelayTimelockController(payable(deployment.timelockController));
        _timelockCall(
            controller,
            deployment.diamond,
            abi.encodeWithSelector(PoolManagementFacet.setDefaultPoolConfig.selector, cfg)
        );
        _timelockCall(
            controller,
            deployment.diamond,
            abi.encodeWithSelector(
                PoolManagementFacet.initPoolWithActionFees.selector, 1, address(eve), cfg, actionFees
            )
        );

        vm.prank(alice);
        uint256 tokenId = PositionManagementFacet(deployment.diamond).mintPosition(1);
        address expectedTba = PositionAgentTBAFacet(deployment.diamond).computeTBAAddress(tokenId);
        vm.prank(alice);
        address deployedTba = PositionAgentTBAFacet(deployment.diamond).deployTBA(tokenId);

        _assertEqAddress(deployedTba, expectedTba, "wallet deployed");
        _assertTrue(PositionAgentViewFacet(deployment.diamond).isTBADeployed(tokenId), "wallet flagged deployed");

        bytes memory data =
            abi.encodeWithSelector(PositionAgentConfigFacet.setIdentityRegistry.selector, address(identityRegistry));
        bytes32 salt = keccak256(abi.encodePacked("position-agent-config-lock", timelockSaltNonce++));
        controller.schedule(deployment.diamond, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(PositionAgent_ConfigLocked.selector);
        controller.execute(deployment.diamond, 0, data, bytes32(0), salt);
    }

    function test_DeployLaunch_IntegratesWalletRegistrationIntoLivePositionReads() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );

        Types.PoolConfig memory cfg = _poolConfig();
        FixedDelayTimelockController controller = FixedDelayTimelockController(payable(deployment.timelockController));
        _timelockCall(
            controller,
            deployment.diamond,
            abi.encodeWithSelector(PoolManagementFacet.setDefaultPoolConfig.selector, cfg)
        );
        _timelockCall(
            controller, deployment.diamond, abi.encodeWithSelector(bytes4(keccak256("initPool(address)")), address(eve))
        );

        vm.prank(alice);
        uint256 tokenId = PositionManagementFacet(deployment.diamond).mintPosition(1);

        address expectedTba = PositionAgentTBAFacet(deployment.diamond).computeTBAAddress(tokenId);
        vm.prank(alice);
        address deployedTba = PositionAgentTBAFacet(deployment.diamond).deployTBA(tokenId);

        _assertEqAddress(deployedTba, expectedTba, "wallet deployed");

        uint256 agentId = 42;
        identityRegistry.setOwner(agentId, deployedTba);

        vm.prank(alice);
        PositionAgentRegistryFacet(deployment.diamond).recordAgentRegistration(tokenId, agentId);

        _assertEq(PositionAgentViewFacet(deployment.diamond).getAgentId(tokenId), agentId, "agent id recorded");
        _assertTrue(PositionAgentViewFacet(deployment.diamond).isAgentRegistered(tokenId), "agent registered");
        _assertTrue(PositionAgentViewFacet(deployment.diamond).isCanonicalAgentLink(tokenId), "canonical link");
        _assertTrue(PositionAgentViewFacet(deployment.diamond).isRegistrationComplete(tokenId), "registration complete");

        EdenViewFacet.PositionAgentWalletView memory agentView =
            EdenViewFacet(deployment.diamond).getPositionAgentView(tokenId);
        _assertEqAddress(agentView.tbaAddress, deployedTba, "agent view tba");
        _assertTrue(agentView.tbaDeployed, "agent view deployed");
        _assertEq(agentView.agentId, agentId, "agent view id");
        _assertTrue(agentView.agentRegistered, "agent view registered");
        _assertEq(agentView.registrationMode, 1, "agent view mode");
        _assertTrue(agentView.canonicalLink, "agent view canonical");
        _assertTrue(!agentView.externalLink, "agent view external");
        _assertTrue(agentView.linkActive, "agent view active");
        _assertEqAddress(agentView.externalAuthorizer, address(0), "agent view authorizer");
        _assertTrue(agentView.registrationComplete, "agent view complete");

        EdenViewFacet.PositionPortfolio memory portfolio =
            EdenViewFacet(deployment.diamond).getPositionPortfolio(tokenId);
        _assertEqAddress(portfolio.owner, alice, "portfolio owner");
        _assertEqAddress(portfolio.agent.tbaAddress, deployedTba, "portfolio tba");
        _assertEq(portfolio.agent.agentId, agentId, "portfolio agent id");
        _assertEq(portfolio.agentRegistrationMode, 1, "portfolio mode");
        _assertTrue(portfolio.agent.canonicalLink, "portfolio canonical");
        _assertTrue(!portfolio.agent.externalLink, "portfolio external");
        _assertTrue(portfolio.agent.linkActive, "portfolio active");
        _assertTrue(portfolio.agent.registrationComplete, "portfolio complete");

        string memory tokenUri = PositionNFT(deployment.positionNFT).tokenURI(tokenId);
        string memory expectedUri = string.concat(
            "equalfi://positions/",
            Strings.toString(tokenId),
            "?poolId=1&tba=",
            Strings.toHexString(uint160(deployedTba), 20),
            "&tbaDeployed=true&agentId=",
            Strings.toString(agentId),
            "&agentMode=1&agentCanonical=true&agentExternal=false&agentActive=true&agentComplete=true"
        );
        _assertEqBytes32(keccak256(bytes(tokenUri)), keccak256(bytes(expectedUri)), "token uri agent state");
    }

    function test_DeployLaunch_IntegratesExternalWalletRegistration_AndCoexistsWithCanonical() public {
        LaunchDeployment memory deployment = deployLaunch(
            address(this),
            address(this),
            treasury,
            address(entryPoint),
            address(erc6551Registry),
            address(identityRegistry)
        );

        Types.PoolConfig memory cfg = _poolConfig();
        FixedDelayTimelockController controller = FixedDelayTimelockController(payable(deployment.timelockController));
        _timelockCall(
            controller,
            deployment.diamond,
            abi.encodeWithSelector(PoolManagementFacet.setDefaultPoolConfig.selector, cfg)
        );
        _timelockCall(
            controller, deployment.diamond, abi.encodeWithSelector(bytes4(keccak256("initPool(address)")), address(eve))
        );

        vm.prank(alice);
        uint256 canonicalTokenId = PositionManagementFacet(deployment.diamond).mintPosition(1);
        vm.prank(bob);
        uint256 externalTokenId = PositionManagementFacet(deployment.diamond).mintPosition(1);

        vm.prank(alice);
        address canonicalTba = PositionAgentTBAFacet(deployment.diamond).deployTBA(canonicalTokenId);
        vm.prank(bob);
        address externalTba = PositionAgentTBAFacet(deployment.diamond).deployTBA(externalTokenId);

        uint256 canonicalAgentId = 101;
        identityRegistry.setOwner(canonicalAgentId, canonicalTba);
        vm.prank(alice);
        PositionAgentRegistryFacet(deployment.diamond).recordAgentRegistration(canonicalTokenId, canonicalAgentId);

        uint256 externalAgentId = 202;
        uint256 deadline = block.timestamp + 1 days;
        identityRegistry.setOwner(externalAgentId, externalOwner);
        bytes32 digest =
            _externalLinkDigest(deployment.diamond, externalTokenId, externalAgentId, bob, externalTba, 0, deadline);
        bytes memory signature = _signDigest(externalOwnerPk, digest);

        vm.prank(bob);
        PositionAgentRegistryFacet(deployment.diamond)
            .linkExternalAgentRegistration(externalTokenId, externalAgentId, deadline, signature);

        _assertTrue(
            PositionAgentViewFacet(deployment.diamond).isCanonicalAgentLink(canonicalTokenId), "canonical path intact"
        );
        _assertTrue(
            !PositionAgentViewFacet(deployment.diamond).isExternalAgentLink(canonicalTokenId),
            "canonical path not external"
        );
        _assertTrue(
            !PositionAgentViewFacet(deployment.diamond).isCanonicalAgentLink(externalTokenId),
            "external path not canonical"
        );
        _assertTrue(
            PositionAgentViewFacet(deployment.diamond).isExternalAgentLink(externalTokenId), "external path active"
        );

        EdenViewFacet.PositionAgentWalletView memory externalAgentView =
            EdenViewFacet(deployment.diamond).getPositionAgentView(externalTokenId);
        _assertEqAddress(externalAgentView.tbaAddress, externalTba, "external tba");
        _assertEq(externalAgentView.agentId, externalAgentId, "external agent id");
        _assertEq(externalAgentView.registrationMode, 2, "external mode");
        _assertTrue(!externalAgentView.canonicalLink, "external canonical");
        _assertTrue(externalAgentView.externalLink, "external flag");
        _assertTrue(externalAgentView.linkActive, "external active");
        _assertEqAddress(externalAgentView.externalAuthorizer, externalOwner, "external authorizer");
        _assertTrue(externalAgentView.registrationComplete, "external complete");

        EdenViewFacet.PositionPortfolio memory canonicalPortfolio =
            EdenViewFacet(deployment.diamond).getPositionPortfolio(canonicalTokenId);
        EdenViewFacet.PositionPortfolio memory externalPortfolio =
            EdenViewFacet(deployment.diamond).getPositionPortfolio(externalTokenId);
        _assertEq(canonicalPortfolio.agentRegistrationMode, 1, "canonical portfolio mode");
        _assertEq(externalPortfolio.agentRegistrationMode, 2, "external portfolio mode");
        _assertTrue(canonicalPortfolio.agent.canonicalLink, "canonical portfolio link");
        _assertTrue(!canonicalPortfolio.agent.externalLink, "canonical portfolio ext");
        _assertTrue(!externalPortfolio.agent.canonicalLink, "external portfolio canonical");
        _assertTrue(externalPortfolio.agent.externalLink, "external portfolio link");
        _assertEqAddress(externalPortfolio.agent.externalAuthorizer, externalOwner, "portfolio authorizer");

        string memory tokenUri = PositionNFT(deployment.positionNFT).tokenURI(externalTokenId);
        string memory expectedUri = string.concat(
            "equalfi://positions/",
            Strings.toString(externalTokenId),
            "?poolId=1&tba=",
            Strings.toHexString(uint160(externalTba), 20),
            "&tbaDeployed=true&agentId=",
            Strings.toString(externalAgentId),
            "&agentMode=2&agentCanonical=false&agentExternal=true&agentActive=true&agentComplete=true"
        );
        _assertEqBytes32(keccak256(bytes(tokenUri)), keccak256(bytes(expectedUri)), "external token uri state");
    }

    function _externalLinkDigest(
        address diamond_,
        uint256 tokenId,
        uint256 agentId,
        address positionOwner,
        address tba,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EqualFiExternalAgentLink(uint256 chainId,address diamond,uint256 positionTokenId,uint256 agentId,address positionOwner,address tbaAddress,uint256 nonce,uint256 deadline)"
                ),
                block.chainid,
                diamond_,
                tokenId,
                agentId,
                positionOwner,
                tba,
                nonce,
                deadline
            )
        );
    }

    function _signDigest(uint256 signerPk, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
