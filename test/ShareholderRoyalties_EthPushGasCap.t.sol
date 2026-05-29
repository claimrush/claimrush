// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockContract} from "./mocks/MockContract.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {ShareholderRoyaltiesHarness} from "./mocks/ShareholderRoyaltiesHarness.sol";

/// @dev Reverts with a specific message so we can distinguish intentional OOG (cap hit)
///      from logic reverts.
contract _CapTarget_GreedyConsumer {
    uint256 public consumed;

    receive() external payable {
        uint256 start = gasleft();
        // Burn any gas forwarded. If callGas == cap the recipient runs out and the push returns false.
        while (gasleft() > 2000) {
            consumed = consumed + 1;
        }
        // Record how much was burned (useful for diagnostics, ignored by tests).
        consumed = start - gasleft();
    }
}

contract _CapTarget_SimpleReceive {
    uint256 public hits;

    receive() external payable {
        hits += 1;
    }
}

/// @dev Burns ~200k gas inside `receive()` and then returns cleanly. Models a
///      smart-wallet / ERC-4337 recipient whose callback is too expensive for the default
///      100k cap but fits comfortably inside the 500k ceiling.
contract _CapTarget_HeavyButFinite {
    uint256 public hits;
    uint256 private _sink;

    receive() external payable {
        uint256 start = gasleft();
        uint256 target = start > 200_000 ? start - 200_000 : 0;
        uint256 n;
        while (gasleft() > target) {
            n = n + 1;
            _sink = n;
        }
        hits += 1;
    }
}

contract ShareholderRoyalties_EthPushGasCapTest is Test {
    ShareholderRoyaltiesHarness internal royalties;
    address internal owner;
    address internal alice;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");

        MockVe ve = new MockVe();
        royalties = new ShareholderRoyaltiesHarness(address(ve), owner);
    }

    // ---- Storage + defaults ----

    function test_ethPushGasCap_defaultIs200k() public view {
        assertEq(royalties.ethPushGasCap(), 200_000);
    }

    // ---- Setter bounds ----

    function test_setEthPushGasCap_acceptsMin() public {
        vm.expectEmit(false, false, false, true, address(royalties));
        emit Events.EthPushGasCapSet(200_000, 50_000);

        vm.prank(owner);
        royalties.setEthPushGasCap(50_000);

        assertEq(royalties.ethPushGasCap(), 50_000);
    }

    function test_setEthPushGasCap_acceptsMax() public {
        vm.prank(owner);
        royalties.setEthPushGasCap(500_000);
        assertEq(royalties.ethPushGasCap(), 500_000);
    }

    function test_setEthPushGasCap_acceptsMidRange() public {
        vm.prank(owner);
        royalties.setEthPushGasCap(150_000);
        assertEq(royalties.ethPushGasCap(), 150_000);
    }

    function test_setEthPushGasCap_revertsBelowMin() public {
        vm.prank(owner);
        vm.expectRevert(Errors.AmountTooLarge.selector);
        royalties.setEthPushGasCap(49_999);
    }

    function test_setEthPushGasCap_revertsAtZero() public {
        vm.prank(owner);
        vm.expectRevert(Errors.AmountTooLarge.selector);
        royalties.setEthPushGasCap(0);
    }

    function test_setEthPushGasCap_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(Errors.AmountTooLarge.selector);
        royalties.setEthPushGasCap(500_001);
    }

    function test_setEthPushGasCap_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        royalties.setEthPushGasCap(200_000);
    }

    // ---- Behavioral: cap actually gates forwarded gas ----

    function test_ethPush_simpleReceive_succeedsAtDefaultCap() public {
        _CapTarget_SimpleReceive target = new _CapTarget_SimpleReceive();

        vm.deal(address(royalties), 1 ether);
        bool ok = royalties.exposed_callWithValueNoReturndata(address(target), 0.1 ether);

        assertTrue(ok);
        assertEq(target.hits(), 1);
        assertEq(address(target).balance, 0.1 ether);
    }

    function test_ethPush_greedyConsumer_failsAtDefaultCap() public {
        _CapTarget_GreedyConsumer target = new _CapTarget_GreedyConsumer();

        vm.deal(address(royalties), 1 ether);
        bool ok = royalties.exposed_callWithValueNoReturndata(address(target), 0.1 ether);

        assertFalse(ok, "push must fail when recipient burns past cap");
        assertEq(address(target).balance, 0, "no ETH should transfer on revert");
    }

    function test_ethPush_heavyRecipient_succeedsOnlyWhenCapRaised() public {
        // A smart-wallet-style recipient that needs ~200k gas to run its receive callback
        // cleanly. At the default 100k cap the push must fail; at a raised cap (>= ~250k) it
        // must succeed and transfer ETH.
        _CapTarget_HeavyButFinite target = new _CapTarget_HeavyButFinite();

        vm.deal(address(royalties), 1 ether);

        // Default cap (100k) — push fails, no ETH transferred, recipient state untouched.
        bool okDefault = royalties.exposed_callWithValueNoReturndata{gas: 1_000_000}(address(target), 0.1 ether);
        assertFalse(okDefault, "heavy recipient must fail under default 100k cap");
        assertEq(address(target).balance, 0, "no ETH should transfer when push fails");
        assertEq(target.hits(), 0, "callee state must revert on OOG");

        // Raise cap to the 500k ceiling — push now succeeds and recipient runs its callback.
        vm.prank(owner);
        royalties.setEthPushGasCap(500_000);

        bool okRaised = royalties.exposed_callWithValueNoReturndata{gas: 1_000_000}(address(target), 0.1 ether);
        assertTrue(okRaised, "heavy recipient must succeed once cap is raised");
        assertEq(address(target).balance, 0.1 ether, "ETH must transfer on success");
        assertEq(target.hits(), 1, "callee callback must run to completion");
    }

    function test_ethPush_EOA_alwaysSucceeds() public {
        address eoa = makeAddr("eoa_recipient");
        vm.deal(address(royalties), 1 ether);

        bool ok = royalties.exposed_callWithValueNoReturndata(eoa, 0.1 ether);
        assertTrue(ok);
        assertEq(eoa.balance, 0.1 ether);
    }

    function test_ethPush_capLoweredToMinStillFundsEOA() public {
        vm.prank(owner);
        royalties.setEthPushGasCap(50_000);

        address eoa = makeAddr("eoa_recipient");
        vm.deal(address(royalties), 1 ether);

        bool ok = royalties.exposed_callWithValueNoReturndata(eoa, 0.05 ether);
        assertTrue(ok);
        assertEq(eoa.balance, 0.05 ether);
    }

    function test_setEthPushGasCap_emitsEventWithOldAndNewValues() public {
        vm.prank(owner);
        royalties.setEthPushGasCap(200_000);

        vm.expectEmit(false, false, false, true, address(royalties));
        emit Events.EthPushGasCapSet(200_000, 350_000);

        vm.prank(owner);
        royalties.setEthPushGasCap(350_000);
    }
}
