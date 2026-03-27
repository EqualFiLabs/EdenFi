// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EdenBasketBase} from "src/eden/EdenBasketBase.sol";
import {EdenLendingFacet} from "src/eden/EdenLendingFacet.sol";
import {PoolManagementFacet} from "src/equallend/PoolManagementFacet.sol";
import {PositionNFT} from "src/nft/PositionNFT.sol";
import {LibAppStorage} from "src/libraries/LibAppStorage.sol";
import {LibEdenBasketStorage} from "src/libraries/LibEdenBasketStorage.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {LibEdenLendingStorage} from "src/libraries/LibEdenLendingStorage.sol";
import {LibModuleEncumbrance} from "src/libraries/LibModuleEncumbrance.sol";
import {LibPositionNFT} from "src/libraries/LibPositionNFT.sol";
import {Types} from "src/libraries/Types.sol";

contract MockERC20Lending is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeOnTransferLendingToken is ERC20 {
    uint256 internal constant BPS = 10_000;
    uint256 public feeBps = 1000;
    address public feeSink = address(0xdead);

    constructor() ERC20("FoT Underlying", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / BPS;
        uint256 remainder = value - fee;
        super._update(from, feeSink, fee);
        super._update(from, to, remainder);
    }
}

contract EdenLendingHarness is PoolManagementFacet, EdenLendingFacet {
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

    function setDefaultPoolConfig(Types.PoolConfig calldata config) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.defaultPoolConfigSet = true;

        store.defaultPoolConfig.rollingApyBps = config.rollingApyBps;
        store.defaultPoolConfig.depositorLTVBps = config.depositorLTVBps;
        store.defaultPoolConfig.maintenanceRateBps = config.maintenanceRateBps;
        store.defaultPoolConfig.flashLoanFeeBps = config.flashLoanFeeBps;
        store.defaultPoolConfig.flashLoanAntiSplit = config.flashLoanAntiSplit;
        store.defaultPoolConfig.minDepositAmount = config.minDepositAmount;
        store.defaultPoolConfig.minLoanAmount = config.minLoanAmount;
        store.defaultPoolConfig.minTopupAmount = config.minTopupAmount;
        store.defaultPoolConfig.isCapped = config.isCapped;
        store.defaultPoolConfig.depositCap = config.depositCap;
        store.defaultPoolConfig.maxUserCount = config.maxUserCount;
        store.defaultPoolConfig.aumFeeMinBps = config.aumFeeMinBps;
        store.defaultPoolConfig.aumFeeMaxBps = config.aumFeeMaxBps;
        store.defaultPoolConfig.borrowFee = config.borrowFee;
        store.defaultPoolConfig.repayFee = config.repayFee;
        store.defaultPoolConfig.withdrawFee = config.withdrawFee;
        store.defaultPoolConfig.flashFee = config.flashFee;
        store.defaultPoolConfig.closeRollingFee = config.closeRollingFee;

        delete store.defaultPoolConfig.fixedTermConfigs;
        for (uint256 i = 0; i < config.fixedTermConfigs.length; i++) {
            store.defaultPoolConfig.fixedTermConfigs.push(config.fixedTermConfigs[i]);
        }
    }

    function principalOf(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userPrincipal[user];
    }

    function loanModuleEncumbrance(uint256 tokenId, uint256 basketId, uint256 loanId) external view returns (uint256) {
        bytes32 positionKey = PositionNFT(LibPositionNFT.s().positionNFTContract).getPositionKey(tokenId);
        uint256 basketPoolId = LibEdenBasketStorage.s().baskets[basketId].poolId;
        return LibModuleEncumbrance.getEncumberedForModule(
            positionKey,
            basketPoolId,
            uint256(keccak256(abi.encodePacked("EDEN_LOAN", loanId)))
        );
    }

    function loanCloseReason(uint256 loanId) external view returns (uint8) {
        return LibEdenLendingStorage.s().loanCloseReason[loanId];
    }

    function loanClosedAt(uint256 loanId) external view returns (uint256) {
        return LibEdenLendingStorage.s().loanClosedAt[loanId];
    }
}

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function deal(address who, uint256 newBalance) external;
}

