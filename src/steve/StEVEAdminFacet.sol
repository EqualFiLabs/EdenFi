// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {StEVEProductBase} from "./StEVEProductBase.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibStEVEAdminStorage} from "../libraries/LibStEVEAdminStorage.sol";
import {LibStEVEStorage} from "../libraries/LibStEVEStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibTimelock} from "../libraries/LibTimelock.sol";
import "../libraries/Errors.sol";

contract StEVEAdminFacet is StEVEProductBase, ReentrancyGuardModifiers {

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

    struct GovernanceConfigView {
        address owner;
        address timelock;
        uint256 timelockDelaySeconds;
        string protocolURI;
        string contractVersion;
    }

    function setProductMetadata(string calldata uri, uint8 productType)
        external
        nonReentrant
        basketExists(LibStEVEStorage.PRODUCT_ID)
    {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibStEVEStorage.ProductMetadata storage metadata = LibStEVEStorage.s().productMetadata;
        string memory oldUri = metadata.uri;
        uint8 oldProductType = metadata.productType;
        metadata.uri = uri;
        metadata.productType = productType;

        emit ProductMetadataUpdated(LibStEVEStorage.PRODUCT_ID, oldUri, uri, oldProductType, productType);
    }

    function setProtocolURI(string calldata uri) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibStEVEAdminStorage.AdminStorage storage store = LibStEVEAdminStorage.s();
        string memory oldUri = store.protocolURI;
        store.protocolURI = uri;

        emit ProtocolURIUpdated(oldUri, uri);
    }

    function setContractVersion(string calldata version) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibStEVEAdminStorage.AdminStorage storage store = LibStEVEAdminStorage.s();
        string memory oldVersion = store.contractVersion;
        store.contractVersion = version;

        emit ContractVersionUpdated(oldVersion, version);
    }

    function setFacetVersion(address facet, string calldata version) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibStEVEAdminStorage.AdminStorage storage store = LibStEVEAdminStorage.s();
        string memory oldVersion = store.facetVersions[facet];
        store.facetVersions[facet] = version;

        emit FacetVersionUpdated(facet, oldVersion, version);
    }

    function setTimelockController(address timelockController) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();
        LibTimelock.validateFixedDelayController(timelockController);

        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        address oldTimelock = LibAppStorage.timelockAddress(app);
        app.timelock = timelockController;

        emit TimelockControllerUpdated(oldTimelock, timelockController);
    }

    function setProductPaused(bool paused) external nonReentrant basketExists(LibStEVEStorage.PRODUCT_ID) {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibStEVEStorage.s().product.paused = paused;
        emit ProductPausedUpdated(LibStEVEStorage.PRODUCT_ID, paused);
    }

    function setProductFees(uint16[] calldata mintFeeBps, uint16[] calldata burnFeeBps, uint16 flashFeeBps)
        external
        nonReentrant
        basketExists(LibStEVEStorage.PRODUCT_ID)
    {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibStEVEStorage.ProductConfig storage product = LibStEVEStorage.s().product;
        uint256 len = product.assets.length;
        if (mintFeeBps.length != len || burnFeeBps.length != len) revert InvalidArrayLength();
        if (flashFeeBps > 1000) revert InvalidParameterRange("flashFeeBps too high");

        for (uint256 i = 0; i < len; i++) {
            if (mintFeeBps[i] > 1000 || burnFeeBps[i] > 1000) {
                revert InvalidParameterRange("product fee too high");
            }
        }

        product.mintFeeBps = mintFeeBps;
        product.burnFeeBps = burnFeeBps;
        product.flashFeeBps = flashFeeBps;

        emit ProductFeeConfigUpdated(LibStEVEStorage.PRODUCT_ID, mintFeeBps, burnFeeBps, flashFeeBps);
    }

    function setPoolFeeShareBps(uint16 poolFeeShareBps) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();
        if (poolFeeShareBps > 10_000) revert InvalidParameterRange("poolFeeShareBps too high");

        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        uint16 oldBps = store.poolFeeShareBps;
        store.poolFeeShareBps = poolFeeShareBps;

        emit PoolFeeShareUpdated(oldBps, poolFeeShareBps);
    }

    function protocolURI() external view returns (string memory) {
        return LibStEVEAdminStorage.s().protocolURI;
    }

    function contractVersion() external view returns (string memory) {
        return LibStEVEAdminStorage.s().contractVersion;
    }

    function facetVersion(address facet) external view returns (string memory) {
        return LibStEVEAdminStorage.s().facetVersions[facet];
    }

    function timelockDelaySeconds() external pure returns (uint256) {
        return LibStEVEAdminStorage.TIMELOCK_DELAY_SECONDS;
    }

    function getGovernanceConfig() external view returns (GovernanceConfigView memory config) {
        config.owner = LibDiamond.diamondStorage().contractOwner;
        config.timelock = LibAppStorage.timelockAddress(LibAppStorage.s());
        config.timelockDelaySeconds = LibStEVEAdminStorage.TIMELOCK_DELAY_SECONDS;
        config.protocolURI = LibStEVEAdminStorage.s().protocolURI;
        config.contractVersion = LibStEVEAdminStorage.s().contractVersion;
    }
}
