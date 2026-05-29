// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {EntryTokenRegistry} from "src/EntryTokenRegistry.sol";
import {Furnace} from "src/Furnace.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";

import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockWETH} from "./mocks/MockWETH.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MineCoreHarness} from "./mocks/MineCoreHarness.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";

contract RescueEthReentrantReceiver {
    MineCore internal immutable mineCore;

    /// @dev 1 = not invoked, 2 = reentry failed (expected), 3 = reentry succeeded (unexpected)
    uint256 public reentryFlag = 1;

    constructor(address mineCore_) {
        mineCore = MineCore(payable(mineCore_));
    }

    receive() external payable {
        (bool ok,) = address(mineCore).call(abi.encodeWithSignature("withdrawRefundBalance(address)", address(this)));
        reentryFlag = ok ? 3 : 2;
    }
}

/// @dev Cancun / EIP-6780 preserved the balance-transfer side of SELFDESTRUCT for contracts
///      created in a prior transaction. This helper force-sends ETH to MineCore without
///      executing MineCore.receive().
contract ForceEthSender {
    constructor() payable {}

    function boom(address payable target) external {
        selfdestruct(target);
    }
}

/// @notice MineCore.receive() must accept ETH only from the configured wrappedNative (WETH)
///         during takeoverWithToken* unwrap. All other inbound ETH reverts with
///         Errors.NotAuthorized() to prevent untracked-balance drift.
contract MineCore_ReceiveGuardTest is Test {
    address internal owner;
    address internal alice;

    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    Furnace internal furnace;
    MineCoreHarness internal mineCore;
    MockWETH internal weth;
    MockAerodromeRouter internal router;
    EntryTokenRegistry internal registry;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");
        alice = makeAddr("alice");

        claim = new ClaimToken(owner);
        ve = new MockVe();
        royalties = new ShareholderRoyalties(address(ve), owner);

        furnace = new Furnace(
            address(claim), address(ve), address(new FurnaceGuardHelper(address(claim), address(ve))), owner
        );
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        mineCore = new MineCoreHarness(address(claim), address(ve), address(royalties), owner);

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setShareholderRoyalties(address(royalties));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        vm.stopPrank();

        ve.setClaimToken(address(claim));
        ve.setFurnace(address(furnace));

        weth = new MockWETH();
        router = new MockAerodromeRouter(address(0xFACADE), address(weth));
    }

    function _wireRegistry() internal {
        registry = new EntryTokenRegistry(owner);
        vm.etch(router.defaultFactory(), hex"00");
        vm.startPrank(owner);
        registry.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        mineCore.setEntryTokenRegistry(address(registry));
        vm.stopPrank();
    }

    // ---- receive() guard ----

    function test_receive_rejectsUnsolicitedEthPreWiring() public {
        // entryTokenRegistry is still address(0) pre-wiring; receive() must revert.
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(mineCore).call{value: 1 ether}("");
        assertFalse(ok, "pre-wiring unsolicited ETH must revert");
    }

    function test_receive_rejectsUnsolicitedEthPostWiring() public {
        _wireRegistry();

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(mineCore).call{value: 1 ether}("");
        assertFalse(ok, "unsolicited ETH must revert");
    }

    function test_receive_rejectsEoaSendPostWiring() public {
        _wireRegistry();

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        (bool ok,) = address(mineCore).call{value: 2 ether}("");
        assertFalse(ok, "EOA plain send must revert");
    }

    function test_receive_acceptsEthFromConfiguredWeth() public {
        _wireRegistry();

        // Fund the WETH contract with native ETH so it has backing to send.
        vm.deal(address(weth), 3 ether);

        uint256 balBefore = address(mineCore).balance;

        // Simulate WETH itself calling MineCore with ETH (what IWETH.withdraw does).
        vm.prank(address(weth));
        (bool ok,) = address(mineCore).call{value: 3 ether}("");
        assertTrue(ok, "WETH-as-sender must succeed");

        assertEq(address(mineCore).balance, balBefore + 3 ether);
    }

    function test_receive_rejectsEthFromDifferentWethAddress() public {
        _wireRegistry();

        // Deploy a second WETH-like contract that is NOT the configured wrappedNative.
        MockWETH otherWeth = new MockWETH();
        vm.deal(address(otherWeth), 1 ether);

        vm.prank(address(otherWeth));
        (bool ok,) = address(mineCore).call{value: 1 ether}("");
        assertFalse(ok, "non-registered WETH must revert");
    }

    function test_receive_rejectsEthFromRegistryItself() public {
        _wireRegistry();

        // Registry is not allowed to send ETH; only the WETH address is.
        vm.deal(address(registry), 1 ether);
        vm.prank(address(registry));
        (bool ok,) = address(mineCore).call{value: 1 ether}("");
        assertFalse(ok, "registry-as-sender must revert");
    }

    function test_receive_stillAcceptsWethAfterEntryTokenRegistryRewire() public {
        _wireRegistry();

        // Rewire to a new registry pointing to the SAME WETH.
        EntryTokenRegistry reg2 = new EntryTokenRegistry(owner);
        vm.startPrank(owner);
        reg2.setRouterConfig(address(router), router.defaultFactory(), address(weth), address(claim));
        mineCore.setEntryTokenRegistry(address(reg2));
        vm.stopPrank();

        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (bool ok,) = address(mineCore).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_receive_tracksCurrentRegistryWrappedNativeAfterOwnerRewire() public {
        _wireRegistry();

        MockWETH rogueWeth = new MockWETH();
        MockEntryTokenRegistry rogueRegistry = new MockEntryTokenRegistry();
        rogueRegistry.setRouterConfig(address(0x1234), address(0x5678), address(rogueWeth), address(claim));

        vm.prank(owner);
        mineCore.setEntryTokenRegistry(address(rogueRegistry));

        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (bool oldOk,) = address(mineCore).call{value: 1 ether}("");
        assertFalse(oldOk, "old wrappedNative must stop working after registry rewire");

        vm.deal(address(rogueWeth), 2 ether);
        vm.prank(address(rogueWeth));
        (bool newOk,) = address(mineCore).call{value: 2 ether}("");
        assertTrue(newOk, "receive() should follow the live registry's wrappedNative");
    }

    function test_receive_rescueEthStillWorksWithRescuableBalance() public {
        _wireRegistry();

        // Simulate untracked surplus by impersonating WETH sender (the only legit path).
        vm.deal(address(weth), 0.5 ether);
        vm.prank(address(weth));
        (bool ok,) = address(mineCore).call{value: 0.5 ether}("");
        assertTrue(ok);

        address sink = makeAddr("rescueSink");
        uint256 sinkBalBefore = sink.balance;

        vm.prank(owner);
        mineCore.rescueEth(sink);

        // With no tracked buckets, everything is rescuable.
        assertEq(sink.balance - sinkBalBefore, 0.5 ether);
        assertEq(address(mineCore).balance, 0);
    }

    function test_rescueEth_reentrantRecipientCannotReenterNonReentrantPath() public {
        _wireRegistry();

        vm.deal(address(weth), 0.75 ether);
        vm.prank(address(weth));
        (bool ok,) = address(mineCore).call{value: 0.75 ether}("");
        assertTrue(ok, "WETH send should seed rescuable balance");

        RescueEthReentrantReceiver sink = new RescueEthReentrantReceiver(address(mineCore));

        vm.prank(owner);
        mineCore.rescueEth(address(sink));

        assertEq(sink.reentryFlag(), 2, "reentrant withdraw attempt must fail under nonReentrant");
        assertEq(address(mineCore).balance, 0, "rescue should still drain the rescuable balance");
    }

    function test_receive_forceSentEthBypassesGuardAndRemainsRescuable() public {
        _wireRegistry();

        ForceEthSender sender = new ForceEthSender{value: 0.6 ether}();
        uint256 senderCodeBefore = address(sender).code.length;
        assertGt(senderCodeBefore, 0, "helper should be deployed before selfdestruct");

        sender.boom(payable(address(mineCore)));

        assertEq(address(mineCore).balance, 0.6 ether, "forced ETH should arrive despite receive() guard");
        assertGt(address(sender).code.length, 0, "Cancun keeps code for pre-existing selfdestructed contracts");

        address sink = makeAddr("forcedEthSink");
        vm.prank(owner);
        mineCore.rescueEth(sink);

        assertEq(sink.balance, 0.6 ether, "forced ETH should be recoverable via rescueEth");
        assertEq(address(mineCore).balance, 0, "rescue should drain the forced ETH");
    }
}
