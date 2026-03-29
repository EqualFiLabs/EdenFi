// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

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
import {FlashLoanFacet} from "src/equallend/FlashLoanFacet.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionMSCAImpl} from "src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {EdenBasketFacet} from "src/eden/EdenBasketFacet.sol";
import {EdenBasketDataFacet} from "src/eden/EdenBasketDataFacet.sol";
import {EdenBasketPositionFacet} from "src/eden/EdenBasketPositionFacet.sol";
import {EdenBasketWalletFacet} from "src/eden/EdenBasketWalletFacet.sol";
import {EdenStEVEFacet} from "src/eden/EdenStEVEFacet.sol";
import {EdenStEVEActionFacet} from "src/eden/EdenStEVEActionFacet.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {EdenAdminFacet} from "src/eden/EdenAdminFacet.sol";
import {Types} from "src/libraries/Types.sol";

interface IPoolManagementFacetInitDefault {
    function initPool(address underlying) external payable returns (uint256);
}

interface IPoolManagementFacetInitConfig {
    function initPool(uint256 pid, address underlying, Types.PoolConfig calldata config) external payable;
}

contract DeployEdenByEqualFi is Script {
    uint256 internal constant LAUNCH_FACET_COUNT = 21;
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
    }

    function runBase() external returns (BaseDeployment memory deployment) {
        address treasury_ = vm.envAddress("TREASURY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address owner_ = vm.envOr("OWNER", deployer);
        require(deployer == owner_, "DeployEdenByEqualFi: PRIVATE_KEY must be OWNER");

        vm.startBroadcast(deployerPrivateKey);
        deployment = deployBase(owner_, treasury_);
        vm.stopBroadcast();

        console2.log("diamond", deployment.diamond);
        console2.log("positionNFT", deployment.positionNFT);
    }

    function run() external returns (LaunchDeployment memory deployment) {
        address governor_ = vm.envAddress("TIMELOCK");
        address treasury_ = vm.envAddress("TREASURY");
        address entryPoint_ = vm.envAddress("ENTRYPOINT_ADDRESS");
        address erc6551Registry_ = vm.envAddress("ERC6551_REGISTRY");
        address identityRegistry_ = vm.envAddress("IDENTITY_REGISTRY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address owner_ = vm.envOr("OWNER", deployer);
        require(deployer == owner_, "DeployEdenByEqualFi: PRIVATE_KEY must be OWNER");

        vm.startBroadcast(deployerPrivateKey);
        deployment =
            deployLaunch(owner_, governor_, treasury_, entryPoint_, erc6551Registry_, identityRegistry_);
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
    }

    function deployBase(address owner_, address treasury_)
        public
        returns (BaseDeployment memory deployment)
    {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _cut(address(cut), _selectorsDiamondCut());
        cuts[1] = _cut(address(loupe), _selectorsDiamondLoupe());
        cuts[2] = _cut(address(own), _selectorsOwnership());

        Diamond diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: owner_}));
        PositionNFT nftContract = new PositionNFT();
        DiamondInit initializer = new DiamondInit();

        IDiamondCut(address(diamond)).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, address(0), treasury_, address(nftContract))
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
    )
        public
        returns (LaunchDeployment memory deployment)
    {
        BaseDeployment memory base = deployBase(owner_, treasury_);
        _installLaunchFacets(base.diamond);

        PositionMSCAImpl positionMSCAImplementation = new PositionMSCAImpl(entryPoint_);
        PositionAgentConfigFacet(base.diamond).setERC6551Registry(erc6551Registry_);
        PositionAgentConfigFacet(base.diamond).setERC6551Implementation(address(positionMSCAImplementation));
        PositionAgentConfigFacet(base.diamond).setIdentityRegistry(identityRegistry_);

        address[] memory proposers = new address[](1);
        proposers[0] = governor_;
        address[] memory executors = new address[](1);
        executors[0] = governor_;
        FixedDelayTimelockController timelockController =
            new FixedDelayTimelockController(proposers, executors, governor_);

        EdenAdminFacet(base.diamond).setTimelockController(address(timelockController));
        OwnershipFacet(base.diamond).transferOwnership(address(timelockController));

        deployment = LaunchDeployment({
            diamond: base.diamond,
            positionNFT: base.positionNFT,
            timelockController: address(timelockController),
            governor: governor_,
            treasury: treasury_,
            entryPoint: entryPoint_,
            erc6551Registry: erc6551Registry_,
            identityRegistry: identityRegistry_,
            positionMSCAImplementation: address(positionMSCAImplementation)
        });
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
            EdenAdminFacet facet = new EdenAdminFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenAdmin());
        }
        {
            EdenViewFacet facet = new EdenViewFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenView());
        }
        {
            EdenLendingFacet facet = new EdenLendingFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenLending());
        }
        {
            EdenRewardFacet facet = new EdenRewardFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenReward());
        }
        {
            EdenStEVEActionFacet facet = new EdenStEVEActionFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenStEVE());
        }
        {
            EdenBasketDataFacet facet = new EdenBasketDataFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenBasketData());
        }
        {
            EdenBasketPositionFacet facet = new EdenBasketPositionFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenBasketPosition());
        }
        {
            EdenBasketWalletFacet facet = new EdenBasketWalletFacet();
            cuts[i++] = _cut(address(facet), _selectorsEdenBasketWallet());
        }

        require(i == LAUNCH_FACET_COUNT, "DeployEdenByEqualFi: bad facet count");
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
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
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
        s = new bytes4[](25);
        s[0] = PoolManagementFacet.initPoolWithActionFees.selector;
        s[1] = IPoolManagementFacetInitConfig.initPool.selector;
        s[2] = IPoolManagementFacetInitDefault.initPool.selector;
        s[3] = PoolManagementFacet.initManagedPool.selector;
        s[4] = PoolManagementFacet.setDefaultPoolConfig.selector;
        s[5] = PoolManagementFacet.setRollingApy.selector;
        s[6] = PoolManagementFacet.setDepositorLTV.selector;
        s[7] = PoolManagementFacet.setMinDepositAmount.selector;
        s[8] = PoolManagementFacet.setMinLoanAmount.selector;
        s[9] = PoolManagementFacet.setMinTopupAmount.selector;
        s[10] = PoolManagementFacet.setDepositCap.selector;
        s[11] = PoolManagementFacet.setIsCapped.selector;
        s[12] = PoolManagementFacet.setMaxUserCount.selector;
        s[13] = PoolManagementFacet.setMaintenanceRate.selector;
        s[14] = PoolManagementFacet.setFlashLoanFee.selector;
        s[15] = PoolManagementFacet.setActionFees.selector;
        s[16] = PoolManagementFacet.addToWhitelist.selector;
        s[17] = PoolManagementFacet.removeFromWhitelist.selector;
        s[18] = PoolManagementFacet.setWhitelistEnabled.selector;
        s[19] = PoolManagementFacet.transferManager.selector;
        s[20] = PoolManagementFacet.renounceManager.selector;
        s[21] = PoolManagementFacet.setAumFee.selector;
        s[22] = PoolManagementFacet.getPoolConfigView.selector;
        s[23] = PoolManagementFacet.getPoolInfoView.selector;
        s[24] = PoolManagementFacet.getPoolMaintenanceView.selector;
    }

    function _selectorsPositionManagement() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = PositionManagementFacet.mintPosition.selector;
        s[1] = PositionManagementFacet.depositToPosition.selector;
        s[2] = PositionManagementFacet.withdrawFromPosition.selector;
        s[3] = PositionManagementFacet.cleanupMembership.selector;
        s[4] = PositionManagementFacet.previewPositionYield.selector;
        s[5] = PositionManagementFacet.claimPositionYield.selector;
    }

    function _selectorsFlashLoan() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = FlashLoanFacet.previewFlashLoanRepayment.selector;
        s[1] = FlashLoanFacet.flashLoan.selector;
    }

    function _selectorsEqualIndexAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = EqualIndexAdminFacetV3.createIndex.selector;
        s[1] = EqualIndexAdminFacetV3.setPaused.selector;
        s[2] = EqualIndexAdminFacetV3.getIndex.selector;
        s[3] = EqualIndexAdminFacetV3.getVaultBalance.selector;
        s[4] = EqualIndexAdminFacetV3.getFeePot.selector;
        s[5] = EqualIndexAdminFacetV3.getIndexPoolId.selector;
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

    function _selectorsEdenBasketWallet() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = EdenBasketWalletFacet.createBasket.selector;
        s[1] = EdenBasketWalletFacet.mintBasket.selector;
        s[2] = EdenBasketWalletFacet.burnBasket.selector;
    }

    function _selectorsEdenBasketPosition() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = EdenBasketPositionFacet.mintBasketFromPosition.selector;
        s[1] = EdenBasketPositionFacet.burnBasketFromPosition.selector;
    }

    function _selectorsEdenBasketData() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = EdenBasketDataFacet.getBasket.selector;
        s[1] = EdenBasketDataFacet.getBasketMetadata.selector;
        s[2] = EdenBasketDataFacet.getBasketPoolId.selector;
        s[3] = EdenBasketDataFacet.getBasketVaultBalance.selector;
        s[4] = EdenBasketDataFacet.getBasketFeePot.selector;
    }

    function _selectorsEdenStEVE() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = EdenStEVEActionFacet.createStEVE.selector;
        s[1] = EdenStEVEActionFacet.depositStEVEToPosition.selector;
        s[2] = EdenStEVEActionFacet.withdrawStEVEFromPosition.selector;
        s[3] = EdenStEVEActionFacet.steveBasketId.selector;
        s[4] = EdenStEVEActionFacet.eligibleSupply.selector;
        s[5] = EdenStEVEActionFacet.eligiblePrincipalOfPosition.selector;
    }

    function _selectorsEdenReward() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = EdenRewardFacet.configureRewards.selector;
        s[1] = EdenRewardFacet.fundRewards.selector;
        s[2] = EdenRewardFacet.claimRewards.selector;
        s[3] = EdenRewardFacet.previewClaimRewards.selector;
        s[4] = EdenRewardFacet.claimableRewards.selector;
        s[5] = EdenRewardFacet.accruedRewardsOfPosition.selector;
        s[6] = EdenRewardFacet.rewardCheckpointOfPosition.selector;
        s[7] = EdenRewardFacet.getRewardConfig.selector;
    }

    function _selectorsEdenLending() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](20);
        s[0] = EdenLendingFacet.borrow.selector;
        s[1] = EdenLendingFacet.repay.selector;
        s[2] = EdenLendingFacet.extend.selector;
        s[3] = EdenLendingFacet.recoverExpired.selector;
        s[4] = EdenLendingFacet.configureLending.selector;
        s[5] = EdenLendingFacet.configureBorrowFeeTiers.selector;
        s[6] = EdenLendingFacet.loanCount.selector;
        s[7] = EdenLendingFacet.borrowerLoanCount.selector;
        s[8] = EdenLendingFacet.getLoanView.selector;
        s[9] = EdenLendingFacet.getLoanIdsByBorrower.selector;
        s[10] = EdenLendingFacet.getActiveLoanIdsByBorrower.selector;
        s[11] = EdenLendingFacet.getLoansByBorrower.selector;
        s[12] = EdenLendingFacet.getActiveLoansByBorrower.selector;
        s[13] = EdenLendingFacet.getLoanIdsByBorrowerPaginated.selector;
        s[14] = EdenLendingFacet.getActiveLoanIdsByBorrowerPaginated.selector;
        s[15] = EdenLendingFacet.previewBorrow.selector;
        s[16] = EdenLendingFacet.previewRepay.selector;
        s[17] = EdenLendingFacet.previewExtend.selector;
        s[18] = EdenLendingFacet.getOutstandingPrincipal.selector;
        s[19] = EdenLendingFacet.getLockedCollateralUnits.selector;
    }

    function _selectorsEdenView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](19);
        s[0] = EdenViewFacet.basketCount.selector;
        s[1] = EdenViewFacet.getBasketIds.selector;
        s[2] = EdenViewFacet.getBasketSummary.selector;
        s[3] = EdenViewFacet.getBasketSummaries.selector;
        s[4] = EdenViewFacet.getProductConfig.selector;
        s[5] = EdenViewFacet.getPositionTokenURI.selector;
        s[6] = EdenViewFacet.hasOpenOffers.selector;
        s[7] = EdenViewFacet.cancelOffersForPosition.selector;
        s[8] = EdenViewFacet.getUserPositionIds.selector;
        s[9] = EdenViewFacet.getUserPositionIdsPaginated.selector;
        s[10] = EdenViewFacet.getPositionPortfolio.selector;
        s[11] = EdenViewFacet.getPositionAgentView.selector;
        s[12] = EdenViewFacet.getUserPortfolio.selector;
        s[13] = EdenViewFacet.canMint.selector;
        s[14] = EdenViewFacet.canBurn.selector;
        s[15] = EdenViewFacet.canBorrow.selector;
        s[16] = EdenViewFacet.canRepay.selector;
        s[17] = EdenViewFacet.canExtend.selector;
        s[18] = EdenViewFacet.canClaimRewards.selector;
    }

    function _selectorsEdenAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[0] = EdenAdminFacet.setBasketMetadata.selector;
        s[1] = EdenAdminFacet.setProtocolURI.selector;
        s[2] = EdenAdminFacet.setContractVersion.selector;
        s[3] = EdenAdminFacet.setFacetVersion.selector;
        s[4] = EdenAdminFacet.setTimelockController.selector;
        s[5] = EdenAdminFacet.setBasketPaused.selector;
        s[6] = EdenAdminFacet.setBasketFees.selector;
        s[7] = EdenAdminFacet.setPoolFeeShareBps.selector;
        s[8] = EdenAdminFacet.protocolURI.selector;
        s[9] = EdenAdminFacet.contractVersion.selector;
        s[10] = EdenAdminFacet.facetVersion.selector;
        s[11] = EdenAdminFacet.timelockDelaySeconds.selector;
        s[12] = EdenAdminFacet.getGovernanceConfig.selector;
    }
}
