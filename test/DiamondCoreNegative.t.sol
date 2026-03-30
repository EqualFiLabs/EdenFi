// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployEqualFi} from "script/DeployEqualFi.s.sol";
import {DiamondInit} from "src/core/DiamondInit.sol";
import {OwnershipFacet} from "src/core/OwnershipFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {InvalidTimelockController, InvalidTimelockDelay} from "src/libraries/Errors.sol";

contract DiamondCoreNegativeTest is DeployEqualFi {
    address internal treasury = _addr("treasury");

    function test_LoupeSelectorsRemainInternallyConsistent() public {
        BaseDeployment memory deployment = deployBase(address(this), treasury);
        _installLaunchFacets(deployment.diamond);

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);
        address[] memory facetAddresses = loupe.facetAddresses();
        _assertTrue(facetAddresses.length > 0, "no facets");

        for (uint256 i = 0; i < facetAddresses.length; i++) {
            bytes4[] memory selectors = loupe.facetFunctionSelectors(facetAddresses[i]);
            _assertTrue(selectors.length > 0, "empty facet selector set");
            for (uint256 j = 0; j < selectors.length; j++) {
                _assertEqAddress(loupe.facetAddress(selectors[j]), facetAddresses[i], "selector routed to wrong facet");
            }
        }
    }

    function test_OwnershipTransferRejectsZeroAddressAndOldOwnerLosesRights() public {
        BaseDeployment memory deployment = deployBase(address(this), treasury);

        vm.expectRevert(bytes("OwnershipFacet: zero address"));
        OwnershipFacet(deployment.diamond).transferOwnership(address(0));

        OwnershipFacet(deployment.diamond).transferOwnership(_addr("alice"));
        _assertEqAddress(OwnershipFacet(deployment.diamond).owner(), _addr("alice"), "new owner");

        vm.expectRevert(bytes("LibDiamond: must be owner"));
        OwnershipFacet(deployment.diamond).transferOwnership(address(this));

        vm.prank(_addr("alice"));
        OwnershipFacet(deployment.diamond).transferOwnership(address(this));
        _assertEqAddress(OwnershipFacet(deployment.diamond).owner(), address(this), "owner restored");
    }

    function test_DiamondInitRejectsInvalidTimelockControllers() public {
        BaseDeployment memory deployment = deployBase(address(this), treasury);
        DiamondInit initializer = new DiamondInit();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);

        vm.expectRevert(abi.encodeWithSelector(InvalidTimelockController.selector, _addr("alice")));
        IDiamondCut(deployment.diamond).diamondCut(
            cuts,
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, _addr("alice"), treasury, address(0))
        );

        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        TimelockController wrongDelay = new TimelockController(1 days, proposers, executors, address(this));

        vm.expectRevert(abi.encodeWithSelector(InvalidTimelockDelay.selector, 7 days, 1 days));
        IDiamondCut(deployment.diamond).diamondCut(
            cuts,
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, address(wrongDelay), treasury, address(0))
        );
    }

    function test_UnauthorizedDiamondCutIsRejected() public {
        BaseDeployment memory deployment = deployBase(address(this), treasury);
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);

        vm.prank(_addr("alice"));
        vm.expectRevert(bytes("LibDiamond: must be owner"));
        IDiamondCut(deployment.diamond).diamondCut(cuts, address(0), "");
    }

    function _assertEqAddress(address left, address right, string memory reason) internal pure {
        require(left == right, reason);
    }

    function _assertTrue(bool condition, string memory reason) internal pure {
        require(condition, reason);
    }

    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(label)))));
    }
}
