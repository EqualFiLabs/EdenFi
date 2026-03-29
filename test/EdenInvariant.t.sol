// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {OwnershipFacet} from "src/core/OwnershipFacet.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";

import {EdenLaunchFixture} from "test/utils/EdenLaunchFixture.t.sol";
import {EdenInvariantHandler, EdenInvariantInspector} from "test/utils/EdenInvariantUtils.t.sol";

contract EdenByEqualFiInvariantTest is StdInvariant, EdenLaunchFixture {
    EdenInvariantInspector internal inspector;
    EdenInvariantHandler internal handler;

    uint256 internal feeBasketId;
    address internal feeBasketToken;
    uint256 internal feeIndexId;
    address internal feeIndexToken;

    function setUp() public override {
        super.setUp();
        _bootstrapEdenProduct();

        (feeBasketId, feeBasketToken) =
            _createBasket(_singleAssetParams("ALT Fee Basket", "AFEE", address(alt), "ipfs://fee-alt", 2, 100, 100));
        (feeIndexId, feeIndexToken) =
            _createIndexThroughTimelock(_singleAssetIndexParams("EVE Index", "eEVE", address(eve), 100, 100));

        EdenInvariantInspector inspectorFacet = new EdenInvariantInspector();
        bytes4[] memory inspectorSelectors = new bytes4[](16);
        inspectorSelectors[0] = EdenInvariantInspector.poolCount.selector;
        inspectorSelectors[1] = EdenInvariantInspector.nativeTrackedTotal.selector;
        inspectorSelectors[2] = EdenInvariantInspector.poolSnapshot.selector;
        inspectorSelectors[3] = EdenInvariantInspector.userPrincipal.selector;
        inspectorSelectors[4] = EdenInvariantInspector.userAccruedYield.selector;
        inspectorSelectors[5] = EdenInvariantInspector.userSameAssetDebt.selector;
        inspectorSelectors[6] = EdenInvariantInspector.isMember.selector;
        inspectorSelectors[7] = EdenInvariantInspector.canClearMembership.selector;
        inspectorSelectors[8] = EdenInvariantInspector.totalEncumbrance.selector;
        inspectorSelectors[9] = EdenInvariantInspector.moduleEncumbrance.selector;
        inspectorSelectors[10] = EdenInvariantInspector.indexEncumbrance.selector;
        inspectorSelectors[11] = EdenInvariantInspector.eligiblePrincipal.selector;
        inspectorSelectors[12] = EdenInvariantInspector.rewardGlobalIndex.selector;
        inspectorSelectors[13] = EdenInvariantInspector.rewardReserve.selector;
        inspectorSelectors[14] = EdenInvariantInspector.positionRewardIndex.selector;
        inspectorSelectors[15] = EdenInvariantInspector.positionAccruedRewards.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(inspectorFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: inspectorSelectors
        });
        _timelockCall(diamond, abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts, address(0), bytes("")));
        inspector = EdenInvariantInspector(diamond);

        EdenInvariantHandler.HandlerConfig memory cfg = EdenInvariantHandler.HandlerConfig({
            diamond: diamond,
            positionNft: positionNft,
            timelockController: timelockController,
            inspector: inspector,
            eve: eve,
            alt: alt,
            steveBasketId: steveBasketId,
            steveToken: steveToken,
            altBasketId: altBasketId,
            altBasketToken: altBasketToken,
            feeBasketId: feeBasketId,
            feeBasketToken: feeBasketToken,
            feeIndexId: feeIndexId,
            feeIndexToken: feeIndexToken
        });
        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = _addr("dave");

        handler = new EdenInvariantHandler(cfg, actors);

        handler.seedInitialState();

        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = handler.mintPosition.selector;
        selectors[1] = handler.depositToHomePool.selector;
        selectors[2] = handler.withdrawFromHomePool.selector;
        selectors[3] = handler.cleanupHomeMembership.selector;
        selectors[4] = handler.claimPositionYield.selector;
        selectors[5] = handler.mintWalletFeeBasket.selector;
        selectors[6] = handler.burnWalletFeeBasket.selector;
        selectors[7] = handler.mintFeeBasketFromPosition.selector;
        selectors[8] = handler.burnFeeBasketFromPosition.selector;
        selectors[9] = handler.mintWalletStEVE.selector;
        selectors[10] = handler.depositWalletStEVEToPosition.selector;
        selectors[11] = handler.withdrawStEVEFromPosition.selector;
        selectors[12] = handler.mintWalletIndex.selector;
        selectors[13] = handler.burnWalletIndex.selector;
        selectors[14] = handler.mintIndexFromPosition.selector;
        selectors[15] = handler.burnIndexFromPosition.selector;
        selectors[16] = handler.fundRewards.selector;
        selectors[17] = handler.claimRewards.selector;
        selectors[18] = handler.borrowAgainstAltBasket.selector;
        selectors[19] = handler.repayLoan.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        bytes4[] memory selectors2 = new bytes4[](5);
        selectors2[0] = handler.extendLoan.selector;
        selectors2[1] = handler.recoverLoan.selector;
        selectors2[2] = handler.transferPosition.selector;
        selectors2[3] = handler.warpTime.selector;
        selectors2[4] = handler.attemptUnauthorizedMutations.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors2}));
    }

    function invariant_SubstrateAccountingRemainsBacked() public view {
        uint256 poolCount = inspector.poolCount();
        uint256 nativeTrackedSum;

        for (uint256 pid = 1; pid < poolCount; pid++) {
            EdenInvariantInspector.PoolSnapshot memory snapshot = inspector.poolSnapshot(pid);
            if (!snapshot.initialized) continue;

            assertGe(
                snapshot.trackedBalance + snapshot.activeCreditPrincipalTotal,
                snapshot.totalDeposits + snapshot.yieldReserve
            );
            assertGe(snapshot.activeCreditPrincipalTotal, snapshot.activeCreditMaturedTotal);

            if (snapshot.underlying == address(0)) {
                nativeTrackedSum += snapshot.trackedBalance;
            }
        }

        assertEq(inspector.nativeTrackedTotal(), nativeTrackedSum);
    }

    function invariant_PositionKeysEncumbranceAndCleanupStaySound() public view {
        uint256 poolCount = inspector.poolCount();
        uint256 trackedCount = handler.positionCount();

        for (uint256 i = 0; i < trackedCount; i++) {
            uint256 tokenId = handler.positionAt(i);
            bytes32 positionKey = positionNft.getPositionKey(tokenId);

            assertEq(positionKey, handler.initialPositionKeyOf(tokenId));

            for (uint256 pid = 1; pid < poolCount; pid++) {
                EdenInvariantInspector.PoolSnapshot memory snapshot = inspector.poolSnapshot(pid);
                if (!snapshot.initialized) continue;

                uint256 principal = inspector.userPrincipal(pid, positionKey);
                uint256 encumbrance = inspector.totalEncumbrance(positionKey, pid);
                assertLe(encumbrance, principal);

                if (handler.wasEverMember(tokenId, pid) && !inspector.isMember(positionKey, pid)) {
                    (bool canClear,) = inspector.canClearMembership(positionKey, pid);
                    assertTrue(canClear);
                }
            }
        }
    }

    function invariant_BasketAndIndexAccountingMatchesPositionHoldings() public view {
        _assertProductSupplyMatchesPrincipal(altBasketId, altBasketToken, EdenViewFacet(diamond).getProductPoolId());
        _assertProductSupplyMatchesPrincipal(feeBasketId, feeBasketToken, EdenViewFacet(diamond).getProductPoolId());
        _assertIndexSupplyMatchesPrincipal(
            feeIndexId, feeIndexToken, EqualIndexAdminFacetV3(diamond).getIndexPoolId(feeIndexId)
        );

        uint256 indexEncumbranceTotal = _sumIndexEncumbrance(1);
        assertEq(inspector.poolSnapshot(1).indexEncumberedTotal, indexEncumbranceTotal);
    }

    function invariant_RewardsRemainConservativeAndPNFTScoped() public view {
        EdenRewardFacet.RewardView memory rewardView = EdenRewardFacet(diamond).getRewardConfig();
        uint256 trackedCount = handler.positionCount();
        uint256 sumEligible;
        uint256 sumClaimable;

        for (uint256 i = 0; i < trackedCount; i++) {
            uint256 tokenId = handler.positionAt(i);
            bytes32 positionKey = positionNft.getPositionKey(tokenId);
            uint256 eligible = inspector.eligiblePrincipal(positionKey);
            sumEligible += eligible;
            sumClaimable += EdenRewardFacet(diamond).previewClaimRewards(tokenId);

            assertLe(eligible, inspector.userPrincipal(EdenViewFacet(diamond).getProductPoolId(), positionKey));
        }

        assertEq(sumEligible, inspector.eligibleSupply());
        assertGe(rewardView.globalRewardIndex, handler.maxObservedRewardIndex());
        assertLe(sumClaimable + rewardView.rewardReserve + handler.totalRewardClaimed(), handler.totalRewardFunded());
    }

    function invariant_LendingLifecycleAndCollateralStayConsistent() public view {
        uint256 trackedLoanCount = handler.loanCount();
        uint256 openCollateral;
        uint256 openOutstanding;
        uint256 moduleEncumbered;

        for (uint256 i = 0; i < trackedLoanCount; i++) {
            uint256 loanId = handler.loanAt(i);
            EdenLendingFacet.LoanView memory loanView = EdenLendingFacet(diamond).getLoanView(loanId);
            bool closed = loanView.closedAt != 0 || loanView.closeReason != 0;

            require(loanView.productId == altBasketId, "loan product mismatch");

            if (!closed) {
                require(loanView.closeReason == 0, "open loan close reason mismatch");
                require(loanView.closedAt == 0, "open loan closedAt mismatch");
                require(loanView.active || loanView.expired, "open loan must be active or expired");
                openCollateral += loanView.collateralUnits;
                openOutstanding += loanView.principals[0];
                require(_trackedPositionExists(loanView.borrowerPositionKey), "untracked borrower position");
            } else {
                require(loanView.closedAt != 0, "closed loan missing closedAt");
                require(loanView.closeReason == 1 || loanView.closeReason == 2, "closed loan reason mismatch");
                require(!loanView.active, "closed loan marked active");
            }
        }

        uint256 trackedCount = handler.positionCount();
        uint256 basketPoolId = EdenViewFacet(diamond).getProductPoolId();
        for (uint256 i = 0; i < trackedCount; i++) {
            bytes32 positionKey = positionNft.getPositionKey(handler.positionAt(i));
            moduleEncumbered += inspector.moduleEncumbrance(positionKey, basketPoolId);
        }

        require(
            EdenLendingFacet(diamond).getLockedCollateralUnits() == openCollateral,
            "locked collateral mismatch"
        );
        require(
            EdenLendingFacet(diamond).getOutstandingPrincipal(address(alt)) == openOutstanding,
            "outstanding principal mismatch"
        );
        require(moduleEncumbered >= openCollateral, "module encumbrance below locked collateral");
    }

    function invariant_GovernanceRemainsTimelocked() public view {
        EdenViewFacet.ProductConfigView memory product = EdenViewFacet(diamond).getProductConfig();

        assertEq(OwnershipFacet(diamond).owner(), address(timelockController));
        assertEq(product.timelock, address(timelockController));
        assertEq(product.timelockDelaySeconds, 7 days);
        assertEq(timelockController.getMinDelay(), 7 days);
        assertEq(handler.unauthorizedMutationSuccesses(), 0);
    }

    function test_InvariantSeedAccountingSanity() public view {
        _assertNamedProductSupplyMatchesPrincipal(
            "alt", altBasketId, altBasketToken, EdenViewFacet(diamond).getProductPoolId()
        );
        _assertNamedProductSupplyMatchesPrincipal(
            "fee-basket", feeBasketId, feeBasketToken, EdenViewFacet(diamond).getProductPoolId()
        );
        _assertNamedIndexSupplyMatchesPrincipal(
            "fee-index", feeIndexId, feeIndexToken, EqualIndexAdminFacetV3(diamond).getIndexPoolId(feeIndexId)
        );
        require(
            inspector.poolSnapshot(1).indexEncumberedTotal == _sumIndexEncumbrance(1), "seed index encumbrance mismatch"
        );
    }

    function test_InvariantSeedRewardSanity() public view {
        EdenRewardFacet.RewardView memory rewardView = EdenRewardFacet(diamond).getRewardConfig();
        uint256 trackedCount = handler.positionCount();
        uint256 sumEligible;
        uint256 sumClaimable;

        for (uint256 i = 0; i < trackedCount; i++) {
            uint256 tokenId = handler.positionAt(i);
            bytes32 positionKey = positionNft.getPositionKey(tokenId);
            uint256 eligible = inspector.eligiblePrincipal(positionKey);
            sumEligible += eligible;
            sumClaimable += EdenRewardFacet(diamond).previewClaimRewards(tokenId);
        }

        require(sumEligible == inspector.eligibleSupply(), "seed eligible supply mismatch");
        require(rewardView.globalRewardIndex >= handler.maxObservedRewardIndex(), "seed reward index mismatch");
        require(
            sumClaimable + rewardView.rewardReserve + handler.totalRewardClaimed() <= handler.totalRewardFunded(),
            "seed reward conservation mismatch"
        );
    }

    function test_InvariantBorrowSanity() public {
        handler.borrowAgainstAltBasket(1, 100, 60, 30, 7 days);
        invariant_LendingLifecycleAndCollateralStayConsistent();
    }

    function _assertProductSupplyMatchesPrincipal(uint256 basketId, address token, uint256 poolId) internal view {
        basketId;
        EdenViewFacet.ProductConfigView memory basket = EdenViewFacet(diamond).getProductConfig();
        require(basket.totalUnits == ERC20(token).totalSupply(), "product total supply mismatch");
        require(ERC20(token).balanceOf(diamond) >= _sumPrincipal(poolId), "product principal mismatch");
    }

    function _assertNamedProductSupplyMatchesPrincipal(
        string memory name,
        uint256 basketId,
        address token,
        uint256 poolId
    ) internal view {
        basketId;
        EdenViewFacet.ProductConfigView memory basket = EdenViewFacet(diamond).getProductConfig();
        require(basket.totalUnits == ERC20(token).totalSupply(), string.concat(name, " total supply mismatch"));
        require(ERC20(token).balanceOf(diamond) >= _sumPrincipal(poolId), string.concat(name, " principal mismatch"));
    }

    function _assertIndexSupplyMatchesPrincipal(uint256 indexId, address token, uint256 poolId) internal view {
        EqualIndexBaseV3.IndexView memory idx = EqualIndexAdminFacetV3(diamond).getIndex(indexId);
        require(idx.totalUnits == ERC20(token).totalSupply(), "index total supply mismatch");
        require(ERC20(token).balanceOf(diamond) >= _sumPrincipal(poolId), "index principal mismatch");
    }

    function _assertNamedIndexSupplyMatchesPrincipal(string memory name, uint256 indexId, address token, uint256 poolId)
        internal
        view
    {
        EqualIndexBaseV3.IndexView memory idx = EqualIndexAdminFacetV3(diamond).getIndex(indexId);
        require(idx.totalUnits == ERC20(token).totalSupply(), string.concat(name, " total supply mismatch"));
        require(ERC20(token).balanceOf(diamond) >= _sumPrincipal(poolId), string.concat(name, " principal mismatch"));
    }

    function _sumPrincipal(uint256 pid) internal view returns (uint256 total) {
        uint256 trackedCount = handler.positionCount();
        for (uint256 i = 0; i < trackedCount; i++) {
            bytes32 positionKey = positionNft.getPositionKey(handler.positionAt(i));
            total += inspector.userPrincipal(pid, positionKey);
        }
    }

    function _sumIndexEncumbrance(uint256 pid) internal view returns (uint256 total) {
        uint256 trackedCount = handler.positionCount();
        for (uint256 i = 0; i < trackedCount; i++) {
            bytes32 positionKey = positionNft.getPositionKey(handler.positionAt(i));
            total += inspector.indexEncumbrance(positionKey, pid);
        }
    }

    function _trackedPositionExists(bytes32 positionKey) internal view returns (bool) {
        uint256 trackedCount = handler.positionCount();
        for (uint256 i = 0; i < trackedCount; i++) {
            if (positionNft.getPositionKey(handler.positionAt(i)) == positionKey) {
                return true;
            }
        }
        return false;
    }

    function assertLe(uint256 left, uint256 right) internal pure {
        require(left <= right, "assertLe failed");
    }

    function assertGe(uint256 left, uint256 right) internal pure {
        require(left >= right, "assertGe failed");
    }
}
