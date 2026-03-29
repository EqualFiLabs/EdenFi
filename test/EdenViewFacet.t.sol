// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenViewFacetTest is EdenLaunchFixture {
    uint8 internal constant ACTION_INVALID_UNITS = 3;
    uint8 internal constant ACTION_INSUFFICIENT_BALANCE = 4;
    uint8 internal constant ACTION_NOTHING_CLAIMABLE = 8;
    uint8 internal constant ACTION_REWARDS_DISABLED = 12;

    uint256 internal alicePositionId;
    uint256 internal bobPositionId;
    uint256 internal constant REGISTRATION_MODE_EXTERNAL_LINKED = 2;
    uint256 internal externalOwnerPk = uint256(0xA71CE);
    address internal externalOwner;

    function setUp() public override {
        super.setUp();
        _bootstrapCorePools();
        (steveBasketId, steveToken) = _createStEVE(_stEveParams(address(eve)));
        _configureRewards(address(eve), 10e18, true);

        externalOwner = vm.addr(externalOwnerPk);

        eve.mint(alice, 200e18);
        eve.mint(address(this), 500e18);

        alicePositionId = _mintPosition(alice, 1);
        bobPositionId = _mintPosition(bob, 1);

        _mintWalletBasket(alice, steveBasketId, eve, 20e18);
        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);

        eve.approve(diamond, 500e18);
        EdenRewardFacet(diamond).fundRewards(500e18, 500e18);
        vm.warp(block.timestamp + 10);
    }

    function test_ProductReads_ExposeSingletonState() public view {
        EdenViewFacet.ProductConfigView memory config = EdenViewFacet(diamond).getProductConfig();
        assertEq(config.productId, steveBasketId);
        assertEq(config.name, "stEVE");
        assertEq(config.symbol, "stEVE");
        assertEq(config.uri, "ipfs://steve");
        assertEq(config.token, steveToken);
        assertEq(config.assets.length, 1);
        assertEq(config.assets[0], address(eve));
        assertEq(config.bundleAmounts.length, 1);
        assertEq(config.bundleAmounts[0], 1e18);
        assertEq(config.poolId, EdenViewFacet(diamond).getProductPoolId());
        assertEq(config.totalUnits, 20e18);
        assertTrue(config.productInitialized);
        assertTrue(config.steveConfigured);
        assertEq(config.steveBasketId, steveBasketId);
        assertEq(config.rewardToken, address(eve));
        assertTrue(config.rewardsEnabled);

        EdenViewFacet.ProductFeeConfigView memory fees = EdenViewFacet(diamond).getProductFeeConfig();
        assertEq(fees.poolFeeShareBps, 1000);
        assertEq(fees.mintFeeBps.length, 1);
        assertEq(fees.mintFeeBps[0], 0);
        assertEq(fees.burnFeeBps.length, 1);
        assertEq(fees.burnFeeBps[0], 0);
        assertEq(fees.flashFeeBps, 50);

        EdenViewFacet.ProductRewardStateView memory rewards = EdenViewFacet(diamond).getProductRewardState();
        assertTrue(rewards.steveConfigured);
        assertEq(rewards.steveBasketId, steveBasketId);
        assertEq(rewards.eligibleSupply, 10e18);
        assertEq(rewards.rewardToken, address(eve));
        assertEq(rewards.rewardRatePerSecond, 10e18);
        assertTrue(rewards.rewardsEnabled);

        assertEq(EdenViewFacet(diamond).getProductVaultBalance(address(eve)), 20e18);
        assertEq(EdenViewFacet(diamond).getProductFeePot(address(eve)), 0);
    }

    function test_PositionReads_ExposeSingletonProductAndRewardState() public view {
        uint256[] memory alicePositionIds = EdenViewFacet(diamond).getUserPositionIds(alice);
        assertEq(alicePositionIds.length, 1);
        assertEq(alicePositionIds[0], alicePositionId);

        EdenViewFacet.PositionProductView memory product =
            EdenViewFacet(diamond).getPositionProductView(alicePositionId);
        assertTrue(product.active);
        assertEq(product.productId, steveBasketId);
        assertEq(product.poolId, EdenViewFacet(diamond).getProductPoolId());
        assertEq(product.token, steveToken);
        assertEq(product.units, 10e18);
        assertEq(product.availableUnits, 10e18);
        assertTrue(product.rewardEligible);

        EdenViewFacet.PositionRewardView memory rewards = EdenViewFacet(diamond).getPositionRewardView(alicePositionId);
        assertEq(rewards.eligiblePrincipal, 10e18);
        assertEq(rewards.accruedRewards, 0);
        assertGt(rewards.claimableRewards, 0);

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(alicePositionId);
        assertEq(portfolio.positionId, alicePositionId);
        assertEq(portfolio.owner, alice);
        assertEq(portfolio.homePoolId, 1);
        assertEq(portfolio.product.units, 10e18);
        assertEq(portfolio.rewards.eligiblePrincipal, 10e18);
        assertEq(portfolio.loans.length, 0);

        EdenViewFacet.PositionPortfolio memory emptyPortfolio =
            EdenViewFacet(diamond).getPositionPortfolio(bobPositionId);
        assertTrue(!emptyPortfolio.product.active);
        assertEq(emptyPortfolio.rewards.eligiblePrincipal, 0);

        EdenViewFacet.UserPortfolio memory userPortfolio = EdenViewFacet(diamond).getUserPortfolio(alice);
        assertEq(userPortfolio.positionIds.length, 1);
        assertEq(userPortfolio.positions.length, 1);
        assertEq(userPortfolio.positions[0].product.units, 10e18);
    }

    function test_PositionAgentReads_ExposeTBAAndCanonicalLinkStatus() public {
        address predicted = PositionAgentTBAFacet(diamond).computeTBAAddress(alicePositionId);

        EdenViewFacet.PositionAgentWalletView memory beforeDeploy =
            EdenViewFacet(diamond).getPositionAgentView(alicePositionId);
        assertEq(beforeDeploy.tbaAddress, predicted);
        assertTrue(!beforeDeploy.tbaDeployed);
        assertEq(beforeDeploy.agentId, 0);
        assertTrue(!beforeDeploy.agentRegistered);
        assertEq(beforeDeploy.registrationMode, 0);
        assertTrue(!beforeDeploy.canonicalLink);
        assertTrue(!beforeDeploy.externalLink);
        assertTrue(!beforeDeploy.linkActive);
        assertEq(beforeDeploy.externalAuthorizer, address(0));
        assertTrue(!beforeDeploy.registrationComplete);

        vm.prank(alice);
        address deployed = PositionAgentTBAFacet(diamond).deployTBA(alicePositionId);
        assertEq(deployed, predicted);
        assertTrue(!PositionAgentViewFacet(diamond).isRegistrationComplete(alicePositionId));

        uint256 agentId = 77;
        identityRegistry.setOwner(agentId, deployed);
        vm.prank(alice);
        PositionAgentRegistryFacet(diamond).recordAgentRegistration(alicePositionId, agentId);

        EdenViewFacet.PositionAgentWalletView memory walletView =
            EdenViewFacet(diamond).getPositionAgentView(alicePositionId);
        assertEq(walletView.tbaAddress, deployed);
        assertTrue(walletView.tbaDeployed);
        assertEq(walletView.agentId, agentId);
        assertTrue(walletView.agentRegistered);
        assertEq(walletView.registrationMode, 1);
        assertTrue(walletView.canonicalLink);
        assertTrue(!walletView.externalLink);
        assertTrue(walletView.linkActive);
        assertEq(walletView.externalAuthorizer, address(0));
        assertTrue(walletView.registrationComplete);
        assertTrue(PositionAgentViewFacet(diamond).isCanonicalAgentLink(alicePositionId));
        assertTrue(PositionAgentViewFacet(diamond).isRegistrationComplete(alicePositionId));
    }

    function test_PositionAgentReads_ExposeExternalLinkModeAndActivity() public {
        vm.prank(alice);
        address deployed = PositionAgentTBAFacet(diamond).deployTBA(alicePositionId);

        uint256 agentId = 88;
        uint256 deadline = block.timestamp + 1 days;
        identityRegistry.setOwner(agentId, externalOwner);

        bytes32 digest = keccak256(
            abi.encode(
                keccak256(
                    "EqualFiExternalAgentLink(uint256 chainId,address diamond,uint256 positionTokenId,uint256 agentId,address positionOwner,address tbaAddress,uint256 nonce,uint256 deadline)"
                ),
                block.chainid,
                diamond,
                alicePositionId,
                agentId,
                alice,
                deployed,
                0,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(externalOwnerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(alice);
        PositionAgentRegistryFacet(diamond).linkExternalAgentRegistration(alicePositionId, agentId, deadline, signature);

        EdenViewFacet.PositionAgentWalletView memory walletView =
            EdenViewFacet(diamond).getPositionAgentView(alicePositionId);
        assertEq(walletView.registrationMode, REGISTRATION_MODE_EXTERNAL_LINKED);
        assertTrue(!walletView.canonicalLink);
        assertTrue(walletView.externalLink);
        assertTrue(walletView.linkActive);
        assertEq(walletView.externalAuthorizer, externalOwner);
        assertTrue(walletView.registrationComplete);

        identityRegistry.setOwner(agentId, bob);

        walletView = EdenViewFacet(diamond).getPositionAgentView(alicePositionId);
        assertEq(walletView.registrationMode, REGISTRATION_MODE_EXTERNAL_LINKED);
        assertTrue(walletView.externalLink);
        assertTrue(!walletView.linkActive);
        assertTrue(!walletView.registrationComplete);
    }

    function test_ActionChecks_UseExplicitStEVESurface() public {
        EdenViewFacet.ActionCheck memory mintCheck = EdenViewFacet(diamond).canMintStEVE(10e18);
        assertTrue(mintCheck.ok);

        EdenViewFacet.ActionCheck memory invalidMint = EdenViewFacet(diamond).canMintStEVE(0);
        assertTrue(!invalidMint.ok);
        assertEq(invalidMint.code, ACTION_INVALID_UNITS);

        EdenViewFacet.ActionCheck memory burnCheck = EdenViewFacet(diamond).canBurnStEVE(alice, 10e18);
        assertTrue(burnCheck.ok);

        EdenViewFacet.ActionCheck memory invalidBurn = EdenViewFacet(diamond).canBurnStEVE(alice, 5);
        assertTrue(!invalidBurn.ok);
        assertEq(invalidBurn.code, ACTION_INVALID_UNITS);

        EdenViewFacet.ActionCheck memory insufficientBurn = EdenViewFacet(diamond).canBurnStEVE(alice, 100e18);
        assertTrue(!insufficientBurn.ok);
        assertEq(insufficientBurn.code, ACTION_INSUFFICIENT_BALANCE);

        EdenViewFacet.ActionCheck memory claimCheck = EdenViewFacet(diamond).canClaimRewards(alicePositionId);
        assertTrue(claimCheck.ok);

        EdenViewFacet.ActionCheck memory emptyClaimCheck = EdenViewFacet(diamond).canClaimRewards(bobPositionId);
        assertTrue(!emptyClaimCheck.ok);
        assertEq(emptyClaimCheck.code, ACTION_NOTHING_CLAIMABLE);

        _configureRewards(address(eve), 0, false);
        EdenViewFacet.ActionCheck memory disabledRewards = EdenViewFacet(diamond).canClaimRewards(alicePositionId);
        assertTrue(!disabledRewards.ok);
        assertEq(disabledRewards.code, ACTION_REWARDS_DISABLED);
    }

    function test_ReadSurfaces_HandlePaginationAndStableHooks() public view {
        uint256[] memory pagedPositions = EdenViewFacet(diamond).getUserPositionIdsPaginated(alice, 1, 1);
        assertEq(pagedPositions.length, 0);

        pagedPositions = EdenViewFacet(diamond).getUserPositionIdsPaginated(alice, 0, 0);
        assertEq(pagedPositions.length, 0);

        bytes32 positionKey = positionNft.getPositionKey(alicePositionId);
        string memory tokenUri = positionNft.tokenURI(alicePositionId);
        address predicted = PositionAgentTBAFacet(diamond).computeTBAAddress(alicePositionId);
        assertEq(
            tokenUri,
            string.concat(
                "equalfi://positions/",
                Strings.toString(alicePositionId),
                "?poolId=1&tba=",
                Strings.toHexString(uint160(predicted), 20),
                "&tbaDeployed=false&agentId=0&agentMode=0&agentCanonical=false&agentExternal=false&agentActive=false&agentComplete=false"
            )
        );
        assertTrue(!EdenViewFacet(diamond).hasOpenOffers(positionKey));

        EdenViewFacet(diamond).cancelOffersForPosition(positionKey);
    }

    function test_ExplicitProductRewardViewsStayReadableWhenRewardsDisabled() public {
        _configureRewards(address(eve), 0, false);

        EdenViewFacet.ProductRewardStateView memory productRewards = EdenViewFacet(diamond).getProductRewardState();
        assertTrue(!productRewards.rewardsEnabled);

        EdenViewFacet.PositionRewardView memory positionRewards =
            EdenViewFacet(diamond).getPositionRewardView(bobPositionId);
        assertEq(positionRewards.eligiblePrincipal, 0);
        assertEq(positionRewards.claimableRewards, 0);
        assertEq(positionRewards.rewardCheckpoint, 0);
    }
}
