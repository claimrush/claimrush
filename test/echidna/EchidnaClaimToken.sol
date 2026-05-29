// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Echidna harness for ClaimToken supply conservation and access-control invariants.
/// @dev Invariants from the invariants document Section 1 (CLAIM token).
contract EchidnaClaimToken is EchidnaSetup {
    address[3] internal actors;

    uint256 internal ghostMinted;
    uint256 internal ghostBurned;
    bool internal sawFrozen;
    address internal mineCoreAtFreeze;

    constructor() payable {
        _deployAndWire();
        actors[0] = address(0x20000);
        actors[1] = address(0x30000);
        actors[2] = address(0x40000);
    }

    // ================================================================
    // Actions
    // ================================================================

    /// @dev Takeover to generate CLAIM emissions via MineCore (the only legitimate minter).
    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;

        uint256 supplyBefore = claim.totalSupply();
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
        uint256 supplyAfter = claim.totalSupply();

        if (supplyAfter > supplyBefore) {
            ghostMinted += (supplyAfter - supplyBefore);
        }
    }

    /// @dev Burn CLAIM held by the caller.
    function action_burn(uint256 amount) public {
        uint256 bal = claim.balanceOf(msg.sender);
        if (bal == 0) return;
        if (amount == 0) amount = 1;
        if (amount > bal) amount = bal;

        uint256 supplyBefore = claim.totalSupply();
        try claim.burn(amount) {}
        catch {
            return;
        }
        uint256 supplyAfter = claim.totalSupply();

        if (supplyBefore > supplyAfter) {
            ghostBurned += (supplyBefore - supplyAfter);
        }
    }

    /// @dev Transfer CLAIM between actors.
    function action_transfer(uint256 actorIdx, uint256 amount) public {
        address to = actors[actorIdx % 3];
        uint256 bal = claim.balanceOf(msg.sender);
        if (bal == 0 || amount == 0) return;
        if (amount > bal) amount = bal;
        try claim.transfer(to, amount) {} catch {}
    }

    /// @dev Attempt direct mint from a non-mineCore caller (should always fail).
    function action_mint_unauthorized(uint256 actorIdx, uint256 amount) public {
        address to = actors[actorIdx % 3];
        if (amount == 0) amount = 1;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        try claim.mint(to, amount) {} catch {}
    }

    /// @dev Attempt transfer to the token contract itself (should always revert).
    function action_transfer_to_self(uint256 amount) public {
        uint256 bal = claim.balanceOf(msg.sender);
        if (bal == 0 || amount == 0) return;
        if (amount > bal) amount = bal;
        try claim.transfer(address(claim), amount) {} catch {}
    }

    /// @dev Snapshot frozen state so we can assert permanence.
    function action_snapshot_freeze() public {
        if (claim.configFrozen() && !sawFrozen) {
            sawFrozen = true;
            mineCoreAtFreeze = claim.mineCore();
        }
    }

    // ================================================================
    // Properties
    // ================================================================

    /// @dev Invariant: totalSupply == ghostMinted - ghostBurned.
    function echidna_supply_conservation() public view returns (bool) {
        return claim.totalSupply() == ghostMinted - ghostBurned;
    }

    /// @dev Invariant: ClaimToken itself must never hold any CLAIM (restricted recipient).
    function echidna_no_self_balance() public view returns (bool) {
        return claim.balanceOf(address(claim)) == 0;
    }

    /// @dev Invariant: once configFrozen is true it stays true.
    function echidna_freeze_permanence() public view returns (bool) {
        if (sawFrozen) {
            return claim.configFrozen();
        }
        return true;
    }

    /// @dev Invariant: once frozen, mineCore address never changes.
    function echidna_minecore_immutable_after_freeze() public view returns (bool) {
        if (sawFrozen) {
            return claim.mineCore() == mineCoreAtFreeze;
        }
        return true;
    }

    /// @dev Invariant: mineCore is always set (post-deployment).
    function echidna_minecore_set() public view returns (bool) {
        return claim.mineCore() != address(0);
    }

    /// @dev Invariant: sum of all tracked actor balances <= totalSupply.
    function echidna_balance_leq_supply() public view returns (bool) {
        uint256 sum = 0;
        for (uint256 i = 0; i < 3; i++) {
            sum += claim.balanceOf(actors[i]);
        }
        sum += claim.balanceOf(address(this));
        return sum <= claim.totalSupply();
    }
}
