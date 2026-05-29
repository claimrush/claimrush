// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Mock
// ═══════════════════════════════════════════════════════════════════════

/// @dev Minimal mock that satisfies the wiring check: claim() returns the configured token.
contract MockMineCorePostconditions {
    address public claim;
    uint256 public emissionStartTime = 1;
    uint256 public GENESIS_ACCRUAL_DURATION = 1;

    constructor(address _claim) {
        claim = _claim;
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Tests — (Formal postcondition verification)
// ═══════════════════════════════════════════════════════════════════════

/// @title ClaimToken formal postcondition and ERC-20 event correctness tests
/// @notice Covers:
///   Transfer event correctness for mint/burn
///   Re-wiring authority revocation
///   Formal postcondition verification (state after each function)
///
/// @dev Run: forge test --match-contract ClaimToken_Postconditions
contract ClaimToken_Postconditions is Test {
    ClaimToken internal token;
    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal mineCore;

    function setUp() public {
        token = new ClaimToken(owner);
        mineCore = address(new MockMineCorePostconditions(address(token)));

        vm.prank(owner);
        token.setMineCore(mineCore);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  ERC-20 Transfer event correctness
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verify mint emits Transfer(address(0), to, amount) per ERC-20
    function test_mint_emitsCorrectTransferEvent() public {
        uint256 amount = 500e18;

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, amount);

        vm.prank(mineCore);
        token.mint(alice, amount);
    }

    /// @notice Verify burn emits Transfer(msg.sender, address(0), amount) per ERC-20
    function test_burn_emitsCorrectTransferEvent() public {
        vm.prank(mineCore);
        token.mint(alice, 1000e18);

        uint256 burnAmount = 300e18;

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, address(0), burnAmount);

        vm.prank(alice);
        token.burn(burnAmount);
    }

    /// @notice Fuzz: mint always emits Transfer(0, to, amount) with correct values
    function testFuzz_mint_emitsTransferEvent(uint128 amount) public {
        vm.assume(amount > 0);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, uint256(amount));

        vm.prank(mineCore);
        token.mint(alice, uint256(amount));
    }

    /// @notice Fuzz: burn always emits Transfer(sender, 0, amount) with correct values
    function testFuzz_burn_emitsTransferEvent(uint128 mintAmt, uint128 burnAmt) public {
        vm.assume(mintAmt > 0);
        vm.assume(burnAmt > 0);
        vm.assume(burnAmt <= mintAmt);

        vm.prank(mineCore);
        token.mint(alice, uint256(mintAmt));

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, address(0), uint256(burnAmt));

        vm.prank(alice);
        token.burn(uint256(burnAmt));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Re-wiring authority revocation
    // ═══════════════════════════════════════════════════════════════════

    /// @notice After setMineCore(B), the previous mineCore A must be rejected
    function test_rewiring_oldMineCoreCannotMint() public {
        address mineCoreA = mineCore; // already set in setUp

        // Verify A can mint
        vm.prank(mineCoreA);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);

        // Re-wire to B
        address mineCoreB = address(new MockMineCorePostconditions(address(token)));
        vm.prank(owner);
        token.setMineCore(mineCoreB);

        // A is now revoked — must revert with OnlyMineCore
        vm.prank(mineCoreA);
        vm.expectRevert(Errors.OnlyMineCore.selector);
        token.mint(alice, 1e18);

        // B can mint
        vm.prank(mineCoreB);
        token.mint(bob, 200e18);
        assertEq(token.balanceOf(bob), 200e18);
    }

    /// @notice Re-wire back to original: A→B→A, both transitions revoke the outgoing core
    function test_rewiring_backAndForth() public {
        address mineCoreA = mineCore;
        address mineCoreB = address(new MockMineCorePostconditions(address(token)));

        // Wire to B
        vm.prank(owner);
        token.setMineCore(mineCoreB);

        // A is revoked
        vm.prank(mineCoreA);
        vm.expectRevert(Errors.OnlyMineCore.selector);
        token.mint(alice, 1);

        // Wire back to A
        vm.prank(owner);
        token.setMineCore(mineCoreA);

        // Now B is revoked
        vm.prank(mineCoreB);
        vm.expectRevert(Errors.OnlyMineCore.selector);
        token.mint(alice, 1);

        // A can mint again
        vm.prank(mineCoreA);
        token.mint(alice, 50e18);
        assertEq(token.balanceOf(alice), 50e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Formal postcondition verification
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Constructor postconditions: owner set, supply 0, mineCore 0, not frozen
    function test_postcondition_constructor() public {
        ClaimToken fresh = new ClaimToken(address(0xBEEF));

        assertEq(fresh.owner(), address(0xBEEF), "owner must be initialOwner");
        assertEq(fresh.totalSupply(), 0, "totalSupply must be 0");
        assertEq(fresh.mineCore(), address(0), "mineCore must be address(0)");
        assertFalse(fresh.configFrozen(), "configFrozen must be false");
        assertEq(fresh.name(), "ClaimRush", "name must be ClaimRush");
        assertEq(fresh.symbol(), "CLAIM", "symbol must be CLAIM");
        assertEq(fresh.decimals(), 18, "decimals must be 18");
    }

    /// @notice setMineCore postconditions: mineCore updated, event emitted
    function test_postcondition_setMineCore() public {
        ClaimToken fresh = new ClaimToken(owner);
        address core = address(new MockMineCorePostconditions(address(fresh)));

        address oldMineCore = fresh.mineCore();
        assertEq(oldMineCore, address(0));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Events.MineCoreChanged(address(0), core);
        fresh.setMineCore(core);

        assertEq(fresh.mineCore(), core, "mineCore must be updated");
        assertFalse(fresh.configFrozen(), "configFrozen must remain false");
        assertEq(fresh.owner(), owner, "owner must not change");
        assertEq(fresh.totalSupply(), 0, "totalSupply must not change");
    }

    /// @notice freezeConfig postconditions: configFrozen=true, mineCore unchanged
    function test_postcondition_freezeConfig() public {
        address currentMineCore = token.mineCore();
        uint256 currentSupply = token.totalSupply();

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Events.ConfigFrozen();
        token.freezeConfig();

        assertTrue(token.configFrozen(), "configFrozen must be true");
        assertEq(token.mineCore(), currentMineCore, "mineCore must not change");
        assertEq(token.owner(), owner, "owner must not change");
        assertEq(token.totalSupply(), currentSupply, "totalSupply must not change");
    }

    /// @notice mint postconditions: balance and totalSupply increase by exact amount
    function test_postcondition_mint() public {
        uint256 amount = 777e18;
        uint256 balBefore = token.balanceOf(alice);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(mineCore);
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), balBefore + amount, "balance must increase by amount");
        assertEq(token.totalSupply(), supplyBefore + amount, "totalSupply must increase by amount");
    }

    /// @notice burn postconditions: balance and totalSupply decrease by exact amount
    function test_postcondition_burn() public {
        vm.prank(mineCore);
        token.mint(alice, 1000e18);

        uint256 burnAmt = 333e18;
        uint256 balBefore = token.balanceOf(alice);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.burn(burnAmt);

        assertEq(token.balanceOf(alice), balBefore - burnAmt, "balance must decrease by amount");
        assertEq(token.totalSupply(), supplyBefore - burnAmt, "totalSupply must decrease by amount");
    }

    /// @notice renounceOwnership postconditions: owner=0, pendingOwner=0
    function test_postcondition_renounceOwnership() public {
        // Set a pending owner first, to verify it gets cleared
        vm.prank(owner);
        token.transferOwnership(alice);
        assertEq(token.pendingOwner(), alice);

        vm.prank(owner);
        token.freezeConfig();

        vm.prank(owner);
        token.renounceOwnership();

        assertEq(token.owner(), address(0), "owner must be address(0)");
        assertEq(token.pendingOwner(), address(0), "pendingOwner must be cleared");
        assertTrue(token.configFrozen(), "configFrozen must remain true");
    }

    /// @notice Full lifecycle: deploy → wire → freeze → renounce → verify terminal state
    function test_fullLifecycle_terminalState() public {
        // 1. Deploy
        ClaimToken t = new ClaimToken(owner);
        assertEq(t.mineCore(), address(0));
        assertFalse(t.configFrozen());

        // 2. Wire
        address core = address(new MockMineCorePostconditions(address(t)));
        vm.prank(owner);
        t.setMineCore(core);
        assertEq(t.mineCore(), core);

        // 3. Mint some tokens (proving minting works)
        vm.prank(core);
        t.mint(alice, 100e18);
        assertEq(t.totalSupply(), 100e18);

        // 4. Freeze
        vm.prank(owner);
        t.freezeConfig();
        assertTrue(t.configFrozen());

        // 5. Minting still works after freeze
        vm.prank(core);
        t.mint(bob, 50e18);
        assertEq(t.totalSupply(), 150e18);

        // 6. Renounce
        vm.prank(owner);
        t.renounceOwnership();
        assertEq(t.owner(), address(0));

        // 7. Terminal state: no admin functions possible
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        t.setMineCore(core);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        t.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        t.renounceOwnership();

        // 8. Minting and burning still work in terminal state
        vm.prank(core);
        t.mint(alice, 25e18);
        assertEq(t.totalSupply(), 175e18);

        vm.prank(alice);
        t.burn(10e18);
        assertEq(t.totalSupply(), 165e18);

        // 9. Transfers still work in terminal state
        vm.prank(alice);
        t.transfer(bob, 5e18);
        assertEq(t.balanceOf(bob), 55e18);
    }

    /// @notice Fuzz: postconditions hold for arbitrary mint+burn sequences
    function testFuzz_postcondition_mintBurnSequence(uint128 mint1, uint128 mint2, uint128 burn1) public {
        vm.assume(mint1 > 0);
        vm.assume(mint2 > 0);
        vm.assume(uint256(mint1) + uint256(mint2) < type(uint128).max);
        vm.assume(burn1 > 0);
        vm.assume(burn1 <= mint1);

        // Mint to alice
        vm.prank(mineCore);
        token.mint(alice, uint256(mint1));

        // Mint to bob
        vm.prank(mineCore);
        token.mint(bob, uint256(mint2));

        // Burn from alice
        vm.prank(alice);
        token.burn(uint256(burn1));

        // Postconditions
        uint256 expectedAlice = uint256(mint1) - uint256(burn1);
        uint256 expectedBob = uint256(mint2);
        uint256 expectedSupply = expectedAlice + expectedBob;

        assertEq(token.balanceOf(alice), expectedAlice, "alice balance postcondition");
        assertEq(token.balanceOf(bob), expectedBob, "bob balance postcondition");
        assertEq(token.totalSupply(), expectedSupply, "totalSupply postcondition");
    }
}
