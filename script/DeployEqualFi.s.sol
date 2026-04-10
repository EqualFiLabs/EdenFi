// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Diamond} from "src/core/Diamond.sol";
import {DiamondCutFacet} from "src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "src/core/OwnershipFacet.sol";
import {DiamondInit} from "src/core/DiamondInit.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";

import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {SelfSecuredCreditFacet} from "src/equallend/SelfSecuredCreditFacet.sol";
import {SelfSecuredCreditViewFacet} from "src/equallend/SelfSecuredCreditViewFacet.sol";
import {FlashLoanFacet} from "src/equallend/FlashLoanFacet.sol";
import {EqualLendDirectFixedOfferFacet} from "src/equallend/EqualLendDirectFixedOfferFacet.sol";
import {EqualLendDirectFixedAgreementFacet} from "src/equallend/EqualLendDirectFixedAgreementFacet.sol";
import {EqualLendDirectLifecycleFacet} from "src/equallend/EqualLendDirectLifecycleFacet.sol";
import {EqualLendDirectRollingOfferFacet} from "src/equallend/EqualLendDirectRollingOfferFacet.sol";
import {EqualLendDirectRollingAgreementFacet} from "src/equallend/EqualLendDirectRollingAgreementFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "src/equallend/EqualLendDirectRollingPaymentFacet.sol";
import {EqualLendDirectRollingLifecycleFacet} from "src/equallend/EqualLendDirectRollingLifecycleFacet.sol";
import {EqualLendDirectConfigFacet} from "src/equallend/EqualLendDirectConfigFacet.sol";
import {EqualLendDirectViewFacet} from "src/equallend/EqualLendDirectViewFacet.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionMSCAImpl} from "src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {EqualXSoloAmmFacet} from "src/equalx/EqualXSoloAmmFacet.sol";
import {EqualXCommunityAmmLiquidityFacet} from "src/equalx/EqualXCommunityAmmLiquidityFacet.sol";
import {EqualXCommunityAmmSwapFacet} from "src/equalx/EqualXCommunityAmmSwapFacet.sol";
import {EqualXCurveCreationFacet} from "src/equalx/EqualXCurveCreationFacet.sol";
import {EqualXCurveExecutionFacet} from "src/equalx/EqualXCurveExecutionFacet.sol";
import {EqualXCurveManagementFacet} from "src/equalx/EqualXCurveManagementFacet.sol";
import {EqualXViewFacet} from "src/equalx/EqualXViewFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {OptionTokenAdminFacet} from "src/options/OptionTokenAdminFacet.sol";
import {OptionTokenViewFacet} from "src/options/OptionTokenViewFacet.sol";
import {OptionsFacet} from "src/options/OptionsFacet.sol";
import {OptionsViewFacet} from "src/options/OptionsViewFacet.sol";
import {Types} from "src/libraries/Types.sol";

interface IPoolManagementFacetInitDefault {
    function initPool(address underlying) external payable returns (uint256);
}

contract LocalMockERC20 is ERC20 {
    uint8 internal immutable localDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        localDecimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return localDecimals;
    }
}

