// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {OwnershipFacet} from "src/core/OwnershipFacet.sol";
import {EdenAdminFacet} from "src/eden/EdenAdminFacet.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenAdminFacetTest is EdenLaunchFixture {
    event ProductMetadataUpdated(
        uint256 indexed productId,
        string oldUri,
        string newUri,
        uint8 oldProductType,
        uint8 newProductType
    );
    event ProtocolURIUpdated(string oldUri, string newUri);
    event ContractVersionUpdated(string oldVersion, string newVersion);
    event FacetVersionUpdated(address indexed facet, string oldVersion, string newVersion);
    event TimelockControllerUpdated(address indexed oldTimelock, address indexed newTimelock);
    event ProductPausedUpdated(uint256 indexed productId, bool paused);
    event ProductFeeConfigUpdated(
        uint256 indexed productId,
        uint16[] mintFeeBps,
        uint16[] burnFeeBps,
        uint16 flashFeeBps
    );
    event PoolFeeShareUpdated(uint16 oldBps, uint16 newBps);
    event RewardConfigUpdated(address indexed rewardToken, uint256 rewardRatePerSecond, bool enabled);
    event LendingConfigUpdated(uint256 indexed basketId, uint40 minDuration, uint40 maxDuration, uint16 ltvBps);

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
    }

    function test_AdminWrites_AreTimelockOnlyAndEmitEvents() public {
        (uint256 productId,) = _createStEVE(_stEveParams(address(eve)));

        vm.expectRevert(bytes("LibAccess: not timelock"));
        EdenAdminFacet(diamond).setProtocolURI("ipfs://blocked");

        vm.recordLogs();
        _setProductMetadata("ipfs://steve-v2", 5);
        _assertIndexedEventEmitted(
            keccak256("ProductMetadataUpdated(uint256,string,string,uint8,uint8)"), bytes32(productId)
        );

        vm.recordLogs();
        _setProtocolURI("ipfs://protocol");
        _assertEventEmitted(keccak256("ProtocolURIUpdated(string,string)"));

        vm.recordLogs();
        _setContractVersion("v1.0.0");
        _assertEventEmitted(keccak256("ContractVersionUpdated(string,string)"));

        vm.recordLogs();
        _setFacetVersion(diamond, "facet-v1");
        _assertIndexedEventEmitted(keccak256("FacetVersionUpdated(address,string,string)"), bytes32(uint256(uint160(diamond))));

        vm.recordLogs();
        _setProductPaused(true);
        _assertIndexedEventEmitted(keccak256("ProductPausedUpdated(uint256,bool)"), bytes32(productId));

        uint16[] memory mintFees = new uint16[](1);
        mintFees[0] = 25;
        uint16[] memory burnFees = new uint16[](1);
        burnFees[0] = 30;
        vm.recordLogs();
        _setProductFees(mintFees, burnFees, 75);
        _assertIndexedEventEmitted(keccak256("ProductFeeConfigUpdated(uint256,uint16[],uint16[],uint16)"), bytes32(productId));

        vm.recordLogs();
        _setPoolFeeShareBps(1500);
        _assertEventEmitted(keccak256("PoolFeeShareUpdated(uint16,uint16)"));

        EdenAdminFacet.GovernanceConfigView memory governance = EdenAdminFacet(diamond).getGovernanceConfig();
        EdenViewFacet.ProductConfigView memory config = EdenViewFacet(diamond).getProductConfig();
        EdenViewFacet.ProductFeeConfigView memory feeConfig = EdenViewFacet(diamond).getProductFeeConfig();
        assertEq(governance.owner, address(timelockController));
        assertEq(governance.timelock, address(timelockController));
        assertEq(governance.timelockDelaySeconds, 7 days);
        assertEq(governance.protocolURI, "ipfs://protocol");
        assertEq(governance.contractVersion, "v1.0.0");
        assertEq(EdenAdminFacet(diamond).facetVersion(diamond), "facet-v1");
        assertEq(config.productId, productId);
        assertEq(config.uri, "ipfs://steve-v2");
        assertEq(config.productType, 5);
        assertTrue(config.paused);
        assertEq(feeConfig.poolFeeShareBps, 1500);
        assertEq(feeConfig.flashFeeBps, 75);
        assertEq(feeConfig.mintFeeBps[0], 25);
        assertEq(feeConfig.burnFeeBps[0], 30);
    }

    function test_ProductConfigWrites_FollowTimelockPath() public {
        (uint256 productId,) = _createStEVE(_stEveParams(address(eve)));

        vm.expectRevert(bytes("LibAccess: not timelock"));
        EdenRewardFacet(diamond).configureRewards(address(eve), 10e18, true);

        vm.expectRevert(bytes("LibAccess: not timelock"));
        EdenLendingFacet(diamond).configureLending(productId, 1 days, 14 days);

        vm.recordLogs();
        _configureRewards(address(eve), 10e18, true);
        _assertIndexedEventEmitted(keccak256("RewardConfigUpdated(address,uint256,bool)"), bytes32(uint256(uint160(address(eve)))));

        vm.recordLogs();
        _configureLending(productId, 1 days, 14 days);
        _assertIndexedEventEmitted(keccak256("LendingConfigUpdated(uint256,uint40,uint40,uint16)"), bytes32(productId));

        EdenViewFacet.ProductConfigView memory config = EdenViewFacet(diamond).getProductConfig();
        assertEq(config.timelockDelaySeconds, 7 days);
        assertEq(config.timelock, address(timelockController));
        assertEq(config.rewardToken, address(eve));
    }

    function test_SetTimelockController_RotatesThroughGovernance() public {
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);

        FixedDelayTimelockController goodController =
            new FixedDelayTimelockController(proposers, executors, address(this));

        vm.recordLogs();
        _setTimelockController(address(goodController));
        _assertEventEmitted(keccak256("TimelockControllerUpdated(address,address)"));

        EdenAdminFacet.GovernanceConfigView memory governance = EdenAdminFacet(diamond).getGovernanceConfig();
        assertEq(governance.timelock, address(goodController));
    }

    function test_GovernanceNegatives_RejectUnauthorizedOwnershipAndDiamondCuts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("LibDiamond: must be owner"));
        OwnershipFacet(diamond).transferOwnership(alice);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.prank(alice);
        vm.expectRevert(bytes("LibAccess: not timelock"));
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function _assertEventEmitted(bytes32 topic0) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == diamond && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return;
            }
        }
        revert("expected event not found");
    }

    function _assertIndexedEventEmitted(bytes32 topic0, bytes32 topic1) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == diamond && logs[i].topics.length > 1 && logs[i].topics[0] == topic0
                    && logs[i].topics[1] == topic1
            ) {
                return;
            }
        }
        revert("expected indexed event not found");
    }
}
