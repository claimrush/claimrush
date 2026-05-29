// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ClaimToken} from "../src/ClaimToken.sol";
import {Errors} from "../src/lib/Errors.sol";

/// @notice Hardening tests for ClaimToken.
contract ClaimToken_HardeningTest is Test {
    ClaimToken internal token;
    address internal owner = address(0xA1);

    // A mock MineCore that returns this ClaimToken from claim()
    MockMineCoreForClaim internal mockCore;

    function setUp() public {
        token = new ClaimToken(owner);
        mockCore = new MockMineCoreForClaim(address(token));

        vm.prank(owner);
        token.setMineCore(address(mockCore));
    }

    /// @dev After freezeConfig, setMineCore must revert.
    function test_freezeConfig_preventsSetMineCore() public {
        vm.prank(owner);
        token.freezeConfig();

        MockMineCoreForClaim newCore = new MockMineCoreForClaim(address(token));
        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        token.setMineCore(address(newCore));
    }

    /// @dev mint and burn still work after freeze.
    function test_mintAndBurn_workAfterFreeze() public {
        vm.prank(owner);
        token.freezeConfig();

        vm.prank(address(mockCore));
        token.mint(address(0xBEEF), 1000e18);
        assertEq(token.balanceOf(address(0xBEEF)), 1000e18);

        vm.prank(address(0xBEEF));
        token.burn(500e18);
        assertEq(token.balanceOf(address(0xBEEF)), 500e18);
    }

    /// @dev Non-mineCore cannot mint even after freeze.
    function testFuzz_onlyMineCore_canMint(address caller) public {
        vm.assume(caller != address(mockCore));
        vm.prank(owner);
        token.freezeConfig();

        vm.prank(caller);
        vm.expectRevert(Errors.OnlyMineCore.selector);
        token.mint(address(0xBEEF), 1e18);
    }

    /// @dev freezeConfig with zero mineCore reverts.
    function test_freezeConfig_revertsIfMineCoreZero() public {
        ClaimToken fresh = new ClaimToken(owner);
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
    }

    /// @dev freezeConfig must revert if mineCore code was destroyed
    ///      between setMineCore and freezeConfig (e.g. selfdestruct pre-Dencun).
    ///      Exercises the defensive code.length == 0 check at line 132.
    function test_freezeConfig_revertsIfMineCoreCodeDestroyed() public {
        // mineCore was wired in setUp; simulate code destruction
        vm.etch(address(mockCore), "");
        assertEq(address(mockCore).code.length, 0, "code should be cleared");

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        token.freezeConfig();
    }
}

/// @dev Minimal mock that satisfies the ClaimToken wiring check: claim() returns the token.
contract MockMineCoreForClaim {
    address public immutable claim;

    constructor(address _claim) {
        claim = _claim;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 1 days;
    }
}

