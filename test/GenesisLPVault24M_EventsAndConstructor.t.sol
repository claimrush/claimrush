// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {GenesisLPVault24M} from "src/vault/GenesisLPVault24M.sol";
import {IGenesisLPVault24M} from "src/interfaces/IGenesisLPVault24M.sol";
import {Errors} from "src/lib/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice test coverage for event emissions and constructor validation.
contract GenesisLPVault24MEventCoverageTest is Test {
    MockERC20 internal lp;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    GenesisLPVault24M internal vault;

    address internal recipient = address(0xCAFE);
    address internal alice = address(0xA);

    function setUp() public {
        lp = new MockERC20("LP", "LP");
        tokenA = new MockERC20("TKA", "TKA");
        tokenB = new MockERC20("TKB", "TKB");
        vault = new GenesisLPVault24M(address(lp), recipient);
    }

    // ─── G24M-11: constructor validation ──────────────────────────────

    function test_constructor_allowsUndeployedDeterministicPoolAddress() public {
        GenesisLPVault24M ghost = new GenesisLPVault24M(address(0xDEAD), recipient);
        assertEq(ghost.pool(), address(0xDEAD));
        assertEq(ghost.lpWithdrawRecipient(), recipient);
    }

    function test_constructor_revertsOnSelfRecipient() public {
        // CREATE deployment address depends only on (deployer, nonce), not init-code, so we
        // can predict the vault's address before construction and pass it as the recipient.
        SelfRecipientCreateFactory factory = new SelfRecipientCreateFactory();
        vm.expectRevert(Errors.WiringMismatch.selector);
        factory.deployVaultWithSelfAsRecipient(address(lp));
    }

    function test_constructor_rejectsDelegatedEOARecipient() public {
        // EIP-7702 delegation designator is exactly `0xEF 0x01 0x00 || delegate` (23 bytes).
        // Constructor must reject it even though `code.length != 0` and `extcodehash` is non-empty.
        address delegate = address(lp);
        bytes memory designator = abi.encodePacked(hex"ef0100", delegate);
        assertEq(designator.length, 23, "EIP-7702 designator length must be 23");

        address fakeRecipient = address(0xCAFE7702);
        vm.etch(fakeRecipient, designator);
        assertEq(fakeRecipient.code.length, 23, "etched code must be 23 bytes");

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new GenesisLPVault24M(address(lp), fakeRecipient);
    }

    // ─── G24M-15: event emission tests ────────────────────────────────

    function test_startLock_emitsLockedEvent() public {
        lp.mint(address(vault), 100e18);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IGenesisLPVault24M.Locked(100e18, block.timestamp, block.timestamp + vault.INITIAL_LOCK_DURATION());

        vault.startLock();
    }

    function test_withdrawLp_emitsWithdrawLpEvent() public {
        lp.mint(address(vault), 25e18);
        vault.startLock();
        vm.warp(vault.unlockTime());

        vm.expectEmit(true, false, false, true, address(vault));
        emit IGenesisLPVault24M.WithdrawLp(recipient, 25e18);

        vm.prank(recipient);
        vault.withdrawLp();
    }

    function test_extendLock_emitsLockExtendedEvent() public {
        lp.mint(address(vault), 10e18);
        vault.startLock();

        uint256 oldUnlock = vault.unlockTime();
        uint256 newUnlock = oldUnlock + 30 days;

        vm.expectEmit(false, false, false, true, address(vault));
        emit IGenesisLPVault24M.LockExtended(oldUnlock, newUnlock);

        vm.prank(recipient);
        vault.extendLock(newUnlock);
    }

    function test_withdrawLp_residualEmitsResidualLpSweptEvent() public {
        lp.mint(address(vault), 10e18);
        vault.startLock();

        vm.warp(vault.unlockTime());
        vm.prank(recipient);
        vault.withdrawLp();

        lp.mint(address(vault), 3e18);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IGenesisLPVault24M.ResidualLpSwept(recipient, 3e18);

        vm.prank(recipient);
        vault.withdrawLp();
    }
}

/// @notice Helper factory used to test the self-recipient rejection branch in
///         `GenesisLPVault24M`'s constructor. CREATE addresses depend only on
///         `(deployer, nonce)` and are independent of init-code, so the factory can predict
///         the vault's deployment address and pass it back as the recipient.
contract SelfRecipientCreateFactory {
    function deployVaultWithSelfAsRecipient(address pool) external returns (address) {
        // First contract created by this factory uses nonce 1; RLP encoding for
        // (address, 1) is `0xd6 0x94 || addr (20 bytes) || 0x01` (22 bytes total).
        bytes memory rlp = abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(0x01));
        address predicted = address(uint160(uint256(keccak256(rlp))));
        return address(new GenesisLPVault24M(pool, predicted));
    }
}
