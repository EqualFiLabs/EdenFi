// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {EdenBasketPositionFacet} from "src/eden/EdenBasketPositionFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {PositionAgentRegistryFacet} from "src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol";
import {PositionAgentTBAFacet} from "src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentViewFacet} from "src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {UnknownIndex} from "src/libraries/Errors.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";

contract EdenViewFacetTest is EdenLaunchFixture {
    uint8 internal constant ACTION_UNKNOWN_BASKET = 1;
    uint8 internal constant ACTION_INVALID_UNITS = 3;
    uint8 internal constant ACTION_INSUFFICIENT_BALANCE = 4;
    uint8 internal constant ACTION_POSITION_MISMATCH = 5;
    uint8 internal constant ACTION_LOAN_NOT_FOUND = 6;
    uint8 internal constant ACTION_LOAN_EXPIRED = 7;
    uint8 internal constant ACTION_NOTHING_CLAIMABLE = 8;
    uint8 internal constant ACTION_INVALID_DURATION = 9;
    uint8 internal constant ACTION_INSUFFICIENT_COLLATERAL = 10;
    uint8 internal constant ACTION_BELOW_MINIMUM_TIER = 11;
    uint8 internal constant ACTION_REWARDS_DISABLED = 12;

    uint256 internal alicePositionId;
    uint256 internal aliceAltPositionId;
    uint256 internal bobPositionId;
    uint256 internal constant REGISTRATION_MODE_EXTERNAL_LINKED = 2;
    uint256 internal externalOwnerPk = uint256(0xA71CE);
    address internal externalOwner;

    function setUp() public override {
        super.setUp();
        _bootstrapEdenProduct();
        externalOwner = vm.addr(externalOwnerPk);

        eve.mint(alice, 200e18);
        alt.mint(alice, 200e18);
        eve.mint(address(this), 500e18);

        alicePositionId = _mintPosition(alice, 1);
        aliceAltPositionId = _mintPosition(alice, 2);
        bobPositionId = _mintPosition(bob, 1);

        _mintWalletBasket(alice, steveBasketId, eve, 20e18);
        _mintWalletBasket(alice, altBasketId, alt, 10e18);
        _depositWalletStEVEToPosition(alice, alicePositionId, 10e18);

        vm.startPrank(alice);
        alt.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(aliceAltPositionId, 2, 100e18, 100e18);
        EdenBasketPositionFacet(diamond).mintBasketFromPosition(aliceAltPositionId, altBasketId, 40e18);
        vm.stopPrank();

        eve.approve(diamond, 500e18);
        EdenRewardFacet(diamond).fundRewards(500e18, 500e18);
        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        EdenLendingFacet(diamond).borrow(aliceAltPositionId, altBasketId, 15e18, 7 days);
    }

    function test_MetadataAndProductConfigReads() public view {
        assertEq(EdenViewFacet(diamond).basketCount(), 2);

        uint256[] memory basketIds = EdenViewFacet(diamond).getBasketIds(0, 10);
        assertEq(basketIds.length, 2);
        assertEq(basketIds[0], steveBasketId);
        assertEq(basketIds[1], altBasketId);

        EdenViewFacet.BasketSummary memory steveSummary = EdenViewFacet(diamond).getBasketSummary(steveBasketId);
        assertEq(steveSummary.name, "stEVE");
        assertTrue(steveSummary.isStEVE);

        EdenViewFacet.ProductConfigView memory config = EdenViewFacet(diamond).getProductConfig();
        assertEq(config.basketCount, 2);
        assertEq(config.steveBasketId, steveBasketId);
        assertEq(config.rewardToken, address(eve));
        assertTrue(config.rewardsEnabled);
    }

    function test_PositionAwarePortfolioReads() public view {
        uint256[] memory alicePositionIds = EdenViewFacet(diamond).getUserPositionIds(alice);
        assertEq(alicePositionIds.length, 2);
        assertEq(alicePositionIds[0], alicePositionId);
        assertEq(alicePositionIds[1], aliceAltPositionId);

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(alicePositionId);
        assertEq(portfolio.positionId, alicePositionId);
        assertEq(portfolio.owner, alice);
        assertEq(portfolio.agent.tbaAddress, PositionAgentViewFacet(diamond).getTBAAddress(alicePositionId));
        assertTrue(!portfolio.agent.tbaDeployed);
        assertEq(portfolio.agent.agentId, 0);
        assertEq(portfolio.agent.registrationMode, 0);
        assertEq(portfolio.agentRegistrationMode, 0);
        assertTrue(!portfolio.agent.canonicalLink);
        assertTrue(!portfolio.agent.externalLink);
        assertTrue(!portfolio.agent.linkActive);
        assertEq(portfolio.agent.externalAuthorizer, address(0));
        assertTrue(!portfolio.agent.registrationComplete);
        assertEq(portfolio.baskets.length, 1);
        assertEq(portfolio.loans.length, 0);
        assertEq(portfolio.rewards.eligiblePrincipal, 10e18);
        assertGt(portfolio.rewards.claimableRewards, 0);

        EdenViewFacet.PositionPortfolio memory altPortfolio =
            EdenViewFacet(diamond).getPositionPortfolio(aliceAltPositionId);
        assertEq(altPortfolio.baskets.length, 1);
        assertEq(altPortfolio.loans.length, 1);

        EdenViewFacet.UserPortfolio memory userPortfolio = EdenViewFacet(diamond).getUserPortfolio(alice);
        assertEq(userPortfolio.positionIds.length, 2);
        assertEq(userPortfolio.positions.length, 2);
        assertEq(userPortfolio.positions[1].loans.length, 1);
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

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(alicePositionId);
        assertEq(portfolio.agent.tbaAddress, deployed);
        assertEq(portfolio.agent.agentId, agentId);
        assertEq(portfolio.agentRegistrationMode, 1);
        assertTrue(portfolio.agent.canonicalLink);
        assertTrue(!portfolio.agent.externalLink);
        assertTrue(portfolio.agent.linkActive);
        assertTrue(portfolio.agent.registrationComplete);
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

        EdenViewFacet.PositionPortfolio memory portfolio = EdenViewFacet(diamond).getPositionPortfolio(alicePositionId);
        assertEq(portfolio.agentRegistrationMode, REGISTRATION_MODE_EXTERNAL_LINKED);
        assertTrue(portfolio.agent.externalLink);
        assertTrue(portfolio.agent.linkActive);
        assertEq(portfolio.agent.externalAuthorizer, externalOwner);
        assertTrue(PositionAgentViewFacet(diamond).isExternalAgentLink(alicePositionId));

        identityRegistry.setOwner(agentId, bob);

        walletView = EdenViewFacet(diamond).getPositionAgentView(alicePositionId);
        assertEq(walletView.registrationMode, REGISTRATION_MODE_EXTERNAL_LINKED);
        assertTrue(walletView.externalLink);
        assertTrue(!walletView.linkActive);
        assertTrue(!walletView.registrationComplete);
    }

    function test_ActionChecksReflectState() public {
        EdenViewFacet.ActionCheck memory mintCheck = EdenViewFacet(diamond).canMint(altBasketId, 10e18);
        assertTrue(mintCheck.ok);

        _setBasketPaused(altBasketId, true);
        EdenViewFacet.ActionCheck memory pausedMint = EdenViewFacet(diamond).canMint(altBasketId, 10e18);
        assertTrue(!pausedMint.ok);
        assertEq(pausedMint.code, 2);
        _setBasketPaused(altBasketId, false);

        EdenViewFacet.ActionCheck memory burnCheck = EdenViewFacet(diamond).canBurn(alice, altBasketId, 100e18);
        assertTrue(!burnCheck.ok);
        assertEq(burnCheck.code, 4);

        EdenViewFacet.ActionCheck memory borrowCheck =
            EdenViewFacet(diamond).canBorrow(aliceAltPositionId, altBasketId, 50e18, 7 days);
        assertTrue(!borrowCheck.ok);
        assertEq(borrowCheck.code, 10);

        EdenViewFacet.ActionCheck memory repayCheck = EdenViewFacet(diamond).canRepay(bobPositionId, 0);
        assertTrue(!repayCheck.ok);
        assertEq(repayCheck.code, 5);

        vm.warp(block.timestamp + 8 days);
        EdenViewFacet.ActionCheck memory extendCheck = EdenViewFacet(diamond).canExtend(aliceAltPositionId, 0, 1 days);
        assertTrue(!extendCheck.ok);
        assertEq(extendCheck.code, 7);

        EdenViewFacet.ActionCheck memory claimCheck = EdenViewFacet(diamond).canClaimRewards(alicePositionId);
        assertTrue(claimCheck.ok);
        EdenViewFacet.ActionCheck memory emptyClaimCheck = EdenViewFacet(diamond).canClaimRewards(bobPositionId);
        assertTrue(!emptyClaimCheck.ok);
    }

    function test_ActionChecks_CoverEveryFailureCode() public {
        EdenViewFacet.ActionCheck memory unknownMint = EdenViewFacet(diamond).canMint(99, 1e18);
        assertTrue(!unknownMint.ok);
        assertEq(unknownMint.code, ACTION_UNKNOWN_BASKET);

        EdenViewFacet.ActionCheck memory invalidMint = EdenViewFacet(diamond).canMint(altBasketId, 0);
        assertTrue(!invalidMint.ok);
        assertEq(invalidMint.code, ACTION_INVALID_UNITS);

        EdenViewFacet.ActionCheck memory invalidBurn = EdenViewFacet(diamond).canBurn(alice, altBasketId, 5);
        assertTrue(!invalidBurn.ok);
        assertEq(invalidBurn.code, ACTION_INVALID_UNITS);

        EdenViewFacet.ActionCheck memory insufficientBurn = EdenViewFacet(diamond).canBurn(alice, altBasketId, 100e18);
        assertTrue(!insufficientBurn.ok);
        assertEq(insufficientBurn.code, ACTION_INSUFFICIENT_BALANCE);

        EdenViewFacet.ActionCheck memory invalidDurationBorrow =
            EdenViewFacet(diamond).canBorrow(aliceAltPositionId, altBasketId, 10e18, 0);
        assertTrue(!invalidDurationBorrow.ok);
        assertEq(invalidDurationBorrow.code, ACTION_INVALID_DURATION);

        EdenViewFacet.ActionCheck memory insufficientCollateralBorrow =
            EdenViewFacet(diamond).canBorrow(aliceAltPositionId, altBasketId, 50e18, 7 days);
        assertTrue(!insufficientCollateralBorrow.ok);
        assertEq(insufficientCollateralBorrow.code, ACTION_INSUFFICIENT_COLLATERAL);

        uint256 tierPositionId = _mintPosition(alice, 2);
        alt.mint(alice, 20e18);
        vm.startPrank(alice);
        alt.approve(diamond, 200e18);
        PositionManagementFacet(diamond).depositToPosition(tierPositionId, 2, 120e18, 120e18);
        EdenBasketPositionFacet(diamond).mintBasketFromPosition(tierPositionId, altBasketId, 40e18);
        vm.stopPrank();

        uint256[] memory mins = new uint256[](1);
        mins[0] = 25e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        _configureBorrowFeeTiers(altBasketId, mins, fees);

        EdenViewFacet.ActionCheck memory belowTier =
            EdenViewFacet(diamond).canBorrow(tierPositionId, altBasketId, 10e18, 7 days);
        assertTrue(!belowTier.ok);
        assertEq(belowTier.code, ACTION_BELOW_MINIMUM_TIER);

        EdenViewFacet.ActionCheck memory positionMismatch = EdenViewFacet(diamond).canRepay(bobPositionId, 0);
        assertTrue(!positionMismatch.ok);
        assertEq(positionMismatch.code, ACTION_POSITION_MISMATCH);

        EdenViewFacet.ActionCheck memory missingLoan = EdenViewFacet(diamond).canRepay(aliceAltPositionId, 999);
        assertTrue(!missingLoan.ok);
        assertEq(missingLoan.code, ACTION_LOAN_NOT_FOUND);

        vm.warp(block.timestamp + 8 days);
        EdenViewFacet.ActionCheck memory expiredExtend = EdenViewFacet(diamond).canExtend(aliceAltPositionId, 0, 1 days);
        assertTrue(!expiredExtend.ok);
        assertEq(expiredExtend.code, ACTION_LOAN_EXPIRED);

        _configureRewards(address(eve), 0, false);
        EdenViewFacet.ActionCheck memory disabledRewards = EdenViewFacet(diamond).canClaimRewards(alicePositionId);
        assertTrue(!disabledRewards.ok);
        assertEq(disabledRewards.code, ACTION_REWARDS_DISABLED);

        _configureRewards(address(eve), 10e18, true);
        EdenViewFacet.ActionCheck memory emptyRewards = EdenViewFacet(diamond).canClaimRewards(bobPositionId);
        assertTrue(!emptyRewards.ok);
        assertEq(emptyRewards.code, ACTION_NOTHING_CLAIMABLE);
    }

    function test_ReadSurfaces_HandleUnknownAndPaginationBoundaries() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownIndex.selector, 99));
        EdenViewFacet(diamond).getBasketSummary(99);

        uint256[] memory emptyIds = EdenViewFacet(diamond).getBasketIds(10, 5);
        assertEq(emptyIds.length, 0);
        emptyIds = EdenViewFacet(diamond).getBasketIds(0, 0);
        assertEq(emptyIds.length, 0);

        EdenViewFacet.BasketSummary[] memory emptySummaries = EdenViewFacet(diamond).getBasketSummaries(10, 5);
        assertEq(emptySummaries.length, 0);
        emptySummaries = EdenViewFacet(diamond).getBasketSummaries(0, 0);
        assertEq(emptySummaries.length, 0);

        uint256[] memory pagedPositions = EdenViewFacet(diamond).getUserPositionIdsPaginated(alice, 1, 1);
        assertEq(pagedPositions.length, 1);
        assertEq(pagedPositions[0], aliceAltPositionId);

        pagedPositions = EdenViewFacet(diamond).getUserPositionIdsPaginated(alice, 5, 1);
        assertEq(pagedPositions.length, 0);

        pagedPositions = EdenViewFacet(diamond).getUserPositionIdsPaginated(alice, 0, 0);
        assertEq(pagedPositions.length, 0);

        uint256[] memory loanIds = EdenLendingFacet(diamond).getLoanIdsByBorrowerPaginated(aliceAltPositionId, 1, 1);
        assertEq(loanIds.length, 0);
        loanIds = EdenLendingFacet(diamond).getLoanIdsByBorrowerPaginated(aliceAltPositionId, 0, 0);
        assertEq(loanIds.length, 0);

        uint256[] memory activeLoanIds =
            EdenLendingFacet(diamond).getActiveLoanIdsByBorrowerPaginated(aliceAltPositionId, 1, 1);
        assertEq(activeLoanIds.length, 0);
        activeLoanIds = EdenLendingFacet(diamond).getActiveLoanIdsByBorrowerPaginated(aliceAltPositionId, 0, 0);
        assertEq(activeLoanIds.length, 0);
    }

    function test_PositionMetadataAndOfferHooks_AreStable() public view {
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
}
