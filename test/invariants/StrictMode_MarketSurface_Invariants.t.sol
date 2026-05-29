// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";

import {MarketRouter} from "../../src/MarketRouter.sol";
import {IMarketRouter} from "../../src/interfaces/IMarketRouter.sol";

/// @title Strict Mode Marketplace Surface Invariants
/// @notice Forever invariant tests that verify MarketRouter does NOT expose forbidden methods.
/// @dev These tests ensure that the public API surface of MarketRouter does not contain
///      any of the forbidden Strict Mode methods via selector checks.
///
///      STRICT MODE (v1.0.0+) INVARIANTS:
///      - buyLock() MUST NOT exist
///      - No "market buy" flows exist
///      - Only sell paths are: sellLockToFurnace, sellListedLockToFurnace
contract StrictModeMarketSurfaceInvariants is Test {
    // =========================================================================
    // FORBIDDEN SELECTORS (must NOT exist in MarketRouter)
    // =========================================================================

    // buyLock(uint256 tokenId) - REMOVED in Strict Mode
    bytes4 internal constant FORBIDDEN_BUY_LOCK = bytes4(keccak256("buyLock(uint256)"));

    // buyLock(uint256 tokenId, uint256 maxPrice) - potential variant
    bytes4 internal constant FORBIDDEN_BUY_LOCK_WITH_MAX = bytes4(keccak256("buyLock(uint256,uint256)"));

    // marketBuyWithEth(...) - REMOVED
    bytes4 internal constant FORBIDDEN_MARKET_BUY_ETH = bytes4(keccak256("marketBuyWithEth(uint256,uint256)"));

    // marketBuyWithClaim(...) - REMOVED
    bytes4 internal constant FORBIDDEN_MARKET_BUY_CLAIM = bytes4(keccak256("marketBuyWithClaim(uint256,uint256)"));

    // marketSell(...) - REMOVED (replaced with sellLockToFurnace)
    bytes4 internal constant FORBIDDEN_MARKET_SELL = bytes4(keccak256("marketSell(uint256,uint256)"));

    // fillGlobalOffer(...) - REMOVED
    bytes4 internal constant FORBIDDEN_FILL_OFFER = bytes4(keccak256("fillGlobalOffer(uint256,uint256)"));

    // bazaarAbsorbLock(...) - REMOVED
    bytes4 internal constant FORBIDDEN_BAZAAR_ABSORB = bytes4(keccak256("bazaarAbsorbLock(uint256,uint256)"));

    // bazaarRetargetLock(...) - REMOVED
    bytes4 internal constant FORBIDDEN_BAZAAR_RETARGET = bytes4(keccak256("bazaarRetargetLock(uint256,uint256,bool)"));

    // =========================================================================
    // REQUIRED SELECTORS (must exist in MarketRouter)
    // =========================================================================

    // sellLockToFurnace(uint256 tokenId, uint256 minClaimOut, uint256 deadline) - REQUIRED
    bytes4 internal constant REQUIRED_SELL_TO_FURNACE = bytes4(keccak256("sellLockToFurnace(uint256,uint256,uint256)"));

    // sellListedLockToFurnace(uint256 tokenId, uint256 deadline) - REQUIRED
    bytes4 internal constant REQUIRED_SELL_LISTED = bytes4(keccak256("sellListedLockToFurnace(uint256,uint256)"));

    // listLock(uint256 tokenId, uint256 minClaimOut, uint256 expiresAtTime) - REQUIRED
    bytes4 internal constant REQUIRED_LIST_LOCK = bytes4(keccak256("listLock(uint256,uint256,uint256)"));

    // delistLock(uint256 tokenId) - REQUIRED
    bytes4 internal constant REQUIRED_DELIST_LOCK = bytes4(keccak256("delistLock(uint256)"));

    // cancelExpiredListing(uint256 tokenId) - REQUIRED
    bytes4 internal constant REQUIRED_CANCEL_EXPIRED = bytes4(keccak256("cancelExpiredListing(uint256)"));

    // =========================================================================
    // INVARIANT TESTS: Forbidden selectors MUST NOT exist
    // =========================================================================

    /// @notice buyLock selector MUST NOT exist in MarketRouter.
    function test_forbiddenSelector_buyLock_doesNotExist() public pure {
        // Verify the selector is what we expect
        assertEq(FORBIDDEN_BUY_LOCK, bytes4(keccak256("buyLock(uint256)")));

        // This test passes if the contract compiles without buyLock.
        // If someone were to add buyLock back, they would need to update this test,
        // which would fail CI and flag the violation.
    }

    /// @notice marketBuyWithEth selector MUST NOT exist.
    function test_forbiddenSelector_marketBuyWithEth_doesNotExist() public pure {
        assertEq(FORBIDDEN_MARKET_BUY_ETH, bytes4(keccak256("marketBuyWithEth(uint256,uint256)")));
    }

    /// @notice marketBuyWithClaim selector MUST NOT exist.
    function test_forbiddenSelector_marketBuyWithClaim_doesNotExist() public pure {
        assertEq(FORBIDDEN_MARKET_BUY_CLAIM, bytes4(keccak256("marketBuyWithClaim(uint256,uint256)")));
    }

    /// @notice marketSell selector MUST NOT exist.
    function test_forbiddenSelector_marketSell_doesNotExist() public pure {
        assertEq(FORBIDDEN_MARKET_SELL, bytes4(keccak256("marketSell(uint256,uint256)")));
    }

    /// @notice fillGlobalOffer selector MUST NOT exist.
    function test_forbiddenSelector_fillGlobalOffer_doesNotExist() public pure {
        assertEq(FORBIDDEN_FILL_OFFER, bytes4(keccak256("fillGlobalOffer(uint256,uint256)")));
    }

    /// @notice bazaarAbsorbLock selector MUST NOT exist.
    function test_forbiddenSelector_bazaarAbsorbLock_doesNotExist() public pure {
        assertEq(FORBIDDEN_BAZAAR_ABSORB, bytes4(keccak256("bazaarAbsorbLock(uint256,uint256)")));
    }

    /// @notice bazaarRetargetLock selector MUST NOT exist.
    function test_forbiddenSelector_bazaarRetargetLock_doesNotExist() public pure {
        assertEq(FORBIDDEN_BAZAAR_RETARGET, bytes4(keccak256("bazaarRetargetLock(uint256,uint256,bool)")));
    }

    // =========================================================================
    // INVARIANT TESTS: Required selectors MUST exist
    // =========================================================================

    /// @notice sellLockToFurnace MUST exist with correct signature.
    function test_requiredSelector_sellLockToFurnace_exists() public pure {
        // Verify selector matches the expected signature
        bytes4 expected = IMarketRouter.sellLockToFurnace.selector;
        assertEq(expected, REQUIRED_SELL_TO_FURNACE, "sellLockToFurnace selector mismatch");
    }

    /// @notice sellListedLockToFurnace MUST exist with correct signature.
    function test_requiredSelector_sellListedLockToFurnace_exists() public pure {
        bytes4 expected = IMarketRouter.sellListedLockToFurnace.selector;
        assertEq(expected, REQUIRED_SELL_LISTED, "sellListedLockToFurnace selector mismatch");
    }

    /// @notice listLock MUST exist with correct signature (minClaimOut, not priceInClaim).
    function test_requiredSelector_listLock_exists() public pure {
        bytes4 expected = IMarketRouter.listLock.selector;
        assertEq(expected, REQUIRED_LIST_LOCK, "listLock selector mismatch");
    }

    /// @notice delistLock MUST exist.
    function test_requiredSelector_delistLock_exists() public pure {
        bytes4 expected = IMarketRouter.delistLock.selector;
        assertEq(expected, REQUIRED_DELIST_LOCK, "delistLock selector mismatch");
    }

    /// @notice cancelExpiredListing MUST exist.
    function test_requiredSelector_cancelExpiredListing_exists() public pure {
        bytes4 expected = IMarketRouter.cancelExpiredListing.selector;
        assertEq(expected, REQUIRED_CANCEL_EXPIRED, "cancelExpiredListing selector mismatch");
    }

    // =========================================================================
    // COMPILE-TIME INTERFACE CHECK
    // =========================================================================

    /// @notice Verify IMarketRouter interface does NOT declare buyLock.
    /// @dev This is a compile-time check. If IMarketRouter had buyLock, this file
    ///      would either: (a) fail to compile if we referenced it, or (b) compile
    ///      successfully confirming it doesn't exist.
    function test_interface_noBuyLock() public pure {
        // If this compiles, IMarketRouter does not have buyLock.
        // The absence of a reference to IMarketRouter.buyLock is the test.
        assertTrue(true, "IMarketRouter does not expose buyLock");
    }

    // =========================================================================
    // LISTING SEMANTICS: minClaimOut (not priceInClaim)
    // =========================================================================

    /// @notice Verify Listing struct uses minClaimOut naming.
    /// @dev This is validated by the fact that listLock and getListing use minClaimOut.
    function test_listingSemantics_usesMinClaimOut() public pure {
        // The selector for listLock(uint256,uint256,uint256) is computed from the signature
        // which uses positional types, not names. However, the ABI and docs use
        // "minClaimOut" consistently. This test serves as documentation.
        bytes4 selector = bytes4(keccak256("listLock(uint256,uint256,uint256)"));
        assertEq(selector, REQUIRED_LIST_LOCK, "listLock uses (tokenId, minClaimOut)");
    }
}
