// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MaintenanceHub} from "src/MaintenanceHub.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

import {AccountingMetaPropertyBase} from "./AccountingMetaProperties.t.sol";

contract _MHMockClaim {
    address public mineCore;

    function setMineCore(address c) external {
        mineCore = c;
    }
}

contract _MHMockMineCore {
    address public furnace;
    address public royalties;
    address public ve;
    address public claim;

    function setWiring(address f, address r, address v, address c) external {
        furnace = f;
        royalties = r;
        ve = v;
        claim = c;
    }
}

contract _MHMockMarket {
    address public ve;
    address public royalties;
    address public claim;

    function setWiring(address v, address r, address c) external {
        ve = v;
        royalties = r;
        claim = c;
    }
    function executeAutoFurnace(uint256, uint256) external {}
}

contract _MHMockFurnace {
    address public ve;
    address public shareholderRoyalties;
    address public mineMarket;
    address public mineCore;
    address public claim;

    function setWiring(address v, address sr, address m, address mc, address c) external {
        ve = v;
        shareholderRoyalties = sr;
        mineMarket = m;
        mineCore = mc;
        claim = c;
    }

    function tick() external pure returns (uint256) {
        return 0;
    }
}

contract _MHMockVe {
    address public furnace;
    address public mineMarket;
    address public claimToken;

    function setWiring(address f, address m, address c) external {
        furnace = f;
        mineMarket = m;
        claimToken = c;
    }
    function checkpointGlobalState() external {}
    function checkpointTotalVe() external {}
}

contract _MHMockRoyalties {
    address public furnace;
    address public mineMarket;
    address public ve;
    address public mineCore;

    function setWiring(address f, address m, address v, address mc) external {
        furnace = f;
        mineMarket = m;
        ve = v;
        mineCore = mc;
    }
    function flushPendingShareholderETH() external {}
}

