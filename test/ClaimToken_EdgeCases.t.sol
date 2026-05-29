// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

// ═══════════════════════════════════════════════════════════════════════
//  Mock helpers
// ═══════════════════════════════════════════════════════════════════════

/// @dev Minimal mock that satisfies the wiring check: claim() returns the configured token.
contract MockMineCoreClaim {
    address public claim;

    constructor(address _claim) {
        claim = _claim;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 1 days;
    }
}

/// @dev Mock whose claim() return can be changed after deployment (simulates drift).
contract DriftableMockCore {
    address public claim;

    constructor(address _claim) {
        claim = _claim;
    }

    function setClaim(address _claim) external {
        claim = _claim;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 1 days;
    }
}

/// @dev Adversarial contract: fallback echoes msg.sender as a 32-byte word.
///      Dual-caller hardening must reject this during reciprocal wiring checks.
contract FallbackEchoCore {
    fallback() external {
        assembly {
            mstore(0, caller())
            return(0, 32)
        }
    }
}

/// @dev Claim view that can drift from a canonical static return to a caller-sensitive one.
contract CallerSensitiveClaimCore {
    address internal immutable _canonicalClaim;
    bool public echoCaller;

    constructor(address claim_) {
        _canonicalClaim = claim_;
    }

    function setEchoCaller(bool enabled) external {
        echoCaller = enabled;
    }

    function claim() external view returns (address) {
        if (echoCaller) return msg.sender;
        return _canonicalClaim;
    }

    function emissionStartTime() external pure returns (uint256) {
        return 1;
    }

    function GENESIS_ACCRUAL_DURATION() external pure returns (uint256) {
        return 1 days;
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ClaimToken spec-conformance and adversarial edge-case coverage
// ═══════════════════════════════════════════════════════════════════════

/// @title ClaimToken edge cases
/// @notice Covers spec-conformance gaps, attack-surface edge cases, and
///         invariant-based adversarial scenarios for `ClaimToken`.
/// @dev Run: forge test --match-contract ClaimToken_EdgeCases
contract ClaimToken_EdgeCases_Test is Test {
    ClaimToken internal token;
    address internal owner = address(0xA11CE);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal mineCore;

    function setUp() public {
        token = new ClaimToken(owner);
        mineCore = address(new MockMineCoreClaim(address(token)));

        vm.prank(owner);
        token.setMineCore(mineCore);
    }

    // ─── Helper ─────────────────────────────────────────────────────
    function _mintTo(address to, uint256 amount) internal {
        vm.prank(mineCore);
        token.mint(to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Spec-conformance gaps
    // ═══════════════════════════════════════════════════════════════════

    // transfer() to address(this) reverts.
    function test_transfer_toSelf_reverts() public {
        _mintTo(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(Errors.TransfersRestricted.selector);
        token.transfer(address(token), 50e18);
    }

    // transferFrom() to address(this) reverts.
    function test_transferFrom_toSelf_reverts() public {
        _mintTo(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 100e18);

        vm.prank(bob);
        vm.expectRevert(Errors.TransfersRestricted.selector);
        token.transferFrom(alice, address(token), 50e18);
    }

    // mint() to address(this) reverts.
    function test_mint_toSelf_reverts() public {
        vm.prank(mineCore);
        vm.expectRevert(Errors.TransfersRestricted.selector);
        token.mint(address(token), 100e18);
    }

    // freezeConfig() called twice reverts.
    function test_freezeConfig_twice_reverts() public {
        vm.prank(owner);
        token.freezeConfig();

        vm.prank(owner);
        vm.expectRevert(Errors.ConfigFrozen.selector);
        token.freezeConfig();
    }

    // freezeConfig() emits ConfigFrozen.
    function test_freezeConfig_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Events.ConfigFrozen();
        token.freezeConfig();
    }

    // setMineCore() emits MineCoreChanged with the expected args.
    function test_setMineCore_emitsEvent() public {
        ClaimToken fresh = new ClaimToken(owner);
        address core = address(new MockMineCoreClaim(address(fresh)));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Events.MineCoreChanged(address(0), core);
        fresh.setMineCore(core);
    }

    // renounceOwnership() before freeze reverts with NotAuthorized.
    function test_renounceOwnership_beforeFreeze_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        token.renounceOwnership();
    }

    // renounceOwnership() after freeze succeeds.
    function test_renounceOwnership_afterFreeze_succeeds() public {
        vm.prank(owner);
        token.freezeConfig();

        vm.prank(owner);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
    }

    // setMineCore() rejects EOAs with NotAContract.
    function test_setMineCore_rejectsEOA() public {
        ClaimToken fresh = new ClaimToken(owner);
        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        fresh.setMineCore(address(0xDEAD));
    }

    // Constructor rejects a zero owner (OZ OwnableInvalidOwner).
    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ClaimToken(address(0));
    }

    // Owner is set correctly after construction.
    function test_constructor_setsOwner() public {
        ClaimToken fresh = new ClaimToken(address(0xBEEF));
        assertEq(fresh.owner(), address(0xBEEF));
    }

    // Ownable2Step two-phase transfer works end to end.
    function test_ownable2Step_fullTransfer() public {
        address newOwner = address(0xCAFE);

        vm.prank(owner);
        token.transferOwnership(newOwner);
        assertEq(token.pendingOwner(), newOwner);
        assertEq(token.owner(), owner);

        vm.prank(newOwner);
        token.acceptOwnership();
        assertEq(token.owner(), newOwner);
        assertEq(token.pendingOwner(), address(0));
    }

    // freezeConfig() reverts with WiringMismatch when claim() reports the wrong token.
    function test_freezeConfig_wiringMismatch_reverts() public {
        ClaimToken fresh = new ClaimToken(owner);
        address correctCore = address(new MockMineCoreClaim(address(fresh)));

        vm.prank(owner);
        fresh.setMineCore(correctCore);

        DriftableMockCore driftable = DriftableMockCore(correctCore);
        // We can't mutate MockMineCoreClaim — so use a driftable mock instead.
        ClaimToken fresh2 = new ClaimToken(owner);
        DriftableMockCore dCore = new DriftableMockCore(address(fresh2));

        vm.prank(owner);
        fresh2.setMineCore(address(dCore));

        // Drift the mock so claim() now returns a different address
        dCore.setClaim(address(0xDEAD));

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh2.freezeConfig();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Attack-surface edge cases
    // ═══════════════════════════════════════════════════════════════════

    // setMineCore self-assignment (same address) succeeds but emits a same-from/same-to event
    function test_setMineCore_selfAssignment_succeeds() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Events.MineCoreChanged(mineCore, mineCore);
        token.setMineCore(mineCore);
        assertEq(token.mineCore(), mineCore);
    }

    // Zero-amount mint reverts
    function test_mint_zeroAmount_reverts() public {
        vm.prank(mineCore);
        vm.expectRevert(Errors.AmountZero.selector);
        token.mint(alice, 0);
    }

    // Zero-amount burn reverts
    function test_burn_zeroAmount_reverts() public {
        _mintTo(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(Errors.AmountZero.selector);
        token.burn(0);
    }

    // Mint to zero address reverts
    function test_mint_toZeroAddress_reverts() public {
        vm.prank(mineCore);
        vm.expectRevert(Errors.ZeroAddress.selector);
        token.mint(address(0), 100e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Invariant-based adversarial tests
    // ═══════════════════════════════════════════════════════════════════

    // renounceOwnership clears pendingOwner
    function test_renounceOwnership_clearsPendingOwner() public {
        address pending = address(0xCAFE);

        vm.prank(owner);
        token.transferOwnership(pending);
        assertEq(token.pendingOwner(), pending);

        vm.prank(owner);
        token.freezeConfig();

        vm.prank(owner);
        token.renounceOwnership();

        assertEq(token.owner(), address(0));
        assertEq(token.pendingOwner(), address(0), "pendingOwner must be cleared after renounce");

        // Pending owner cannot resurrect ownership
        vm.prank(pending);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pending));
        token.acceptOwnership();
    }

    // transferOwnership still works after config freeze
    function test_transferOwnership_afterFreeze_works() public {
        vm.prank(owner);
        token.freezeConfig();

        address newOwner = address(0xCAFE);

        vm.prank(owner);
        token.transferOwnership(newOwner);

        vm.prank(newOwner);
        token.acceptOwnership();
        assertEq(token.owner(), newOwner);
    }

    // Fallback-echo contract is rejected by the dual-caller wiring probe
    function test_fallbackEcho_rejectedByWiringCheck() public {
        FallbackEchoCore echoCore = new FallbackEchoCore();
        ClaimToken fresh = new ClaimToken(owner);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.setMineCore(address(echoCore));
    }

    function test_freezeConfig_rejectsCallerSensitiveClaimDrift() public {
        ClaimToken fresh = new ClaimToken(owner);
        CallerSensitiveClaimCore driftingCore = new CallerSensitiveClaimCore(address(fresh));

        vm.prank(owner);
        fresh.setMineCore(address(driftingCore));

        driftingCore.setEchoCaller(true);

        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.freezeConfig();
    }

    // Self-referential wiring is blocked
    function test_setMineCore_selfReferential_reverts() public {
        ClaimToken fresh = new ClaimToken(owner);
        vm.prank(owner);
        vm.expectRevert(Errors.WiringMismatch.selector);
        fresh.setMineCore(address(fresh));
    }

    // Fuzz: transferFrom preserves total supply
    function testFuzz_transferFrom_preservesTotalSupply(uint128 mintAmt, uint128 xferAmt) public {
        vm.assume(mintAmt > 0);
        vm.assume(xferAmt > 0);
        vm.assume(xferAmt <= mintAmt);

        _mintTo(alice, uint256(mintAmt));
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, bob, uint256(xferAmt));

        assertEq(token.totalSupply(), supplyBefore, "supply must not change on transferFrom");
    }

    // Max-approval semantics: infinite allowance is not decremented
    function test_maxApproval_notDecremented() public {
        _mintTo(alice, 1000e18);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, bob, 100e18);

        assertEq(token.allowance(alice, bob), type(uint256).max, "max approval must not decrement");
    }

    // ---- Wire-time freeze + renounce coverage ----

    // Critical: mint() still works after owner is renounced
    function test_mintWorksAfterOwnershipRenounced() public {
        vm.prank(owner);
        token.freezeConfig();

        vm.prank(owner);
        token.renounceOwnership();
        assertEq(token.owner(), address(0), "owner should be zero");

        vm.prank(mineCore);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18, "mint must succeed with renounced owner");
    }

    // setMineCore() blocked after freeze + renounce
    function test_setMineCoreBlockedAfterFreezeAndRenounce() public {
        vm.prank(owner);
        token.freezeConfig();

        vm.prank(owner);
        token.renounceOwnership();

        MockMineCoreClaim core2 = new MockMineCoreClaim(address(token));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.setMineCore(address(core2));
    }

    // freezeConfig() reverts when mineCore is not set
    function test_freezeConfig_revertsIfMineCoreNotSet() public {
        ClaimToken fresh = new ClaimToken(owner);
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.freezeConfig();
    }

    // burn() still works after ownership renounced
    function test_burnWorksAfterOwnershipRenounced() public {
        vm.prank(owner);
        token.freezeConfig();
        vm.prank(owner);
        token.renounceOwnership();

        vm.prank(mineCore);
        token.mint(alice, 500e18);

        vm.prank(alice);
        token.burn(200e18);
        assertEq(token.balanceOf(alice), 300e18, "burn must succeed with renounced owner");
    }
}
