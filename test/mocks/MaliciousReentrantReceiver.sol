// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Mock contract that attempts a configurable reentrant call back
///         into the caller on every ETH receive.
/// @dev    Used by adversarial Echidna harnesses to verify that ETH-paying
///         paths in MineCore (king payout), ShareholderRoyalties (claim),
///         MarketRouter (refund), and GenesisLPVault24M (rescue) hold their
///         `nonReentrant` modifiers under attack.
///
///         The harness sets `reentrantTarget` and `reentrantData`; on the
///         next ETH receive, this contract issues a `call` to that target
///         with that data. The protocol under test must reject the
///         reentrant call (via ReentrancyGuard) without reverting the outer
///         payment — King payouts are best-effort with bounded gas, but
///         shareholder claim and escrow refund flows MUST hold their guards.
contract MaliciousReentrantReceiver {
    address public reentrantTarget;
    bytes public reentrantData;
    uint256 public reentrantGas;
    bool internal _entered;

    /// @notice Counter incremented on every successful reentrant call. Used
    ///         by the harness to detect double-credit / double-payout bugs.
    uint256 public reentrantSuccesses;

    /// @notice Counter incremented on every reentrant call that reverted.
    ///         Used by the harness to confirm guards are working.
    uint256 public reentrantReverts;

    constructor() {}

    function setReentrantCall(address target, bytes calldata data, uint256 gas) external {
        reentrantTarget = target;
        reentrantData = data;
        reentrantGas = gas == 0 ? gasleft() : gas;
    }

    function clearReentrantCall() external {
        reentrantTarget = address(0);
        reentrantData = "";
        reentrantGas = 0;
    }

    receive() external payable {
        _attemptReentrancy();
    }

    fallback() external payable {
        _attemptReentrancy();
    }

    function _attemptReentrancy() internal {
        if (reentrantTarget == address(0) || _entered) return;
        _entered = true;
        (bool ok,) = reentrantTarget.call{gas: reentrantGas}(reentrantData);
        if (ok) {
            reentrantSuccesses++;
        } else {
            reentrantReverts++;
        }
        _entered = false;
    }

    /// @notice Proxy a low-level call as `msg.sender == address(this)`.
    /// @dev    Lets the harness drive the protocol from the attacker's
    ///         identity so that paths like `MineCore.takeover` (which
    ///         capture msg.sender as the new King) plant the attacker as
    ///         the recipient of subsequent ETH-paying flows.
    function proxyCall(address target, uint256 ethValue, bytes calldata data)
        external
        payable
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = target.call{value: ethValue}(data);
    }
}
