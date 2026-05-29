// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {EchidnaSetup} from "../EchidnaSetup.sol";

/// @title ClaimToken supply-conservation worst-case search.
/// @notice Optimization-mode harness. Targets supply drift, self-balance leak,
///         and post-freeze configuration mutability. Each `optimize_*`
///         function returns an `int256` Echidna maximizes; positive values
///         indicate a conservation violation.
contract EchidnaClaimTokenOptimize is EchidnaSetup {
    address[3] internal actors;

    int256 internal worstSelfBalanceLeak;
    int256 internal worstSumAboveSupply;
    int256 internal worstUnauthorizedMintCount;

    constructor() payable {
        _deployAndWire();
        actors[0] = address(0x20000);
        actors[1] = address(0x30000);
        actors[2] = address(0x40000);
    }

    // ================================================================
    // Actions
    // ================================================================

    function action_takeover() public payable {
        uint256 price = mineCore.getCurrentTakeoverPrice();
        if (msg.value < price) return;
        try mineCore.takeover{value: price}(type(uint256).max) {} catch {}
    }

    function action_burn(uint256 amount) public {
        uint256 bal = claim.balanceOf(msg.sender);
        if (bal == 0) return;
        if (amount == 0) amount = 1;
        if (amount > bal) amount = bal;
        try claim.burn(amount) {} catch {}
    }

    function action_transfer(uint256 actorIdx, uint256 amount) public {
        address to = actors[actorIdx % 3];
        uint256 bal = claim.balanceOf(msg.sender);
        if (bal == 0 || amount == 0) return;
        if (amount > bal) amount = bal;
        try claim.transfer(to, amount) {} catch {}
    }

    function action_mint_unauthorized(uint256 actorIdx, uint256 amount) public {
        address to = actors[actorIdx % 3];
        if (amount == 0) amount = 1;
        if (amount > 1_000_000e18) amount = 1_000_000e18;
        // `claim.mint` is `onlyMineCore`. A successful mint from any other
        // sender is a role-gating violation; track the count.
        try claim.mint(to, amount) {
            int256 next = worstUnauthorizedMintCount + int256(uint256(1));
            if (next > worstUnauthorizedMintCount) worstUnauthorizedMintCount = next;
        } catch {}
    }

    function action_observeSelfBalanceLeak() public {
        uint256 self = claim.balanceOf(address(claim));
        int256 leak = int256(self);
        if (leak > worstSelfBalanceLeak) worstSelfBalanceLeak = leak;
    }

    function action_observeSumAboveSupply() public {
        uint256 sum = 0;
        for (uint256 i = 0; i < 3; i++) {
            sum += claim.balanceOf(actors[i]);
        }
        sum += claim.balanceOf(address(this));
        int256 above = int256(sum) - int256(claim.totalSupply());
        if (above > worstSumAboveSupply) worstSumAboveSupply = above;
    }

    // ================================================================
    // Optimization targets
    // ================================================================

    /// @notice Worst observed `balanceOf(claim)` (the token holding its own
    ///         supply). Must remain `<= 0`.
    function optimize_claim_selfBalanceLeak() public view returns (int256) {
        return worstSelfBalanceLeak;
    }

    /// @notice Worst observed surplus of `Σtracked balances` over
    ///         `totalSupply`. Must remain `<= 0`.
    function optimize_claim_sumAboveSupply() public view returns (int256) {
        return worstSumAboveSupply;
    }

    /// @notice Count of successful `mint` calls from a non-MineCore caller.
    ///         Must remain `<= 0` — the role gate is the only mint authority.
    function optimize_claim_unauthorizedMintCount() public view returns (int256) {
        return worstUnauthorizedMintCount;
    }
}
