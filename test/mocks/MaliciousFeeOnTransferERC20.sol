// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC20 that skims a configurable fee on every transfer.
/// @dev Used by adversarial Echidna harnesses to verify that the protocol
///      either rejects fee-on-transfer entry tokens at the registry layer
///      or never silently delivers less than the user requested when one
///      slips through.
///
///      The fee is taken from the recipient's incoming amount, mirroring the
///      common fee-on-transfer pattern (USDT-style and Reflect-style tokens).
contract MaliciousFeeOnTransferERC20 is ERC20 {
    /// @notice Fee in basis points skimmed from each transfer (max 10_000).
    uint256 public feeBps;

    /// @notice Address that receives skimmed fees.
    address public feeSink;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_, address feeSink_) ERC20(name_, symbol_) {
        require(feeBps_ <= 10_000, "fee>100%");
        feeBps = feeBps_;
        feeSink = feeSink_ == address(0) ? address(this) : feeSink_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 newFeeBps) external {
        require(newFeeBps <= 10_000, "fee>100%");
        feeBps = newFeeBps;
    }

    /// @dev Override the internal `_update` so the fee skim runs uniformly on
    ///      `transfer`, `transferFrom`, and any future ERC20 mutator.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        uint256 net = value - fee;
        super._update(from, to, net);
        if (fee != 0) super._update(from, feeSink, fee);
    }
}