contract EdenLendingFacetTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EdenLendingHarness internal harness;
    PositionNFT internal positionNft;
    MockERC20Lending internal eve;
    MockFeeOnTransferLendingToken internal fot;

    address internal alice = _addr("alice");
    address internal bob = _addr("bob");
    address internal treasury = _addr("treasury");

    function setUp() public {
        harness = new EdenLendingHarness();
        harness.setOwner(address(this));
        harness.setTimelock(_addr("timelock"));
        harness.setTreasury(treasury);
        harness.setFeeSplits(1000, 0);

        positionNft = new PositionNFT();
        positionNft.setMinter(address(harness));
        harness.setPositionNft(address(positionNft));

        eve = new MockERC20Lending("EVE", "EVE");
        fot = new MockFeeOnTransferLendingToken();

        Types.PoolConfig memory cfg = _poolConfig();
        Types.ActionFeeSet memory actionFees;
        harness.initPoolWithActionFees(1, address(eve), cfg, actionFees);
        harness.initPoolWithActionFees(2, address(fot), cfg, actionFees);
        harness.setDefaultPoolConfig(cfg);
    }

    function test_PositionOwnedBorrowRepayAndViews() public {
        eve.mint(alice, 200e18);

        vm.prank(alice);
        eve.approve(address(harness), 200e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 100e18, 100e18);

        (uint256 basketId,) =
            harness.createBasket(_singleAssetParams("EDEN", "EDEN", address(eve), "ipfs://eden", 0));
        uint256 basketPoolId = harness.getBasketPoolId(basketId);

        vm.prank(alice);
        harness.mintBasketFromPosition(positionId, basketId, 50e18);

        harness.configureLending(basketId, 1 days, 14 days);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        harness.configureBorrowFeeTiers(basketId, mins, fees);

        EdenLendingFacet.BorrowPreview memory borrowPreview =
            harness.previewBorrow(positionId, basketId, 20e18, 7 days);
        _assertEq(borrowPreview.availableCollateral, 50e18, "available collateral");
        _assertEq(borrowPreview.principals[0], 20e18, "preview principal");
        _assertTrue(borrowPreview.invariantSatisfied, "preview invariant");

        vm.prank(alice);
        uint256 loanId = harness.borrow(positionId, basketId, 20e18, 7 days);

        _assertEq(harness.loanCount(), 1, "loan count");
        _assertEq(harness.borrowerLoanCount(positionId), 1, "borrower loan count");
        _assertEq(harness.principalOf(basketPoolId, positionKey), 50e18, "basket principal unchanged");
        _assertEq(harness.loanModuleEncumbrance(positionId, basketId, loanId), 20e18, "collateral encumbered");
        _assertEq(harness.getOutstandingPrincipal(basketId, address(eve)), 20e18, "outstanding principal");
        _assertEq(harness.getBasketVaultBalance(basketId, address(eve)), 30e18, "vault reduced");

        EdenLendingFacet.LoanView memory liveLoan = harness.getLoanView(loanId);
        _assertEq(uint256(liveLoan.borrowerPositionKey), uint256(positionKey), "borrower position key");
        _assertTrue(liveLoan.active, "loan active");
        _assertTrue(!liveLoan.expired, "loan not expired");
        _assertEq(liveLoan.principals[0], 20e18, "loan principals");

        EdenLendingFacet.RepayPreview memory repayPreview = harness.previewRepay(positionId, loanId);
        _assertEq(repayPreview.principals[0], 20e18, "repay principal");
        _assertEq(repayPreview.unlockedCollateralUnits, 20e18, "unlocked collateral");

        vm.prank(alice);
        eve.approve(address(harness), 20e18);
        vm.prank(alice);
        harness.repay(positionId, loanId);

        _assertEq(harness.loanModuleEncumbrance(positionId, basketId, loanId), 0, "collateral unlocked");
        _assertEq(harness.getOutstandingPrincipal(basketId, address(eve)), 0, "outstanding cleared");
        _assertEq(harness.getBasketVaultBalance(basketId, address(eve)), 50e18, "vault restored");

        EdenLendingFacet.LoanView memory closedLoan = harness.getLoanView(loanId);
        _assertTrue(!closedLoan.active, "loan closed");
        _assertEq(harness.loanCloseReason(loanId), 1, "repay close reason");
        _assertTrue(harness.loanClosedAt(loanId) > 0, "closedAt recorded");

        uint256[] memory allLoanIds = harness.getLoanIdsByBorrower(positionId);
        _assertEq(allLoanIds.length, 1, "borrower history preserved");
        uint256[] memory activeLoanIds = harness.getActiveLoanIdsByBorrower(positionId);
        _assertEq(activeLoanIds.length, 0, "no active loans after repay");
    }

    function test_ExtendRecoveryAndPagination() public {
        eve.mint(alice, 300e18);

        vm.prank(alice);
        eve.approve(address(harness), 300e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(1);
        bytes32 positionKey = positionNft.getPositionKey(positionId);

        vm.prank(alice);
        harness.depositToPosition(positionId, 1, 120e18, 120e18);

        (uint256 basketId,) =
            harness.createBasket(_singleAssetParams("Recoverable", "RCV", address(eve), "ipfs://rcv", 0));
        uint256 basketPoolId = harness.getBasketPoolId(basketId);

        vm.prank(alice);
        harness.mintBasketFromPosition(positionId, basketId, 60e18);

        harness.configureLending(basketId, 1 days, 20 days);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0.01 ether;
        harness.configureBorrowFeeTiers(basketId, mins, fees);

        vm.deal(alice, 1 ether);

        vm.prank(alice);
        uint256 loanOne = harness.borrow{value: 0.01 ether}(positionId, basketId, 10e18, 5 days);
        vm.prank(alice);
        uint256 loanTwo = harness.borrow{value: 0.01 ether}(positionId, basketId, 15e18, 5 days);

        EdenLendingFacet.ExtendPreview memory extendPreview =
            harness.previewExtend(positionId, loanOne, 3 days);
        _assertEq(extendPreview.feeNative, 0.01 ether, "extend preview fee");
        _assertEq(extendPreview.newMaturity, uint40(harness.getLoanView(loanOne).maturity + 3 days), "extend maturity");

        vm.prank(alice);
        harness.extend{value: 0.01 ether}(positionId, loanOne, 3 days);
        _assertEq(harness.getLoanView(loanOne).maturity, extendPreview.newMaturity, "extended maturity stored");

        uint256[] memory paginated = harness.getLoanIdsByBorrowerPaginated(positionId, 1, 1);
        _assertEq(paginated.length, 1, "pagination length");
        _assertEq(paginated[0], loanTwo, "pagination content");

        vm.warp(block.timestamp + 9 days);
        harness.recoverExpired(loanTwo);

        _assertEq(harness.loanModuleEncumbrance(positionId, basketId, loanTwo), 0, "encumbrance cleared on recovery");
        _assertEq(harness.principalOf(basketPoolId, positionKey), 45e18, "basket principal burned on recovery");
        _assertEq(harness.getBasket(basketId).totalUnits, 45e18, "basket supply reduced");
        _assertEq(harness.loanCloseReason(loanTwo), 2, "recovery close reason");

        EdenLendingFacet.LoanView memory recovered = harness.getLoanView(loanTwo);
        _assertTrue(!recovered.active, "recovered loan inactive");
        _assertTrue(recovered.expired, "recovered loan remains expired in view");

        uint256[] memory activeLoans = harness.getActiveLoanIdsByBorrower(positionId);
        _assertEq(activeLoans.length, 0, "no active loans after expiry");
    }

    function test_RepayRevertsWhenFoTDeltaIsInsufficient() public {
        fot.mint(alice, 400e18);

        vm.prank(alice);
        fot.approve(address(harness), 400e18);
        vm.prank(alice);
        uint256 positionId = harness.mintPosition(2);

        vm.prank(alice);
        harness.depositToPosition(positionId, 2, 180e18, 200e18);

        (uint256 basketId,) =
            harness.createBasket(_singleAssetParams("FoTBasket", "FBT", address(fot), "ipfs://fot", 0));
        harness.configureLending(basketId, 1 days, 14 days);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 1e18;
        uint256[] memory fees = new uint256[](1);
        fees[0] = 0;
        harness.configureBorrowFeeTiers(basketId, mins, fees);

        vm.prank(alice);
        harness.mintBasketFromPosition(positionId, basketId, 90e18);

        vm.prank(alice);
        uint256 loanId = harness.borrow(positionId, basketId, 30e18, 7 days);

        vm.prank(alice);
        fot.approve(address(harness), 30e18);
        vm.prank(alice);
        (bool ok,) = address(harness).call(
            abi.encodeWithSelector(harness.repay.selector, positionId, loanId)
        );
        _assertTrue(!ok, "FoT underreceipt must revert exact repay");
    }

    function _singleAssetParams(
        string memory name_,
        string memory symbol_,
        address asset,
        string memory uri_,
        uint8 basketType
    ) internal pure returns (EdenBasketBase.CreateBasketParams memory p) {
        p.name = name_;
        p.symbol = symbol_;
        p.uri = uri_;
        p.assets = new address[](1);
        p.assets[0] = asset;
        p.bundleAmounts = new uint256[](1);
        p.bundleAmounts[0] = 1e18;
        p.mintFeeBps = new uint16[](1);
        p.mintFeeBps[0] = 0;
        p.burnFeeBps = new uint16[](1);
        p.burnFeeBps[0] = 0;
        p.flashFeeBps = 50;
        p.basketType = basketType;
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