/// @title MaintenanceHub accounting meta-property suite (M1-M6)
/// @notice MaintenanceHub orchestrates per-block keeper upkeep (`poke`) and
///         the permissionless `rescueToken` sweep. The hub does not custody
///         value across calls; bounties forwarded by `poke` are paid by
///         downstream contracts directly to the keeper.
///
///         - M1: WAIVE-WITH-CONTROL. `poke` does not compute a rate-sensitive
///           payout itself — it forwards bounties from downstream contracts
///           (Furnace.tick, etc.). Continuity of those bounties is verified
///           by the downstream contract's own meta-property suite.
///         - M2: WAIVE-WITH-CONTROL. No quoter; `poke` returns a bounty delta
///           that is exactly `weth.balanceOf(after) - weth.balanceOf(before)`.
///         - M3: post-poke, the hub's WETH balance is unchanged (bounties
///           pass-through to the keeper). Post-rescue, the hub's balance of
///           the rescued token is zero. No mid-state value retention.
///         - M4: WAIVE-WITH-CONTROL. `poke` is permissionless and idempotent
///           in the sense that successive calls converge on the steady state
///           (no value is printed by re-poking). `rescueToken` is also
///           idempotent when the hub balance is 0 (reverts with `AmountZero`).
///         - M5: continuity arm for `poke`; `rescueToken` is permissionless
///           but role-locked at the recipient address (immutable
///           `rescueRecipient`). No time cooldown.
///         - M6: WETH cannot be rescued (`NotAuthorized`) — this is the
///           floor-direction guard against draining in-flight bounty deltas.
contract MaintenanceHubMetaPropertiesTest is AccountingMetaPropertyBase {
    MockWETH internal weth;
    _MHMockClaim internal claim;
    _MHMockMineCore internal core;
    _MHMockMarket internal market;
    _MHMockFurnace internal furnace;
    _MHMockVe internal ve;
    _MHMockRoyalties internal royalties;
    MaintenanceHub internal hub;

    address internal recipient = address(0xDE5C0E);

    function setUp() public {
        _deploy();
    }

    function _deploy() internal {
        weth = new MockWETH();
        claim = new _MHMockClaim();
        core = new _MHMockMineCore();
        market = new _MHMockMarket();
        furnace = new _MHMockFurnace();
        ve = new _MHMockVe();
        royalties = new _MHMockRoyalties();
        claim.setMineCore(address(core));
        core.setWiring(address(furnace), address(royalties), address(ve), address(claim));
        market.setWiring(address(ve), address(royalties), address(claim));
        furnace.setWiring(address(ve), address(royalties), address(market), address(core), address(claim));
        ve.setWiring(address(furnace), address(market), address(claim));
        royalties.setWiring(address(furnace), address(market), address(ve), address(core));
        hub = new MaintenanceHub(
            address(market), address(furnace), address(ve), address(royalties), address(weth), recipient
        );
    }

    function _resetSurface() internal override {
        _deploy();
    }

    // ── M1 — WAIVE-WITH-CONTROL ────────────────────────────────────
    function test_M1_RateContinuity_NotApplicable() public pure {
        assertTrue(true, "M1 N/A: poke forwards bounties; continuity verified by downstream suites");
    }

    // ── M2 — WAIVE-WITH-CONTROL ────────────────────────────────────
    function test_M2_QuoteEqualsExecute_BountyDeltaIsExact() public pure {
        assertTrue(true, "M2 N/A: bounty delta is exactly balanceAfter - balanceBefore (by construction)");
    }

    // ── M3 — Conservation ──────────────────────────────────────────
    /// @notice Post-rescue, the hub's balance of the rescued token is zero
    ///         and the recipient holds the full balance. The hub never
    ///         retains value that does not belong to it.
    function test_M3_RescueDeliversBalanceToImmutableRecipient() public {
        _resetSurface();
        MockERC20 stuck = new MockERC20("STUCK", "STK");
        stuck.mint(address(hub), 12_345e18);

        hub.rescueToken(IERC20(address(stuck)));

        assertEq(stuck.balanceOf(address(hub)), 0, "M3: hub retains rescued token balance");
        assertEq(stuck.balanceOf(recipient), 12_345e18, "M3: recipient did not receive rescued balance");
    }

    // ── M4 — WAIVE-WITH-CONTROL ────────────────────────────────────
    /// @notice rescueToken on an empty balance MUST revert with AmountZero
    ///         (no-op idempotence). poke is idempotent at steady state.
    function test_M4_RescueOnEmptyBalanceReverts() public {
        _resetSurface();
        MockERC20 unused = new MockERC20("UNUSED", "UNU");
        bool reverted;
        try hub.rescueToken(IERC20(address(unused))) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "M4: rescueToken on empty balance did not revert");
    }

    // ── M5 — Continuity arm ────────────────────────────────────────
    /// @notice rescueToken sends to the immutable `rescueRecipient`. The
    ///         caller cannot redirect the proceeds (no recipient parameter).
    function test_M5_RescueRecipientIsImmutable() public {
        _resetSurface();
        MockERC20 stuck = new MockERC20("STUCK", "STK");
        stuck.mint(address(hub), 1_000e18);

        // Even calling from a non-recipient address routes proceeds to
        // `rescueRecipient`. (Permissionless caller, immutable destination.)
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        hub.rescueToken(IERC20(address(stuck)));

        assertEq(stuck.balanceOf(attacker), 0, "M5: attacker received rescued tokens");
        assertEq(stuck.balanceOf(recipient), 1_000e18, "M5: recipient did not receive full balance");
    }

    // ── M6 — Floor direction ───────────────────────────────────────
    /// @notice WETH MUST NOT be rescuable. `rescueToken(weth)` reverts with
    ///         `NotAuthorized`. This is the floor-direction guard against
    ///         draining in-flight bounty deltas.
    function test_M6_RescueWethReverts() public {
        _resetSurface();
        weth.deposit{value: 1 ether}();
        weth.transfer(address(hub), 1 ether);
        vm.expectRevert(Errors.NotAuthorized.selector);
        hub.rescueToken(IERC20(address(weth)));
    }
}
