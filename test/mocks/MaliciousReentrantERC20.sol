// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC20 that calls back into a configurable target on every
///         transfer, simulating ERC-777 / hookful tokens.
/// @dev    Used by adversarial harnesses to verify reentrancy guards on every
///         path that pulls an entry token. The callback fires on both `from`
///         and `to` sides; harnesses set `reentrantTarget` and `reentrantData`
///         to drive a reentrant call back into the protocol mid-transfer.
contract MaliciousReentrantERC20 is ERC20 {
    address public reentrantTarget;
    bytes public reentrantData;
    bool internal _entered;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Configure the reentrancy callback. Set `target == address(0)`
    ///         to disable the callback (transfer behaves as plain ERC20).
    function setReentrantCall(address target, bytes calldata data) external {
        reentrantTarget = target;
        reentrantData = data;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        if (reentrantTarget != address(0) && !_entered) {
            _entered = true;
            (bool ok,) = reentrantTarget.call(reentrantData);
            // Suppress revert so the outer transfer can complete; the protocol
            // under test is what must catch and reject the reentrant call via
            // its own ReentrancyGuard.
            ok;
            _entered = false;
        }
    }
}
