// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {EdenBasketBase} from "./EdenBasketBase.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibEdenAdminStorage} from "../libraries/LibEdenAdminStorage.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibTimelock} from "../libraries/LibTimelock.sol";
import "../libraries/Errors.sol";

contract EdenAdminFacet is EdenBasketBase, ReentrancyGuardModifiers {

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
    event TimelockControllerUpdated(address indexed oldTimelock, address indexed newTimelock);
    event BasketPausedUpdated(uint256 indexed basketId, bool paused);
    event BasketFeeConfigUpdated(
        uint256 indexed basketId,
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

    function setBasketMetadata(uint256 basketId, string calldata uri, uint8 basketType)
        external
        nonReentrant
        basketExists(basketId)
    {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibEdenBasketStorage.ProductMetadata storage metadata = LibEdenBasketStorage.s().productMetadata;
        string memory oldUri = metadata.uri;
        uint8 oldBasketType = metadata.productType;
        metadata.uri = uri;
        metadata.productType = basketType;

        emit BasketMetadataUpdated(basketId, oldUri, uri, oldBasketType, basketType);
    }

    function setProtocolURI(string calldata uri) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibEdenAdminStorage.AdminStorage storage store = LibEdenAdminStorage.s();
        string memory oldUri = store.protocolURI;
        store.protocolURI = uri;

        emit ProtocolURIUpdated(oldUri, uri);
    }

    function setContractVersion(string calldata version) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibEdenAdminStorage.AdminStorage storage store = LibEdenAdminStorage.s();
        string memory oldVersion = store.contractVersion;
        store.contractVersion = version;

        emit ContractVersionUpdated(oldVersion, version);
    }

    function setFacetVersion(address facet, string calldata version) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibEdenAdminStorage.AdminStorage storage store = LibEdenAdminStorage.s();
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

    function setBasketPaused(uint256 basketId, bool paused) external nonReentrant basketExists(basketId) {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibEdenBasketStorage.s().product.paused = paused;
        emit BasketPausedUpdated(basketId, paused);
    }

    function setBasketFees(
        uint256 basketId,
        uint16[] calldata mintFeeBps,
        uint16[] calldata burnFeeBps,
        uint16 flashFeeBps
    ) external nonReentrant basketExists(basketId) {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();

        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        uint256 len = basket.assets.length;
        if (mintFeeBps.length != len || burnFeeBps.length != len) revert InvalidArrayLength();
        if (flashFeeBps > 1000) revert InvalidParameterRange("flashFeeBps too high");

        for (uint256 i = 0; i < len; i++) {
            if (mintFeeBps[i] > 1000 || burnFeeBps[i] > 1000) {
                revert InvalidParameterRange("basket fee too high");
            }
        }

        basket.mintFeeBps = mintFeeBps;
        basket.burnFeeBps = burnFeeBps;
        basket.flashFeeBps = flashFeeBps;

        emit BasketFeeConfigUpdated(basketId, mintFeeBps, burnFeeBps, flashFeeBps);
    }

    function setPoolFeeShareBps(uint16 poolFeeShareBps) external nonReentrant {
        LibCurrency.assertZeroMsgValue();
        LibAccess.enforceTimelockOrOwnerIfUnset();
        if (poolFeeShareBps > 10_000) revert InvalidParameterRange("poolFeeShareBps too high");

        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        uint16 oldBps = store.poolFeeShareBps;
        store.poolFeeShareBps = poolFeeShareBps;

        emit PoolFeeShareUpdated(oldBps, poolFeeShareBps);
    }

    function protocolURI() external view returns (string memory) {
        return LibEdenAdminStorage.s().protocolURI;
    }

    function contractVersion() external view returns (string memory) {
        return LibEdenAdminStorage.s().contractVersion;
    }

    function facetVersion(address facet) external view returns (string memory) {
        return LibEdenAdminStorage.s().facetVersions[facet];
    }

    function timelockDelaySeconds() external pure returns (uint256) {
        return LibEdenAdminStorage.TIMELOCK_DELAY_SECONDS;
    }

    function getGovernanceConfig() external view returns (GovernanceConfigView memory config) {
        config.owner = LibDiamond.diamondStorage().contractOwner;
        config.timelock = LibAppStorage.timelockAddress(LibAppStorage.s());
        config.timelockDelaySeconds = LibEdenAdminStorage.TIMELOCK_DELAY_SECONDS;
        config.protocolURI = LibEdenAdminStorage.s().protocolURI;
        config.contractVersion = LibEdenAdminStorage.s().contractVersion;
    }
}
