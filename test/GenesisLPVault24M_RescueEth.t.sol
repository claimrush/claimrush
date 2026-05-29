// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {Errors} from "src/lib/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Recipient that rejects ETH transfers. No `receive()` or
///         `fallback()` is defined, so any ETH-bearing call reverts.
contract RejectEthRecipient {}

/// @notice Test coverage for GenesisLPVault24M.rescueEth().
contract GenesisLPVault24M_RescueEthTest is Test {
    MockERC20 internal lp;
    GenesisLPVault24M internal vault;

    address internal recipient = address(0xCAFE);
    address internal attacker = address(0xBAD);

    function setUp() public {
        lp = new MockERC20("LP", "LP");
        vault = new GenesisLPVault24M(address(lp), recipient);
    }

    // ── Happy path ─────────────────────────────────────────────────

    function test_rescueEth_sendsBalanceToRecipient() public {
        uint256 amount = 1.5 ether;
        vm.deal(address(vault), amount);

        vm.prank(recipient);
        vault.rescueEth();

        assertEq(address(vault).balance, 0, "vault should be drained");
        assertEq(recipient.balance, amount, "recipient should receive ETH");
    }

    function test_rescueEth_emitsTokenRescuedEvent() public {
        uint256 amount = 0.1 ether;
        vm.deal(address(vault), amount);

        vm.expectEmit(true, true, false, true, address(vault));
        emit GenesisLPVault24M.TokenRescued(address(0), recipient, amount);

        vm.prank(recipient);
        vault.rescueEth();
    }

    // ── Revert: no ETH to rescue ───────────────────────────────────

    function test_rescueEth_revertsWhenNoEth() public {
        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.NoTokenToRescue.selector);
        vault.rescueEth();
    }

    // ── Revert: only lpWithdrawRecipient ────────────────────────────

    function test_rescueEth_revertsForNonRecipient() public {
        vm.deal(address(vault), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(GenesisLPVault24M.OnlyLpWithdrawRecipient.selector);
        vault.rescueEth();
    }

    // ── Revert: recipient cannot receive ETH ────────────────────────

    function test_rescueEth_revertsWhenRecipientRejectsEth() public {
        RejectEthRecipient rejecter = new RejectEthRecipient();
        GenesisLPVault24M rejectVault = new GenesisLPVault24M(address(lp), address(rejecter));

        vm.deal(address(rejectVault), 1 ether);

        vm.prank(address(rejecter));
        vm.expectRevert(Errors.EthTransferFailed.selector);
        rejectVault.rescueEth();
    }

    // ── Double rescue ──────────────────────────────────────────────

    function test_rescueEth_secondCallRevertsWhenDrained() public {
        vm.deal(address(vault), 2 ether);

        vm.prank(recipient);
        vault.rescueEth();
        assertEq(recipient.balance, 2 ether);

        vm.prank(recipient);
        vm.expectRevert(GenesisLPVault24M.NoTokenToRescue.selector);
        vault.rescueEth();
    }

    // ── Fuzz: arbitrary ETH amount ─────────────────────────────────

    function testFuzz_rescueEth_transfersExactAmount(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(vault), amount);

        vm.prank(recipient);
        vault.rescueEth();

        assertEq(address(vault).balance, 0);
        assertEq(recipient.balance, amount);
    }
}
