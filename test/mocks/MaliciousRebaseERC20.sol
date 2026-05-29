// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC20 that rebases all balances by an adversary-controlled
///         factor, simulating Ampleforth-style supply changes.
/// @dev    `rebase(factorBps)` multiplies every recorded balance by
///         `factorBps / 10_000` at the next access. Used by adversarial
///         harnesses to verify that the protocol either rejects rebase
///         tokens at the entry registry or maintains accounting integrity
///         when a balance unexpectedly changes between approve and pull.
contract MaliciousRebaseERC20 is ERC20 {
    uint256 internal constant SCALE_DENOM = 1e18;

    /// @notice Cumulative rebase scalar applied on every `balanceOf` read and
    ///         every `_update`. Stored as a `1e18`-scaled fixed-point number.
    uint256 public scale = SCALE_DENOM;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        uint256 raw = (amount * SCALE_DENOM) / scale;
        _mint(to, raw);
    }

    /// @notice Apply a multiplicative rebase. `factorBps == 10_000` is a no-op,
    ///         `< 10_000` shrinks all balances, `> 10_000` grows them.
    function rebase(uint256 factorBps) external {
        require(factorBps != 0, "factor=0");
        scale = (scale * factorBps) / 10_000;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return (super.balanceOf(account) * scale) / SCALE_DENOM;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return (super.totalSupply() * scale) / SCALE_DENOM;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        // Convert the user-facing `value` back to internal raw units before
        // delegating to the base `_update`. This matches the ratio used by
        // every other balance read.
        uint256 raw = (value * SCALE_DENOM) / scale;
        super._update(from, to, raw);
    }
}
