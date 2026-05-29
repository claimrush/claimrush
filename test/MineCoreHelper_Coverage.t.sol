// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MineCoreHelper} from "src/MineCoreHelper.sol";
import {Constants} from "src/lib/Constants.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockVe} from "./mocks/MockVe.sol";

// ──────────────────────────────────────────────────────────
//  Minimal wiring mocks (mutable setters, no circular-dep)
// ──────────────────────────────────────────────────────────

contract MockFurnaceWiring {
    address public mineCore;
    address public claim;
    address public ve;
    address public shareholderRoyalties;

    function setMineCore(address v) external {
        mineCore = v;
    }

    function setClaim(address v) external {
        claim = v;
    }

    function setVe(address v) external {
        ve = v;
    }

    function setShareholderRoyalties(address v) external {
        shareholderRoyalties = v;
    }
}

contract MockFurnaceHelperExtra is MockFurnaceWiring {
    address public delegationHub;
    address public entryTokenRegistry;

    function setDelegationHub(address v) external {
        delegationHub = v;
    }

    function setEntryTokenRegistry(address v) external {
        entryTokenRegistry = v;
    }
}

/// @dev Ve mock that deliberately OMITS claimToken() getter.
///      _staticcallAddress will return address(0), so constructor-time root checks
///      treat it as "unknown" while runtime furnace wiring must fail closed.
contract MockVeWiringNoClaimToken {
    address public furnace;

    function setFurnace(address v) external {
        furnace = v;
    }
    // NO claimToken() — address(0) returned by _staticcallAddress
}

/// @dev Ve mock WITH claimToken() getter for the baseline comparison.
contract MockVeWiringFull {
    address public furnace;
    address public claimToken;

    function setFurnace(address v) external {
        furnace = v;
    }

    function setClaimToken(address v) external {
        claimToken = v;
    }
}

/// @dev Royalties mock that deliberately OMITS mineCore() getter.
///      Like the ve stub above, this remains constructor-compatible but must fail
///      the runtime reciprocal wiring checks.
contract MockRoyaltiesWiringNoMineCore {
    address public ve;
    address public furnace;

    function setVe(address v) external {
        ve = v;
    }

    function setFurnace(address v) external {
        furnace = v;
    }
    // NO mineCore() — address(0) returned by _staticcallAddress
}

/// @dev Royalties mock WITH mineCore() getter for the baseline comparison.
contract MockRoyaltiesWiringFull {
    address public ve;
    address public furnace;
    address public mineCore;

    function setVe(address v) external {
        ve = v;
    }

    function setFurnace(address v) external {
        furnace = v;
    }

    function setMineCore(address v) external {
        mineCore = v;
    }
}

contract MockGuardianWiring {
    address public mineCore;
    address public claim;

    function setMineCore(address v) external {
        mineCore = v;
    }

    function setClaim(address v) external {
        claim = v;
    }
}

contract MockClaimMineCore {
    address public mineCore;

    function setMineCore(address v) external {
        mineCore = v;
    }
}

contract MockCodeOnly {}

/// @dev Registry whose `getRouterConfig()` reverts with a large bytes payload — used to
///      verify that MineCoreHelper's `try/catch` collapses revert-data bombs into a
///      bounded `RouterConfigNotSet` revert without copying the hostile returndata.
contract MockRevertingRegistry {
    function getRouterConfig() external pure returns (address, address, address, address) {
        bytes memory bomb = new bytes(8192);
        assembly ("memory-safe") {
            revert(add(bomb, 0x20), mload(bomb))
        }
    }
}

contract MockEntryTokenRegistryConfig {
    address internal _router;
    address internal _factory;
    address internal _wrappedNative;
    address internal _claimToken;

    function setRouterConfig(address router_, address factory_, address wrappedNative_, address claimToken_) external {
        _router = router_;
        _factory = factory_;
        _wrappedNative = wrappedNative_;
        _claimToken = claimToken_;
    }

    function getRouterConfig()
        external
        view
        returns (address router, address factory, address wrappedNative, address claimToken)
    {
        return (_router, _factory, _wrappedNative, _claimToken);
    }
}

// ──────────────────────────────────────────────────────────
//  Tests
// ──────────────────────────────────────────────────────────

