// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionManagementFacet} from "src/equallend/PositionManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibActiveCreditIndex} from "src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibFeeIndex} from "src/libraries/LibFeeIndex.sol";
import {LibFeeRouter} from "src/libraries/LibFeeRouter.sol";
import {LibPoolMembership} from "src/libraries/LibPoolMembership.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20Position is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PositionSubstrateHarness is PoolManagementFacet, PositionManagementFacet {
    function setOwner(address owner_) external {
        LibDiamond.setContractOwner(owner_);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function setTreasury(address treasury_) external {
        LibAppStorage.s().treasury = treasury_;
    }

    function setFeeSplits(uint256 treasuryBps, uint256 activeCreditBps) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) revert();
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = uint16(treasuryBps);
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
        store.activeCreditShareConfigured = true;
    }

    function setPositionNft(address nft) external {
        LibPositionNFT.s().positionNFTContract = nft;
        LibPositionNFT.s().nftModeEnabled = nft != address(0);
    }

    function seedPoolBalances(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.totalDeposits = totalDeposits;
        pool.trackedBalance = trackedBalance;
    }

    function seedActiveCreditBase(uint256 pid, bytes32 user, uint256 principal, uint40 startTime) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.activeCreditPrincipalTotal = principal;
        pool.activeCreditMaturedTotal = principal;
        pool.userActiveCreditStateEncumbrance[user] =
            Types.ActiveCreditState({principal: principal, startTime: startTime, indexSnapshot: pool.activeCreditIndex});
    }

    function routeFeeSamePool(uint256 pid, uint256 amount, bytes32 source)
        external
        returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex)
    {
        return LibFeeRouter.routeSamePool(pid, amount, source, true, 0);
    }

    function pendingFeeYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }

    function pendingActiveCreditYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibActiveCreditIndex.pendingYield(pid, user);
    }

    function principalOf(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[user];
    }

    function accruedYieldOf(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[user];
    }

    function trackedBalanceOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function totalDepositsOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].totalDeposits;
    }

    function isPoolMember(bytes32 positionKey, uint256 pid) external view returns (bool) {
        return LibPoolMembership.isMember(positionKey, pid);
    }

    function canClearMembership(bytes32 positionKey, uint256 pid)
        external
        view
        returns (bool canClear, string memory reason)
    {
        return LibPoolMembership.canClearMembership(positionKey, pid);
    }
}

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
}

