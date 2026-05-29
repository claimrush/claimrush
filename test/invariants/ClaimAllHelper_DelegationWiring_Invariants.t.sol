// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {Errors} from "src/lib/Errors.sol";

contract ClaimAllHelperInvariantMineCoreMock {
    address public royalties;
    address public claimAllHelper;
    address public delegationHub;
    address public furnace;

    uint256 public withdrawCalls;

    function setRoyalties(address v) external {
        royalties = v;
    }

    function setClaimAllHelper(address v) external {
        claimAllHelper = v;
    }

    function setDelegationHub(address v) external {
        delegationHub = v;
    }

    function setFurnace(address v) external {
        furnace = v;
    }

    function withdrawKingBalanceFor(address) external {
        withdrawCalls += 1;
    }
}

contract ClaimAllHelperInvariantRoyaltiesMock {
    address public mineCore;
    address public claimAllHelper;
    address public furnace;

    uint256 public calls;

    function setMineCore(address v) external {
        mineCore = v;
    }

    function setClaimAllHelper(address v) external {
        claimAllHelper = v;
    }

    function setFurnace(address v) external {
        furnace = v;
    }

    function claimShareholderFor(address, uint8, uint256, uint256, bool, uint256) external {
        calls += 1;
    }
}

contract ClaimAllHelperInvariantFurnaceMock {
    address public mineCore;
    address public shareholderRoyalties;
    address public delegationHub;

    function setMineCore(address v) external {
        mineCore = v;
    }

    function setShareholderRoyalties(address v) external {
        shareholderRoyalties = v;
    }

    function setDelegationHub(address v) external {
        delegationHub = v;
    }
}

contract ClaimAllHelperInvariantDelegationHubMock {
    bool public authorized;

    function setAuthorized(bool v) external {
        authorized = v;
    }

    function isAuthorized(address, address, uint256) external view returns (bool) {
        return authorized;
    }
}

/// @dev Delegated helper flows must resolve the canonical hub from the live
///      MineCore/Furnace/ShareholderRoyalties bundle, not from a raw stored pointer alone.
contract ClaimAllHelperDelegationWiringInvariants is Test {
    ClaimAllHelper internal helper;
    ClaimAllHelperInvariantMineCoreMock internal mineCore;
    ClaimAllHelperInvariantRoyaltiesMock internal royalties;
    ClaimAllHelperInvariantFurnaceMock internal furnace;
    ClaimAllHelperInvariantDelegationHubMock internal hub;

    address internal user = address(0xA11CE);
    address internal delegate = address(0xB0B);

    function setUp() public {
        mineCore = new ClaimAllHelperInvariantMineCoreMock();
        royalties = new ClaimAllHelperInvariantRoyaltiesMock();
        furnace = new ClaimAllHelperInvariantFurnaceMock();
        hub = new ClaimAllHelperInvariantDelegationHubMock();
        helper = new ClaimAllHelper(address(royalties), address(mineCore));

        _wireCanonical(address(furnace), address(hub));
    }

    function _wireCanonical(address furnaceAddr, address hubAddr) internal {
        mineCore.setRoyalties(address(royalties));
        mineCore.setClaimAllHelper(address(helper));
        mineCore.setDelegationHub(hubAddr);
        mineCore.setFurnace(furnaceAddr);

        royalties.setMineCore(address(mineCore));
        royalties.setClaimAllHelper(address(helper));
        royalties.setFurnace(furnaceAddr);

        ClaimAllHelperInvariantFurnaceMock(furnaceAddr).setMineCore(address(mineCore));
        ClaimAllHelperInvariantFurnaceMock(furnaceAddr).setShareholderRoyalties(address(royalties));
        ClaimAllHelperInvariantFurnaceMock(furnaceAddr).setDelegationHub(hubAddr);
    }

    function testCanonicalDelegatedFlowsAcceptWhenLiveBundleAgrees() public {
        hub.setAuthorized(true);

        // The delegated bundle path is ETH-only (mode = 0) by design.
        vm.startPrank(delegate);
        helper.withdrawKingBalanceForUser(user);
        helper.claimAllFor(user, 0, 0, 0, false, 0);
        vm.stopPrank();

        assertEq(mineCore.withdrawCalls(), 2);
        assertEq(royalties.calls(), 1);
    }

    function testDelegatedWithdrawRejectsForeignMineCoreHubRoot() public {
        hub.setAuthorized(true);
        ClaimAllHelperInvariantDelegationHubMock otherHub = new ClaimAllHelperInvariantDelegationHubMock();
        otherHub.setAuthorized(true);
        mineCore.setDelegationHub(address(otherHub));

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.withdrawKingBalanceForUser(user);
    }

    function testDelegatedClaimAllRejectsSplitBrainFurnaceBundle() public {
        hub.setAuthorized(true);
        ClaimAllHelperInvariantFurnaceMock otherFurnace = new ClaimAllHelperInvariantFurnaceMock();
        otherFurnace.setMineCore(address(mineCore));
        otherFurnace.setShareholderRoyalties(address(royalties));
        otherFurnace.setDelegationHub(address(hub));
        mineCore.setFurnace(address(otherFurnace));

        vm.prank(delegate);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.claimAllFor(user, 1, 77, 180 days, true, 42);
    }
}
