// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {StEVEProductBase} from "./StEVEProductBase.sol";
import {StEVELendingLogic} from "./StEVELendingLogic.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {BasketToken} from "../tokens/BasketToken.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";
import {IERC8004IdentityRegistry} from "@agent-wallet-core/adapters/ERC8004IdentityAdapter.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibStEVEAdminStorage} from "../libraries/LibStEVEAdminStorage.sol";
import {LibStEVEStorage} from "../libraries/LibStEVEStorage.sol";
import {LibStEVELendingStorage} from "../libraries/LibStEVELendingStorage.sol";
import {LibEdenRewardsEngine} from "../libraries/LibEdenRewardsEngine.sol";
import {LibEdenRewardsStorage} from "../libraries/LibEdenRewardsStorage.sol";
import {LibStEVEEligibilityStorage} from "../libraries/LibStEVEEligibilityStorage.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

contract StEVEViewFacet is StEVELendingLogic {
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

    struct ProductConfigView {
        uint256 productId;
        address treasury;
        address timelock;
        uint256 timelockDelaySeconds;
        uint16 poolFeeShareBps;
        string protocolURI;
        string contractVersion;
        bool productInitialized;
        string name;
        string symbol;
        string uri;
        address token;
        address creator;
        uint64 createdAt;
        uint8 productType;
        bool paused;
        address[] assets;
        uint256[] bundleAmounts;
        uint256 poolId;
        uint256 totalUnits;
        bool steveConfigured;
        uint256 rewardProgramCount;
        uint256 activeRewardProgramCount;
    }

    struct ProductFeeConfigView {
        uint16 poolFeeShareBps;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
    }

    struct ProductRewardStateView {
        bool steveConfigured;
        uint256 eligibleSupply;
        uint256 rewardProgramCount;
        uint256 activeRewardProgramCount;
        uint256 totalRewardReserve;
        bool onlyPnftHeldStEVEEligible;
        bool walletHeldStEVERewardEligible;
        bool rewardsAccrueToPosition;
        bool rewardsConfigured;
    }

    struct PositionProductView {
        bool active;
        uint256 productId;
        uint256 poolId;
        address token;
        uint8 productType;
        uint256 units;
        uint256 encumberedUnits;
        uint256 availableUnits;
        bool paused;
        bool rewardEligible;
    }

    struct PositionRewardView {
        uint256 eligiblePrincipal;
        uint256 claimableRewards;
        uint256 rewardProgramCount;
        uint256 claimableProgramCount;
        bool rewardsAccrueToPosition;
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
        PositionProductView product;
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

    function getProductConfig() external view returns (ProductConfigView memory view_) {
        LibAppStorage.AppStorage storage app = LibAppStorage.s();
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        LibStEVEStorage.ProductConfig storage product = store.product;
        LibStEVEStorage.ProductMetadata storage metadata = store.productMetadata;
        LibStEVEEligibilityStorage.EligibilityStorage storage steve = LibStEVEEligibilityStorage.s();
        (uint256 rewardProgramCount, uint256 activeRewardProgramCount,) = _rewardProgramSummary();

        view_.productId = LibStEVEStorage.PRODUCT_ID;
        view_.treasury = LibAppStorage.treasuryAddress(app);
        view_.timelock = LibAppStorage.timelockAddress(app);
        view_.timelockDelaySeconds = LibStEVEAdminStorage.TIMELOCK_DELAY_SECONDS;
        view_.productInitialized = store.productInitialized;
        view_.poolFeeShareBps = _basketPoolFeeShareBps();
        view_.protocolURI = LibStEVEAdminStorage.s().protocolURI;
        view_.contractVersion = LibStEVEAdminStorage.s().contractVersion;
        view_.name = metadata.name;
        view_.symbol = metadata.symbol;
        view_.uri = metadata.uri;
        view_.token = product.token;
        view_.creator = metadata.creator;
        view_.createdAt = metadata.createdAt;
        view_.productType = metadata.productType;
        view_.paused = product.paused;
        view_.assets = product.assets;
        view_.bundleAmounts = product.bundleAmounts;
        view_.poolId = product.poolId;
        view_.totalUnits = product.totalUnits;
        view_.steveConfigured = steve.configured;
        view_.rewardProgramCount = rewardProgramCount;
        view_.activeRewardProgramCount = activeRewardProgramCount;
    }

    function getProductPoolId() external view returns (uint256) {
        return LibStEVEStorage.s().product.poolId;
    }

    function getProductFeeConfig() external view returns (ProductFeeConfigView memory view_) {
        LibStEVEStorage.ProductConfig storage product = LibStEVEStorage.s().product;
        view_.poolFeeShareBps = _basketPoolFeeShareBps();
        view_.mintFeeBps = product.mintFeeBps;
        view_.burnFeeBps = product.burnFeeBps;
        view_.flashFeeBps = product.flashFeeBps;
    }

    function getProductRewardState() external view returns (ProductRewardStateView memory view_) {
        LibStEVEEligibilityStorage.EligibilityStorage storage steve = LibStEVEEligibilityStorage.s();
        (uint256 rewardProgramCount, uint256 activeRewardProgramCount, uint256 totalRewardReserve) =
            _rewardProgramSummary();

        view_.steveConfigured = steve.configured;
        view_.eligibleSupply = steve.eligibleSupply;
        view_.rewardProgramCount = rewardProgramCount;
        view_.activeRewardProgramCount = activeRewardProgramCount;
        view_.totalRewardReserve = totalRewardReserve;
        view_.onlyPnftHeldStEVEEligible = true;
        view_.walletHeldStEVERewardEligible = false;
        view_.rewardsAccrueToPosition = true;
        view_.rewardsConfigured = rewardProgramCount != 0;
    }

    function getProductVaultBalance(address asset) external view returns (uint256) {
        return LibStEVEStorage.s().accounting.vaultBalances[asset];
    }

    function getProductFeePot(address asset) external view returns (uint256) {
        return LibStEVEStorage.s().accounting.feePots[asset];
    }

    function getPositionTokenURI(uint256 positionId) external view returns (string memory) {
        PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
        PositionAgentWalletView memory agent = _positionAgentWallet(positionId);
        return string.concat(
            "equalfi://positions/", Strings.toString(positionId), _positionQueryString(nft, positionId, agent)
        );
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

    function getPositionProductView(uint256 positionId) public view returns (PositionProductView memory product) {
        return _positionProduct(LibPositionHelpers.positionKey(positionId));
    }

    function getPositionRewardView(uint256 positionId) public view returns (PositionRewardView memory rewards_) {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        uint256 eligiblePrincipal = LibStEVEEligibilityStorage.s().eligiblePrincipal[positionKey];
        (uint256 claimableRewards, uint256 rewardProgramCount, uint256 claimableProgramCount) =
            _positionRewardSummary(positionKey, eligiblePrincipal);
        rewards_ = PositionRewardView({
            eligiblePrincipal: eligiblePrincipal,
            claimableRewards: claimableRewards,
            rewardProgramCount: rewardProgramCount,
            claimableProgramCount: claimableProgramCount,
            rewardsAccrueToPosition: true
        });
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
        portfolio.product = _positionProduct(positionKey);
        portfolio.rewards = getPositionRewardView(positionId);
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
        agent.canonicalLink =
            wallet.positionRegistrationMode[positionId] == LibPositionAgentStorage.AgentRegistrationMode.CanonicalOwned;
        agent.externalLink =
            wallet.positionRegistrationMode[positionId] == LibPositionAgentStorage.AgentRegistrationMode.ExternalLinked;
        agent.externalAuthorizer = wallet.externalAgentAuthorizer[positionId];

        if (
            wallet.erc6551Registry == address(0) || wallet.erc6551Implementation == address(0)
                || wallet.erc6551Registry.code.length == 0
        ) {
            return agent;
        }

        agent.tbaAddress = IERC6551Registry(wallet.erc6551Registry)
            .account(
                wallet.erc6551Implementation,
                wallet.tbaSalt,
                block.chainid,
                LibPositionNFT.s().positionNFTContract,
                positionId
            );
        agent.tbaDeployed = agent.tbaAddress.code.length > 0;

        if (!agent.agentRegistered || wallet.identityRegistry == address(0) || wallet.identityRegistry.code.length == 0)
        {
            return agent;
        }

        (bool ok, bytes memory data) = wallet.identityRegistry
            .staticcall(abi.encodeWithSelector(IERC8004IdentityRegistry.ownerOf.selector, agent.agentId));
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

    function canMintStEVE(uint256 units) external view returns (ActionCheck memory) {
        if (!LibStEVEStorage.s().productInitialized) {
            return _fail(ACTION_UNKNOWN_BASKET, "product not configured");
        }
        if (units == 0 || units % UNIT_SCALE != 0) {
            return _fail(ACTION_INVALID_UNITS, "invalid units");
        }
        if (LibStEVEStorage.s().product.paused) {
            return _fail(ACTION_BASKET_PAUSED, "product paused");
        }
        return _ok();
    }

    function canBurnStEVE(address owner, uint256 units) external view returns (ActionCheck memory) {
        if (!LibStEVEStorage.s().productInitialized) {
            return _fail(ACTION_UNKNOWN_BASKET, "product not configured");
        }
        if (units == 0 || units % UNIT_SCALE != 0) {
            return _fail(ACTION_INVALID_UNITS, "invalid units");
        }
        LibStEVEStorage.ProductConfig storage basket = LibStEVEStorage.s().product;
        if (basket.paused) {
            return _fail(ACTION_BASKET_PAUSED, "product paused");
        }
        if (BasketToken(basket.token).balanceOf(owner) < units) {
            return _fail(ACTION_INSUFFICIENT_BALANCE, "insufficient stEVE balance");
        }
        return _ok();
    }

    function canBorrow(uint256 positionId, uint256 collateralUnits, uint40 duration)
        external
        view
        returns (ActionCheck memory)
    {
        if (!LibStEVEStorage.s().productInitialized) {
            return _fail(ACTION_UNKNOWN_BASKET, "product not configured");
        }
        if (collateralUnits == 0 || collateralUnits % UNIT_SCALE != 0) {
            return _fail(ACTION_INVALID_UNITS, "invalid collateral units");
        }

        LibStEVEStorage.ProductConfig storage basket = LibStEVEStorage.s().product;
        if (basket.paused) {
            return _fail(ACTION_BASKET_PAUSED, "product paused");
        }

        LibStEVELendingStorage.LendingStorage storage lending = LibStEVELendingStorage.s();
        LibStEVELendingStorage.LendingConfig memory config = lending.lendingConfig;
        if (duration == 0 || config.minDuration == 0 || duration < config.minDuration || duration > config.maxDuration)
        {
            return _fail(ACTION_INVALID_DURATION, "invalid duration");
        }

        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        uint256 availableCollateral = _availableCollateral(positionKey, basket.poolId);
        if (collateralUnits > availableCollateral) {
            return _fail(ACTION_INSUFFICIENT_COLLATERAL, "insufficient available collateral");
        }

        if (!_hasBorrowFeeTier(lending.borrowFeeTiers, collateralUnits)) {
            return _fail(ACTION_BELOW_MINIMUM_TIER, "below minimum fee tier");
        }

        (address[] memory assets, uint256[] memory principals) =
            _deriveLoanPrincipals(basket, collateralUnits, LibStEVELendingStorage.DEFAULT_LTV_BPS);
        uint256 newLockedCollateral = lending.lockedCollateralUnits + collateralUnits;
        if (!_redeemabilityInvariantSatisfied(basket, assets, principals, newLockedCollateral, basket.totalUnits)) {
            return _fail(ACTION_INSUFFICIENT_BALANCE, "product vault invariant would fail");
        }

        return _ok();
    }

    function canRepay(uint256 positionId, uint256 loanId) external view returns (ActionCheck memory) {
        LibStEVELendingStorage.LendingStorage storage lending = LibStEVELendingStorage.s();
        LibStEVELendingStorage.Loan storage loan = lending.loans[loanId];
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
        LibStEVELendingStorage.LendingStorage storage lending = LibStEVELendingStorage.s();
        LibStEVELendingStorage.Loan storage loan = lending.loans[loanId];
        if (loan.borrowerPositionKey == bytes32(0) || lending.loanClosed[loanId]) {
            return _fail(ACTION_LOAN_NOT_FOUND, "loan not found");
        }
        if (loan.borrowerPositionKey != LibPositionHelpers.positionKey(positionId)) {
            return _fail(ACTION_POSITION_MISMATCH, "position mismatch");
        }
        if (block.timestamp > loan.maturity) {
            return _fail(ACTION_LOAN_EXPIRED, "loan expired");
        }

        LibStEVELendingStorage.LendingConfig memory config = lending.lendingConfig;
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
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        uint256 eligiblePrincipal = LibStEVEEligibilityStorage.s().eligiblePrincipal[positionKey];
        (uint256 claimableRewards, uint256 rewardProgramCount,) = _positionRewardSummary(positionKey, eligiblePrincipal);
        if (claimableRewards != 0) {
            return _ok();
        }
        (, uint256 activeRewardProgramCount,) = _rewardProgramSummary();
        if (rewardProgramCount == 0 || activeRewardProgramCount == 0) {
            return _fail(ACTION_REWARDS_DISABLED, "rewards disabled");
        }
        return _fail(ACTION_NOTHING_CLAIMABLE, "nothing claimable");
    }

    function _positionProduct(bytes32 positionKey) internal view returns (PositionProductView memory product) {
        LibStEVEStorage.ProductStorage storage store = LibStEVEStorage.s();
        if (!store.productInitialized) {
            return product;
        }

        LibStEVEStorage.ProductConfig storage basket = store.product;
        uint256 principal = LibAppStorage.s().pools[basket.poolId].userPrincipal[positionKey];
        uint256 encumbered = LibEncumbrance.total(positionKey, basket.poolId);
        if (principal == 0 && encumbered == 0) {
            return product;
        }

        product = PositionProductView({
            active: true,
            productId: LibStEVEStorage.PRODUCT_ID,
            poolId: basket.poolId,
            token: basket.token,
            productType: store.productMetadata.productType,
            units: principal,
            encumberedUnits: encumbered,
            availableUnits: principal > encumbered ? principal - encumbered : 0,
            paused: basket.paused,
            rewardEligible: LibStEVEEligibilityStorage.s().eligiblePrincipal[positionKey] != 0
        });
    }

    function _hasBorrowFeeTier(LibStEVELendingStorage.BorrowFeeTier[] storage tiers, uint256 collateralUnits)
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

    function _rewardProgramSummary()
        internal
        view
        returns (uint256 rewardProgramCount, uint256 activeRewardProgramCount, uint256 totalRewardReserve)
    {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        uint256[] storage programIds = LibEdenRewardsStorage.programIdsForTarget(
            store, LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, LibEdenRewardsStorage.STEVE_TARGET_ID
        );
        rewardProgramCount = programIds.length;

        for (uint256 i = 0; i < rewardProgramCount; i++) {
            uint256 programId = programIds[i];
            LibEdenRewardsStorage.RewardProgramConfig storage config = store.programs[programId].config;
            if (_isProgramActive(config)) {
                activeRewardProgramCount++;
            }
            totalRewardReserve += LibEdenRewardsEngine.previewProgramState(programId).fundedReserve;
        }
    }

    function _positionRewardSummary(bytes32 positionKey, uint256 eligiblePrincipal)
        internal
        view
        returns (uint256 claimableRewards, uint256 rewardProgramCount, uint256 claimableProgramCount)
    {
        LibEdenRewardsStorage.RewardsStorage storage store = LibEdenRewardsStorage.s();
        uint256[] storage programIds = LibEdenRewardsStorage.programIdsForTarget(
            store, LibEdenRewardsStorage.RewardTargetType.STEVE_POSITION, LibEdenRewardsStorage.STEVE_TARGET_ID
        );
        rewardProgramCount = programIds.length;

        for (uint256 i = 0; i < rewardProgramCount; i++) {
            uint256 claimable = _previewProgramClaimable(store, programIds[i], positionKey, eligiblePrincipal);
            if (claimable == 0) {
                continue;
            }

            claimableRewards += claimable;
            claimableProgramCount++;
        }
    }

    function _previewProgramClaimable(
        LibEdenRewardsStorage.RewardsStorage storage store,
        uint256 programId,
        bytes32 positionKey,
        uint256 eligiblePrincipal
    ) internal view returns (uint256 claimable) {
        LibEdenRewardsStorage.RewardProgramState memory previewState = LibEdenRewardsEngine.previewProgramState(programId);
        uint256 checkpoint = store.positionRewardIndex[programId][positionKey];
        claimable = store.accruedRewards[programId][positionKey];

        if (previewState.globalRewardIndex <= checkpoint || eligiblePrincipal == 0) {
            return claimable;
        }

        claimable += Math.mulDiv(
            eligiblePrincipal,
            previewState.globalRewardIndex - checkpoint,
            LibEdenRewardsStorage.REWARD_INDEX_SCALE
        );
    }

    function _isProgramActive(LibEdenRewardsStorage.RewardProgramConfig storage config) internal view returns (bool) {
        if (config.closed || !config.enabled || config.paused || config.rewardRatePerSecond == 0) {
            return false;
        }

        if (config.endTime != 0 && config.endTime <= block.timestamp) {
            return false;
        }

        return true;
    }

}
