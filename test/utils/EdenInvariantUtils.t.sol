// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {OwnershipFacet} from "src/core/OwnershipFacet.sol";
import {FixedDelayTimelockController} from "src/governance/FixedDelayTimelockController.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {EqualIndexAdminFacetV3} from "src/equalindex/EqualIndexAdminFacetV3.sol";
import {EqualIndexActionsFacetV3} from "src/equalindex/EqualIndexActionsFacetV3.sol";
import {EqualIndexBaseV3} from "src/equalindex/EqualIndexBaseV3.sol";
import {EqualIndexPositionFacet} from "src/equalindex/EqualIndexPositionFacet.sol";
import {EdenAdminFacet} from "src/eden/EdenAdminFacet.sol";
import {EdenBasketDataFacet} from "src/eden/EdenBasketDataFacet.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {EdenRewardFacet} from "src/eden/EdenRewardFacet.sol";
import {EdenStEVEActionFacet} from "src/eden/EdenStEVEActionFacet.sol";
import {EdenStEVEWalletFacet} from "src/eden/EdenStEVEWalletFacet.sol";
import {EdenViewFacet} from "src/eden/EdenViewFacet.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibEdenRewardStorage} from "src/libraries/LibEdenRewardStorage.sol";
import {LibEdenStEVEStorage} from "src/libraries/LibEdenStEVEStorage.sol";
import {LibEncumbrance} from "src/libraries/LibEncumbrance.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionHelpers} from "src/libraries/LibPositionHelpers.sol";
import {Types} from "src/libraries/Types.sol";

import {MockERC20Launch} from "test/utils/EdenLaunchFixture.t.sol";
import {ILegacyEdenPositionFacet} from "test/utils/LegacyEdenPositionFacet.sol";
import {ILegacyEdenWalletFacet} from "test/utils/LegacyEdenWalletFacet.sol";

contract EdenInvariantInspector {
    struct PoolSnapshot {
        address underlying;
        bool initialized;
        uint256 totalDeposits;
        uint256 trackedBalance;
        uint256 yieldReserve;
        uint256 userCount;
        uint256 indexEncumberedTotal;
        uint256 activeCreditPrincipalTotal;
        uint256 activeCreditMaturedTotal;
        uint256 feeIndex;
        uint256 maintenanceIndex;
    }

    function poolCount() external view returns (uint256) {
        return LibAppStorage.s().poolCount;
    }

    function nativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function poolSnapshot(uint256 pid) external view returns (PoolSnapshot memory snapshot) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        snapshot.underlying = p.underlying;
        snapshot.initialized = p.initialized;
        snapshot.totalDeposits = p.totalDeposits;
        snapshot.trackedBalance = p.trackedBalance;
        snapshot.yieldReserve = p.yieldReserve;
        snapshot.userCount = p.userCount;
        snapshot.indexEncumberedTotal = p.indexEncumberedTotal;
        snapshot.activeCreditPrincipalTotal = p.activeCreditPrincipalTotal;
        snapshot.activeCreditMaturedTotal = p.activeCreditMaturedTotal;
        snapshot.feeIndex = p.feeIndex;
        snapshot.maintenanceIndex = p.maintenanceIndex;
    }

    function userPrincipal(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[positionKey];
    }

    function userAccruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[positionKey];
    }

    function userSameAssetDebt(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userSameAssetDebt[positionKey];
    }

    function isMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(positionKey, pid);
    }

    function canClearMembership(bytes32 positionKey, uint256 pid) external view returns (bool, string memory) {
        return LibPoolMembership.canClearMembership(positionKey, pid);
    }

    function totalEncumbrance(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.total(positionKey, pid);
    }

    function moduleEncumbrance(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.getModuleEncumbered(positionKey, pid);
    }

    function indexEncumbrance(bytes32 positionKey, uint256 pid) external view returns (uint256) {
        return LibEncumbrance.getIndexEncumbered(positionKey, pid);
    }

    function eligibleSupply() external view returns (uint256) {
        return LibEdenStEVEStorage.s().eligibleSupply;
    }

    function eligiblePrincipal(bytes32 positionKey) external view returns (uint256) {
        return LibEdenStEVEStorage.s().eligiblePrincipal[positionKey];
    }

    function rewardGlobalIndex() external view returns (uint256) {
        return LibEdenRewardStorage.s().config.globalRewardIndex;
    }

    function rewardReserve() external view returns (uint256) {
        return LibEdenRewardStorage.s().config.rewardReserve;
    }

    function positionRewardIndex(bytes32 positionKey) external view returns (uint256) {
        return LibEdenRewardStorage.s().positionRewardIndex[positionKey];
    }

    function positionAccruedRewards(bytes32 positionKey) external view returns (uint256) {
        return LibEdenRewardStorage.s().accruedRewards[positionKey];
    }
}

