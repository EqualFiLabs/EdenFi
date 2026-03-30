// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {DeployEqualFi} from "script/DeployEqualFi.s.sol";
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
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {PositionAgent_ConfigLocked} from "src/libraries/PositionAgentErrors.sol";
import {StEVEAdminFacet} from "src/steve/StEVEAdminFacet.sol";
import {StEVEProductBase} from "src/steve/StEVEProductBase.sol";
import {StEVEPositionFacet} from "src/steve/StEVEPositionFacet.sol";
import {StEVEActionFacet} from "src/steve/StEVEActionFacet.sol";
import {StEVEWalletFacet} from "src/steve/StEVEWalletFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {StEVELendingFacet} from "src/steve/StEVELendingFacet.sol";
import {StEVEViewFacet} from "src/steve/StEVEViewFacet.sol";
import {LibEdenRewardsStorage} from "src/libraries/LibEdenRewardsStorage.sol";
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

contract DeployEqualFiTest is DeployEqualFi {
    uint256 internal constant EIP170_RUNTIME_CODE_SIZE_LIMIT = 24_576;
    bytes4 internal constant CREATE_BASKET_SELECTOR =
        bytes4(keccak256("createBasket((string,string,string,address[],uint256[],uint16[],uint16[],uint16,uint8))"));
    bytes4 internal constant MINT_BASKET_SELECTOR = bytes4(keccak256("mintBasket(uint256,uint256,address,uint256[])"));
    bytes4 internal constant BURN_BASKET_SELECTOR = bytes4(keccak256("burnBasket(uint256,uint256,address)"));
    bytes4 internal constant LEGACY_MINT_BASKET_FROM_POSITION_SELECTOR =
        bytes4(keccak256("mintBasketFromPosition(uint256,uint256,uint256)"));
    bytes4 internal constant LEGACY_BURN_BASKET_FROM_POSITION_SELECTOR =
        bytes4(keccak256("burnBasketFromPosition(uint256,uint256,uint256)"));
    bytes4 internal constant LEGACY_SET_BASKET_METADATA_SELECTOR =
        bytes4(keccak256("setBasketMetadata(uint256,string,uint8)"));
    bytes4 internal constant LEGACY_SET_BASKET_PAUSED_SELECTOR = bytes4(keccak256("setBasketPaused(uint256,bool)"));
    bytes4 internal constant LEGACY_SET_BASKET_FEES_SELECTOR =
        bytes4(keccak256("setBasketFees(uint256,uint16[],uint16[],uint16)"));

    struct StEVEDeploymentState {
        uint256 steveBasketId;
        address steveToken;
        uint256 rewardProgramId;
    }

    address internal treasury = _addr("treasury");
    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal carol = _addr("carol");
    uint256 internal externalOwnerPk = uint256(0xA71CE);
    address internal externalOwner = vm.addr(externalOwnerPk);
    uint256 internal timelockSaltNonce;

    MockERC20Deploy internal eve;
    MockEntryPointLaunch internal entryPoint;
    MockERC6551RegistryLaunch internal erc6551Registry;
    MockIdentityRegistryLaunch internal identityRegistry;

    PositionNFT internal positionNft;
    address internal diamond;

    function setUp() public {
        eve = new MockERC20Deploy("EVE", "EVE");
        entryPoint = new MockEntryPointLaunch();
        erc6551Registry = new MockERC6551RegistryLaunch();
        identityRegistry = new MockIdentityRegistryLaunch();

        BaseDeployment memory deployment = deployBase(address(this), treasury);
        diamond = deployment.diamond;
        positionNft = PositionNFT(deployment.positionNFT);
        _installLaunchFacets(diamond);
    }

    function test_DeployLaunch_WiresDiamondCoreAndStEVEAndEdenFacetSet() public view {
        _assertEqAddress(OwnershipFacet(diamond).owner(), address(this), "owner wired");
        _assertEqAddress(positionNft.minter(), diamond, "position nft minter");
        _assertEqAddress(positionNft.diamond(), diamond, "position nft diamond");

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address[] memory facetAddresses = loupe.facetAddresses();
        _assertEq(facetAddresses.length, TOTAL_FACET_COUNT, "facet count");

        _assertTrue(
            loupe.facetAddress(PositionManagementFacet.mintPosition.selector) != address(0), "position facet cut"
        );
        _assertTrue(loupe.facetAddress(FlashLoanFacet.flashLoan.selector) != address(0), "pool flash facet cut");
        _assertTrue(
            loupe.facetAddress(EqualIndexAdminFacetV3.createIndex.selector) != address(0), "equalindex facet cut"
        );
        _assertTrue(
            loupe.facetAddress(EqualIndexActionsFacetV3.flashLoan.selector) != address(0), "index flash action cut"
        );
        _assertTrue(
            loupe.facetAddress(EqualIndexLendingFacet.borrowFromPosition.selector) != address(0),
            "index lending facet cut"
        );
        _assertTrue(
            loupe.facetAddress(PositionAgentConfigFacet.setERC6551Registry.selector) != address(0),
            "position agent config facet cut"
        );
        _assertTrue(
            loupe.facetAddress(PositionAgentTBAFacet.deployTBA.selector) != address(0), "position agent tba facet cut"
        );
        _assertTrue(
            loupe.facetAddress(PositionAgentViewFacet.getTBAInterfaceSupport.selector) != address(0),
            "position agent view facet cut"
        );
        _assertTrue(
            loupe.facetAddress(PositionAgentViewFacet.isCanonicalAgentLink.selector) != address(0),
            "position agent canonical link view cut"
        );
        _assertTrue(
            loupe.facetAddress(PositionAgentViewFacet.isExternalAgentLink.selector) != address(0),
            "position agent external link view cut"
        );
        _assertTrue(
            loupe.facetAddress(PositionAgentViewFacet.isRegistrationComplete.selector) != address(0),
            "position agent registration complete view cut"
        );
        _assertTrue(
            loupe.facetAddress(PositionAgentRegistryFacet.recordAgentRegistration.selector) != address(0),
            "position agent registry facet cut"
        );
        _assertTrue(
            loupe.facetAddress(EqualScaleAlphaFacet.registerBorrowerProfile.selector) != address(0),
            "equalscale alpha facet cut"
        );
        _assertTrue(
            loupe.facetAddress(EqualScaleAlphaAdminFacet.freezeLine.selector) != address(0),
            "equalscale alpha admin facet cut"
        );
        _assertTrue(
            loupe.facetAddress(EqualScaleAlphaViewFacet.getBorrowerProfile.selector) != address(0),
            "equalscale alpha view facet cut"
        );

        address[] memory edenFacetAddresses = new address[](EDEN_SINGLETON_FACET_COUNT);
        edenFacetAddresses[0] = _assertSelectorGroupInstalled(loupe, _selectorsEdenAdmin());
        edenFacetAddresses[1] = _assertSelectorGroupInstalled(loupe, _selectorsEdenView());
        edenFacetAddresses[2] = _assertSelectorGroupInstalled(loupe, _selectorsEdenLending());
        edenFacetAddresses[3] = _assertSelectorGroupInstalled(loupe, _selectorsEdenRewards());
        edenFacetAddresses[4] = _assertSelectorGroupInstalled(loupe, _selectorsEdenStEVE());
        edenFacetAddresses[5] = _assertSelectorGroupInstalled(loupe, _selectorsEdenStEVEPosition());
        edenFacetAddresses[6] = _assertSelectorGroupInstalled(loupe, _selectorsEdenStEVEWallet());
        _assertEq(_countDistinctNonZero(edenFacetAddresses), EDEN_SINGLETON_FACET_COUNT, "stEVE and EDEN facet count");

        _assertEqAddress(loupe.facetAddress(CREATE_BASKET_SELECTOR), address(0), "legacy create basket removed");
        _assertEqAddress(loupe.facetAddress(MINT_BASKET_SELECTOR), address(0), "legacy wallet mint removed");
        _assertEqAddress(loupe.facetAddress(BURN_BASKET_SELECTOR), address(0), "legacy wallet burn removed");
        _assertEqAddress(
            loupe.facetAddress(LEGACY_MINT_BASKET_FROM_POSITION_SELECTOR), address(0), "legacy position mint removed"
        );
        _assertEqAddress(
            loupe.facetAddress(LEGACY_BURN_BASKET_FROM_POSITION_SELECTOR), address(0), "legacy position burn removed"
        );
        _assertEqAddress(
            loupe.facetAddress(LEGACY_SET_BASKET_METADATA_SELECTOR),
            address(0),
            "legacy basket metadata selector removed"
        );
        _assertEqAddress(
            loupe.facetAddress(LEGACY_SET_BASKET_PAUSED_SELECTOR), address(0), "legacy basket pause selector removed"
        );
        _assertEqAddress(
            loupe.facetAddress(LEGACY_SET_BASKET_FEES_SELECTOR), address(0), "legacy basket fee selector removed"
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

        address equalIndexLendingFacet = loupe.facetAddress(EqualIndexLendingFacet.borrowFromPosition.selector);
        _assertTrue(equalIndexLendingFacet != address(0), "index lending selector installed");
        _assertEqAddress(
            equalIndexLendingFacet,
            loupe.facetAddress(EqualIndexLendingFacet.repayFromPosition.selector),
            "index lending borrow and repay stay together"
        );
        _assertEqAddress(
            equalIndexLendingFacet,
            loupe.facetAddress(EqualIndexLendingFacet.recoverExpiredIndexLoan.selector),
            "index lending recovery stays together"
        );

        _assertTrue(poolFlashFacet != equalIndexActionsFacet, "pool and index flash lanes stay separate");
        _assertTrue(
            equalIndexActionsFacet != equalIndexPositionFacet, "EqualIndex action and position lanes stay explicit"
        );
        _assertTrue(
            equalIndexPositionFacet != equalIndexLendingFacet, "EqualIndex position and lending lanes stay explicit"
        );
        _assertTrue(
            loupe.facetAddress(StEVEWalletFacet.mintStEVE.selector) != equalIndexActionsFacet,
            "EDEN wallet selector does not own generic EqualIndex wallet flows"
        );
        _assertTrue(
            loupe.facetAddress(StEVEPositionFacet.mintStEVEFromPosition.selector) != equalIndexPositionFacet,
            "EDEN position selector does not own generic EqualIndex position flows"
        );
    }

    function test_DeployLaunch_SelectorSurfaceMatchesIntendedFinalBoundary() public view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address[] memory facetAddresses = loupe.facetAddresses();

        _assertEq(facetAddresses.length, TOTAL_FACET_COUNT, "facet count");
        _assertExactSelectorSurfaceInstalled(loupe);
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

        StEVEViewFacet.ProductConfigView memory product = StEVEViewFacet(launchedDiamond).getProductConfig();
        _assertEqAddress(product.timelock, address(controller), "product timelock");

        vm.expectRevert(bytes("LibAccess: not timelock"));
        StEVEAdminFacet(launchedDiamond).setProtocolURI("ipfs://blocked");

        _timelockCall(
            controller,
            launchedDiamond,
            abi.encodeWithSelector(StEVEAdminFacet.setProtocolURI.selector, "ipfs://timelocked")
        );

        _assertEqBytes32(
            keccak256(bytes(StEVEAdminFacet(launchedDiamond).protocolURI())),
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

    function test_DeployLaunch_SupportsSingletonWalletFlowsAndAdminReads() public {
        StEVEDeploymentState memory state = _bootstrapStEVEProduct();

        eve.mint(bob, 100e18);
        vm.startPrank(bob);
        eve.approve(diamond, 100e18);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = 50e18;
        StEVEWalletFacet(diamond).mintStEVE(50e18, bob, maxInputs);
        StEVEWalletFacet(diamond).burnStEVE(50e18, bob);
        vm.stopPrank();
        _assertEq(ERC20(state.steveToken).balanceOf(bob), 0, "wallet stEVE burned");

        StEVEAdminFacet(diamond).setProtocolURI("ipfs://steve");
        StEVEAdminFacet(diamond).setContractVersion("launch-v1");

        StEVEViewFacet.ProductConfigView memory product = StEVEViewFacet(diamond).getProductConfig();
        _assertEqAddress(product.timelock, address(0), "timelock unset before launch handoff");
        _assertEqAddress(product.treasury, treasury, "treasury set");
        _assertEq(product.productId, state.steveBasketId, "product id");
        _assertEq(product.rewardProgramCount, 1, "reward program count");
    }

    function test_DeployLaunch_SupportsProgramScopedPositionRewardsAndLending() public {
        StEVEDeploymentState memory state = _bootstrapStEVEProduct();

        eve.mint(alice, 500e18);

        vm.startPrank(alice);
        eve.approve(diamond, 500e18);

        uint256[] memory maxSteveInputs = new uint256[](1);
        maxSteveInputs[0] = 200e18;
        StEVEWalletFacet(diamond).mintStEVE(200e18, alice, maxSteveInputs);

        uint256 stevePositionId = PositionManagementFacet(diamond).mintPosition(1);
        ERC20(state.steveToken).approve(diamond, 100e18);
        StEVEActionFacet(diamond).depositStEVEToPosition(stevePositionId, 100e18, 100e18);
        vm.stopPrank();

        StEVEViewFacet.ActionCheck memory borrowCheck = StEVEViewFacet(diamond).canBorrow(stevePositionId, 30e18, 7 days);
        _assertTrue(borrowCheck.ok, "borrow check");

        vm.prank(alice);
        uint256 loanId = StEVELendingFacet(diamond).borrow(stevePositionId, 30e18, 7 days);
        _assertEq(StEVELendingFacet(diamond).loanCount(), 1, "loan created");

        vm.prank(alice);
        StEVELendingFacet(diamond).repay(stevePositionId, loanId);

        eve.mint(address(this), 500e18);
        eve.approve(diamond, 500e18);
        EdenRewardsFacet(diamond).fundRewardProgram(state.rewardProgramId, 500e18, 500e18);

        vm.warp(block.timestamp + 1 days);

        _assertGt(
            EdenRewardsFacet(diamond).previewRewardProgramPosition(state.rewardProgramId, stevePositionId).claimableRewards,
            0,
            "claim preview positive"
        );
        _assertGt(bytes(positionNft.tokenURI(stevePositionId)).length, 0, "token uri available");

        vm.prank(alice);
        positionNft.transferFrom(alice, carol, stevePositionId);
        _assertEqAddress(positionNft.ownerOf(stevePositionId), carol, "position transferred");

        StEVEViewFacet.PositionPortfolio memory positionPortfolioBeforeClaim =
            StEVEViewFacet(diamond).getPositionPortfolio(stevePositionId);
        _assertEqAddress(positionPortfolioBeforeClaim.owner, carol, "portfolio owner");
        _assertGt(positionPortfolioBeforeClaim.rewards.claimableRewards, 0, "portfolio rewards visible");

        uint256 before = eve.balanceOf(carol);
        vm.prank(carol);
        uint256 claimed = EdenRewardsFacet(diamond).claimRewardProgram(state.rewardProgramId, stevePositionId, carol);
        _assertGt(claimed, 0, "rewards claimed");
        _assertEq(eve.balanceOf(carol), before + claimed, "reward balance increased");
    }

    function _bootstrapStEVEProduct() internal returns (StEVEDeploymentState memory state) {
        PoolManagementFacet pools = PoolManagementFacet(diamond);

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        pools.setDefaultPoolConfig(cfg);
        pools.initPoolWithActionFees(1, address(eve), cfg, actionFees);

        (state.steveBasketId, state.steveToken) = StEVEActionFacet(diamond).createStEVE(_stEveParams(address(eve)));

        state.rewardProgramId = EdenRewardsFacet(diamond).createRewardProgram(
            LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION,
            LibEdenRewardsStorage.STEVE_TARGET_ID,
            address(eve),
            address(this),
            1e18,
            0,
            0,
            true
        );
        StEVELendingFacet(diamond).configureLending(1 days, 14 days);

        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        StEVELendingFacet(diamond).configureBorrowFeeTiers(mins, fees);
    }

    function _timelockCall(FixedDelayTimelockController controller, address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encodePacked("equalfi-timelock", timelockSaltNonce++));
        controller.schedule(target, 0, data, bytes32(0), salt, 7 days);
        vm.warp(block.timestamp + 7 days + 1);
        controller.execute(target, 0, data, bytes32(0), salt);
    }

    function _singleAssetParams(string memory name_, string memory symbol_, address asset, string memory uri_)
        internal
        pure
        returns (StEVEProductBase.CreateBasketParams memory p)
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

    function _stEveParams(address eveToken) internal pure returns (StEVEProductBase.CreateBasketParams memory p) {
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

    function _assertExactSelectorSurfaceInstalled(IDiamondLoupe loupe) internal view {
        address[] memory facetAddresses = new address[](TOTAL_FACET_COUNT);
        uint256 i;

        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsDiamondCut());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsDiamondLoupe());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsOwnership());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsPoolManagement());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsPositionManagement());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsFlashLoan());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEqualIndexAdmin());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEqualIndexActions());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEqualIndexPosition());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEqualIndexLending());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsPositionAgentConfig());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsPositionAgentTBA());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsPositionAgentView());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsPositionAgentRegistry());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlpha());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlphaAdmin());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEqualScaleAlphaView());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEdenAdmin());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEdenView());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEdenLending());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEdenRewards());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEdenStEVE());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEdenStEVEPosition());
        facetAddresses[i++] = _assertSelectorGroupInstalled(loupe, _selectorsEdenStEVEWallet());

        _assertEq(i, TOTAL_FACET_COUNT, "expected facet groups");
        _assertEq(_countDistinctNonZero(facetAddresses), TOTAL_FACET_COUNT, "exact facet surface count");
    }

    function _containsSelector(bytes4[] memory selectors, bytes4 target) internal pure returns (bool) {
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] == target) {
                return true;
            }
        }
        return false;
    }

    function _countDistinctNonZero(address[] memory accounts) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < accounts.length; i++) {
            address candidate = accounts[i];
            if (candidate == address(0)) continue;

            bool seen;
            for (uint256 j = 0; j < i; j++) {
                if (accounts[j] == candidate) {
                    seen = true;
                    break;
                }
            }

            if (!seen) {
                count++;
            }
        }
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

        StEVEViewFacet.PositionAgentWalletView memory agentView =
            StEVEViewFacet(deployment.diamond).getPositionAgentView(tokenId);
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

        StEVEViewFacet.PositionPortfolio memory portfolio =
            StEVEViewFacet(deployment.diamond).getPositionPortfolio(tokenId);
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

        StEVEViewFacet.PositionAgentWalletView memory externalAgentView =
            StEVEViewFacet(deployment.diamond).getPositionAgentView(externalTokenId);
        _assertEqAddress(externalAgentView.tbaAddress, externalTba, "external tba");
        _assertEq(externalAgentView.agentId, externalAgentId, "external agent id");
        _assertEq(externalAgentView.registrationMode, 2, "external mode");
        _assertTrue(!externalAgentView.canonicalLink, "external canonical");
        _assertTrue(externalAgentView.externalLink, "external flag");
        _assertTrue(externalAgentView.linkActive, "external active");
        _assertEqAddress(externalAgentView.externalAuthorizer, externalOwner, "external authorizer");
        _assertTrue(externalAgentView.registrationComplete, "external complete");

        StEVEViewFacet.PositionPortfolio memory canonicalPortfolio =
            StEVEViewFacet(deployment.diamond).getPositionPortfolio(canonicalTokenId);
        StEVEViewFacet.PositionPortfolio memory externalPortfolio =
            StEVEViewFacet(deployment.diamond).getPositionPortfolio(externalTokenId);
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
