// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Minimal initializer + Ownable2Step + ReentrancyGuard base for proxy-backed protocol contracts.
abstract contract UpgradeableProtocolBase {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    address private _owner;
    address private _pendingOwner;
    uint256 private _reentrancyStatus;
    bool private _initialized;

    /// @dev Reserved storage slots for future state additions to this base. Every upgradeable
    ///      child (`MineCore`, `Furnace`, `ShareholderRoyalties`, `MarketRouter`) inherits from
    ///      this base; appending new state here without a gap would shift every child's storage
    ///      layout. This 50-slot gap (1,600 bytes) absorbs up to 50 words of future base state
    ///      without touching child layouts.
    ///
    ///      When adding a new state var to this base:
    ///        1. Declare it ABOVE `__gap` (between `_initialized` and `__gap`).
    ///        2. Decrease `__gap` length by ceil(bytes(newVar)/32).
    ///        3. Re-run storage-layout regression on all child contracts.
    ///
    ///      Zero runtime-bytecode cost: unused storage emits no instructions. Only the layout
    ///      metadata is affected.
    uint256[50] private __gap;

    error InvalidInitialization();
    error OwnableInvalidOwner(address owner);
    error OwnableUnauthorizedAccount(address account);
    error ReentrancyGuardReentrantCall();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier initializer() {
        if (_initialized) revert InvalidInitialization();
        _initialized = true;
        _;
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrancyGuardReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    error DelegatedEOAOwner(address account);

    function transferOwnership(address newOwner) external virtual onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _validateNewOwner(newOwner);
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    /// @dev Reject EIP-7702 delegation designators on the new owner candidate.
    ///      A 7702-delegated owner exposes public-executor code under the
    ///      owner role and lets arbitrary callers exercise owner-only protocol
    ///      surfaces post-acceptance. The designator is exactly 23 bytes and
    ///      starts with `0xEF0100`; the prefix check is the canonical guard
    ///      so legitimate 23-byte runtime contracts (small constructors that
    ///      land at that length without the 7702 marker) pass unchanged. Bare
    ///      EOAs (`code.length == 0`) and normal contracts pass through.
    ///
    ///      Tightly EIP-170-constrained derived contracts MAY override this
    ///      hook to a no-op when other layers (proxy admin guard + deploy
    ///      script discipline) cover the same threat model. Overrides MUST
    ///      document the alternative coverage in their NatSpec.
    function _validateNewOwner(address newOwner) internal view virtual {
        if (newOwner.code.length != 23) return;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(newOwner, 0x00, 0x00, 0x03)
            prefix := mload(0x00)
        }
        if (prefix == 0xEF0100) revert DelegatedEOAOwner(newOwner);
    }

    /// @dev Re-runs `_validateNewOwner(msg.sender)` so a nominee that installs
    ///      a 7702 delegation designator between nomination and acceptance is
    ///      rejected at acceptance time. The transfer-time check alone cannot
    ///      catch this race because the nominee is free to change account
    ///      shape after the call to `transferOwnership`.
    function acceptOwnership() external virtual {
        address sender = msg.sender;
        if (_pendingOwner != sender) revert OwnableUnauthorizedAccount(sender);
        _validateNewOwner(sender);
        _transferOwnership(sender);
    }

    /// @dev Re-runs `_validateNewOwner(msg.sender)` on every owner-only call so a
    ///      seated owner that installs an EIP-7702 delegation designator after
    ///      acceptance cannot expose owner-only protocol surfaces through public
    ///      executor code. Bare EOAs (`code.length == 0`) and normal contracts
    ///      pass through; only the 23-byte `0xEF0100...` designator is rejected.
    ///      The runtime cost is one `extcodecopy(msg.sender, 0, 0, 3)` per
    ///      owner-only call.
    function _checkOwner() internal view virtual {
        address sender = msg.sender;
        if (_owner != sender) revert OwnableUnauthorizedAccount(sender);
        _validateNewOwner(sender);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        delete _pendingOwner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function __UpgradeableProtocolBase_init(address initialOwner) internal {
        if (_owner != address(0) || _reentrancyStatus != 0) revert InvalidInitialization();
        _transferOwnership(initialOwner);
        _reentrancyStatus = _NOT_ENTERED;
    }

    function _disableInitializers() internal {
        _initialized = true;
    }
}
