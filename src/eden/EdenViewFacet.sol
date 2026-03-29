// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {EdenBasketBase} from "./EdenBasketBase.sol";
import {EdenLendingLogic} from "./EdenLendingLogic.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {BasketToken} from "../tokens/BasketToken.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {IERC8004IdentityRegistry} from "@agent-wallet-core/adapters/ERC8004IdentityAdapter.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibEdenAdminStorage} from "../libraries/LibEdenAdminStorage.sol";
import {LibEdenBasketStorage} from "../libraries/LibEdenBasketStorage.sol";
import {LibEdenLendingStorage} from "../libraries/LibEdenLendingStorage.sol";
import {LibEdenRewards} from "../libraries/LibEdenRewards.sol";
import {LibEdenRewardStorage} from "../libraries/LibEdenRewardStorage.sol";
import {LibEdenStEVEStorage} from "../libraries/LibEdenStEVEStorage.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

contract EdenViewFacet is EdenLendingLogic {
    uint8 public constant ACTION_OK = 0;
    uint8 public constant ACTION_UNKNOWN_BASKET = 1;
    uint8 public constant ACTION_BASKET_PAUSED = 2;
    uint8 public constant ACTION_INVALID_UNITS = 3;
    uint8 public constant ACTION_INSUFFICIENT_BALANCE = 4;
    uint8 public constant ACTION_POSITION_MISMATCH = 5;
    uint8 public constant ACTION_LOAN_NOT_FOUND = 6;
    uint8 public constant ACTION_LOAN_EXPIRED = 7;
    uint8 public constant ACTION_NOTHING_CLAIMABLE = 8;
    uint8 public constant ACTION_INVALID_DURATION = 9;
    uint8 public constant ACTION_INSUFFICIENT_COLLATERAL = 10;
    uint8 public constant ACTION_BELOW_MINIMUM_TIER = 11;
    uint8 public constant ACTION_REWARDS_DISABLED = 12;

    struct BasketSummary {
        uint256 basketId;
        string name;
        string symbol;
        string uri;
        address token;
        uint256 poolId;
        uint256 totalUnits;
        uint8 basketType;
        bool paused;
        bool isStEVE;
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
    }

    struct ProductConfigView {
        address treasury;
        address timelock;
        uint256 timelockDelaySeconds;
        uint256 basketCount;
        uint16 poolFeeShareBps;
        string protocolURI;
        string contractVersion;
        bool steveConfigured;
        uint256 steveBasketId;
        address rewardToken;
        uint256 rewardRatePerSecond;
        uint256 rewardReserve;
        bool rewardsEnabled;
    }

    struct PositionBasketView {
        uint256 basketId;
        uint256 poolId;
        address token;
        uint8 basketType;
        uint256 units;
        uint256 encumberedUnits;
        uint256 availableUnits;
        bool paused;
    }

    struct PositionRewardView {
        uint256 eligiblePrincipal;
        uint256 accruedRewards;
        uint256 claimableRewards;
    }

    struct PositionAgentWalletView {
        address tbaAddress;
        bool tbaDeployed;
        uint256 agentId;
        bool agentRegistered;
        uint8 registrationMode;
        bool canonicalLink;
        bool externalLink;
        bool linkActive;
        address externalAuthorizer;
        bool registrationComplete;
    }

    struct PositionPortfolio {
        uint256 positionId;
        bytes32 positionKey;
        address owner;
        uint256 homePoolId;
        uint8 agentRegistrationMode;
        PositionAgentWalletView agent;
        PositionBasketView[] baskets;
        PositionRewardView rewards;
        LoanView[] loans;
    }

    struct UserPortfolio {
        address user;
        uint256[] positionIds;
        PositionPortfolio[] positions;
    }

    struct ActionCheck {
        bool ok;
        uint8 code;
        string reason;
    }

    function basketCount() external view returns (uint256) {
        return LibEdenBasketStorage.s().productInitialized ? 1 : 0;
    }

    function getBasketIds(uint256 start, uint256 limit) external view returns (uint256[] memory basketIds) {
        uint256 count = LibEdenBasketStorage.s().productInitialized ? 1 : 0;
        if (start >= count || limit == 0) return new uint256[](0);

        basketIds = new uint256[](1);
        basketIds[0] = LibEdenBasketStorage.PRODUCT_ID;
    }

    function getBasketSummary(uint256 basketId) public view basketExists(basketId) returns (BasketSummary memory summary) {
        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        LibEdenBasketStorage.ProductConfig storage basket = store.product;
        LibEdenBasketStorage.ProductMetadata storage metadata = store.productMetadata;

        summary.basketId = basketId;
        summary.name = metadata.name;
        summary.symbol = metadata.symbol;
        summary.uri = metadata.uri;
        summary.token = basket.token;
        summary.poolId = basket.poolId;
        summary.totalUnits = basket.totalUnits;
        summary.basketType = metadata.productType;
        summary.paused = basket.paused;
        summary.isStEVE = LibEdenStEVEStorage.s().configured && basketId == LibEdenStEVEStorage.s().basketId;
        summary.assets = basket.assets;
        summary.bundleAmounts = basket.bundleAmounts;
        summary.mintFeeBps = basket.mintFeeBps;
        summary.burnFeeBps = basket.burnFeeBps;
        summary.flashFeeBps = basket.flashFeeBps;
    }

    function getBasketSummaries(uint256 start, uint256 limit) external view returns (BasketSummary[] memory summaries) {
        uint256 count = LibEdenBasketStorage.s().productInitialized ? 1 : 0;
        if (start >= count || limit == 0) return new BasketSummary[](0);

        summaries = new BasketSummary[](1);
        summaries[0] = getBasketSummary(LibEdenBasketStorage.PRODUCT_ID);
    }

    function getProductConfig() external view returns (ProductConfigView memory view_) {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        LibEdenStEVEStorage.StEVEStorage storage steve = LibEdenStEVEStorage.s();

        view_.treasury = LibAppStorage.treasuryAddress(app);
        view_.timelock = LibAppStorage.timelockAddress(app);
        view_.timelockDelaySeconds = LibEdenAdminStorage.TIMELOCK_DELAY_SECONDS;
        view_.basketCount = LibEdenBasketStorage.s().productInitialized ? 1 : 0;
        view_.poolFeeShareBps = _basketPoolFeeShareBps();
        view_.protocolURI = LibEdenAdminStorage.s().protocolURI;
        view_.contractVersion = LibEdenAdminStorage.s().contractVersion;
        view_.steveConfigured = steve.configured;
        view_.steveBasketId = steve.configured ? steve.basketId : 0;
        view_.rewardToken = rewards.config.rewardToken;
        view_.rewardRatePerSecond = rewards.config.rewardRatePerSecond;
        view_.rewardReserve = LibEdenRewards.previewRewardReserve();
        view_.rewardsEnabled = rewards.config.enabled;
    }

    function getPositionTokenURI(uint256 positionId) external view returns (string memory) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        PositionAgentWalletView memory agent = _positionAgentWallet(positionId);
        return string.concat("equalfi://positions/", Strings.toString(positionId), _positionQueryString(nft, positionId, agent));
    }

    function hasOpenOffers(bytes32) external pure returns (bool) {
        return false;
    }

    function cancelOffersForPosition(bytes32) external pure {}

    function getUserPositionIds(address user) public view returns (uint256[] memory positionIds) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        uint256 balance = nft.balanceOf(user);
        positionIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            positionIds[i] = nft.tokenOfOwnerByIndex(user, i);
        }
    }

    function getUserPositionIdsPaginated(address user, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory positionIds)
    {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        uint256 balance = nft.balanceOf(user);
        if (start >= balance || limit == 0) return new uint256[](0);

        uint256 remaining = balance - start;
        uint256 resultLen = remaining < limit ? remaining : limit;
        positionIds = new uint256[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            positionIds[i] = nft.tokenOfOwnerByIndex(user, start + i);
        }
    }

    function getPositionAgentView(uint256 positionId) public view returns (PositionAgentWalletView memory agent) {
        return _positionAgentWallet(positionId);
    }

    function getPositionPortfolio(uint256 positionId) public view returns (PositionPortfolio memory portfolio) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        uint256[] memory loanIds = _loanIdsByBorrower(positionId);

        portfolio.positionId = positionId;
        portfolio.positionKey = positionKey;
        portfolio.owner = nft.ownerOf(positionId);
        portfolio.homePoolId = nft.getPoolId(positionId);
        portfolio.agent = _positionAgentWallet(positionId);
        portfolio.agentRegistrationMode = portfolio.agent.registrationMode;
        portfolio.baskets = _positionBaskets(positionKey);
        portfolio.rewards = PositionRewardView({
            eligiblePrincipal: LibEdenStEVEStorage.s().eligiblePrincipal[positionKey],
            accruedRewards: LibEdenRewardStorage.s().accruedRewards[positionKey],
            claimableRewards: LibEdenRewards.previewPositionRewards(positionKey)
        });
        portfolio.loans = new LoanView[](loanIds.length);
        for (uint256 i = 0; i < loanIds.length; i++) {
            portfolio.loans[i] = _getLoanView(loanIds[i]);
        }
    }

    function _positionAgentWallet(uint256 positionId) internal view returns (PositionAgentWalletView memory agent) {
        LibPositionAgentStorage.AgentStorage storage wallet = LibPositionAgentStorage.s();
        agent.agentId = wallet.positionToAgentId[positionId];
        agent.agentRegistered = agent.agentId != 0;
        agent.registrationMode = uint8(wallet.positionRegistrationMode[positionId]);
        agent.canonicalLink = wallet.positionRegistrationMode[positionId]
            == LibPositionAgentStorage.AgentRegistrationMode.CanonicalOwned;
        agent.externalLink = wallet.positionRegistrationMode[positionId]
            == LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked;
        agent.externalAuthorizer = wallet.externalAgentAuthorizer[positionId];

        if (
            wallet.erc6551Registry == address(0) || wallet.erc6551Implementation == address(0)
                || wallet.erc6551Registry.code.length == 0
        ) {
            return agent;
        }

        agent.tbaAddress = IERC6551Registry(wallet.erc6551Registry).account(
            wallet.erc6551Implementation,
            wallet.tbaSalt,
            block.chainid,
            LibPositionNFT.s().positionNFTContract,
            positionId
        );
        agent.tbaDeployed = agent.tbaAddress.code.length > 0;

        if (!agent.agentRegistered || wallet.identityRegistry == address(0) || wallet.identityRegistry.code.length == 0) {
            return agent;
        }

        (bool ok, bytes memory data) = wallet.identityRegistry.staticcall(
            abi.encodeWithSelector(IERC8004IdentityRegistry.ownerOf.selector, agent.agentId)
        );
        if (!ok || data.length < 32) {
            return agent;
        }

        address registryOwner = abi.decode(data, (address));
        if (agent.canonicalLink) {
            agent.linkActive = registryOwner == agent.tbaAddress;
        } else if (agent.externalLink) {
            agent.linkActive = registryOwner == agent.externalAuthorizer;
        }
        agent.registrationComplete = agent.linkActive;
    }

    function _positionQueryString(PositionNFT nft, uint256 positionId, PositionAgentWalletView memory agent)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "?poolId=",
            Strings.toString(nft.getPoolId(positionId)),
            "&tba=",
            Strings.toHexString(uint160(agent.tbaAddress), 20),
            _agentQueryString(agent)
        );
    }

    function _agentQueryString(PositionAgentWalletView memory agent) internal pure returns (string memory) {
        return string.concat(
            "&tbaDeployed=",
            _boolString(agent.tbaDeployed),
            "&agentId=",
            Strings.toString(agent.agentId),
            "&agentMode=",
            Strings.toString(agent.registrationMode),
            "&agentCanonical=",
            _boolString(agent.canonicalLink),
            "&agentExternal=",
            _boolString(agent.externalLink),
            "&agentActive=",
            _boolString(agent.linkActive),
            "&agentComplete=",
            _boolString(agent.registrationComplete)
        );
    }

    function getUserPortfolio(address user) external view returns (UserPortfolio memory portfolio) {
        uint256[] memory positionIds = getUserPositionIds(user);
        portfolio.user = user;
        portfolio.positionIds = positionIds;
        portfolio.positions = new PositionPortfolio[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            portfolio.positions[i] = getPositionPortfolio(positionIds[i]);
        }
    }

    function canMint(uint256 basketId, uint256 units) external view returns (ActionCheck memory) {
        if (!_isKnownBasketId(basketId)) {
            return _fail(ACTION_UNKNOWN_BASKET, "unknown basket");
        }
        if (units == 0 || units % UNIT_SCALE != 0) {
            return _fail(ACTION_INVALID_UNITS, "invalid units");
        }
        if (LibEdenBasketStorage.s().product.paused) {
            return _fail(ACTION_BASKET_PAUSED, "basket paused");
        }
        return _ok();
    }

    function canBurn(address owner, uint256 basketId, uint256 units) external view returns (ActionCheck memory) {
        if (!_isKnownBasketId(basketId)) {
            return _fail(ACTION_UNKNOWN_BASKET, "unknown basket");
        }
        if (units == 0 || units % UNIT_SCALE != 0) {
            return _fail(ACTION_INVALID_UNITS, "invalid units");
        }
        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        if (basket.paused) {
            return _fail(ACTION_BASKET_PAUSED, "basket paused");
        }
        if (BasketToken(basket.token).balanceOf(owner) < units) {
            return _fail(ACTION_INSUFFICIENT_BALANCE, "insufficient basket balance");
        }
        return _ok();
    }

    function canBorrow(uint256 positionId, uint256 basketId, uint256 collateralUnits, uint40 duration)
        external
        view
        returns (ActionCheck memory)
    {
        if (!_isKnownBasketId(basketId)) {
            return _fail(ACTION_UNKNOWN_BASKET, "unknown basket");
        }
        if (collateralUnits == 0 || collateralUnits % UNIT_SCALE != 0) {
            return _fail(ACTION_INVALID_UNITS, "invalid collateral units");
        }

        LibEdenBasketStorage.ProductConfig storage basket = LibEdenBasketStorage.s().product;
        if (basket.paused) {
            return _fail(ACTION_BASKET_PAUSED, "basket paused");
        }

        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        LibEdenLendingStorage.LendingConfig memory config = lending.lendingConfigs[basketId];
        if (
            duration == 0 || config.minDuration == 0 || duration < config.minDuration || duration > config.maxDuration
        ) {
            return _fail(ACTION_INVALID_DURATION, "invalid duration");
        }

        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        uint256 availableCollateral = _availableCollateral(positionKey, basket.poolId);
        if (collateralUnits > availableCollateral) {
            return _fail(ACTION_INSUFFICIENT_COLLATERAL, "insufficient available collateral");
        }

        if (!_hasBorrowFeeTier(lending.borrowFeeTiers[basketId], collateralUnits)) {
            return _fail(ACTION_BELOW_MINIMUM_TIER, "below minimum fee tier");
        }

        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, collateralUnits, LibEdenLendingStorage.DEFAULT_LTV_BPS);
        uint256 newLockedCollateral = lending.lockedCollateralUnits[basketId] + collateralUnits;
        if (
            !_redeemabilityInvariantSatisfied(
                basketId, basket, assets, principals, newLockedCollateral, basket.totalUnits
            )
        ) {
            return _fail(ACTION_INSUFFICIENT_BALANCE, "basket vault invariant would fail");
        }

        return _ok();
    }

    function canRepay(uint256 positionId, uint256 loanId) external view returns (ActionCheck memory) {
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrowerPositionKey == bytes32(0) || lending.loanClosed[loanId]) {
            return _fail(ACTION_LOAN_NOT_FOUND, "loan not found");
        }
        if (loan.borrowerPositionKey != LibPositionHelpers.positionKey(positionId)) {
            return _fail(ACTION_POSITION_MISMATCH, "position mismatch");
        }
        return _ok();
    }

    function canExtend(uint256 positionId, uint256 loanId, uint40 addedDuration)
        external
        view
        returns (ActionCheck memory)
    {
        LibEdenLendingStorage.LendingStorage storage lending = LibEdenLendingStorage.s();
        LibEdenLendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrowerPositionKey == bytes32(0) || lending.loanClosed[loanId]) {
            return _fail(ACTION_LOAN_NOT_FOUND, "loan not found");
        }
        if (loan.borrowerPositionKey != LibPositionHelpers.positionKey(positionId)) {
            return _fail(ACTION_POSITION_MISMATCH, "position mismatch");
        }
        if (block.timestamp > loan.maturity) {
            return _fail(ACTION_LOAN_EXPIRED, "loan expired");
        }

        LibEdenLendingStorage.LendingConfig memory config = lending.lendingConfigs[loan.basketId];
        if (addedDuration == 0 || config.maxDuration == 0) {
            return _fail(ACTION_INVALID_DURATION, "invalid duration");
        }

        uint256 extendedMaturity = uint256(loan.maturity) + addedDuration;
        if (extendedMaturity > block.timestamp + config.maxDuration) {
            return _fail(ACTION_INVALID_DURATION, "invalid duration");
        }

        return _ok();
    }

    function canClaimRewards(uint256 positionId) external view returns (ActionCheck memory) {
        LibEdenRewardStorage.RewardStorage storage rewards = LibEdenRewardStorage.s();
        if (!rewards.config.enabled || rewards.config.rewardToken == address(0)) {
            return _fail(ACTION_REWARDS_DISABLED, "rewards disabled");
        }
        if (LibEdenRewards.previewPositionRewards(LibPositionHelpers.positionKey(positionId)) == 0) {
            return _fail(ACTION_NOTHING_CLAIMABLE, "nothing claimable");
        }
        return _ok();
    }

    function _positionBaskets(bytes32 positionKey) internal view returns (PositionBasketView[] memory baskets) {
        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        if (!store.productInitialized) {
            return new PositionBasketView[](0);
        }

        LibEdenBasketStorage.ProductConfig storage basket = store.product;
        uint256 principal = LibAppStorage.s().pools[basket.poolId].userPrincipal[positionKey];
        uint256 encumbered = LibEncumbrance.total(positionKey, basket.poolId);
        if (principal == 0 && encumbered == 0) {
            return new PositionBasketView[](0);
        }

        baskets = new PositionBasketView[](1);
        baskets[0] = PositionBasketView({
            basketId: LibEdenBasketStorage.PRODUCT_ID,
            poolId: basket.poolId,
            token: basket.token,
            basketType: store.productMetadata.productType,
            units: principal,
            encumberedUnits: encumbered,
            availableUnits: principal > encumbered ? principal - encumbered : 0,
            paused: basket.paused
        });
    }

    function _hasBorrowFeeTier(LibEdenLendingStorage.BorrowFeeTier[] storage tiers, uint256 collateralUnits)
        internal
        view
        returns (bool found)
    {
        uint256 len = tiers.length;
        for (uint256 i = 0; i < len; i++) {
            if (collateralUnits >= tiers[i].minCollateralUnits) {
                found = true;
            } else {
                break;
            }
        }
    }

    function _ok() internal pure returns (ActionCheck memory check) {
        check.ok = true;
        check.code = ACTION_OK;
        check.reason = "ok";
    }

    function _fail(uint8 code, string memory reason) internal pure returns (ActionCheck memory check) {
        check.ok = false;
        check.code = code;
        check.reason = reason;
    }

    function _boolString(bool value) internal pure returns (string memory) {
        return value ? "true" : "false";
    }

    function _isKnownBasketId(uint256 basketId) internal view returns (bool) {
        LibEdenBasketStorage.EdenProductStorage storage store = LibEdenBasketStorage.s();
        return store.productInitialized && basketId == LibEdenBasketStorage.PRODUCT_ID;
    }
}
