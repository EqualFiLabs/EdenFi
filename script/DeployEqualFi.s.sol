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
import {EqualIndexLendingFacet} from "src/equalindex/EqualIndexLendingFacet.sol";
import {PositionAgentConfigFacet} from "src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionMSCAImpl} from "src/agent-wallet/erc6900/PositionMSCAImpl.sol";
import {EqualScaleAlphaFacet} from "src/equalscale/EqualScaleAlphaFacet.sol";
import {EqualScaleAlphaAdminFacet} from "src/equalscale/EqualScaleAlphaAdminFacet.sol";
import {EqualScaleAlphaViewFacet} from "src/equalscale/EqualScaleAlphaViewFacet.sol";
import {EdenRewardsFacet} from "src/eden/EdenRewardsFacet.sol";
import {Types} from "src/libraries/Types.sol";

interface IPoolManagementFacetInitDefault {
    function initPool(address underlying) external payable returns (uint256);
}

contract DeployEqualFi is Script {
    uint256 internal constant DIAMOND_CORE_FACET_COUNT = 3;
    uint256 internal constant SUBSTRATE_LAUNCH_FACET_COUNT = 14;
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
        address governor_ = vm.envAddress("TIMELOCK");
        address treasury_ = vm.envAddress("TREASURY");
        address entryPoint_ = vm.envAddress("ENTRYPOINT_ADDRESS");
        address erc6551Registry_ = vm.envAddress("ERC6551_REGISTRY");
        address identityRegistry_ = vm.envAddress("IDENTITY_REGISTRY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address owner_ = vm.envOr("OWNER", deployer);
        require(deployer == owner_, "DeployEqualFi: PRIVATE_KEY must be OWNER");

        vm.startBroadcast(deployerPrivateKey);
        deployment = deployLaunch(owner_, governor_, treasury_, entryPoint_, erc6551Registry_, identityRegistry_);
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
        address[] memory proposers = new address[](1);
        proposers[0] = governor_;
        address[] memory executors = new address[](1);
        executors[0] = governor_;
        FixedDelayTimelockController timelockController =
            new FixedDelayTimelockController(proposers, executors, governor_);

        BaseDeployment memory base = _deployBase(owner_, treasury_, address(0));
        _installLaunchFacets(base.diamond);

        PositionMSCAImpl positionMSCAImplementation = new PositionMSCAImpl(entryPoint_);
        PositionAgentConfigFacet(base.diamond).setERC6551Registry(erc6551Registry_);
        PositionAgentConfigFacet(base.diamond).setERC6551Implementation(address(positionMSCAImplementation));
        PositionAgentConfigFacet(base.diamond).setIdentityRegistry(identityRegistry_);
        _installTimelock(base.diamond, treasury_, address(timelockController));

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

    function _installTimelock(address diamond, address treasury_, address timelock_) internal {
        DiamondInit initializer = new DiamondInit();
        IDiamondCut(diamond).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, timelock_, treasury_, address(0))
        );
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
            EqualIndexLendingFacet facet = new EqualIndexLendingFacet();
            cuts[i++] = _cut(address(facet), _selectorsEqualIndexLending());
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

    function _selectorsEqualIndexLending() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](16);
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
        s[15] = EqualIndexLendingFacet.lendingModuleId.selector;
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

    function _selectorsEdenRewards() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](16);
        s[0] = EdenRewardsFacet.createRewardProgram.selector;
        s[1] = EdenRewardsFacet.setRewardProgramTransferFeeBps.selector;
        s[2] = EdenRewardsFacet.setRewardProgramEnabled.selector;
        s[3] = EdenRewardsFacet.pauseRewardProgram.selector;
        s[4] = EdenRewardsFacet.resumeRewardProgram.selector;
        s[5] = EdenRewardsFacet.endRewardProgram.selector;
        s[6] = EdenRewardsFacet.closeRewardProgram.selector;
        s[7] = EdenRewardsFacet.fundRewardProgram.selector;
        s[8] = EdenRewardsFacet.accrueRewardProgram.selector;
        s[9] = EdenRewardsFacet.settleRewardProgramPosition.selector;
        s[10] = EdenRewardsFacet.claimRewardProgram.selector;
        s[11] = EdenRewardsFacet.getRewardProgram.selector;
        s[12] = EdenRewardsFacet.previewRewardProgramState.selector;
        s[13] = EdenRewardsFacet.getRewardProgramIdsByTarget.selector;
        s[14] = EdenRewardsFacet.previewRewardProgramPosition.selector;
        s[15] = EdenRewardsFacet.previewRewardProgramsForPosition.selector;
    }

}