contract EdenInvariantHandler {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant MAX_TRACKED_POSITIONS = 12;
    uint256 internal constant MAX_TRACKED_LOANS = 24;
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct HandlerConfig {
        address diamond;
        PositionNFT positionNft;
        FixedDelayTimelockController timelockController;
        EdenInvariantInspector inspector;
        MockERC20Launch eve;
        MockERC20Launch alt;
        uint256 steveBasketId;
        address steveToken;
        uint256 altBasketId;
        address altBasketToken;
        uint256 feeBasketId;
        address feeBasketToken;
        uint256 feeIndexId;
        address feeIndexToken;
    }

    address public immutable diamond;
    PositionNFT public immutable positionNft;
    FixedDelayTimelockController public immutable timelockController;
    EdenInvariantInspector public immutable inspector;

    MockERC20Launch public immutable eve;
    MockERC20Launch public immutable alt;

    uint256 public immutable steveBasketId;
    address public immutable steveToken;
    uint256 public immutable altBasketId;
    address public immutable altBasketToken;
    uint256 public immutable feeBasketId;
    address public immutable feeBasketToken;
    uint256 public immutable feeIndexId;
    address public immutable feeIndexToken;

    uint256 public immutable stevePoolId;
    uint256 public immutable altBasketPoolId;
    uint256 public immutable feeBasketPoolId;
    uint256 public immutable feeIndexPoolId;

    address[] internal actors;
    uint256[] internal trackedPositions;
    uint256[] internal trackedLoans;

    mapping(uint256 => bytes32) internal initialPositionKeys;
    mapping(uint256 => mapping(uint256 => bool)) internal everJoinedPool;

    uint256 public totalRewardFunded;
    uint256 public totalRewardClaimed;
    uint256 public unauthorizedMutationAttempts;
    uint256 public unauthorizedMutationSuccesses;
    uint256 public maxObservedRewardIndex;

    bool internal seeded;

    constructor(HandlerConfig memory cfg, address[] memory actors_) {
        diamond = cfg.diamond;
        positionNft = cfg.positionNft;
        timelockController = cfg.timelockController;
        inspector = cfg.inspector;
        eve = cfg.eve;
        alt = cfg.alt;
        steveBasketId = cfg.steveBasketId;
        steveToken = cfg.steveToken;
        altBasketId = cfg.altBasketId;
        altBasketToken = cfg.altBasketToken;
        feeBasketId = cfg.feeBasketId;
        feeBasketToken = cfg.feeBasketToken;
        feeIndexId = cfg.feeIndexId;
        feeIndexToken = cfg.feeIndexToken;

        stevePoolId = EdenBasketDataFacet(cfg.diamond).getBasketPoolId(cfg.steveBasketId);
        altBasketPoolId = EdenBasketDataFacet(cfg.diamond).getBasketPoolId(cfg.altBasketId);
        feeBasketPoolId = EdenBasketDataFacet(cfg.diamond).getBasketPoolId(cfg.feeBasketId);
        feeIndexPoolId = EqualIndexAdminFacetV3(cfg.diamond).getIndexPoolId(cfg.feeIndexId);

        for (uint256 i = 0; i < actors_.length; i++) {
            actors.push(actors_[i]);
        }

        maxObservedRewardIndex = cfg.inspector.rewardGlobalIndex();
    }

    function seedInitialState() external {
        if (seeded) return;
        seeded = true;

        uint256 evePosition = _mintPositionForActor(0, 1);
        uint256 altPosition = _mintPositionForActor(1, 2);

        _topUpHomePool(evePosition, 200 * UNIT);
        _topUpHomePool(altPosition, 250 * UNIT);

        _mintWalletStEVEForOwner(evePosition, 100 * UNIT);
        _depositWalletStEVE(evePosition, 100 * UNIT);

        _mintFeeBasketFromPositionInternal(altPosition, 60 * UNIT);
        _mintAltBasketFromPositionInternal(altPosition, 80 * UNIT);
        _mintIndexFromPositionInternal(evePosition, 75 * UNIT);

        _fundRewardsInternal(400 * UNIT);
        _syncRewardIndex();
    }

    function mintPosition(uint256 actorSeed, uint256 poolSeed) external {
        if (trackedPositions.length >= MAX_TRACKED_POSITIONS) return;
        uint256 pid = (poolSeed % 2) + 1;
        _mintPositionForActor(actorSeed, pid);
    }

    function depositToHomePool(uint256 positionSeed, uint256 amountSeed) external {
        uint256 positionId = _pickTrackedPosition(positionSeed);
        if (positionId == 0) return;
        uint256 amount = _units(amountSeed, 10, 200);
        _topUpHomePool(positionId, amount);
    }

    function withdrawFromHomePool(uint256 positionSeed, uint256 amountSeed) external {
        uint256 positionId = _pickTrackedPosition(positionSeed);
        if (positionId == 0) return;

        uint256 pid = positionNft.getPoolId(positionId);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 principal = inspector.userPrincipal(pid, positionKey);
        uint256 encumbrance = inspector.totalEncumbrance(positionKey, pid);
        if (principal <= encumbrance) return;

        uint256 available = principal - encumbrance;
        uint256 amount = _boundToPrincipal(amountSeed, available);
        if (amount == 0) return;

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        PositionManagementFacet(diamond).withdrawFromPosition(positionId, pid, amount, 0);
        _syncRewardIndex();
    }

    function cleanupHomeMembership(uint256 positionSeed) external {
        uint256 positionId = _pickTrackedPosition(positionSeed);
        if (positionId == 0) return;

        uint256 pid = positionNft.getPoolId(positionId);
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        if (!inspector.isMember(positionKey, pid)) return;
        (bool canClear,) = inspector.canClearMembership(positionKey, pid);
        if (!canClear) return;

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        PositionManagementFacet(diamond).cleanupMembership(positionId, pid);
        _syncRewardIndex();
    }

    function claimPositionYield(uint256 positionSeed, uint256 poolSeed) external {
        uint256 positionId = _pickTrackedPosition(positionSeed);
        if (positionId == 0) return;

        uint256 pid = (poolSeed % 2) + 1;
        uint256 claimable = PositionManagementFacet(diamond).previewPositionYield(positionId, pid);
        if (claimable == 0) return;

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        PositionManagementFacet(diamond).claimPositionYield(positionId, pid, owner, 0);
        _syncRewardIndex();
    }

    function mintWalletFeeBasket(uint256 actorSeed, uint256 unitsSeed) external {
        address actor = _actor(actorSeed);
        uint256 units = _units(unitsSeed, 5, 80);
        uint256 required = _quoteSingleAssetBasketMint(feeBasketId, units);

        alt.mint(actor, required);
        vm.startPrank(actor);
        alt.approve(diamond, required);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = required;
        ILegacyEdenWalletFacet(diamond).mintBasket(feeBasketId, units, actor, maxInputs);
        vm.stopPrank();
        _syncRewardIndex();
    }

    function burnWalletFeeBasket(uint256 actorSeed, uint256 unitsSeed) external {
        address actor = _pickActorWithBalance(ERC20(feeBasketToken), actorSeed);
        if (actor == address(0)) return;

        uint256 balance = ERC20(feeBasketToken).balanceOf(actor);
        uint256 units = _boundToPrincipal(unitsSeed, balance);
        if (units == 0) return;

        vm.prank(actor);
        ILegacyEdenWalletFacet(diamond).burnBasket(feeBasketId, units, actor);
        _syncRewardIndex();
    }

    function mintFeeBasketFromPosition(uint256 positionSeed, uint256 unitsSeed) external {
        uint256 positionId = _pickPositionByHomePool(positionSeed, 2);
        if (positionId == 0) return;
        uint256 units = _units(unitsSeed, 5, 80);
        _mintFeeBasketFromPositionInternal(positionId, units);
    }

    function burnFeeBasketFromPosition(uint256 positionSeed, uint256 unitsSeed) external {
        uint256 positionId = _pickPositionWithPrincipal(positionSeed, feeBasketPoolId);
        if (positionId == 0) return;

        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 principal = inspector.userPrincipal(feeBasketPoolId, positionKey);
        uint256 units = _boundToPrincipal(unitsSeed, principal);
        if (units == 0) return;

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        ILegacyEdenPositionFacet(diamond).burnBasketFromPosition(positionId, feeBasketId, units);
        _syncRewardIndex();
    }

    function mintWalletStEVE(uint256 actorSeed, uint256 unitsSeed) external {
        address actor = _actor(actorSeed);
        uint256 units = _units(unitsSeed, 5, 80);

        eve.mint(actor, units);
        vm.startPrank(actor);
        eve.approve(diamond, units);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = units;
        EdenStEVEWalletFacet(diamond).mintStEVE(units, actor, maxInputs);
        vm.stopPrank();
        _syncRewardIndex();
    }

    function depositWalletStEVEToPosition(uint256 positionSeed, uint256 amountSeed) external {
        uint256 positionId = _pickTrackedPosition(positionSeed);
        if (positionId == 0) return;

        uint256 amount = _units(amountSeed, 5, 80);
        _mintWalletStEVEForOwner(positionId, amount);
        _depositWalletStEVE(positionId, amount);
    }

    function withdrawStEVEFromPosition(uint256 positionSeed, uint256 amountSeed) external {
        uint256 positionId = _pickTrackedPosition(positionSeed);
        if (positionId == 0) return;

        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 eligible = inspector.eligiblePrincipal(positionKey);
        if (eligible == 0) return;

        uint256 amount = _boundToPrincipal(amountSeed, eligible);
        if (amount == 0) return;

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        EdenStEVEActionFacet(diamond).withdrawStEVEFromPosition(positionId, amount, 0);
        _syncRewardIndex();
    }

    function mintWalletIndex(uint256 actorSeed, uint256 unitsSeed) external {
        address actor = _actor(actorSeed);
        uint256 units = _units(unitsSeed, 5, 80);
        uint256 required = _quoteSingleAssetIndexMint(units);

        eve.mint(actor, required);
        vm.startPrank(actor);
        eve.approve(diamond, required);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = required;
        EqualIndexActionsFacetV3(diamond).mint(feeIndexId, units, actor, maxInputs);
        vm.stopPrank();
        _syncRewardIndex();
    }

    function burnWalletIndex(uint256 actorSeed, uint256 unitsSeed) external {
        address actor = _pickActorWithBalance(ERC20(feeIndexToken), actorSeed);
        if (actor == address(0)) return;

        uint256 balance = ERC20(feeIndexToken).balanceOf(actor);
        uint256 units = _boundToPrincipal(unitsSeed, balance);
        if (units == 0) return;

        vm.prank(actor);
        EqualIndexActionsFacetV3(diamond).burn(feeIndexId, units, actor);
        _syncRewardIndex();
    }

    function mintIndexFromPosition(uint256 positionSeed, uint256 unitsSeed) external {
        uint256 positionId = _pickPositionByHomePool(positionSeed, 1);
        if (positionId == 0) return;
        uint256 units = _units(unitsSeed, 5, 80);
        _mintIndexFromPositionInternal(positionId, units);
    }

    function burnIndexFromPosition(uint256 positionSeed, uint256 unitsSeed) external {
        uint256 positionId = _pickPositionWithPrincipal(positionSeed, feeIndexPoolId);
        if (positionId == 0) return;

        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 principal = inspector.userPrincipal(feeIndexPoolId, positionKey);
        uint256 units = _boundToPrincipal(unitsSeed, principal);
        if (units == 0) return;

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        EqualIndexPositionFacet(diamond).burnFromPosition(positionId, feeIndexId, units);
        _syncRewardIndex();
    }

    function fundRewards(uint256 amountSeed) external {
        uint256 amount = _units(amountSeed, 25, 200);
        _fundRewardsInternal(amount);
    }

    function claimRewards(uint256 positionSeed) external {
        uint256 positionId = _pickTrackedPosition(positionSeed);
        if (positionId == 0) return;

        uint256 claimable = EdenRewardFacet(diamond).previewClaimRewards(positionId);
        if (claimable == 0) return;

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        uint256 claimed = EdenRewardFacet(diamond).claimRewards(positionId, owner);
        totalRewardClaimed += claimed;
        _syncRewardIndex();
    }

    function borrowAgainstAltBasket(
        uint256 positionSeed,
        uint256 depositSeed,
        uint256 mintSeed,
        uint256 collateralSeed,
        uint256 durationSeed
    ) external {
        if (trackedLoans.length >= MAX_TRACKED_LOANS) return;

        uint256 positionId = _pickPositionByHomePool(positionSeed, 2);
        if (positionId == 0) return;

        uint256 depositAmount = _units(depositSeed, 50, 250);
        uint256 mintUnits = _units(mintSeed, 20, 120);
        uint256 collateralUnits = _units(collateralSeed, 5, 60);
        uint40 duration = uint40(_bound(durationSeed, 1 days, 14 days));

        _topUpHomePool(positionId, depositAmount);
        _mintAltBasketFromPositionInternal(positionId, mintUnits);

        EdenLendingFacet.BorrowPreview memory preview =
            EdenLendingFacet(diamond).previewBorrow(positionId, altBasketId, collateralUnits, duration);
        if (!preview.invariantSatisfied || preview.collateralUnits == 0) return;

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        uint256 loanId = EdenLendingFacet(diamond).borrow(positionId, altBasketId, preview.collateralUnits, duration);
        trackedLoans.push(loanId);
        _markJoined(positionId, altBasketPoolId);
        _syncRewardIndex();
    }

    function repayLoan(uint256 loanSeed) external {
        (uint256 loanId, bool found) = _pickActiveLoan(loanSeed);
        if (!found) return;

        EdenLendingFacet.LoanView memory loanView = EdenLendingFacet(diamond).getLoanView(loanId);
        uint256 positionId = _findPositionIdByKey(loanView.borrowerPositionKey);
        if (positionId == 0) return;

        EdenLendingFacet.RepayPreview memory preview = EdenLendingFacet(diamond).previewRepay(positionId, loanId);
        if (preview.principals.length == 0 || preview.principals[0] == 0) return;

        address owner = positionNft.ownerOf(positionId);
        alt.mint(owner, preview.principals[0]);
        vm.startPrank(owner);
        alt.approve(diamond, preview.principals[0]);
        EdenLendingFacet(diamond).repay(positionId, loanId);
        vm.stopPrank();
        _syncRewardIndex();
    }

    function extendLoan(uint256 loanSeed, uint256 durationSeed) external {
        (uint256 loanId, bool found) = _pickActiveLoan(loanSeed);
        if (!found) return;

        EdenLendingFacet.LoanView memory loanView = EdenLendingFacet(diamond).getLoanView(loanId);
        uint256 positionId = _findPositionIdByKey(loanView.borrowerPositionKey);
        if (positionId == 0) return;

        uint40 extraDuration = uint40(_bound(durationSeed, 1 days, 7 days));
        EdenLendingFacet.ExtendPreview memory preview =
            EdenLendingFacet(diamond).previewExtend(positionId, loanId, extraDuration);

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        EdenLendingFacet(diamond).extend{value: preview.feeNative}(positionId, loanId, extraDuration);
        _syncRewardIndex();
    }

    function recoverLoan(uint256 loanSeed, uint256 warpSeed) external {
        (uint256 loanId, bool found) = _pickActiveLoan(loanSeed);
        if (!found) return;

        EdenLendingFacet.LoanView memory loanView = EdenLendingFacet(diamond).getLoanView(loanId);
        if (block.timestamp <= loanView.maturity) {
            vm.warp(uint256(loanView.maturity) + _bound(warpSeed, 1, 2 days));
        }
        EdenLendingFacet(diamond).recoverExpired(loanId);
        _syncRewardIndex();
    }

    function transferPosition(uint256 positionSeed, uint256 actorSeed) external {
        uint256 positionId = _pickTrackedPosition(positionSeed);
        if (positionId == 0) return;

        address from = positionNft.ownerOf(positionId);
        address to = _actor(actorSeed);
        if (from == to) return;

        vm.prank(from);
        positionNft.transferFrom(from, to, positionId);
        _syncRewardIndex();
    }

    function warpTime(uint256 warpSeed) external {
        vm.warp(block.timestamp + _bound(warpSeed, 1 hours, 2 days));
        _syncRewardIndex();
    }

    function attemptUnauthorizedMutations(uint256 actorSeed, uint256 actionSeed) external {
        address actor = _actor(actorSeed);
        unauthorizedMutationAttempts += 1;

        bool ok;
        if (actionSeed % 6 == 0) {
            vm.prank(actor);
            (ok,) = diamond.call(abi.encodeWithSelector(EdenAdminFacet.setProtocolURI.selector, "ipfs://bad"));
        } else if (actionSeed % 6 == 1) {
            vm.prank(actor);
            (ok,) = diamond.call(abi.encodeWithSelector(EdenAdminFacet.setPoolFeeShareBps.selector, uint16(1234)));
        } else if (actionSeed % 6 == 2) {
            vm.prank(actor);
            (ok,) = diamond.call(abi.encodeWithSelector(OwnershipFacet.transferOwnership.selector, actor));
        } else if (actionSeed % 6 == 3) {
            IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
            vm.prank(actor);
            (ok,) = diamond.call(abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cuts, address(0), ""));
        } else if (actionSeed % 6 == 4) {
            vm.prank(actor);
            (ok,) = address(timelockController).call(
                abi.encodeWithSelector(FixedDelayTimelockController.updateDelay.selector, 1 days)
            );
        } else {
            vm.prank(actor);
            (ok,) = address(timelockController).call(
                abi.encodeWithSelector(
                    TimelockController.schedule.selector,
                    diamond,
                    uint256(0),
                    abi.encodeWithSelector(EdenAdminFacet.setContractVersion.selector, "bad"),
                    bytes32(0),
                    keccak256("bad-salt"),
                    7 days
                )
            );
        }

        if (ok) {
            unauthorizedMutationSuccesses += 1;
        }
        _syncRewardIndex();
    }

    function positionCount() external view returns (uint256) {
        return trackedPositions.length;
    }

    function positionAt(uint256 index) external view returns (uint256) {
        return trackedPositions[index];
    }

    function loanCount() external view returns (uint256) {
        return trackedLoans.length;
    }

    function loanAt(uint256 index) external view returns (uint256) {
        return trackedLoans[index];
    }

    function initialPositionKeyOf(uint256 tokenId) external view returns (bytes32) {
        return initialPositionKeys[tokenId];
    }

    function wasEverMember(uint256 tokenId, uint256 pid) external view returns (bool) {
        return everJoinedPool[tokenId][pid];
    }

    function _mintPositionForActor(uint256 actorSeed, uint256 pid) internal returns (uint256 positionId) {
        if (trackedPositions.length >= MAX_TRACKED_POSITIONS) return 0;
        address actor = _actor(actorSeed);
        vm.prank(actor);
        positionId = PositionManagementFacet(diamond).mintPosition(pid);
        trackedPositions.push(positionId);
        initialPositionKeys[positionId] = positionNft.getPositionKey(positionId);
        everJoinedPool[positionId][pid] = true;
        _syncRewardIndex();
    }

    function _topUpHomePool(uint256 positionId, uint256 amount) internal {
        uint256 pid = positionNft.getPoolId(positionId);
        address owner = positionNft.ownerOf(positionId);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        if (pid == 1) {
            eve.mint(owner, amount);
            vm.startPrank(owner);
            eve.approve(diamond, amount);
            PositionManagementFacet(diamond).depositToPosition(positionId, pid, amount, amount);
            vm.stopPrank();
        } else if (pid == 2) {
            alt.mint(owner, amount);
            vm.startPrank(owner);
            alt.approve(diamond, amount);
            PositionManagementFacet(diamond).depositToPosition(positionId, pid, amount, amount);
            vm.stopPrank();
        } else {
            return;
        }

        everJoinedPool[positionId][pid] = true;
        if (inspector.isMember(positionKey, pid)) {
            everJoinedPool[positionId][pid] = true;
        }
        _syncRewardIndex();
    }

    function _mintAltBasketFromPositionInternal(uint256 positionId, uint256 units) internal {
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 available = _availablePrincipal(2, positionKey);
        if (available < units) {
            _topUpHomePool(positionId, units - available);
        }

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        ILegacyEdenPositionFacet(diamond).mintBasketFromPosition(positionId, altBasketId, units);
        _markJoined(positionId, altBasketPoolId);
        _syncRewardIndex();
    }

    function _mintFeeBasketFromPositionInternal(uint256 positionId, uint256 units) internal {
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 required = _quoteSingleAssetBasketMint(feeBasketId, units);
        uint256 available = _availablePrincipal(2, positionKey);
        if (available < required) {
            _topUpHomePool(positionId, required - available);
        }

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        ILegacyEdenPositionFacet(diamond).mintBasketFromPosition(positionId, feeBasketId, units);
        _markJoined(positionId, feeBasketPoolId);
        _syncRewardIndex();
    }

    function _mintIndexFromPositionInternal(uint256 positionId, uint256 units) internal {
        bytes32 positionKey = positionNft.getPositionKey(positionId);
        uint256 required = _quoteSingleAssetIndexMint(units);
        uint256 available = _availablePrincipal(1, positionKey);
        if (available < required) {
            _topUpHomePool(positionId, required - available);
        }

        address owner = positionNft.ownerOf(positionId);
        vm.prank(owner);
        EqualIndexPositionFacet(diamond).mintFromPosition(positionId, feeIndexId, units);
        _markJoined(positionId, feeIndexPoolId);
        _syncRewardIndex();
    }

    function _mintWalletStEVEForOwner(uint256 positionId, uint256 amount) internal {
        address owner = positionNft.ownerOf(positionId);
        eve.mint(owner, amount);
        vm.startPrank(owner);
        eve.approve(diamond, amount);
        uint256[] memory maxInputs = new uint256[](1);
        maxInputs[0] = amount;
        EdenStEVEWalletFacet(diamond).mintStEVE(amount, owner, maxInputs);
        vm.stopPrank();
        _syncRewardIndex();
    }

    function _depositWalletStEVE(uint256 positionId, uint256 amount) internal {
        address owner = positionNft.ownerOf(positionId);
        vm.startPrank(owner);
        ERC20(steveToken).approve(diamond, amount);
        EdenStEVEActionFacet(diamond).depositStEVEToPosition(positionId, amount, amount);
        vm.stopPrank();
        _markJoined(positionId, stevePoolId);
        _syncRewardIndex();
    }

    function _fundRewardsInternal(uint256 amount) internal {
        address actor = _actor(amount);
        eve.mint(actor, amount);
        vm.startPrank(actor);
        eve.approve(diamond, amount);
        uint256 funded = EdenRewardFacet(diamond).fundRewards(amount, amount);
        vm.stopPrank();
        totalRewardFunded += funded;
        _syncRewardIndex();
    }

    function _markJoined(uint256 positionId, uint256 pid) internal {
        everJoinedPool[positionId][pid] = true;
    }

    function _syncRewardIndex() internal {
        uint256 current = inspector.rewardGlobalIndex();
        if (current > maxObservedRewardIndex) {
            maxObservedRewardIndex = current;
        }
    }

    function _quoteSingleAssetBasketMint(uint256 basketId, uint256 units) internal view returns (uint256 required) {
        EdenBasketDataFacet.BasketView memory basket = EdenBasketDataFacet(diamond).getBasket(basketId);
        uint256 totalSupply = basket.totalUnits;
        uint256 vaultBalance = EdenBasketDataFacet(diamond).getBasketVaultBalance(basketId, basket.assets[0]);
        uint256 feePot = EdenBasketDataFacet(diamond).getBasketFeePot(basketId, basket.assets[0]);

        uint256 baseDeposit;
        uint256 potBuyIn;
        if (totalSupply == 0) {
            baseDeposit = Math.mulDiv(basket.bundleAmounts[0], units, UNIT);
        } else {
            baseDeposit = Math.mulDiv(vaultBalance, units, totalSupply, Math.Rounding.Ceil);
            potBuyIn = Math.mulDiv(feePot, units, totalSupply, Math.Rounding.Ceil);
        }
        uint256 gross = baseDeposit + potBuyIn;
        uint256 fee = Math.mulDiv(gross, basket.mintFeeBps[0], 10_000, Math.Rounding.Ceil);
        return gross + fee;
    }

    function _quoteSingleAssetIndexMint(uint256 units) internal view returns (uint256 required) {
        EqualIndexBaseV3.IndexView memory idx = EqualIndexAdminFacetV3(diamond).getIndex(feeIndexId);
        uint256 totalSupply = idx.totalUnits;
        uint256 vaultBalance = EqualIndexAdminFacetV3(diamond).getVaultBalance(feeIndexId, idx.assets[0]);
        uint256 feePot = EqualIndexAdminFacetV3(diamond).getFeePot(feeIndexId, idx.assets[0]);

        uint256 vaultIn;
        uint256 potBuyIn;
        if (totalSupply == 0) {
            vaultIn = Math.mulDiv(idx.bundleAmounts[0], units, UNIT);
        } else {
            vaultIn = Math.mulDiv(vaultBalance, units, totalSupply, Math.Rounding.Ceil);
            potBuyIn = Math.mulDiv(feePot, units, totalSupply, Math.Rounding.Ceil);
        }
        uint256 gross = vaultIn + potBuyIn;
        uint256 fee = Math.mulDiv(gross, idx.mintFeeBps[0], 10_000, Math.Rounding.Ceil);
        return gross + fee;
    }

    function _pickTrackedPosition(uint256 seed) internal view returns (uint256) {
        if (trackedPositions.length == 0) return 0;
        return trackedPositions[seed % trackedPositions.length];
    }

    function _pickPositionByHomePool(uint256 seed, uint256 pid) internal view returns (uint256) {
        uint256 len = trackedPositions.length;
        if (len == 0) return 0;
        uint256 start = seed % len;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = trackedPositions[(start + i) % len];
            if (positionNft.getPoolId(tokenId) == pid) {
                return tokenId;
            }
        }
        return 0;
    }

    function _pickPositionWithPrincipal(uint256 seed, uint256 pid) internal view returns (uint256) {
        uint256 len = trackedPositions.length;
        if (len == 0) return 0;
        uint256 start = seed % len;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = trackedPositions[(start + i) % len];
            bytes32 positionKey = positionNft.getPositionKey(tokenId);
            if (inspector.userPrincipal(pid, positionKey) > 0) {
                return tokenId;
            }
        }
        return 0;
    }

    function _findPositionIdByKey(bytes32 positionKey) internal view returns (uint256) {
        for (uint256 i = 0; i < trackedPositions.length; i++) {
            uint256 tokenId = trackedPositions[i];
            if (positionNft.getPositionKey(tokenId) == positionKey) {
                return tokenId;
            }
        }
        return 0;
    }

    function _pickActiveLoan(uint256 seed) internal view returns (uint256 loanId, bool found) {
        uint256 len = trackedLoans.length;
        if (len == 0) return (0, false);
        uint256 start = seed % len;
        for (uint256 i = 0; i < len; i++) {
            uint256 candidate = trackedLoans[(start + i) % len];
            EdenLendingFacet.LoanView memory loanView = EdenLendingFacet(diamond).getLoanView(candidate);
            if (loanView.active) {
                return (candidate, true);
            }
        }
        return (0, false);
    }

    function _pickActorWithBalance(ERC20 token, uint256 seed) internal view returns (address) {
        uint256 len = actors.length;
        uint256 start = seed % len;
        for (uint256 i = 0; i < len; i++) {
            address actor = actors[(start + i) % len];
            if (token.balanceOf(actor) > 0) {
                return actor;
            }
        }
        return address(0);
    }

    function _availablePrincipal(uint256 pid, bytes32 positionKey) internal view returns (uint256) {
        uint256 principal = inspector.userPrincipal(pid, positionKey);
        uint256 encumbrance = inspector.totalEncumbrance(positionKey, pid);
        if (encumbrance >= principal) return 0;
        return principal - encumbrance;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _units(uint256 seed, uint256 minUnits, uint256 maxUnits) internal pure returns (uint256) {
        return _bound(seed, minUnits, maxUnits) * UNIT;
    }

    function _boundToPrincipal(uint256 seed, uint256 principal) internal pure returns (uint256) {
        uint256 wholeUnits = principal / UNIT;
        if (wholeUnits == 0) return 0;
        return _bound(seed, 1, wholeUnits) * UNIT;
    }

    function _bound(uint256 seed, uint256 minValue, uint256 maxValue) internal pure returns (uint256) {
        if (maxValue < minValue) {
            return minValue;
        }
        if (maxValue == minValue) {
            return minValue;
        }
        return minValue + (seed % (maxValue - minValue + 1));
    }
}