contract PositionSubstrateTest {
    bytes32 internal constant ROUTER_SOURCE = keccak256("TEST_ROUTER");
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    PositionSubstrateHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20Position internal token;

    address internal alice = _addr("alice");
    address internal treasury = _addr("treasury");

    function setUp() public {
        harness = new PositionSubstrateHarness();
        harness.setOwner(address(this));
        harness.setTimelock(_addr("timelock"));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        token = new MockERC20Position("Mock", "MOCK");

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(token), cfg, actionFees);
    }

    function test_MintPosition_DepositWithdrawAndCleanupMembership() public {
        token.mint(alice, 20e18);

        vm.prank(alice);
        token.approve(address(harness), 20e18);

        vm.prank(alice);
        uint256 tokenId = harness.mintPosition(1);

        bytes32 positionKey = positionNft.getPositionKey(tokenId);

        vm.prank(alice);
        harness.depositToPosition(tokenId, 1, 10e18, 10e18);

        _assertTrue(harness.isPoolMember(positionKey, 1), "membership created");
        _assertEq(harness.principalOf(1, positionKey), 10e18, "principal after deposit");
        _assertEq(harness.totalDepositsOf(1), 10e18, "pool deposits after deposit");
        _assertEq(harness.trackedBalanceOf(1), 10e18, "tracked balance after deposit");

        vm.prank(alice);
        harness.withdrawFromPosition(tokenId, 1, 4e18, 4e18);

        _assertEq(harness.principalOf(1, positionKey), 6e18, "principal after partial withdraw");
        _assertEq(token.balanceOf(alice), 14e18, "wallet balance after partial withdraw");

        vm.prank(alice);
        harness.withdrawFromPosition(tokenId, 1, 6e18, 6e18);

        _assertEq(harness.principalOf(1, positionKey), 0, "principal after full withdraw");
        _assertEq(token.balanceOf(alice), 20e18, "wallet balance after full withdraw");

        (bool canClear, string memory reason) = harness.canClearMembership(positionKey, 1);
        _assertTrue(canClear, reason);

        vm.prank(alice);
        harness.cleanupMembership(tokenId, 1);

        _assertTrue(!harness.isPoolMember(positionKey, 1), "membership cleared");
    }

    function test_DepositToPosition_SettlesFeeIndexBeforePrincipalIncrease() public {
        token.mint(alice, 200e18);

        vm.prank(alice);
        token.approve(address(harness), 200e18);

        vm.prank(alice);
        uint256 tokenId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(tokenId);

        vm.prank(alice);
        harness.depositToPosition(tokenId, 1, 100e18, 100e18);

        token.mint(address(harness), 10e18);
        harness.seedPoolBalances(1, 100e18, 110e18);
        (uint256 toTreasury,, uint256 toFeeIndex) = harness.routeFeeSamePool(1, 10e18, ROUTER_SOURCE);

        _assertEq(toTreasury, 1e18, "treasury split");
        _assertEq(toFeeIndex, 9e18, "fee index split");
        _assertEq(harness.pendingFeeYield(1, positionKey), 9e18, "pending fee yield");

        vm.prank(alice);
        harness.depositToPosition(tokenId, 1, 50e18, 50e18);

        _assertEq(harness.accruedYieldOf(1, positionKey), 9e18, "yield settled before principal increase");
        _assertEq(harness.principalOf(1, positionKey), 150e18, "principal after second deposit");
    }

    function test_DepositToPosition_SettlesActiveCreditBeforePrincipalIncrease() public {
        harness.setFeeSplits(1000, 7000);
        vm.warp(3 days);

        token.mint(alice, 120e18);
        vm.prank(alice);
        token.approve(address(harness), 120e18);

        vm.prank(alice);
        uint256 tokenId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(tokenId);

        vm.prank(alice);
        harness.depositToPosition(tokenId, 1, 100e18, 100e18);

        harness.seedActiveCreditBase(1, positionKey, 100e18, uint40(block.timestamp - 2 days));

        token.mint(address(harness), 10e18);
        harness.seedPoolBalances(1, 100e18, 110e18);
        (, uint256 toActiveCredit,) = harness.routeFeeSamePool(1, 10e18, ROUTER_SOURCE);
        _assertEq(toActiveCredit, 7e18, "active credit split");

        uint256 pendingBefore = harness.pendingActiveCreditYield(1, positionKey);
        _assertEq(pendingBefore, 7e18, "pending active credit yield before deposit");

        vm.prank(alice);
        harness.depositToPosition(tokenId, 1, 10e18, 10e18);

        _assertEq(harness.accruedYieldOf(1, positionKey), 9e18, "active credit and fee index settled before principal increase");
        _assertEq(harness.principalOf(1, positionKey), 110e18, "principal after active credit deposit");
    }

    function _poolConfig() internal pure returns (Types.PoolConfig memory cfg) {
        Types.FixedTermConfig[] memory fixedTerms = new Types.FixedTermConfig[](1);
        fixedTerms[0] = Types.FixedTermConfig({durationSecs: 7 days, apyBps: 500});

        cfg.rollingApyBps = 500;
        cfg.depositorLTVBps = 8000;
        cfg.maintenanceRateBps = 100;
        cfg.flashLoanFeeBps = 20;
        cfg.flashLoanAntiSplit = false;
        cfg.minDepositAmount = 1e18;
        cfg.minLoanAmount = 1e18;
        cfg.minTopupAmount = 1e18;
        cfg.isCapped = false;
        cfg.depositCap = 0;
        cfg.maxUserCount = 0;
        cfg.aumFeeMinBps = 10;
        cfg.aumFeeMaxBps = 100;
        cfg.fixedTermConfigs = fixedTerms;
    }

    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }

    function _assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function _assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }
}
