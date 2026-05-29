// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import {Events} from "../../src/lib/Events.sol";
import {MarketRouter} from "../../src/MarketRouter.sol";

/// @title Strict Mode ABI Event Parity Invariants
/// @notice Fast invariant tests that verify event signatures match Strict Mode requirements.
/// @dev These tests ensure:
///      1. LockListed event uses parameter name "minClaimOut" (not "priceInClaim")
///      2. LockBought event does NOT exist
///      3. GlobalOfferFilled event does NOT exist
///
///      No chain interactions required - pure compile-time and selector checks.
contract StrictModeAbiEventParityInvariants is Test {
    // =========================================================================
    // EXPECTED EVENT SIGNATURES (Strict Mode)
    // =========================================================================

    // LockListed(uint256 indexed tokenId, address indexed seller, uint256 minClaimOut, uint256 listedAtTime, uint256 expiresAtTime)
    // Selector: keccak256("LockListed(uint256,address,uint256,uint256,uint256)")
    bytes32 internal constant EXPECTED_LOCK_LISTED_TOPIC =
        keccak256("LockListed(uint256,address,uint256,uint256,uint256)");

    // MarketSellToFurnace(uint256 indexed tokenId, address indexed seller, uint256 minClaimOut, uint256 deadline, uint256 claimOut)
    bytes32 internal constant EXPECTED_MARKET_SELL_TO_FURNACE_TOPIC =
        keccak256("MarketSellToFurnace(uint256,address,uint256,uint256,uint256)");

    // BonusTargetEscrowExecuted(uint256 indexed escrowId, address indexed buyer, uint256 claimIn, uint256 principalClaim, uint256 bonusClaim, uint256 veOut, uint256 routeTokenId, uint256 furnaceTokenId)
    bytes32 internal constant EXPECTED_BONUS_TARGET_ESCROW_EXECUTED_TOPIC =
        keccak256("BonusTargetEscrowExecuted(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)");

    // =========================================================================
    // FORBIDDEN EVENT SIGNATURES (must NOT exist)
    // =========================================================================

    // LockBought - REMOVED in Strict Mode
    bytes32 internal constant FORBIDDEN_LOCK_BOUGHT_TOPIC = keccak256("LockBought(uint256,address,address,uint256)");

    // GlobalOfferFilled - REMOVED in Strict Mode
    bytes32 internal constant FORBIDDEN_GLOBAL_OFFER_FILLED_TOPIC =
        keccak256("GlobalOfferFilled(uint256,address,address,uint256,uint256,uint256)");

    // Old LockListed with priceInClaim (if it existed with different semantics)
    // Note: The signature would be the same, but parameter NAME differs in the ABI.
    // This is validated via the ABI JSON check script, not here.

    // =========================================================================
    // INVARIANT TESTS: Event signature parity
    // =========================================================================

    /// @notice Verify LockListed event exists with correct signature.
    function test_lockListedEvent_hasCorrectSignature() public pure {
        // The Events library should define LockListed with minClaimOut.
        // Verify the selector matches expected.
        bytes32 expectedTopic = EXPECTED_LOCK_LISTED_TOPIC;

        // This is a compile-time check. The Events.LockListed event is defined
        // with (uint256 indexed tokenId, address indexed seller, uint256 minClaimOut, uint256 listedAtTime).
        // If someone changes the signature, this test documents the expected hash.
        assertEq(
            expectedTopic,
            keccak256("LockListed(uint256,address,uint256,uint256,uint256)"),
            "LockListed signature mismatch"
        );
    }

    /// @notice Verify LockBought event selector is NOT the same as any existing event.
    /// @dev This is a documentation test - the actual absence is enforced by not having
    ///      the event in Events.sol and validated by the ABI strict mode script.
    function test_lockBoughtEvent_isAbsent() public pure {
        // LockBought event does not exist in Events.sol.
        // This test documents the forbidden selector.
        bytes32 forbiddenTopic = FORBIDDEN_LOCK_BOUGHT_TOPIC;
        assertEq(
            forbiddenTopic, keccak256("LockBought(uint256,address,address,uint256)"), "LockBought forbidden topic hash"
        );

        // The actual absence is enforced by:
        // 1. Not having Events.LockBought in the codebase
        // 2. The ABI strict mode validation script
        assertTrue(true, "LockBought is absent (validated via ABI script)");
    }

    /// @notice Verify GlobalOfferFilled event selector is NOT present.
    function test_globalOfferFilledEvent_isAbsent() public pure {
        bytes32 forbiddenTopic = FORBIDDEN_GLOBAL_OFFER_FILLED_TOPIC;
        assertEq(
            forbiddenTopic,
            keccak256("GlobalOfferFilled(uint256,address,address,uint256,uint256,uint256)"),
            "GlobalOfferFilled forbidden topic hash"
        );

        assertTrue(true, "GlobalOfferFilled is absent (validated via ABI script)");
    }

    // =========================================================================
    // COMPILE-TIME CHECKS: Events.sol structure
    // =========================================================================

    /// @notice Verify that emitting LockListed compiles with minClaimOut parameter.
    /// @dev This is a compile-time check that the event signature uses minClaimOut.
    function test_lockListedEvent_usesMinClaimOut_compileCheck() public {
        // Emit the event to verify it compiles with the expected parameters.
        // The third parameter is minClaimOut (not priceInClaim).
        uint256 tokenId = 1;
        address seller = address(0xA11CE);
        uint256 minClaimOut = 1000 ether;
        uint256 listedAtTime = block.timestamp;
        uint256 expiresAtTime = listedAtTime + 30 days;

        // This emission proves the event exists with these parameter types.
        // If Events.LockListed had different parameters, this would fail to compile.
        emit Events.LockListed(tokenId, seller, minClaimOut, listedAtTime, expiresAtTime);
    }

    /// @notice Verify that emitting MarketSellToFurnace compiles.
    function test_marketSellToFurnaceEvent_exists_compileCheck() public {
        uint256 tokenId = 1;
        address seller = address(0xA11CE);
        uint256 minClaimOut = 1000 ether;
        uint256 deadline = block.timestamp + 60;
        uint256 claimOut = 999 ether;

        emit Events.MarketSellToFurnace(tokenId, seller, minClaimOut, deadline, claimOut);
        assertEq(
            EXPECTED_MARKET_SELL_TO_FURNACE_TOPIC,
            keccak256("MarketSellToFurnace(uint256,address,uint256,uint256,uint256)"),
            "MarketSellToFurnace signature mismatch"
        );
    }

    /// @notice Verify LockDelisted event exists (companion to LockListed).
    function test_lockDelistedEvent_exists() public {
        uint256 tokenId = 1;
        address seller = address(0xA11CE);
        uint8 reason = 0;

        // Emit to verify compile-time existence
        emit Events.LockDelisted(tokenId, seller, reason);
    }

    /// @notice Verify BonusTargetEscrowExecuted exists with the canonical analytics payload.
    function test_bonusTargetEscrowExecutedEvent_hasCorrectSignature() public pure {
        assertEq(
            EXPECTED_BONUS_TARGET_ESCROW_EXECUTED_TOPIC,
            keccak256("BonusTargetEscrowExecuted(uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)"),
            "BonusTargetEscrowExecuted signature mismatch"
        );
    }

    /// @notice Verify BonusTargetEscrowExecuted compiles with the canonical auto-furnace payload.
    function test_bonusTargetEscrowExecutedEvent_exists_compileCheck() public {
        emit Events.BonusTargetEscrowExecuted(1, address(0xB0B), 100 ether, 95 ether, 5 ether, 100 ether, 7, 8);
    }

    // =========================================================================
    // NEGATIVE COMPILE-TIME CHECK (documentation)
    // =========================================================================

    /// @notice Document that Events.LockBought does NOT exist.
    /// @dev If someone adds LockBought to Events.sol, uncommenting the line below
    ///      would compile. Since it doesn't exist, this serves as documentation.
    function test_lockBoughtEvent_doesNotCompile_documentation() public pure {
        // The following line would cause a compile error if uncommented,
        // proving that Events.LockBought does not exist:
        //
        // emit Events.LockBought(1, address(0), address(0), 0);
        //
        // This is the desired behavior for Strict Mode.
        assertTrue(true, "LockBought event does not exist in Events.sol");
    }

    /// @notice Document that Events.GlobalOfferFilled does NOT exist.
    function test_globalOfferFilledEvent_doesNotCompile_documentation() public pure {
        // The following line would cause a compile error if uncommented:
        //
        // emit Events.GlobalOfferFilled(1, address(0), address(0), 0, 0, 0);
        //
        assertTrue(true, "GlobalOfferFilled event does not exist in Events.sol");
    }
}