contract LocalMockFeeOnTransfer is LocalMockERC20 {
    uint256 internal constant BPS = 10_000;

    uint256 public feeBps = 1000;
    address public feeSink = address(0xdead);

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        LocalMockERC20(name_, symbol_, decimals_)
    {}

    function setFeeBps(uint256 newFeeBps) external {
        require(newFeeBps <= BPS, "feeBps");
        feeBps = newFeeBps;
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

contract DeployEqualFi is Script {
    string internal constant DEFAULT_OPTION_TOKEN_BASE_URI = "ipfs://equalfi/options";
    uint256 internal constant LOCAL_TEST_MINT_AMOUNT = 1_000_000e18;
    uint256 internal constant LOCAL_EVE_POOL_ID = 1;
    uint256 internal constant LOCAL_ALT_POOL_ID = 2;
    uint256 internal constant LOCAL_FOT_POOL_ID = 3;
    uint256 internal constant LOCAL_NATIVE_POOL_ID = 4;
    uint256 internal constant DIAMOND_CORE_FACET_COUNT = 3;
    uint256 internal constant DIRECT_LAUNCH_FACET_COUNT = 9;
    uint256 internal constant EQUALX_LAUNCH_FACET_COUNT = 7;
    uint256 internal constant SUBSTRATE_LAUNCH_FACET_COUNT = 27 + DIRECT_LAUNCH_FACET_COUNT;
    uint256 internal constant EDEN_REWARDS_FACET_COUNT = 1;
    uint256 internal constant LAUNCH_FACET_COUNT = SUBSTRATE_LAUNCH_FACET_COUNT + EDEN_REWARDS_FACET_COUNT;
    uint256 internal constant TOTAL_FACET_COUNT = DIAMOND_CORE_FACET_COUNT + LAUNCH_FACET_COUNT;
    uint256 internal constant CUT_BATCH_SIZE = 3;

    struct BaseDeployment {
        address diamond;
        address positionNFT;
    }

    struct LaunchDeployment {
        address diamond;
        address positionNFT;
        address timelockController;
        address governor;
        address treasury;
        address entryPoint;
        address erc6551Registry;
        address identityRegistry;
        address positionMSCAImplementation;
        address optionToken;
    }

    struct LocalLaunchDeployment {
        LaunchDeployment launch;
        address eveToken;
        address altToken;
        address fotToken;
        uint256 evePoolId;
        uint256 altPoolId;
        uint256 fotPoolId;
        uint256 nativePoolId;
    }

    struct LaunchSetup {
        BaseDeployment base;
        address timelockController;
        address optionToken;
        address positionMSCAImplementation;
    }

    struct LocalTestTokens {
        address eve;
        address alt;
        address fot;
    }

    struct LocalLaunchEnv {
        address owner;
        address governor;
        address treasury;
        address entryPoint;
        address erc6551Registry;
        address identityRegistry;
        uint256 deployerPrivateKey;
        address deployer;
    }

    struct LocalPoolBootstrap {
        uint256 evePoolId;
        uint256 altPoolId;
        uint256 fotPoolId;
        uint256 nativePoolId;
    }

    function runBase() external returns (BaseDeployment memory deployment) {
        address treasury_ = vm.envAddress("TREASURY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address owner_ = vm.envOr("OWNER", deployer);
        require(deployer == owner_, "DeployEqualFi: PRIVATE_KEY must be OWNER");

        vm.startBroadcast(deployerPrivateKey);
        deployment = deployBase(owner_, treasury_);
        vm.stopBroadcast();

        console2.log("diamond", deployment.diamond);
        console2.log("positionNFT", deployment.positionNFT);
    }

    function run() external returns (LaunchDeployment memory deployment) {
        LocalLaunchEnv memory env = _loadLaunchEnv();

        vm.startBroadcast(env.deployerPrivateKey);
        deployment = deployLaunch(
            env.owner, env.governor, env.treasury, env.entryPoint, env.erc6551Registry, env.identityRegistry
        );
        vm.stopBroadcast();

        console2.log("diamond", deployment.diamond);
        console2.log("positionNFT", deployment.positionNFT);
        console2.log("timelockController", deployment.timelockController);
        console2.log("governor", deployment.governor);
        console2.log("treasury", deployment.treasury);
        console2.log("entryPoint", deployment.entryPoint);
        console2.log("erc6551Registry", deployment.erc6551Registry);
        console2.log("identityRegistry", deployment.identityRegistry);
        console2.log("positionMSCAImplementation", deployment.positionMSCAImplementation);
        console2.log("optionToken", deployment.optionToken);
    }

    function runLocal() external returns (LocalLaunchDeployment memory deployment) {
        LocalLaunchEnv memory env = _loadLaunchEnv();

        vm.startBroadcast(env.deployerPrivateKey);
        deployment = deployLocalLaunch(
            env.owner, env.governor, env.treasury, env.entryPoint, env.erc6551Registry, env.identityRegistry
        );
        vm.stopBroadcast();

        console2.log("diamond", deployment.launch.diamond);
        console2.log("positionNFT", deployment.launch.positionNFT);
        console2.log("timelockController", deployment.launch.timelockController);
        console2.log("governor", deployment.launch.governor);
        console2.log("treasury", deployment.launch.treasury);
        console2.log("entryPoint", deployment.launch.entryPoint);
        console2.log("erc6551Registry", deployment.launch.erc6551Registry);
        console2.log("identityRegistry", deployment.launch.identityRegistry);
        console2.log("positionMSCAImplementation", deployment.launch.positionMSCAImplementation);
        console2.log("optionToken", deployment.launch.optionToken);
        console2.log("eveToken", deployment.eveToken);
        console2.log("altToken", deployment.altToken);
        console2.log("fotToken", deployment.fotToken);
        console2.log("evePoolId", deployment.evePoolId);
        console2.log("altPoolId", deployment.altPoolId);
        console2.log("fotPoolId", deployment.fotPoolId);
        console2.log("nativePoolId", deployment.nativePoolId);
    }

    function deployBase(address owner_, address treasury_) public returns (BaseDeployment memory deployment) {
        deployment = _deployBase(owner_, treasury_, address(0));
    }

    function _deployBase(address owner_, address treasury_, address timelock_)
        internal
        returns (BaseDeployment memory deployment)
    {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](DIAMOND_CORE_FACET_COUNT);
        cuts[0] = _cut(address(cut), _selectorsDiamondCut());
        cuts[1] = _cut(address(loupe), _selectorsDiamondLoupe());
        cuts[2] = _cut(address(own), _selectorsOwnership());

        Diamond diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: owner_}));
        PositionNFT nftContract = new PositionNFT();
        DiamondInit initializer = new DiamondInit();

        IDiamondCut(address(diamond))
            .diamondCut(
                new IDiamondCut.FacetCut[](0),
                address(initializer),
                abi.encodeWithSelector(DiamondInit.init.selector, timelock_, treasury_, address(nftContract))
            );

        deployment = BaseDeployment({diamond: address(diamond), positionNFT: address(nftContract)});
    }

    function deployLaunch(
        address owner_,
        address governor_,
        address treasury_,
        address entryPoint_,
        address erc6551Registry_,
        address identityRegistry_
    ) public returns (LaunchDeployment memory deployment) {
        LaunchSetup memory setup =
            _deployLaunchSetup(owner_, governor_, treasury_, entryPoint_, erc6551Registry_, identityRegistry_);
        deployment = _finalizeLaunch(setup, governor_, treasury_, entryPoint_, erc6551Registry_, identityRegistry_);
    }

    function deployLocalLaunch(
        address owner_,
        address governor_,
        address treasury_,
        address entryPoint_,
        address erc6551Registry_,
        address identityRegistry_
    ) public returns (LocalLaunchDeployment memory deployment) {
        LaunchSetup memory setup =
            _deployLaunchSetup(owner_, governor_, treasury_, entryPoint_, erc6551Registry_, identityRegistry_);
        LocalTestTokens memory tokens = _deployLocalTestTokens(owner_);
        LocalPoolBootstrap memory pools = _bootstrapLocalProtocol(setup.base.diamond, tokens);
        LaunchDeployment memory launch =
            _finalizeLaunch(setup, governor_, treasury_, entryPoint_, erc6551Registry_, identityRegistry_);

        deployment = LocalLaunchDeployment({
            launch: launch,
            eveToken: tokens.eve,
            altToken: tokens.alt,
            fotToken: tokens.fot,
            evePoolId: pools.evePoolId,
            altPoolId: pools.altPoolId,
            fotPoolId: pools.fotPoolId,
            nativePoolId: pools.nativePoolId
        });
    }

    function _installTimelock(address diamond, address treasury_, address timelock_) internal {
        DiamondInit initializer = new DiamondInit();
        IDiamondCut(diamond).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, timelock_, treasury_, address(0))
        );
    }

    function _loadLaunchEnv() internal view returns (LocalLaunchEnv memory env) {
        env.governor = vm.envAddress("TIMELOCK");
        env.treasury = vm.envAddress("TREASURY");
        env.entryPoint = vm.envAddress("ENTRYPOINT_ADDRESS");
        env.erc6551Registry = vm.envAddress("ERC6551_REGISTRY");
        env.identityRegistry = vm.envAddress("IDENTITY_REGISTRY");
        env.deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        env.deployer = vm.addr(env.deployerPrivateKey);
        env.owner = vm.envOr("OWNER", env.deployer);
        require(env.deployer == env.owner, "DeployEqualFi: PRIVATE_KEY must be OWNER");
    }

    function _deployLaunchSetup(
        address owner_,
        address governor_,
        address treasury_,
        address entryPoint_,
        address erc6551Registry_,
        address identityRegistry_
    ) internal returns (LaunchSetup memory setup) {
        address[] memory proposers = new address[](1);
        proposers[0] = governor_;
        address[] memory executors = new address[](1);
        executors[0] = governor_;
        FixedDelayTimelockController timelockController =
            new FixedDelayTimelockController(proposers, executors, governor_);

        BaseDeployment memory base = _deployBase(owner_, treasury_, address(0));
        _installLaunchFacets(base.diamond);
        address optionToken = OptionTokenAdminFacet(base.diamond).deployOptionToken(
            DEFAULT_OPTION_TOKEN_BASE_URI, address(timelockController)
        );

        PositionMSCAImpl positionMSCAImplementation = new PositionMSCAImpl(entryPoint_);
        PositionAgentConfigFacet(base.diamond).setERC6551Registry(erc6551Registry_);
        PositionAgentConfigFacet(base.diamond).setERC6551Implementation(address(positionMSCAImplementation));
        PositionAgentConfigFacet(base.diamond).setIdentityRegistry(identityRegistry_);

        setup = LaunchSetup({
            base: base,
            timelockController: address(timelockController),
            optionToken: optionToken,
            positionMSCAImplementation: address(positionMSCAImplementation)
        });
    }

    function _finalizeLaunch(
        LaunchSetup memory setup,
        address governor_,
        address treasury_,
        address entryPoint_,
        address erc6551Registry_,
        address identityRegistry_
    ) internal returns (LaunchDeployment memory deployment) {
        _installTimelock(setup.base.diamond, treasury_, setup.timelockController);
        OwnershipFacet(setup.base.diamond).transferOwnership(setup.timelockController);

        deployment = LaunchDeployment({
            diamond: setup.base.diamond,
            positionNFT: setup.base.positionNFT,
            timelockController: setup.timelockController,
            governor: governor_,
            treasury: treasury_,
            entryPoint: entryPoint_,
            erc6551Registry: erc6551Registry_,
            identityRegistry: identityRegistry_,
            positionMSCAImplementation: setup.positionMSCAImplementation,
            optionToken: setup.optionToken
        });
    }

    function _deployLocalTestTokens(address initialHolder) internal returns (LocalTestTokens memory tokens) {
        LocalMockERC20 eve = new LocalMockERC20("EqualFi Launch EVE", "EVE", 18);
        LocalMockERC20 alt = new LocalMockERC20("EqualFi Launch ALT", "ALT", 18);
        LocalMockFeeOnTransfer fot = new LocalMockFeeOnTransfer("EqualFi Launch FoT", "FOT", 18);

        eve.mint(initialHolder, LOCAL_TEST_MINT_AMOUNT);
        alt.mint(initialHolder, LOCAL_TEST_MINT_AMOUNT);
        fot.mint(initialHolder, LOCAL_TEST_MINT_AMOUNT);

        tokens = LocalTestTokens({eve: address(eve), alt: address(alt), fot: address(fot)});
    }

    function _bootstrapLocalProtocol(address diamond, LocalTestTokens memory tokens)
        internal
        returns (LocalPoolBootstrap memory pools)
    {
        Types.PoolConfig memory config = _localLaunchPoolConfig();
        Types.ActionFeeSet memory actionFees = _localLaunchActionFees();

        PoolManagementFacet(diamond).setDefaultPoolConfig(config);
        PoolManagementFacet(diamond).initPoolWithActionFees(LOCAL_EVE_POOL_ID, tokens.eve, config, actionFees);
        PoolManagementFacet(diamond).initPoolWithActionFees(LOCAL_ALT_POOL_ID, tokens.alt, config, actionFees);
        PoolManagementFacet(diamond).initPoolWithActionFees(LOCAL_FOT_POOL_ID, tokens.fot, config, actionFees);
        PoolManagementFacet(diamond).initPoolWithActionFees(LOCAL_NATIVE_POOL_ID, address(0), config, actionFees);

        pools = LocalPoolBootstrap({
            evePoolId: LOCAL_EVE_POOL_ID,
            altPoolId: LOCAL_ALT_POOL_ID,
            fotPoolId: LOCAL_FOT_POOL_ID,
            nativePoolId: LOCAL_NATIVE_POOL_ID
        });
    }

    function _localLaunchPoolConfig() internal pure returns (Types.PoolConfig memory cfg) {
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

    function _localLaunchActionFees() internal pure returns (Types.ActionFeeSet memory actionFees) {
        actionFees.borrowFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.repayFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.withdrawFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.flashFee = Types.ActionFeeConfig({amount: 0, enabled: false});
        actionFees.closeRollingFee = Types.ActionFeeConfig({amount: 0, enabled: false});
    }

    function _installLaunchFacets(address diamond) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](LAUNCH_FACET_COUNT);
        uint256 i;

        {
            PoolManagementFacet facet = new PoolManagementFacet();
            cuts[i++] = _cut(address(facet), _selectorsPoolManagement());
        }
        {
            PositionManagementFacet facet = new PositionManagementFacet();
            cuts[i++] = _cut(address(facet), _selectorsPositionManagement());
        }
        {
            FlashLoanFacet facet = new FlashLoanFacet();
            cuts[i++] = _cut(address(facet), _selectorsFlashLoan());
        }
        {
            SelfSecuredCreditFacet facet = new SelfSecuredCreditFacet();
            cuts[i++] = _cut(address(facet), _selectorsSelfSecuredCredit());
        }
        {
            SelfSecuredCreditViewFacet facet = new SelfSecuredCreditViewFacet();
            cuts[i++] = _cut(address(facet), _selectorsSelfSecuredCreditView());
        }
        {
            EqualIndexAdminFacetV3 facet = new EqualIndexAdminFacetV3();
            cuts[i++] = _cut(address(facet), _selectorsEqualIndexAdmin());
        }
        {
            EqualIndexActionsFacetV3 facet = new EqualIndexActionsFacetV3();
            cuts[i++] = _cut(address(facet), _selectorsEqualIndexActions());
        }
        {
            EqualIndexPositionFacet facet = new EqualIndexPositionFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualIndexPosition());
        }
        {
            EqualIndexLendingFacet facet = new EqualIndexLendingFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualIndexLending());
        }
        {
            EqualLendDirectFixedOfferFacet facet = new EqualLendDirectFixedOfferFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectFixedOffer());
        }
        {
            EqualLendDirectFixedAgreementFacet facet = new EqualLendDirectFixedAgreementFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectFixedAgreement());
        }
        {
            EqualLendDirectLifecycleFacet facet = new EqualLendDirectLifecycleFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectLifecycle());
        }
        {
            EqualLendDirectRollingOfferFacet facet = new EqualLendDirectRollingOfferFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectRollingOffer());
        }
        {
            EqualLendDirectRollingAgreementFacet facet = new EqualLendDirectRollingAgreementFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectRollingAgreement());
        }
        {
            EqualLendDirectRollingPaymentFacet facet = new EqualLendDirectRollingPaymentFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectRollingPayment());
        }
        {
            EqualLendDirectRollingLifecycleFacet facet = new EqualLendDirectRollingLifecycleFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectRollingLifecycle());
        }
        {
            EqualLendDirectConfigFacet facet = new EqualLendDirectConfigFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectConfig());
        }
        {
            EqualLendDirectViewFacet facet = new EqualLendDirectViewFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualLendDirectView());
        }
        {
            PositionAgentConfigFacet facet = new PositionAgentConfigFacet();
            cuts[i++] = _cut(address(facet), _selectorsPositionAgentConfig());
        }
        {
            PositionAgentTBAFacet facet = new PositionAgentTBAFacet();
            cuts[i++] = _cut(address(facet), _selectorsPositionAgentTBA());
        }
        {
            PositionAgentViewFacet facet = new PositionAgentViewFacet();
            cuts[i++] = _cut(address(facet), _selectorsPositionAgentView());
        }
        {
            PositionAgentRegistryFacet facet = new PositionAgentRegistryFacet();
            cuts[i++] = _cut(address(facet), _selectorsPositionAgentRegistry());
        }
        {
            EqualScaleAlphaFacet facet = new EqualScaleAlphaFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualScaleAlpha());
        }
        {
            EqualScaleAlphaAdminFacet facet = new EqualScaleAlphaAdminFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualScaleAlphaAdmin());
        }
        {
            EqualScaleAlphaViewFacet facet = new EqualScaleAlphaViewFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualScaleAlphaView());
        }
        {
            EqualXSoloAmmFacet facet = new EqualXSoloAmmFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualXSoloAmm());
        }
        {
            EqualXCommunityAmmLiquidityFacet facet = new EqualXCommunityAmmLiquidityFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualXCommunityAmmLiquidity());
        }
        {
            EqualXCommunityAmmSwapFacet facet = new EqualXCommunityAmmSwapFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualXCommunityAmmSwap());
        }
        {
            EqualXCurveCreationFacet facet = new EqualXCurveCreationFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualXCurveCreation());
        }
        {
            EqualXCurveExecutionFacet facet = new EqualXCurveExecutionFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualXCurveExecution());
        }
        {
            EqualXCurveManagementFacet facet = new EqualXCurveManagementFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualXCurveManagement());
        }
        {
            EqualXViewFacet facet = new EqualXViewFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualXView());
        }
        {
            OptionTokenAdminFacet facet = new OptionTokenAdminFacet();
            cuts[i++] = _cut(address(facet), _selectorsOptionTokenAdmin());
        }
        {
            OptionTokenViewFacet facet = new OptionTokenViewFacet();
            cuts[i++] = _cut(address(facet), _selectorsOptionTokenView());
        }
        {
            OptionsFacet facet = new OptionsFacet();
            cuts[i++] = _cut(address(facet), _selectorsOptions());
        }
        {
            OptionsViewFacet facet = new OptionsViewFacet();
            cuts[i++] = _cut(address(facet), _selectorsOptionsView());
        }
        {
            EdenRewardsFacet facet = new EdenRewardsFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenRewards());
        }

        require(i == LAUNCH_FACET_COUNT, "DeployEqualFi: bad facet count");
        _applyCutsInBatches(diamond, cuts, CUT_BATCH_SIZE);
    }

    function _applyCutsInBatches(address diamond, IDiamondCut.FacetCut[] memory cuts, uint256 batchSize) internal {
        uint256 offset;
        uint256 total = cuts.length;

        while (offset < total) {
            uint256 batchLen = total - offset;
            if (batchLen > batchSize) {
                batchLen = batchSize;
            }

            IDiamondCut.FacetCut[] memory batch = new IDiamondCut.FacetCut[](batchLen);
            for (uint256 i; i < batchLen; ++i) {
                batch[i] = cuts[offset + i];
            }

            IDiamondCut(diamond).diamondCut(batch, address(0), "");
            offset += batchLen;
        }
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _selectorsDiamondCut() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectorsDiamondLoupe() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _selectorsOwnership() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function _selectorsPoolManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](24);
        s[0] = PoolManagementFacet.initPoolWithActionFees.selector;
        s[1] = IPoolManagementFacetInitDefault.initPool.selector;
        s[2] = PoolManagementFacet.initManagedPool.selector;
        s[3] = PoolManagementFacet.setDefaultPoolConfig.selector;
        s[4] = PoolManagementFacet.setRollingApy.selector;
        s[5] = PoolManagementFacet.setDepositorLTV.selector;
        s[6] = PoolManagementFacet.setMinDepositAmount.selector;
        s[7] = PoolManagementFacet.setMinLoanAmount.selector;
        s[8] = PoolManagementFacet.setMinTopupAmount.selector;
        s[9] = PoolManagementFacet.setDepositCap.selector;
        s[10] = PoolManagementFacet.setIsCapped.selector;
        s[11] = PoolManagementFacet.setMaxUserCount.selector;
        s[12] = PoolManagementFacet.setMaintenanceRate.selector;
        s[13] = PoolManagementFacet.setFlashLoanFee.selector;
        s[14] = PoolManagementFacet.setActionFees.selector;
        s[15] = PoolManagementFacet.addToWhitelist.selector;
        s[16] = PoolManagementFacet.removeFromWhitelist.selector;
        s[17] = PoolManagementFacet.setWhitelistEnabled.selector;
        s[18] = PoolManagementFacet.transferManager.selector;
        s[19] = PoolManagementFacet.renounceManager.selector;
        s[20] = PoolManagementFacet.setAumFee.selector;
        s[21] = PoolManagementFacet.getPoolConfigView.selector;
        s[22] = PoolManagementFacet.getPoolInfoView.selector;
        s[23] = PoolManagementFacet.getPoolMaintenanceView.selector;
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = PositionManagementFacet.mintPosition.selector;
        s[1] = PositionManagementFacet.depositToPosition.selector;
        s[2] = PositionManagementFacet.joinPositionPool.selector;
        s[3] = PositionManagementFacet.withdrawFromPosition.selector;
        s[4] = PositionManagementFacet.cleanupMembership.selector;
        s[5] = PositionManagementFacet.previewPositionYield.selector;
        s[6] = PositionManagementFacet.claimPositionYield.selector;
    }

    function _selectorsFlashLoan() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = FlashLoanFacet.previewFlashLoanRepayment.selector;
        s[1] = FlashLoanFacet.flashLoan.selector;
    }

    function _selectorsSelfSecuredCredit() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = SelfSecuredCreditFacet.drawSelfSecuredCredit.selector;
        s[1] = SelfSecuredCreditFacet.repaySelfSecuredCredit.selector;
        s[2] = SelfSecuredCreditFacet.closeSelfSecuredCredit.selector;
        s[3] = SelfSecuredCreditFacet.previewSelfSecuredCreditMaintenance.selector;
        s[4] = SelfSecuredCreditFacet.getSelfSecuredCreditLineView.selector;
        s[5] = SelfSecuredCreditFacet.setSelfSecuredCreditAciMode.selector;
        s[6] = SelfSecuredCreditFacet.serviceSelfSecuredCredit.selector;
        s[7] = SelfSecuredCreditFacet.selfSettleSelfSecuredCredit.selector;
    }

    function _selectorsSelfSecuredCreditView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = SelfSecuredCreditViewFacet.getSscLine.selector;
        s[1] = SelfSecuredCreditViewFacet.previewSscDraw.selector;
        s[2] = SelfSecuredCreditViewFacet.previewSscRepay.selector;
        s[3] = SelfSecuredCreditViewFacet.previewSscService.selector;
        s[4] = SelfSecuredCreditViewFacet.previewSscTerminalSettlement.selector;
        s[5] = SelfSecuredCreditViewFacet.claimableSscFeeYield.selector;
        s[6] = SelfSecuredCreditViewFacet.claimableSscAciYield.selector;
        s[7] = SelfSecuredCreditViewFacet.sscAciMode.selector;
        s[8] = SelfSecuredCreditViewFacet.pendingSscSelfPayEffect.selector;
        s[9] = SelfSecuredCreditViewFacet.maxAdditionalSscDraw.selector;
    }

    function _selectorsEqualIndexAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = EqualIndexAdminFacetV3.createIndex.selector;
        s[1] = EqualIndexAdminFacetV3.setPaused.selector;
        s[2] = EqualIndexAdminFacetV3.getIndex.selector;
        s[3] = EqualIndexAdminFacetV3.getVaultBalance.selector;
        s[4] = EqualIndexAdminFacetV3.getFeePot.selector;
        s[5] = EqualIndexAdminFacetV3.getIndexPoolId.selector;
        s[6] = EqualIndexAdminFacetV3.setEqualIndexPoolFeeShareBps.selector;
        s[7] = EqualIndexAdminFacetV3.setEqualIndexMintBurnFeeIndexShareBps.selector;
    }

    function _selectorsEqualIndexActions() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualIndexActionsFacetV3.mint.selector;
        s[1] = EqualIndexActionsFacetV3.burn.selector;
        s[2] = EqualIndexActionsFacetV3.flashLoan.selector;
    }

    function _selectorsEqualIndexPosition() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualIndexPositionFacet.mintFromPosition.selector;
        s[1] = EqualIndexPositionFacet.burnFromPosition.selector;
    }

    function _selectorsEqualIndexLending() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](15);
        s[0] = EqualIndexLendingFacet.configureLending.selector;
        s[1] = EqualIndexLendingFacet.configureBorrowFeeTiers.selector;
        s[2] = EqualIndexLendingFacet.borrowFromPosition.selector;
        s[3] = EqualIndexLendingFacet.repayFromPosition.selector;
        s[4] = EqualIndexLendingFacet.extendFromPosition.selector;
        s[5] = EqualIndexLendingFacet.recoverExpiredIndexLoan.selector;
        s[6] = EqualIndexLendingFacet.getLoan.selector;
        s[7] = EqualIndexLendingFacet.getOutstandingPrincipal.selector;
        s[8] = EqualIndexLendingFacet.getLockedCollateralUnits.selector;
        s[9] = EqualIndexLendingFacet.getLendingConfig.selector;
        s[10] = EqualIndexLendingFacet.economicBalance.selector;
        s[11] = EqualIndexLendingFacet.maxBorrowable.selector;
        s[12] = EqualIndexLendingFacet.quoteBorrowBasket.selector;
        s[13] = EqualIndexLendingFacet.quoteBorrowFee.selector;
        s[14] = EqualIndexLendingFacet.getBorrowFeeTiers.selector;
    }

    function _selectorsEqualLendDirectFixedOffer() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = EqualLendDirectFixedOfferFacet.postFixedLenderOffer.selector;
        s[1] = EqualLendDirectFixedOfferFacet.postFixedBorrowerOffer.selector;
        s[2] = EqualLendDirectFixedOfferFacet.postLenderRatioTrancheOffer.selector;
        s[3] = EqualLendDirectFixedOfferFacet.postBorrowerRatioTrancheOffer.selector;
        s[4] = EqualLendDirectFixedOfferFacet.cancelFixedOffer.selector;
        s[5] = EqualLendDirectFixedOfferFacet.cancelLenderRatioTrancheOffer.selector;
        s[6] = EqualLendDirectFixedOfferFacet.cancelBorrowerRatioTrancheOffer.selector;
        s[7] = EqualLendDirectFixedOfferFacet.cancelOffersForPosition.selector;
        s[8] = EqualLendDirectFixedOfferFacet.hasOpenOffers.selector;
        s[9] = EqualLendDirectFixedOfferFacet.getPositionTokenURI.selector;
    }

    function _selectorsEqualLendDirectFixedAgreement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = EqualLendDirectFixedAgreementFacet.acceptFixedLenderOffer.selector;
        s[1] = EqualLendDirectFixedAgreementFacet.acceptFixedBorrowerOffer.selector;
        s[2] = EqualLendDirectFixedAgreementFacet.acceptLenderRatioTrancheOffer.selector;
        s[3] = EqualLendDirectFixedAgreementFacet.acceptBorrowerRatioTrancheOffer.selector;
    }

    function _selectorsEqualLendDirectLifecycle() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = EqualLendDirectLifecycleFacet.repay.selector;
        s[1] = EqualLendDirectLifecycleFacet.exerciseDirect.selector;
        s[2] = EqualLendDirectLifecycleFacet.callDirect.selector;
        s[3] = EqualLendDirectLifecycleFacet.recover.selector;
    }

    function _selectorsEqualLendDirectRollingOffer() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualLendDirectRollingOfferFacet.postRollingLenderOffer.selector;
        s[1] = EqualLendDirectRollingOfferFacet.postRollingBorrowerOffer.selector;
        s[2] = EqualLendDirectRollingOfferFacet.cancelRollingOffer.selector;
    }

    function _selectorsEqualLendDirectRollingAgreement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualLendDirectRollingAgreementFacet.acceptRollingLenderOffer.selector;
        s[1] = EqualLendDirectRollingAgreementFacet.acceptRollingBorrowerOffer.selector;
    }

    function _selectorsEqualLendDirectRollingPayment() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = EqualLendDirectRollingPaymentFacet.makeRollingPayment.selector;
    }

    function _selectorsEqualLendDirectRollingLifecycle() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualLendDirectRollingLifecycleFacet.exerciseRolling.selector;
        s[1] = EqualLendDirectRollingLifecycleFacet.recoverRolling.selector;
        s[2] = EqualLendDirectRollingLifecycleFacet.repayRollingInFull.selector;
    }

    function _selectorsEqualLendDirectConfig() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualLendDirectConfigFacet.setDirectConfig.selector;
        s[1] = EqualLendDirectConfigFacet.setRollingConfig.selector;
    }

    function _selectorsEqualLendDirectView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](20);
        s[0] = EqualLendDirectViewFacet.getDirectConfig.selector;
        s[1] = EqualLendDirectViewFacet.getDirectRollingConfig.selector;
        s[2] = EqualLendDirectViewFacet.getOfferKind.selector;
        s[3] = EqualLendDirectViewFacet.getAgreementKind.selector;
        s[4] = EqualLendDirectViewFacet.getFixedLenderOffer.selector;
        s[5] = EqualLendDirectViewFacet.getFixedBorrowerOffer.selector;
        s[6] = EqualLendDirectViewFacet.getLenderRatioTrancheOffer.selector;
        s[7] = EqualLendDirectViewFacet.getBorrowerRatioTrancheOffer.selector;
        s[8] = EqualLendDirectViewFacet.getRollingLenderOffer.selector;
        s[9] = EqualLendDirectViewFacet.getRollingBorrowerOffer.selector;
        s[10] = EqualLendDirectViewFacet.getFixedAgreement.selector;
        s[11] = EqualLendDirectViewFacet.getRollingAgreement.selector;
        s[12] = EqualLendDirectViewFacet.getBorrowerOfferIds.selector;
        s[13] = EqualLendDirectViewFacet.getLenderOfferIds.selector;
        s[14] = EqualLendDirectViewFacet.getBorrowerAgreementIds.selector;
        s[15] = EqualLendDirectViewFacet.getLenderAgreementIds.selector;
        s[16] = EqualLendDirectViewFacet.previewRollingPayment.selector;
        s[17] = EqualLendDirectViewFacet.getRollingStatus.selector;
        s[18] = EqualLendDirectViewFacet.getLenderRatioTrancheStatus.selector;
        s[19] = EqualLendDirectViewFacet.getBorrowerRatioTrancheStatus.selector;
    }

    function _selectorsPositionAgentConfig() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = PositionAgentConfigFacet.setERC6551Registry.selector;
        s[1] = PositionAgentConfigFacet.setERC6551Implementation.selector;
        s[2] = PositionAgentConfigFacet.setIdentityRegistry.selector;
    }

    function _selectorsPositionAgentTBA() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = PositionAgentTBAFacet.computeTBAAddress.selector;
        s[1] = PositionAgentTBAFacet.deployTBA.selector;
        s[2] = PositionAgentTBAFacet.getTBAImplementation.selector;
        s[3] = PositionAgentTBAFacet.getERC6551Registry.selector;
    }

    function _selectorsPositionAgentView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = PositionAgentViewFacet.getAgentRegistrationMode.selector;
        s[1] = PositionAgentViewFacet.getExternalAgentAuthorizer.selector;
        s[2] = PositionAgentViewFacet.getTBAAddress.selector;
        s[3] = PositionAgentViewFacet.getAgentId.selector;
        s[4] = PositionAgentViewFacet.isAgentRegistered.selector;
        s[5] = PositionAgentViewFacet.isCanonicalAgentLink.selector;
        s[6] = PositionAgentViewFacet.isExternalAgentLink.selector;
        s[7] = PositionAgentViewFacet.isRegistrationComplete.selector;
        s[8] = PositionAgentViewFacet.isTBADeployed.selector;
        s[9] = PositionAgentViewFacet.getCanonicalRegistries.selector;
        s[10] = PositionAgentViewFacet.getTBAInterfaceSupport.selector;
    }

    function _selectorsPositionAgentRegistry() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = PositionAgentRegistryFacet.recordAgentRegistration.selector;
        s[1] = PositionAgentRegistryFacet.linkExternalAgentRegistration.selector;
        s[2] = PositionAgentRegistryFacet.unlinkExternalAgentRegistration.selector;
        s[3] = PositionAgentRegistryFacet.revokeExternalAgentRegistration.selector;
        s[4] = PositionAgentRegistryFacet.getIdentityRegistry.selector;
    }

    function _selectorsEqualScaleAlpha() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](19);
        s[0] = EqualScaleAlphaFacet.registerBorrowerProfile.selector;
        s[1] = EqualScaleAlphaFacet.updateBorrowerProfile.selector;
        s[2] = EqualScaleAlphaFacet.createLineProposal.selector;
        s[3] = EqualScaleAlphaFacet.updateLineProposal.selector;
        s[4] = EqualScaleAlphaFacet.cancelLineProposal.selector;
        s[5] = EqualScaleAlphaFacet.commitSolo.selector;
        s[6] = EqualScaleAlphaFacet.transitionToPooledOpen.selector;
        s[7] = EqualScaleAlphaFacet.commitPooled.selector;
        s[8] = EqualScaleAlphaFacet.cancelCommitment.selector;
        s[9] = EqualScaleAlphaFacet.activateLine.selector;
        s[10] = EqualScaleAlphaFacet.draw.selector;
        s[11] = EqualScaleAlphaFacet.repayLine.selector;
        s[12] = EqualScaleAlphaFacet.enterRefinancing.selector;
        s[13] = EqualScaleAlphaFacet.rollCommitment.selector;
        s[14] = EqualScaleAlphaFacet.exitCommitment.selector;
        s[15] = EqualScaleAlphaFacet.resolveRefinancing.selector;
        s[16] = EqualScaleAlphaFacet.markDelinquent.selector;
        s[17] = EqualScaleAlphaFacet.chargeOffLine.selector;
        s[18] = EqualScaleAlphaFacet.closeLine.selector;
    }

    function _selectorsEqualScaleAlphaAdmin() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualScaleAlphaAdminFacet.freezeLine.selector;
        s[1] = EqualScaleAlphaAdminFacet.unfreezeLine.selector;
        s[2] = EqualScaleAlphaAdminFacet.setChargeOffThreshold.selector;
    }

    function _selectorsEqualScaleAlphaView() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = EqualScaleAlphaViewFacet.getBorrowerProfile.selector;
        s[1] = EqualScaleAlphaViewFacet.getCreditLine.selector;
        s[2] = EqualScaleAlphaViewFacet.getBorrowerLineIds.selector;
        s[3] = EqualScaleAlphaViewFacet.getLineCommitments.selector;
        s[4] = EqualScaleAlphaViewFacet.getLenderPositionCommitments.selector;
        s[5] = EqualScaleAlphaViewFacet.previewDraw.selector;
        s[6] = EqualScaleAlphaViewFacet.previewLineRepay.selector;
        s[7] = EqualScaleAlphaViewFacet.isLineDrawEligible.selector;
        s[8] = EqualScaleAlphaViewFacet.currentMinimumDue.selector;
        s[9] = EqualScaleAlphaViewFacet.getTreasuryTelemetry.selector;
        s[10] = EqualScaleAlphaViewFacet.getRefinanceStatus.selector;
        s[11] = EqualScaleAlphaViewFacet.getLineLossSummary.selector;
    }

    function _selectorsEqualXSoloAmm() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = EqualXSoloAmmFacet.createEqualXSoloAmmMarket.selector;
        s[1] = EqualXSoloAmmFacet.setEqualXSoloAmmMinRebalanceTimelock.selector;
        s[2] = EqualXSoloAmmFacet.scheduleEqualXSoloAmmRebalance.selector;
        s[3] = EqualXSoloAmmFacet.cancelEqualXSoloAmmRebalance.selector;
        s[4] = EqualXSoloAmmFacet.executeEqualXSoloAmmRebalance.selector;
        s[5] = EqualXSoloAmmFacet.previewEqualXSoloAmmSwapExactIn.selector;
        s[6] = EqualXSoloAmmFacet.swapEqualXSoloAmmExactIn.selector;
        s[7] = EqualXSoloAmmFacet.finalizeEqualXSoloAmmMarket.selector;
        s[8] = EqualXSoloAmmFacet.cancelEqualXSoloAmmMarket.selector;
    }

    function _selectorsEqualXCommunityAmmLiquidity() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = EqualXCommunityAmmLiquidityFacet.createEqualXCommunityAmmMarket.selector;
        s[1] = EqualXCommunityAmmLiquidityFacet.joinEqualXCommunityAmmMarket.selector;
        s[2] = EqualXCommunityAmmLiquidityFacet.claimEqualXCommunityAmmFees.selector;
        s[3] = EqualXCommunityAmmLiquidityFacet.leaveEqualXCommunityAmmMarket.selector;
        s[4] = EqualXCommunityAmmLiquidityFacet.finalizeEqualXCommunityAmmMarket.selector;
        s[5] = EqualXCommunityAmmLiquidityFacet.cancelEqualXCommunityAmmMarket.selector;
    }

    function _selectorsEqualXCommunityAmmSwap() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualXCommunityAmmSwapFacet.previewEqualXCommunityAmmSwapExactIn.selector;
        s[1] = EqualXCommunityAmmSwapFacet.swapEqualXCommunityAmmExactIn.selector;
    }

    function _selectorsEqualXCurveCreation() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EqualXCurveCreationFacet.createEqualXCurve.selector;
        s[1] = EqualXCurveCreationFacet.setEqualXCurveProfile.selector;
    }

    function _selectorsEqualXCurveExecution() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = EqualXCurveExecutionFacet.previewEqualXCurveQuote.selector;
        s[1] = EqualXCurveExecutionFacet.getEqualXCurveCommitment.selector;
        s[2] = bytes4(keccak256("executeEqualXCurveSwap(uint256,uint256,uint256,uint256,uint64,address)"));
        s[3] = bytes4(
            keccak256("executeEqualXCurveSwap(uint256,uint256,uint256,uint256,uint64,address,uint32,bytes32)")
        );
    }

    function _selectorsEqualXCurveManagement() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EqualXCurveManagementFacet.updateEqualXCurve.selector;
        s[1] = EqualXCurveManagementFacet.cancelEqualXCurve.selector;
        s[2] = EqualXCurveManagementFacet.expireEqualXCurve.selector;
    }

    function _selectorsEqualXView() internal pure virtual returns (bytes4[] memory s) {
        s = new bytes4[](27);
        s[0] = EqualXViewFacet.getEqualXSoloAmmMarket.selector;
        s[1] = EqualXViewFacet.getEqualXCommunityAmmMarket.selector;
        s[2] = EqualXViewFacet.getEqualXCurveMarket.selector;
        s[3] = EqualXViewFacet.getEqualXCurveProfile.selector;
        s[4] = EqualXViewFacet.isEqualXCurveProfileApproved.selector;
        s[5] = EqualXViewFacet.getEqualXBuiltInCurveProfiles.selector;
        s[6] = EqualXViewFacet.getEqualXSoloAmmStatus.selector;
        s[7] = EqualXViewFacet.getEqualXSoloAmmPendingRebalance.selector;
        s[8] = EqualXViewFacet.getEqualXCommunityAmmStatus.selector;
        s[9] = EqualXViewFacet.getEqualXCurveStatus.selector;
        s[10] = EqualXViewFacet.getEqualXMarketsByPosition.selector;
        s[11] = EqualXViewFacet.getEqualXMarketsByPositionId.selector;
        s[12] = EqualXViewFacet.getEqualXMarketsByPositionAndType.selector;
        s[13] = EqualXViewFacet.getEqualXMarketsByPositionIdAndType.selector;
        s[14] = EqualXViewFacet.getEqualXMarketsByPair.selector;
        s[15] = EqualXViewFacet.getEqualXMarketsByPairAndType.selector;
        s[16] = EqualXViewFacet.getEqualXActiveMarkets.selector;
        s[17] = EqualXViewFacet.getEqualXActiveMarketsByPosition.selector;
        s[18] = EqualXViewFacet.getEqualXActiveMarketsByPositionId.selector;
        s[19] = EqualXViewFacet.getEqualXActiveMarketsByPair.selector;
        s[20] = EqualXViewFacet.quoteEqualXSoloAmmExactIn.selector;
        s[21] = EqualXViewFacet.quoteEqualXCommunityAmmExactIn.selector;
        s[22] = EqualXViewFacet.quoteEqualXCurveExactIn.selector;
        s[23] = EqualXViewFacet.getEqualXSoloAmmMakerFeeBuckets.selector;
        s[24] = EqualXViewFacet.getEqualXCommunityMakerView.selector;
        s[25] = EqualXViewFacet.getEqualXCommunityMakerViewById.selector;
        s[26] = EqualXViewFacet.previewEqualXCommunityMakerFees.selector;
    }

    function _selectorsOptionTokenAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OptionTokenAdminFacet.deployOptionToken.selector;
        s[1] = OptionTokenAdminFacet.setOptionToken.selector;
    }

    function _selectorsOptionTokenView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OptionTokenViewFacet.getOptionToken.selector;
        s[1] = OptionTokenViewFacet.hasOptionToken.selector;
    }

    function _selectorsOptions() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = OptionsFacet.createOptionSeries.selector;
        s[1] = OptionsFacet.exerciseOptions.selector;
        s[2] = OptionsFacet.exerciseOptionsFor.selector;
        s[3] = OptionsFacet.reclaimOptions.selector;
        s[4] = OptionsFacet.burnReclaimedOptionsClaims.selector;
        s[5] = OptionsFacet.setOptionsPaused.selector;
        s[6] = OptionsFacet.setEuropeanTolerance.selector;
    }

    function _selectorsOptionsView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = OptionsViewFacet.getOptionSeries.selector;
        s[1] = OptionsViewFacet.getOptionSeriesIdsByPosition.selector;
        s[2] = OptionsViewFacet.getOptionSeriesIdsByPositionKey.selector;
        s[3] = OptionsViewFacet.getOptionSeriesProductiveCollateral.selector;
        s[4] = OptionsViewFacet.getOptionPositionProductiveCollateral.selector;
        s[5] = OptionsViewFacet.getOptionPositionProductiveCollateralByKey.selector;
        s[6] = OptionsViewFacet.previewExercisePayment.selector;
        s[7] = OptionsViewFacet.isOptionsPaused.selector;
        s[8] = OptionsViewFacet.europeanToleranceSeconds.selector;
    }

    function _selectorsEdenRewards() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](17);
        s[0] = EdenRewardsFacet.createRewardProgram.selector;
        s[1] = EdenRewardsFacet.setRewardProgramTransferFeeBps.selector;
        s[2] = EdenRewardsFacet.setRewardProgramManager.selector;
        s[3] = EdenRewardsFacet.setRewardProgramEnabled.selector;
        s[4] = EdenRewardsFacet.pauseRewardProgram.selector;
        s[5] = EdenRewardsFacet.resumeRewardProgram.selector;
        s[6] = EdenRewardsFacet.endRewardProgram.selector;
        s[7] = EdenRewardsFacet.closeRewardProgram.selector;
        s[8] = EdenRewardsFacet.fundRewardProgram.selector;
        s[9] = EdenRewardsFacet.accrueRewardProgram.selector;
        s[10] = EdenRewardsFacet.settleRewardProgramPosition.selector;
        s[11] = EdenRewardsFacet.claimRewardProgram.selector;
        s[12] = EdenRewardsFacet.getRewardProgram.selector;
        s[13] = EdenRewardsFacet.previewRewardProgramState.selector;
        s[14] = EdenRewardsFacet.getRewardProgramIdsByTarget.selector;
        s[15] = EdenRewardsFacet.previewRewardProgramPosition.selector;
        s[16] = EdenRewardsFacet.previewRewardProgramsForPosition.selector;
    }

}
