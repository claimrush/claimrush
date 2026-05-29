// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";

contract ClaimTokenTest is Test {
    ClaimToken internal claim;

    address internal owner = address(0xA11CE);
    address internal mineCore;
    address internal alice = address(0xA);
    address internal bob = address(0xB);

    function setUp() public {
        claim = new ClaimToken(owner);
        mineCore = address(new MineCoreClaimViewMock(address(claim)));
    }

    function testTokenMetadataIsCorrect() public {
        assertEq(claim.name(), "ClaimRush");
        assertEq(claim.symbol(), "CLAIM");
        assertEq(claim.decimals(), 18);
    }

    function testInitialSupplyIsZero() public {
        assertEq(claim.totalSupply(), 0);
        assertEq(claim.balanceOf(alice), 0);
        assertEq(claim.mineCore(), address(0));
    }

    function testSetMineCoreOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        claim.setMineCore(mineCore);
    }

    function testSetMineCoreRevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        claim.setMineCore(address(0));
    }

    function testSetMineCoreAcceptsCanonicalClaimRoot() public {
        vm.prank(owner);
        claim.setMineCore(mineCore);

        assertEq(claim.mineCore(), mineCore);
    }

    function testOnlyMineCoreCanMint() public {
        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineCore.selector);
        claim.mint(alice, 1);

        vm.prank(mineCore);
        claim.mint(alice, 100e18);

        assertEq(claim.balanceOf(alice), 100e18);
        assertEq(claim.totalSupply(), 100e18);
    }

    function testNoTransferFeesAndNoHiddenSupplyChanges() public {
        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.prank(mineCore);
        claim.mint(alice, 100e18);
        uint256 supplyBefore = claim.totalSupply();

        vm.prank(alice);
        assertTrue(claim.transfer(bob, 40e18));

        assertEq(claim.balanceOf(alice), 60e18);
        assertEq(claim.balanceOf(bob), 40e18);
        assertEq(claim.totalSupply(), supplyBefore);

        vm.prank(bob);
        claim.approve(alice, 10e18);

        vm.prank(alice);
        assertTrue(claim.transferFrom(bob, alice, 10e18));

        assertEq(claim.balanceOf(alice), 70e18);
        assertEq(claim.balanceOf(bob), 30e18);
        assertEq(claim.totalSupply(), supplyBefore);
    }

    function testBurnReducesSupply() public {
        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.prank(mineCore);
        claim.mint(alice, 100e18);

        vm.prank(alice);
        claim.burn(25e18);

        assertEq(claim.balanceOf(alice), 75e18);
        assertEq(claim.totalSupply(), 75e18);
    }

    function testBurnRevertsWhenInsufficientBalance() public {
        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.prank(mineCore);
        claim.mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert();
        claim.burn(2e18);
    }

    /// @dev `burnFrom` is not part of v1.0.0.
    function testBurnFromIsNotImplemented() public {
        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.prank(mineCore);
        claim.mint(alice, 1e18);

        (bool ok, bytes memory data) =
            address(claim).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1e18));

        assertFalse(ok, "burnFrom must not be implemented");
        assertEq(data.length, 0, "expected empty revert data for missing selector");
    }

    function testMintRevertsWhenToIsZero() public {
        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.prank(mineCore);
        vm.expectRevert();
        claim.mint(address(0), 1);
    }

    function testFreezeConfigStopsSetMineCore() public {
        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.prank(owner);
        claim.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        claim.setMineCore(address(0x1234));
    }

    function testSetMineCoreFailsClosedBeforeFreezeWhenClaimRootMismatches() public {
        address wrongMineCore = address(new MineCoreClaimViewMock(address(0xDEAD)));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        claim.setMineCore(wrongMineCore);
    }

    function testFuzz_setMineCoreRejectsAnyWrongClaimRoot(uint256 wrongRoot) public {
        vm.assume(wrongRoot != 0);
        vm.assume(wrongRoot != uint256(uint160(address(claim))));

        // forge-lint: disable-next-line(unsafe-typecast)
        address wrongMineCore = address(new MineCoreClaimViewMock(address(uint160(wrongRoot))));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        claim.setMineCore(wrongMineCore);
    }
}

contract MineCoreClaimViewMock {
    address public claim;

    constructor(address claim_) {
        claim = claim_;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 1 days;
    }
}
