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
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgent_ConfigLocked} from "src/libraries/PositionAgentErrors.sol";
import {EdenAdminFacet} from "src/eden/EdenAdminFacet.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenBasketFacet} from "src/eden/EdenBasketFacet.sol";
import {EdenStEVEFacet} from "src/eden/EdenStEVEFacet.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {Types} from "src/libraries/Types.sol";
import {
    MockEntryPointLaunch,
    MockERC6551RegistryLaunch,
    MockIdentityRegistryLaunch
} from "test/utils/PositionAgentBootstrapMocks.sol";

contract MockERC20Deploy is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployEdenByEqualFiTest is DeployEdenByEqualFi {
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
        _assertEq(facetAddresses.length, 20, "facet count");

        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(PositionManagementFacet.mintPosition.selector) != address(0),
            "position facet cut"
        );
        _assertTrue(
            IDiamondLoupe(diamond).facetAddress(EqualIndexAdminFacetV3.createIndex.selector) != address(0),
            "equalindex facet cut"
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
            IDiamondLoupe(diamond).facetAddress(EdenBasketFacet.createBasket.selector) != address(0),
            "eden basket facet cut"
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
            IDiamondLoupe(diamond).facetAddress(EdenAdminFacet.setProtocolURI.selector) != address(0),
            "eden admin facet cut"
        );
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
        FixedDelayTimelockController controller =
            FixedDelayTimelockController(payable(deployment.timelockController));

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
        FixedDelayTimelockController controller =
            FixedDelayTimelockController(payable(deployment.timelockController));

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
        EdenBasketFacet(diamond).mintBasket(state.altBasketId, 50e18, bob, maxAltInputs);
        EdenBasketFacet(diamond).burnBasket(state.altBasketId, 50e18, bob);
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
        EdenBasketFacet(diamond).mintBasket(state.steveBasketId, 100e18, alice, maxSteveInputs);

        uint256 stevePositionId = PositionManagementFacet(diamond).mintPosition(1);
        ERC20(state.steveToken).approve(diamond, 100e18);
        EdenStEVEFacet(diamond).depositStEVEToPosition(stevePositionId, 100e18, 100e18);

        uint256 altPositionId = PositionManagementFacet(diamond).mintPosition(2);
        PositionManagementFacet(diamond).depositToPosition(altPositionId, 2, 200e18, 200e18);
        EdenBasketFacet(diamond).mintBasketFromPosition(altPositionId, state.altBasketId, 100e18);
        vm.stopPrank();

        EdenViewFacet.ActionCheck memory borrowCheck =
            EdenViewFacet(diamond).canBorrow(altPositionId, state.altBasketId, 30e18, 7 days);
        _assertTrue(borrowCheck.ok, "borrow check");

        vm.prank(alice);
        uint256 loanId = EdenLendingFacet(diamond).borrow(altPositionId, state.altBasketId, 30e18, 7 days);
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

        (state.steveBasketId, state.steveToken) =
            EdenStEVEFacet(diamond).createStEVE(_stEveParams(address(eve)));
        (state.altBasketId, state.altBasketToken) =
            EdenBasketFacet(diamond).createBasket(_singleAssetParams("ALT Basket", "ALTB", address(alt), "ipfs://alt"));

        EdenRewardFacet(diamond).configureRewards(address(eve), 1e18, true);
        EdenLendingFacet(diamond).configureLending(state.altBasketId, 1 days, 14 days);

        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        EdenLendingFacet(diamond).configureBorrowFeeTiers(state.altBasketId, mins, fees);
    }

    function _timelockCall(FixedDelayTimelockController controller, address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encodePacked("edenfi-timelock", timelockSaltNonce++));
        controller.schedule(target, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        controller.execute(target, 0, data, bytes32(0), salt);
    }

    function _singleAssetParams(
        string memory name_,
        string memory symbol_,
        address asset,
        string memory uri_
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
        FixedDelayTimelockController controller =
            FixedDelayTimelockController(payable(deployment.timelockController));
        _timelockCall(
            controller,
            deployment.diamond,
            abi.encodeWithSelector(PoolManagementFacet.setDefaultPoolConfig.selector, cfg)
        );
        _timelockCall(
            controller,
            deployment.diamond,
            abi.encodeWithSelector(PoolManagementFacet.initPoolWithActionFees.selector, 1, address(eve), cfg, actionFees)
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
        FixedDelayTimelockController controller =
            FixedDelayTimelockController(payable(deployment.timelockController));
        _timelockCall(
            controller,
            deployment.diamond,
            abi.encodeWithSelector(PoolManagementFacet.setDefaultPoolConfig.selector, cfg)
        );
        _timelockCall(
            controller,
            deployment.diamond,
            abi.encodeWithSelector(bytes4(keccak256("initPool(address)")), address(eve))
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
        _assertTrue(
            PositionAgentViewFacet(deployment.diamond).isRegistrationComplete(tokenId), "registration complete"
        );

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

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(deployment.diamond).getPositionPortfolio(tokenId);
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
}
