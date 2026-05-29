// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Adversarial mocks targeting _staticcallAddress / probeClaim assembly
// ═══════════════════════════════════════════════════════════════════════

/// @dev Returns only 20 raw bytes (not ABI-encoded 32-byte word).
///      Assembly check requires returndatasize >= 32; this must be rejected.
contract ShortReturnCore {
    fallback() external {
        assembly {
            mstore(0, 0) // zero-fill
            return(12, 20) // return only 20 bytes (an unpadded address)
        }
    }
}

/// @dev Consumes > 100 000 gas in a tight loop before returning.
///      The 100k gas cap in _staticcallAddress must cause this to fail.
contract GasBombCore {
    fallback() external {
        uint256 i;
        // Each SLOAD costs ~2100 gas; 50 iterations ≈ 105k gas
        for (i = 0; i < 50; i++) {
            assembly {
                let _x := sload(i)
            }
        }
        // If we somehow get here, return a valid-looking address
        assembly {
            mstore(0, address())
            return(0, 32)
        }
    }
}

/// @dev Returns 1024 bytes of returndata (return-data bomb).
///      _staticcallAddress must safely read only the first 32 bytes.
contract OversizedReturnCore {
    address internal immutable _claim;

    constructor(address claim_) {
        _claim = claim_;
    }

    fallback() external {
        address c = _claim;
        assembly {
            // Fill 1024 bytes with garbage
            for { let i := 0 } lt(i, 32) { i := add(i, 1) } {
                mstore(mul(i, 32), 0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF)
            }
            // Place correct ABI-encoded address in first 32 bytes
            mstore(0, c)
            return(0, 1024)
        }
    }
}

/// @dev Returns nothing (zero returndata). Must be rejected.
contract EmptyReturnCore {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// @dev Returns the correct address but with dirty upper 12 bytes.
///      The AND mask in assembly must correctly strip the dirty bits.
contract DirtyUpperBytesCore {
    address internal immutable _claim;

    constructor(address claim_) {
        _claim = claim_;
    }

    function claim() external view returns (bytes32) {
        // Return 32 bytes where upper 12 bytes are 0xFF (dirty)
        // and lower 20 bytes are the correct address.
        return bytes32(uint256(type(uint96).max) << 160 | uint256(uint160(_claim)));
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 604800;
    }
}

/// @dev Legitimate mock for baseline comparison.
contract MockMineCoreAssembly {
    address public claim;
    uint256 public emissionStartTime = 1;
    uint256 public GENESIS_ACCRUAL_DURATION = 1;

    constructor(address claim_) {
        claim = claim_;
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════════════

/// @title ClaimToken assembly hardening tests
/// @notice Tests _staticcallAddress and probeClaim against adversarial returndata patterns.
/// @dev Run: forge test --match-contract ClaimToken_AssemblyHardening
///
/// Storage layout reference (OZ v5 inheritance chain):
///   ERC20:        slots 0-4  (_balances, _allowances, _totalSupply, _name, _symbol)
///   Ownable:      slot  5    (_owner)
///   Ownable2Step: slot  6    (_pendingOwner)
///   ClaimToken:   slot  7    (mineCore [address, 20B] | configFrozen [bool, 1B])
///   _wiringProbe: immutable  (in bytecode, not storage)
contract ClaimToken_AssemblyHardening is Test {
    address internal owner = address(0xA11CE);

    /// @dev ClaimToken.mineCore is at storage slot 7 (packed with configFrozen).
    uint256 internal constant SLOT_MINECORE = 7;

    // ── Short returndata (< 32 bytes) → rejected ─────────────────────

    function test_shortReturn_rejectedBySetMineCore() public {
        ClaimToken token = new ClaimToken(owner);
        ShortReturnCore mock = new ShortReturnCore();

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        token.setMineCore(address(mock));
    }

    function test_shortReturn_rejectedByFreezeConfig() public {
        ClaimToken token = new ClaimToken(owner);
        MockMineCoreAssembly legit = new MockMineCoreAssembly(address(token));

        vm.prank(owner);
        token.setMineCore(address(legit));

        // Replace mineCore in slot 7 with the short-return mock.
        // configFrozen (byte 20) stays false (0x00) since we only write the address to the low 20 bytes.
        ShortReturnCore bad = new ShortReturnCore();
        vm.store(address(token), bytes32(SLOT_MINECORE), bytes32(uint256(uint160(address(bad)))));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        token.freezeConfig();
    }

    // ── Empty returndata (0 bytes) → rejected ────────────────────────

    function test_emptyReturn_rejectedBySetMineCore() public {
        ClaimToken token = new ClaimToken(owner);
        EmptyReturnCore mock = new EmptyReturnCore();

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        token.setMineCore(address(mock));
    }

    // ── Gas bomb (> 100k gas) → rejected ─────────────────────────────

    function test_gasBomb_rejectedBySetMineCore() public {
        ClaimToken token = new ClaimToken(owner);
        GasBombCore mock = new GasBombCore();

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        token.setMineCore(address(mock));
    }

    // ── Oversized returndata (1024 bytes) → accepted if first 32 correct ──

    function test_oversizedReturn_acceptedIfCorrect() public {
        ClaimToken token = new ClaimToken(owner);
        OversizedReturnCore mock = new OversizedReturnCore(address(token));

        vm.prank(owner);
        token.setMineCore(address(mock));
        assertEq(token.mineCore(), address(mock));
    }

    // ── Dirty upper bytes → AND mask correctly strips ─────────────────

    function test_dirtyUpperBytes_acceptedAfterMask() public {
        ClaimToken token = new ClaimToken(owner);
        DirtyUpperBytesCore mock = new DirtyUpperBytesCore(address(token));

        vm.prank(owner);
        token.setMineCore(address(mock));
        assertEq(token.mineCore(), address(mock));
    }

    // ── Baseline: legitimate mock passes both checks ─────────────────

    function test_legitimateMock_passesWiringCheck() public {
        ClaimToken token = new ClaimToken(owner);
        MockMineCoreAssembly mock = new MockMineCoreAssembly(address(token));

        vm.prank(owner);
        token.setMineCore(address(mock));
        assertEq(token.mineCore(), address(mock));

        vm.prank(owner);
        token.freezeConfig();
        assertTrue(token.configFrozen());
    }

    // ── EOA (no code) → rejected before wiring check ─────────────────

    function testFuzz_eoa_rejectedBySetMineCore(address eoa) public {
        vm.assume(eoa != address(0));
        vm.assume(eoa.code.length == 0);

        ClaimToken token = new ClaimToken(owner);

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        token.setMineCore(eoa);
    }
}