/// @notice Dedicated unit tests for MineCoreHelper edge cases (MCH-07).
contract MineCoreHelper_Coverage_Test is Test {
    MineCoreHelper helper;

    uint256 constant D = 63_072_000; // EMISSION_DECAY_PERIOD
    uint256 constant KING_LAUNCH = 50e18;
    uint256 constant KING_FLOOR = 5_555_555_555_555_555_555;
    uint256 constant FURNACE_LAUNCH = 5e18;
    uint256 constant FURNACE_FLOOR = 555_555_555_555_555_555;
    uint256 constant DECAY_PERIOD = 3600;
    uint256 constant PRICE_FLOOR = 0.001 ether;
    uint256 constant EM_START = 1_700_000_000;

    function setUp() public {
        helper = new MineCoreHelper();
    }

    // ═══════════════════════════════════════════════════════
    //  1. DIFFERENTIAL EMISSION TESTS
    // ═══════════════════════════════════════════════════════

    /// @dev Left-Riemann sum (underestimates), right-Riemann sum (overestimates).
    ///      The trapezoidal result must lie between them.
    function _referenceSums(uint256 emStart, uint256 ts0, uint256 ts1, uint256 launchRate, uint256 floorRate)
        internal
        pure
        returns (uint256 leftSum, uint256 rightSum)
    {
        if (ts1 <= ts0 || ts1 <= emStart) return (0, 0);
        if (ts0 < emStart) ts0 = emStart;

        uint256 diff = launchRate > floorRate ? launchRate - floorRate : 0;

        for (uint256 t = ts0; t < ts1; t++) {
            uint256 elapsed = t - emStart;
            uint256 rate = elapsed >= D || diff == 0 ? floorRate : launchRate - Math.mulDiv(diff, elapsed, D);
            if (rate < floorRate) rate = floorRate;
            leftSum += rate;
        }
        for (uint256 t = ts0 + 1; t <= ts1; t++) {
            uint256 elapsed = t - emStart;
            uint256 rate = elapsed >= D || diff == 0 ? floorRate : launchRate - Math.mulDiv(diff, elapsed, D);
            if (rate < floorRate) rate = floorRate;
            rightSum += rate;
        }
    }

    /// @dev Rate is non-increasing, so left Riemann OVER-estimates and right UNDER-estimates.
    ///      Therefore: rightSum <= trapezoidal (exact) <= leftSum.

    function test_differential_kingEmitted_earlyDecay() public view {
        uint256 ts0 = EM_START;
        uint256 ts1 = EM_START + 100;
        uint256 actual = helper.kingEmitted(EM_START, ts0, ts1);
        (uint256 left, uint256 right) = _referenceSums(EM_START, ts0, ts1, KING_LAUNCH, KING_FLOOR);
        assertGe(actual, right, "trap >= right Riemann (underestimate)");
        assertLe(actual, left, "trap <= left Riemann (overestimate)");
    }

    function test_differential_kingEmitted_midDecay() public view {
        uint256 mid = EM_START + D / 2;
        uint256 actual = helper.kingEmitted(EM_START, mid, mid + 100);
        (uint256 left, uint256 right) = _referenceSums(EM_START, mid, mid + 100, KING_LAUNCH, KING_FLOOR);
        assertGe(actual, right);
        assertLe(actual, left);
    }

    function test_differential_kingEmitted_nearFloor() public view {
        uint256 ts0 = EM_START + D - 100;
        uint256 actual = helper.kingEmitted(EM_START, ts0, ts0 + 100);
        (uint256 left, uint256 right) = _referenceSums(EM_START, ts0, ts0 + 100, KING_LAUNCH, KING_FLOOR);
        assertGe(actual, right);
        assertLe(actual, left);
    }

    function test_differential_kingEmitted_crossingBoundary() public view {
        uint256 ts0 = EM_START + D - 50;
        uint256 ts1 = EM_START + D + 50;
        uint256 actual = helper.kingEmitted(EM_START, ts0, ts1);
        (uint256 left, uint256 right) = _referenceSums(EM_START, ts0, ts1, KING_LAUNCH, KING_FLOOR);
        assertGe(actual, right);
        assertLe(actual, left);
    }

    function test_differential_furnaceEmitted_earlyDecay() public view {
        uint256 actual = helper.furnaceEmitted(EM_START, EM_START, EM_START + 100);
        (uint256 left, uint256 right) =
            _referenceSums(EM_START, EM_START, EM_START + 100, FURNACE_LAUNCH, FURNACE_FLOOR);
        assertGe(actual, right);
        assertLe(actual, left);
    }

    function testFuzz_differential_kingEmitted(uint32 offset, uint16 duration) public view {
        vm.assume(duration > 0 && duration <= 3600);
        uint256 ts0 = EM_START + uint256(offset);
        uint256 ts1 = ts0 + uint256(duration);
        uint256 actual = helper.kingEmitted(EM_START, ts0, ts1);
        (uint256 left, uint256 right) = _referenceSums(EM_START, ts0, ts1, KING_LAUNCH, KING_FLOOR);
        assertGe(actual, right, "fuzz: trap >= right (underestimate)");
        assertLe(actual, left, "fuzz: trap <= left (overestimate)");
    }

    // ═══════════════════════════════════════════════════════
    //  2. EMISSION KNOWN VALUES & EDGE CASES
    // ═══════════════════════════════════════════════════════

    function test_kingEmitted_fullDecayPeriod_knownValue() public view {
        uint256 expected = Math.mulDiv(KING_LAUNCH + KING_FLOOR, D, 2);
        uint256 actual = helper.kingEmitted(EM_START, EM_START, EM_START + D);
        assertEq(actual, expected);
    }

    function test_furnaceEmitted_fullDecayPeriod_knownValue() public view {
        uint256 expected = Math.mulDiv(FURNACE_LAUNCH + FURNACE_FLOOR, D, 2);
        uint256 actual = helper.furnaceEmitted(EM_START, EM_START, EM_START + D);
        assertEq(actual, expected);
    }

    function test_kingEmitted_postFloor_exactProduct() public view {
        uint256 ts0 = EM_START + D + 1000;
        uint256 dt = 86_400;
        uint256 actual = helper.kingEmitted(EM_START, ts0, ts0 + dt);
        assertEq(actual, KING_FLOOR * dt, "post-floor must be floorRate * dt");
    }

    function test_kingEmitted_10to1_furnaceRatio() public view {
        uint256 ts0 = EM_START + 1000;
        uint256 ts1 = ts0 + 100_000;
        uint256 king = helper.kingEmitted(EM_START, ts0, ts1);
        uint256 furnace = helper.furnaceEmitted(EM_START, ts0, ts1);
        // Approximately 10:1 — floor constants differ by 5 CLAIM-wei/sec
        // (KING_FLOOR=...555 vs 10*FURNACE_FLOOR=...550) plus mulDiv rounding.
        assertApproxEqAbs(king, furnace * 10, 1e6, "king/furnace ratio must be ~10:1");
    }

    function test_kingEmitted_ts0EqTs1_zero() public view {
        assertEq(helper.kingEmitted(EM_START, EM_START + 500, EM_START + 500), 0);
    }

    function test_kingEmitted_ts1LtTs0_zero() public view {
        assertEq(helper.kingEmitted(EM_START, EM_START + 2000, EM_START + 1000), 0);
    }

    function test_kingEmitted_bothBeforeEmissionStart_zero() public view {
        assertEq(helper.kingEmitted(EM_START, EM_START - 100, EM_START - 1), 0);
    }

    function test_kingEmitted_ts0BeforeEmissionStart_clamped() public view {
        uint256 withClamp = helper.kingEmitted(EM_START, EM_START - 1000, EM_START + 100);
        uint256 withoutClamp = helper.kingEmitted(EM_START, EM_START, EM_START + 100);
        assertEq(withClamp, withoutClamp);
    }

    function test_kingEmitted_singleSecond_atFloor() public view {
        uint256 ts = EM_START + D + 9999;
        assertEq(helper.kingEmitted(EM_START, ts, ts + 1), KING_FLOOR);
    }

    function test_getFurnaceEmissionRateAt_beforeStart_returnsLaunch() public view {
        assertEq(helper.getFurnaceEmissionRateAt(EM_START, EM_START - 1), FURNACE_LAUNCH);
        assertEq(helper.getFurnaceEmissionRateAt(EM_START, EM_START), FURNACE_LAUNCH);
    }

    function test_getFurnaceEmissionRateAt_midDecay_matchesRateFormula() public view {
        uint256 elapsed = D / 2;
        uint256 diff = FURNACE_LAUNCH - FURNACE_FLOOR;
        uint256 expected = FURNACE_LAUNCH - Math.mulDiv(diff, elapsed, D);
        assertEq(helper.getFurnaceEmissionRateAt(EM_START, EM_START + elapsed), expected);
    }

    function test_getFurnaceEmissionRateAt_afterFloor_returnsFloor() public view {
        assertEq(helper.getFurnaceEmissionRateAt(EM_START, EM_START + D), FURNACE_FLOOR);
        assertEq(helper.getFurnaceEmissionRateAt(EM_START, EM_START + D + 123), FURNACE_FLOOR);
    }

    function testFuzz_kingEmitted_isStrictlyMonotonicOnceLive(uint32 offset, uint32 duration, uint16 extension)
        public
        view
    {
        vm.assume(duration > 0);
        vm.assume(extension > 0);

        uint256 ts0 = EM_START + uint256(offset);
        uint256 ts1 = ts0 + uint256(duration);
        uint256 ts2 = ts1 + uint256(extension);

        uint256 first = helper.kingEmitted(EM_START, ts0, ts1);
        uint256 second = helper.kingEmitted(EM_START, ts0, ts2);

        assertGt(second, first, "later ts1 must strictly increase emitted CLAIM after start");
    }

    /// @dev Trapezoidal integration is exact for the real-valued piecewise-linear rate.
    ///      The integer implementation floor-rounds each `_rateAt` (one per evaluation
    ///      timestamp) and the outer `mulDiv` (one per `_emitted` call). The drift between
    ///      the whole-interval and split computations is bounded above by `(c - a)` wei in
    ///      the worst case (each per-second rate over-approximation contributes ≤ 1 wei to
    ///      the integral over that second, with rate-inflation cancelling between the two
    ///      sides). The tolerance below uses that bound plus a small constant for the two
    ///      additional `mulDiv` floors introduced by splitting.
    function testFuzz_kingEmitted_isSplitAdditive(uint32 offset, uint16 leftSpan, uint16 rightSpan) public view {
        vm.assume(leftSpan > 0);
        vm.assume(rightSpan > 0);

        uint256 a = EM_START + uint256(offset);
        uint256 b = a + uint256(leftSpan);
        uint256 c = b + uint256(rightSpan);

        uint256 whole = helper.kingEmitted(EM_START, a, c);
        uint256 split = helper.kingEmitted(EM_START, a, b) + helper.kingEmitted(EM_START, b, c);

        uint256 tolerance = (c - a) + 4;
        assertApproxEqAbs(whole, split, tolerance, "piecewise integral must be additive within rounding tolerance");
    }

    /// @dev Cross-checks `furnaceEmitted` for the same split-additivity invariant. See the
    ///      tolerance derivation on `testFuzz_kingEmitted_isSplitAdditive`.
    function testFuzz_furnaceEmitted_isSplitAdditive(uint32 offset, uint16 leftSpan, uint16 rightSpan) public view {
        vm.assume(leftSpan > 0);
        vm.assume(rightSpan > 0);

        uint256 a = EM_START + uint256(offset);
        uint256 b = a + uint256(leftSpan);
        uint256 c = b + uint256(rightSpan);

        uint256 whole = helper.furnaceEmitted(EM_START, a, c);
        uint256 split = helper.furnaceEmitted(EM_START, a, b) + helper.furnaceEmitted(EM_START, b, c);

        uint256 tolerance = (c - a) + 4;
        assertApproxEqAbs(whole, split, tolerance, "piecewise integral must be additive within rounding tolerance");
    }

    // ═══════════════════════════════════════════════════════
    //  3. TAKEOVER PRICE EDGE CASES
    // ═══════════════════════════════════════════════════════

    function test_takeoverPrice_noKing_returnsFloor() public view {
        assertEq(helper.takeoverPrice(address(0), 100, 1 ether, 200), PRICE_FLOOR);
    }

    function test_takeoverPrice_refEqFloor_returnsFloor() public view {
        assertEq(helper.takeoverPrice(address(1), 100, PRICE_FLOOR, 200), PRICE_FLOOR);
    }

    function test_takeoverPrice_refBelowFloor_returnsFloor() public view {
        assertEq(helper.takeoverPrice(address(1), 100, PRICE_FLOOR / 2, 200), PRICE_FLOOR);
    }

    function test_takeoverPrice_atReignStart_returnsRef() public view {
        assertEq(helper.takeoverPrice(address(1), 1000, 1 ether, 1000), 1 ether);
    }

    function test_takeoverPrice_beforeReignStart_returnsRef() public view {
        assertEq(helper.takeoverPrice(address(1), 1000, 1 ether, 999), 1 ether);
    }

    function test_takeoverPrice_atDecayEnd_returnsFloor() public view {
        assertEq(helper.takeoverPrice(address(1), 1000, 1 ether, 1000 + DECAY_PERIOD), PRICE_FLOOR);
    }

    function test_takeoverPrice_pastDecayEnd_returnsFloor() public view {
        assertEq(helper.takeoverPrice(address(1), 1000, 1 ether, 1000 + DECAY_PERIOD + 999), PRICE_FLOOR);
    }

    function test_takeoverPrice_midpoint_halfRef() public view {
        uint256 price = helper.takeoverPrice(address(1), 1000, 2 ether, 1000 + DECAY_PERIOD / 2);
        assertEq(price, 1 ether);
    }

    function test_takeoverPrice_roundsFavorablyToKing() public view {
        uint256 ref = 1 ether;
        uint256 price = helper.takeoverPrice(address(1), 1000, ref, 1001);
        // true price = ref * (3599/3600) = 999722222222222222.222...
        // mulDiv floors decayed, so price rounds UP
        assertTrue(price * DECAY_PERIOD >= ref * (DECAY_PERIOD - 1), "must round up (favor king)");
    }

    function test_takeoverPrice_saturatedReference_decaysWithoutOverflow() public view {
        uint256 ref = type(uint256).max;
        uint256 nearEndTs = 1000 + DECAY_PERIOD - 1;
        uint256 expectedNearEnd = ref - Math.mulDiv(ref, DECAY_PERIOD - 1, DECAY_PERIOD);

        assertEq(helper.takeoverPrice(address(1), 1000, ref, 1000), ref);
        assertEq(helper.takeoverPrice(address(1), 1000, ref, nearEndTs), expectedNearEnd);
        assertEq(helper.takeoverPrice(address(1), 1000, ref, 1000 + DECAY_PERIOD), PRICE_FLOOR);
    }

    // ═══════════════════════════════════════════════════════
    //  4. DELEGATION PERMISSION — ALL BRANCHES
    // ═══════════════════════════════════════════════════════

    address constant SENDER = address(0xB0B);
    address constant KING = address(0xA11CE);

    function test_delegation_ethOnly_broadPerm() public view {
        uint256 used = helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT,
            SENDER,
            KING,
            address(0x1),
            address(0x2), // eth changed
            KING,
            KING // claim unchanged
        );
        assertEq(used, DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT);
    }

    function test_delegation_ethOnly_callerOnlyPerm() public view {
        uint256 used = helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY,
            SENDER,
            KING,
            SENDER,
            address(0x2), // eth → sender
            KING,
            KING
        );
        assertEq(used, DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY);
    }

    function test_delegation_ethOnly_callerOnly_wrongAddr_reverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY,
            SENDER,
            KING,
            address(0x9),
            address(0x2), // NOT sender
            KING,
            KING
        );
    }

    function test_delegation_claimOnly_broadPerm() public view {
        uint256 used = helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT,
            SENDER,
            KING,
            SENDER,
            SENDER, // eth unchanged
            address(0x1),
            address(0x2) // claim changed
        );
        assertEq(used, DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT);
    }

    function test_delegation_claimOnly_toUserOnlyPerm() public view {
        uint256 used = helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY,
            SENDER,
            KING,
            SENDER,
            SENDER,
            KING,
            address(0x2) // claim → king
        );
        assertEq(used, DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY);
    }

    function test_delegation_claimOnly_toUserOnly_wrongAddr_reverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY,
            SENDER,
            KING,
            SENDER,
            SENDER,
            address(0x9),
            address(0x2) // NOT king
        );
    }

    function test_delegation_bothChanged_broadPerms() public view {
        uint256 perms =
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT;
        uint256 used = helper.resolveDelegatedReignRecipientPerms(
            perms, SENDER, KING, address(0x1), address(0x2), address(0x3), address(0x4)
        );
        assertEq(used, perms);
    }

    function test_delegation_bothChanged_narrowPerms() public view {
        uint256 perms = DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY
            | DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT_TO_USER_ONLY;
        uint256 used = helper.resolveDelegatedReignRecipientPerms(
            perms,
            SENDER,
            KING,
            SENDER,
            address(0x2), // eth → sender
            KING,
            address(0x4) // claim → king
        );
        assertEq(used, perms);
    }

    function test_delegation_neitherChanged_returnsZero() public view {
        uint256 used = helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT,
            SENDER,
            KING,
            address(0x1),
            address(0x1), // same
            KING,
            KING // same
        );
        assertEq(used, 0);
    }

    function test_delegation_noSplitBits_reverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_TAKEOVER_FOR, // no split bits
            SENDER,
            KING,
            address(0x1),
            address(0x2),
            address(0x3),
            address(0x4)
        );
    }

    function test_delegation_broadSubsumesNarrow_eth() public view {
        uint256 perms = DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT
            | DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT_TO_CALLER_ONLY;
        uint256 used = helper.resolveDelegatedReignRecipientPerms(
            perms,
            SENDER,
            KING,
            address(0x9),
            address(0x2), // eth → third party (only broad allows)
            KING,
            KING
        );
        assertEq(used, DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT, "broad must be consumed, not narrow");
    }

    function test_delegation_ethChanged_noEthPerm_reverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_CLAIM_RECIPIENT, // only claim perm
            SENDER,
            KING,
            address(0x1),
            address(0x2), // eth changed!
            KING,
            KING
        );
    }

    function test_delegation_claimChanged_noClaimPerm_reverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.resolveDelegatedReignRecipientPerms(
            DelegationPermissions.P_SET_REIGN_ETH_RECIPIENT, // only eth perm
            SENDER,
            KING,
            SENDER,
            SENDER,
            address(0x3),
            address(0x4) // claim changed!
        );
    }

    // ═══════════════════════════════════════════════════════
    //  5. WIRING STRICTNESS EDGE CASES
    // ═══════════════════════════════════════════════════════

    /// @dev ve omits claimToken() → strict runtime wiring check must now fail closed.
    function test_wiring_strictCheck_veNoClaimToken_fails() public {
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");

        MockFurnaceWiring f = new MockFurnaceWiring();
        MockVeWiringNoClaimToken v = new MockVeWiringNoClaimToken();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();

        f.setMineCore(mc);
        f.setClaim(cl);
        f.setVe(address(v));
        f.setShareholderRoyalties(address(r));
        v.setFurnace(address(f));
        r.setVe(address(v));
        r.setFurnace(address(f));
        r.setMineCore(mc);

        bool ok = helper.isReciprocallyWiredFurnace(mc, cl, address(v), address(r), address(f));
        assertFalse(ok, "runtime wiring must fail when ve omits claimToken()");
    }

    /// @dev royalties omits mineCore() → strict runtime wiring check must now fail closed.
    function test_wiring_strictCheck_royaltiesNoMineCore_fails() public {
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");

        MockFurnaceWiring f = new MockFurnaceWiring();
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringNoMineCore r = new MockRoyaltiesWiringNoMineCore();

        f.setMineCore(mc);
        f.setClaim(cl);
        f.setVe(address(v));
        f.setShareholderRoyalties(address(r));
        v.setFurnace(address(f));
        v.setClaimToken(cl);
        r.setVe(address(v));
        r.setFurnace(address(f));

        bool ok = helper.isReciprocallyWiredFurnace(mc, cl, address(v), address(r), address(f));
        assertFalse(ok, "runtime wiring must fail when royalties omits mineCore()");
    }

    /// @dev Both optional-getter omissions on the same wiring path still fail closed.
    function test_wiring_strictCheck_bothOmitted_fails() public {
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");

        MockFurnaceWiring f = new MockFurnaceWiring();
        MockVeWiringNoClaimToken v = new MockVeWiringNoClaimToken();
        MockRoyaltiesWiringNoMineCore r = new MockRoyaltiesWiringNoMineCore();

        f.setMineCore(mc);
        f.setClaim(cl);
        f.setVe(address(v));
        f.setShareholderRoyalties(address(r));
        v.setFurnace(address(f));
        r.setVe(address(v));
        r.setFurnace(address(f));

        bool ok = helper.isReciprocallyWiredFurnace(mc, cl, address(v), address(r), address(f));
        assertFalse(ok, "both omitted getters must fail runtime wiring");
    }

    /// @dev Baseline: all getters present and correct → passes.
    function test_wiring_allGetters_correct_passes() public {
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");

        MockFurnaceWiring f = new MockFurnaceWiring();
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();

        f.setMineCore(mc);
        f.setClaim(cl);
        f.setVe(address(v));
        f.setShareholderRoyalties(address(r));
        v.setFurnace(address(f));
        v.setClaimToken(cl);
        r.setVe(address(v));
        r.setFurnace(address(f));
        r.setMineCore(mc);

        assertTrue(helper.isReciprocallyWiredFurnace(mc, cl, address(v), address(r), address(f)));
    }

    /// @dev ve.claimToken() returns WRONG address (not address(0)) → hard fail.
    function test_wiring_veWrongClaimToken_fails() public {
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");

        MockFurnaceWiring f = new MockFurnaceWiring();
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();

        f.setMineCore(mc);
        f.setClaim(cl);
        f.setVe(address(v));
        f.setShareholderRoyalties(address(r));
        v.setFurnace(address(f));
        v.setClaimToken(makeAddr("wrongClaim")); // WRONG
        r.setVe(address(v));
        r.setFurnace(address(f));
        r.setMineCore(mc);

        assertFalse(helper.isReciprocallyWiredFurnace(mc, cl, address(v), address(r), address(f)));
    }

    /// @dev royalties.mineCore() returns WRONG address → hard fail.
    function test_wiring_royaltiesWrongMineCore_fails() public {
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");

        MockFurnaceWiring f = new MockFurnaceWiring();
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();

        f.setMineCore(mc);
        f.setClaim(cl);
        f.setVe(address(v));
        f.setShareholderRoyalties(address(r));
        v.setFurnace(address(f));
        v.setClaimToken(cl);
        r.setVe(address(v));
        r.setFurnace(address(f));
        r.setMineCore(makeAddr("wrongMC")); // WRONG

        assertFalse(helper.isReciprocallyWiredFurnace(mc, cl, address(v), address(r), address(f)));
    }

    /// @dev furnace == address(0) → immediate false.
    function test_wiring_zeroFurnace_fails() public {
        assertFalse(
            helper.isReciprocallyWiredFurnace(makeAddr("mc"), makeAddr("cl"), makeAddr("ve"), makeAddr("r"), address(0))
        );
    }

    function test_requireCanonicalCoreRoots_acceptsCanonicalRoots() public {
        address mc = makeAddr("mineCore");
        MockClaimMineCore claimToken = new MockClaimMineCore();
        address cl = address(claimToken);
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();
        claimToken.setMineCore(mc);
        v.setClaimToken(cl);
        r.setVe(address(v));

        helper.requireCanonicalCoreRoots(mc, cl, address(v), address(r));
    }

    function test_requireCanonicalCoreRoots_softPassesWhenGettersOmitted() public {
        address mc = makeAddr("mineCore");
        MockCodeOnly claimToken = new MockCodeOnly();
        address cl = address(claimToken);
        MockVeWiringNoClaimToken v = new MockVeWiringNoClaimToken();
        MockRoyaltiesWiringNoMineCore r = new MockRoyaltiesWiringNoMineCore();
        r.setVe(address(v));

        helper.requireCanonicalCoreRoots(mc, cl, address(v), address(r));
    }

    function test_requireCanonicalCoreRoots_wrongVeClaim_reverts() public {
        address mc = makeAddr("mineCore");
        MockCodeOnly claimToken = new MockCodeOnly();
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();
        v.setClaimToken(makeAddr("wrongClaim"));
        r.setVe(address(v));

        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.requireCanonicalCoreRoots(mc, address(claimToken), address(v), address(r));
    }

    function test_requireCanonicalCoreRoots_wrongRoyaltiesVe_reverts() public {
        address mc = makeAddr("mineCore");
        MockCodeOnly claimToken = new MockCodeOnly();
        address cl = address(claimToken);
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();
        v.setClaimToken(cl);
        r.setVe(makeAddr("wrongVe"));

        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.requireCanonicalCoreRoots(mc, cl, address(v), address(r));
    }

    function test_requireCanonicalCoreRoots_wrongClaimMineCore_reverts() public {
        address mc = makeAddr("mineCore");
        MockClaimMineCore claimToken = new MockClaimMineCore();
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();

        claimToken.setMineCore(makeAddr("otherMineCore"));
        v.setClaimToken(address(claimToken));
        r.setVe(address(v));

        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.requireCanonicalCoreRoots(mc, address(claimToken), address(v), address(r));
    }

    function test_sharesEntryTokenRegistry_trueWhenSameRegistry() public {
        MockFurnaceHelperExtra f = new MockFurnaceHelperExtra();
        address reg = makeAddr("registry");
        f.setEntryTokenRegistry(reg);

        assertTrue(helper.sharesEntryTokenRegistry(address(f), reg));
    }

    function test_sharesEntryTokenRegistry_falseWhenGetterMissingOrDifferent() public {
        MockFurnaceWiring f1 = new MockFurnaceWiring();
        MockFurnaceHelperExtra f2 = new MockFurnaceHelperExtra();
        f2.setEntryTokenRegistry(makeAddr("otherRegistry"));

        assertFalse(helper.sharesEntryTokenRegistry(address(f1), makeAddr("registry")));
        assertFalse(helper.sharesEntryTokenRegistry(address(f2), makeAddr("registry")));
    }

    function test_requireCanonicalDelegationHub_acceptsCanonicalHub() public {
        address mc = makeAddr("mc");
        MockCodeOnly claimToken = new MockCodeOnly();
        MockCodeOnly hubContract = new MockCodeOnly();
        address cl = address(claimToken);
        address hub = address(hubContract);

        MockFurnaceHelperExtra f = new MockFurnaceHelperExtra();
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();

        f.setMineCore(mc);
        f.setClaim(cl);
        f.setVe(address(v));
        f.setShareholderRoyalties(address(r));
        f.setDelegationHub(hub);
        v.setFurnace(address(f));
        v.setClaimToken(cl);
        r.setVe(address(v));
        r.setFurnace(address(f));
        r.setMineCore(mc);

        helper.requireCanonicalDelegationHub(mc, cl, address(v), address(r), address(f), hub);
    }

    function test_requireCanonicalDelegationHub_mismatch_reverts() public {
        address mc = makeAddr("mc");
        MockCodeOnly claimToken = new MockCodeOnly();
        MockCodeOnly hubContract = new MockCodeOnly();
        address cl = address(claimToken);
        address hub = address(hubContract);

        MockFurnaceHelperExtra f = new MockFurnaceHelperExtra();
        MockVeWiringFull v = new MockVeWiringFull();
        MockRoyaltiesWiringFull r = new MockRoyaltiesWiringFull();

        f.setMineCore(mc);
        f.setClaim(cl);
        f.setVe(address(v));
        f.setShareholderRoyalties(address(r));
        f.setDelegationHub(makeAddr("otherHub"));
        v.setFurnace(address(f));
        v.setClaimToken(cl);
        r.setVe(address(v));
        r.setFurnace(address(f));
        r.setMineCore(mc);

        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.requireCanonicalDelegationHub(mc, cl, address(v), address(r), address(f), hub);
    }

    // ═══════════════════════════════════════════════════════
    //  6. AUTO-LOCK DESTINATION — ALL FAILURE CODES
    // ═══════════════════════════════════════════════════════

    MockVe internal mockVe;

    function _deployMockVe() internal {
        mockVe = new MockVe();
    }

    function test_autoLock_createOnce_returnsOk() public {
        _deployMockVe();
        (bool ok, uint256 tid, uint256 dur, bool autoMax, uint8 reason) =
            helper.resolveKingAutoLockDestination(address(mockVe), KING, 0, 30 days, false);
        assertTrue(ok);
        assertEq(tid, 0);
        assertEq(dur, 30 days);
        assertFalse(autoMax);
        assertEq(reason, 0);
    }

    function test_autoLock_createOnce_autoMax() public {
        _deployMockVe();
        (bool ok,, uint256 dur, bool autoMax,) =
            helper.resolveKingAutoLockDestination(address(mockVe), KING, 0, 365 days, true);
        assertTrue(ok);
        assertEq(dur, 365 days);
        assertTrue(autoMax);
    }

    function test_autoLock_invalidTokenId() public {
        _deployMockVe();
        // tokenId 999 does not exist → ownerOf reverts
        (bool ok,,,, uint8 reason) = helper.resolveKingAutoLockDestination(address(mockVe), KING, 999, 30 days, false);
        assertFalse(ok);
        assertEq(reason, 4); // KING_AUTOLOCK_REASON_INVALID_TOKEN_ID
    }

    function test_autoLock_notOwner() public {
        _deployMockVe();
        mockVe.setOwner(1, address(0xDEAD)); // owned by someone else
        mockVe.setLockInfo(1, 1000e18, block.timestamp + 365 days, false, false);
        (bool ok,,,, uint8 reason) = helper.resolveKingAutoLockDestination(address(mockVe), KING, 1, 30 days, false);
        assertFalse(ok);
        assertEq(reason, 1); // KING_AUTOLOCK_REASON_NOT_OWNER
    }

    function test_autoLock_listed() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        mockVe.setLockInfo(1, 1000e18, block.timestamp + 365 days, false, true); // listed = true
        (bool ok,,,, uint8 reason) = helper.resolveKingAutoLockDestination(address(mockVe), KING, 1, 30 days, false);
        assertFalse(ok);
        assertEq(reason, 2); // KING_AUTOLOCK_REASON_LISTED
    }

    function test_autoLock_expired_lockEndPast() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        mockVe.setLockInfo(1, 1000e18, block.timestamp - 1, false, false); // expired
        (bool ok,,,, uint8 reason) = helper.resolveKingAutoLockDestination(address(mockVe), KING, 1, 30 days, false);
        assertFalse(ok);
        assertEq(reason, 3); // KING_AUTOLOCK_REASON_EXPIRED
    }

    function test_autoLock_expired_remainingBelowMin() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        // remaining = 6 days < MIN_LOCK_DURATION (7 days)
        mockVe.setLockInfo(1, 1000e18, block.timestamp + 6 days, false, false);
        (bool ok,,,, uint8 reason) = helper.resolveKingAutoLockDestination(address(mockVe), KING, 1, 30 days, false);
        assertFalse(ok);
        assertEq(reason, 3); // KING_AUTOLOCK_REASON_EXPIRED
    }

    function test_autoLock_existingAutoMax_usesMaxDuration() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        mockVe.setLockInfo(1, 1000e18, block.timestamp + 365 days, true, false); // autoMax = true
        (bool ok, uint256 tid, uint256 dur, bool autoMax,) =
            helper.resolveKingAutoLockDestination(address(mockVe), KING, 1, 30 days, false);
        assertTrue(ok);
        assertEq(tid, 1);
        assertEq(dur, Constants.MAX_LOCK_DURATION);
        assertFalse(autoMax, "createAutoMax must be false for existing autoMax lock");
    }

    function test_autoLock_existingLock_durationZero_usesRemaining() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        uint256 remaining = 100 days;
        mockVe.setLockInfo(1, 1000e18, block.timestamp + remaining, false, false);
        (bool ok,, uint256 dur,,) = helper.resolveKingAutoLockDestination(address(mockVe), KING, 1, 0, false);
        assertTrue(ok);
        assertEq(dur, remaining, "durationSeconds=0 must use remaining");
    }

    function test_autoLock_existingLock_desiredBelowRemaining_clampsUp() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        uint256 remaining = 100 days;
        mockVe.setLockInfo(1, 1000e18, block.timestamp + remaining, false, false);
        // desired = 30 days < remaining = 100 days → clamped to remaining
        (bool ok,, uint256 dur,,) = helper.resolveKingAutoLockDestination(address(mockVe), KING, 1, 30 days, false);
        assertTrue(ok);
        assertEq(dur, remaining, "desired < remaining must clamp up");
    }

    function test_autoLock_existingLock_desiredAboveRemaining_usesDesired() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        uint256 remaining = 30 days;
        mockVe.setLockInfo(1, 1000e18, block.timestamp + remaining, false, false);
        // desired = 100 days > remaining = 30 days → uses desired
        (bool ok,, uint256 dur,,) = helper.resolveKingAutoLockDestination(address(mockVe), KING, 1, 100 days, false);
        assertTrue(ok);
        assertEq(dur, 100 days, "desired > remaining must use desired");
    }

    function test_validateKingAutoLockExistingTarget_acceptsValidTarget() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        mockVe.setLockInfo(1, 1000e18, block.timestamp + 100 days, false, false);

        helper.validateKingAutoLockExistingTarget(address(mockVe), KING, 1, 0);
    }

    function test_validateKingAutoLockExistingTarget_invalidToken_reverts() public {
        _deployMockVe();

        vm.expectRevert(Errors.InvalidToken.selector);
        helper.validateKingAutoLockExistingTarget(address(mockVe), KING, 999, 0);
    }

    function test_validateKingAutoLockExistingTarget_notOwner_reverts() public {
        _deployMockVe();
        mockVe.setOwner(1, address(0xBEEF));
        mockVe.setLockInfo(1, 1000e18, block.timestamp + 100 days, false, false);

        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.validateKingAutoLockExistingTarget(address(mockVe), KING, 1, 0);
    }

    function test_validateKingAutoLockExistingTarget_listed_reverts() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        mockVe.setLockInfo(1, 1000e18, block.timestamp + 100 days, false, true);

        vm.expectRevert(Errors.LockListedOrFrozen.selector);
        helper.validateKingAutoLockExistingTarget(address(mockVe), KING, 1, 0);
    }

    function test_validateKingAutoLockExistingTarget_expired_reverts() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        mockVe.setLockInfo(1, 1000e18, block.timestamp, false, false);

        vm.expectRevert(Errors.LockExpired.selector);
        helper.validateKingAutoLockExistingTarget(address(mockVe), KING, 1, 0);
    }

    function test_validateKingAutoLockExistingTarget_autoMaxWrongDuration_reverts() public {
        _deployMockVe();
        mockVe.setOwner(1, KING);
        mockVe.setLockInfo(1, 1000e18, block.timestamp + 100 days, true, false);

        vm.expectRevert(Errors.InvalidDuration.selector);
        helper.validateKingAutoLockExistingTarget(address(mockVe), KING, 1, uint32(30 days));
    }

    // ═══════════════════════════════════════════════════════
    //  7. GENESIS GUARDIAN — MINIMAL CHECKS
    // ═══════════════════════════════════════════════════════

    function test_genesisGuardian_zeroAddr_false() public view {
        assertFalse(helper.isCanonicalGenesisGuardian(address(0xAA), address(0xBB), address(0)));
    }

    function test_genesisGuardian_eoa_false() public view {
        assertFalse(helper.isCanonicalGenesisGuardian(address(0xAA), address(0xBB), address(0xCC)));
    }

    function test_genesisGuardian_matchingPointers_true() public {
        MockGuardianWiring g = new MockGuardianWiring();
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");
        g.setMineCore(mc);
        g.setClaim(cl);

        assertTrue(helper.isCanonicalGenesisGuardian(mc, cl, address(g)));
    }

    function test_genesisGuardian_wrongClaim_false() public {
        MockGuardianWiring g = new MockGuardianWiring();
        address mc = makeAddr("mc");
        g.setMineCore(mc);
        g.setClaim(makeAddr("wrongClaim"));

        assertFalse(helper.isCanonicalGenesisGuardian(mc, makeAddr("claim"), address(g)));
    }

    function test_getValidatedRouterConfig_acceptsCanonicalConfig() public {
        MockEntryTokenRegistryConfig reg = new MockEntryTokenRegistryConfig();
        MockCodeOnly router = new MockCodeOnly();
        MockCodeOnly factory = new MockCodeOnly();
        MockCodeOnly wrappedNative = new MockCodeOnly();
        MockCodeOnly claimToken = new MockCodeOnly();
        reg.setRouterConfig(address(router), address(factory), address(wrappedNative), address(claimToken));

        (address outRouter, address outFactory, address outWrapped) =
            helper.getValidatedRouterConfig(address(reg), address(claimToken));

        assertEq(outRouter, address(router));
        assertEq(outFactory, address(factory));
        assertEq(outWrapped, address(wrappedNative));
    }

    function test_getValidatedRouterConfig_zeroField_reverts() public {
        MockEntryTokenRegistryConfig reg = new MockEntryTokenRegistryConfig();
        MockCodeOnly router = new MockCodeOnly();
        MockCodeOnly factory = new MockCodeOnly();
        MockCodeOnly claimToken = new MockCodeOnly();
        reg.setRouterConfig(address(router), address(factory), address(0), address(claimToken));

        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        helper.getValidatedRouterConfig(address(reg), address(claimToken));
    }

    function test_getValidatedRouterConfig_nonContractField_reverts() public {
        MockEntryTokenRegistryConfig reg = new MockEntryTokenRegistryConfig();
        MockCodeOnly claimToken = new MockCodeOnly();
        reg.setRouterConfig(makeAddr("router"), makeAddr("factory"), makeAddr("weth"), address(claimToken));

        vm.expectRevert(Errors.NotAContract.selector);
        helper.getValidatedRouterConfig(address(reg), address(claimToken));
    }

    function test_getValidatedRouterConfig_claimMismatch_reverts() public {
        MockEntryTokenRegistryConfig reg = new MockEntryTokenRegistryConfig();
        MockCodeOnly router = new MockCodeOnly();
        MockCodeOnly factory = new MockCodeOnly();
        MockCodeOnly wrappedNative = new MockCodeOnly();
        MockCodeOnly claimToken = new MockCodeOnly();
        reg.setRouterConfig(address(router), address(factory), address(wrappedNative), address(claimToken));

        vm.expectRevert(Errors.InvalidToken.selector);
        helper.getValidatedRouterConfig(address(reg), makeAddr("otherClaim"));
    }

    // ═══════════════════════════════════════════════════════
    //  Side-B regression: revert-data bomb, EIP-7702, range guards
    // ═══════════════════════════════════════════════════════

    /// @dev A hostile registry whose `getRouterConfig()` reverts with arbitrarily large
    ///      revert data must NOT propagate that data through the helper. The helper's
    ///      `try/catch` collapses the revert into a deterministic `RouterConfigNotSet`.
    function test_getValidatedRouterConfig_revertBomb_collapsesToRouterConfigNotSet() public {
        MockRevertingRegistry reg = new MockRevertingRegistry();
        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        helper.getValidatedRouterConfig(address(reg), makeAddr("anyClaim"));
    }

    /// @dev A 7702-delegated EOA presents `code.length == 23` with a `0xEF0100...` prefix.
    ///      The helper's wiring/admission paths must reject such addresses identically to
    ///      bare EOAs.
    function _etchDelegatedEOA(address a, address delegate) internal {
        bytes memory designator = new bytes(23);
        designator[0] = 0xEF;
        designator[1] = 0x01;
        designator[2] = 0x00;
        bytes20 d = bytes20(delegate);
        for (uint256 i = 0; i < 20; i++) {
            designator[3 + i] = d[i];
        }
        vm.etch(a, designator);
    }

    function test_isCanonicalGenesisGuardian_rejectsDelegatedEOA() public {
        address candidate = makeAddr("delegatedEOA");
        _etchDelegatedEOA(candidate, address(this));
        assertFalse(helper.isCanonicalGenesisGuardian(makeAddr("mc"), makeAddr("cl"), candidate));
    }

    function test_requireCanonicalCoreRoots_rejectsDelegatedEOA() public {
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");
        address veRoot = makeAddr("ve");
        address royaltiesRoot = makeAddr("royalties");
        _etchDelegatedEOA(cl, address(this));
        vm.etch(veRoot, hex"6000");
        vm.etch(royaltiesRoot, hex"6000");
        vm.expectRevert(Errors.NotAContract.selector);
        helper.requireCanonicalCoreRoots(mc, cl, veRoot, royaltiesRoot);
    }

    function test_isReciprocallyWiredFurnace_rejectsDelegatedEOA() public {
        address mc = makeAddr("mc");
        address cl = makeAddr("cl");
        address ve = makeAddr("ve2");
        address royalties = makeAddr("royalties2");
        address furnace = makeAddr("furnace");
        _etchDelegatedEOA(furnace, address(this));
        vm.etch(ve, hex"6000");
        vm.etch(royalties, hex"6000");
        assertFalse(helper.isReciprocallyWiredFurnace(mc, cl, ve, royalties, furnace));
    }

    function test_requireCanonicalDelegationHub_rejectsDelegatedEOA() public {
        address hub = makeAddr("hub");
        _etchDelegatedEOA(hub, address(this));
        vm.expectRevert(Errors.NotAContract.selector);
        helper.requireCanonicalDelegationHub(
            makeAddr("mc"), makeAddr("cl"), makeAddr("ve"), makeAddr("royalties"), makeAddr("furnace"), hub
        );
    }

    function test_getValidatedRouterConfig_rejectsDelegatedEOAReg() public {
        address reg = makeAddr("reg7702");
        _etchDelegatedEOA(reg, address(this));
        vm.expectRevert(Errors.RouterConfigNotSet.selector);
        helper.getValidatedRouterConfig(reg, makeAddr("cl"));
    }

    /// @dev When `tokenId == 0` and `durationSeconds` is out of the lock-duration range,
    ///      the resolver must return `(false, ..., KING_AUTOLOCK_REASON_INVALID_DURATION)`.
    function test_resolveKingAutoLock_freshLock_belowMin_returnsReason5() public {
        _deployMockVe();
        address king = address(0xCAFE);
        (bool ok,,,, uint8 reason) = helper.resolveKingAutoLockDestination(
            address(mockVe), king, 0, uint32(Constants.MIN_LOCK_DURATION - 1), false
        );
        assertFalse(ok);
        assertEq(reason, 5, "reason must be KING_AUTOLOCK_REASON_INVALID_DURATION");
    }

    function test_resolveKingAutoLock_freshLock_aboveMax_returnsReason5() public {
        _deployMockVe();
        address king = address(0xCAFE);
        (bool ok,,,, uint8 reason) =
            helper.resolveKingAutoLockDestination(address(mockVe), king, 0, type(uint32).max, false);
        assertFalse(ok);
        assertEq(reason, 5);
    }

    /// @dev When `tokenId == 0` and `durationSeconds == 0`, the bypass-validation branch
    ///      passes through unchanged ("use what MineCore already validated" semantics).
    function test_resolveKingAutoLock_freshLock_zeroDuration_passesThrough() public {
        _deployMockVe();
        address king = address(0xCAFE);
        (bool ok,, uint256 dur,, uint8 reason) =
            helper.resolveKingAutoLockDestination(address(mockVe), king, 0, 0, true);
        assertTrue(ok);
        assertEq(dur, 0);
        assertEq(reason, 0);
    }
}
