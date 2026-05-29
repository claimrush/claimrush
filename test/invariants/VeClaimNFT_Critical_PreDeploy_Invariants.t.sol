// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "../mocks/MockShareholderRoyaltiesCheckpoint.sol";

/// @title Critical pre-deploy invariant tests for VeClaimNFT.
/// @dev 40-step random state machine with 3 actors. Covers 8 invariant groups:
///      INV-1: Global bias safety (bias >= 0 after checkpoint)
///      INV-2: totalVeCache monotonicity (decreases or stays flat between checkpoints)
///      INV-3: globalLastTs never exceeds block.timestamp
///      INV-4: Per-user ve bounds (veBalanceOf <= totalVeCurrent)
///      INV-5: Principal conservation (totalLockedClaim == sum of lock amounts)
///      INV-6: Lock field consistency (amount > 0 ↔ lockEnd > 0, autoMax → lockEnd > now)
///      INV-7: Ve decay monotonicity (warp forward → ve decreases for non-autoMax)
///      INV-8: Token ID allocation (monotonically increasing, unique)
contract VeClaimNFTCriticalPreDeployInvariantsTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MockShareholderRoyaltiesCheckpoint internal srMock;

    address internal owner = address(0xA11CE);
    address internal mineCore = address(0xC0DE);
    address internal mineMarket = address(0xB0B0);
    address internal furnace = address(0xF00D);

    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal carol = address(0xC);

    uint256[] internal allTokenIds;

    function setUp() public {
        vm.etch(owner, hex"00");
        vm.etch(mineCore, hex"00");
        vm.etch(mineMarket, hex"00");
        vm.etch(furnace, hex"00");

        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        srMock = new MockShareholderRoyaltiesCheckpoint();
        srMock.setWiring(mineCore, mineMarket, furnace, address(ve));

        vm.mockCall(owner, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(furnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnace, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnace, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(furnace, abi.encodeWithSignature("delegationHub()"), abi.encode(address(0)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnace));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(srMock)));
        vm.mockCall(mineCore, abi.encodeWithSignature("delegationHub()"), abi.encode(address(0)));
        vm.mockCall(mineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));

        vm.prank(owner);
        claim.setMineCore(mineCore);

        vm.startPrank(owner);
        ve.setMineMarket(mineMarket);
        ve.setFurnace(furnace);
        vm.stopPrank();

        vm.prank(mineCore);
        claim.mint(alice, 100_000_000e18);
        vm.prank(mineCore);
        claim.mint(bob, 100_000_000e18);
        vm.prank(mineCore);
        claim.mint(carol, 100_000_000e18);

        vm.prank(alice);
        claim.approve(address(ve), type(uint256).max);
        vm.prank(bob);
        claim.approve(address(ve), type(uint256).max);
        vm.prank(carol);
        claim.approve(address(ve), type(uint256).max);
    }

    // ---- Helpers ----

    function _actor(uint256 seed) internal view returns (address) {
        uint256 idx = seed % 3;
        if (idx == 0) return alice;
        if (idx == 1) return bob;
        return carol;
    }

    function _createLockAs(address user, uint256 amount, uint256 duration, bool autoMax) internal returns (uint256) {
        vm.prank(user);
        uint256 tokenId = ve.createLock(amount, duration, autoMax);
        allTokenIds.push(tokenId);
        return tokenId;
    }

    // ---- INV-1: Global bias safety ----

    function testFuzz_globalBiasNonNegativeAfterCheckpoint(uint256 seed) public {
        uint256 amt = bound(seed, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);
        _createLockAs(alice, amt, 90 days, false);

        vm.warp(block.timestamp + 180 days);
        ve.checkpointGlobalState();

        uint256 cached = ve.totalVeCached();
        assertTrue(cached < type(uint256).max / 2, "INV-1: bias overflow - cached exceeds safe range");
    }

    // ---- INV-2: totalVeCache monotonicity ----

    function testFuzz_totalVeCacheDecreasesBetweenCheckpoints(uint256 seed) public {
        uint256 amt = bound(seed, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);
        _createLockAs(alice, amt, Constants.MAX_LOCK_DURATION, false);

        ve.checkpointGlobalState();
        uint256 before = ve.totalVeCached();

        vm.warp(block.timestamp + 30 days);
        ve.checkpointGlobalState();
        uint256 after_ = ve.totalVeCached();

        assertLe(after_, before, "INV-2: totalVeCached increased without new locks");
    }

    // ---- INV-3: globalLastTs never exceeds block.timestamp ----

    function testFuzz_globalLastTsBounded(uint256 seed) public {
        uint256 amt = bound(seed, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);
        _createLockAs(alice, amt, 90 days, false);

        vm.warp(block.timestamp + 7 days);
        ve.checkpointGlobalState();

        assertLe(ve.globalLastTs(), block.timestamp, "INV-3: globalLastTs exceeds block.timestamp");
    }

    // ---- INV-4: Per-user ve bounds ----

    function testFuzz_userVeLeqTotalVe(uint256 seed) public {
        uint256 amt = bound(seed, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);
        _createLockAs(alice, amt, Constants.MAX_LOCK_DURATION, false);
        _createLockAs(bob, amt, Constants.MAX_LOCK_DURATION, true);

        ve.checkpointGlobalState();

        uint256 aliceVe = ve.veBalanceOf(alice);
        uint256 bobVe = ve.veBalanceOf(bob);
        uint256 total = ve.totalVeCurrent();

        assertLe(aliceVe, total, "INV-4: alice ve exceeds totalVeCurrent");
        assertLe(bobVe, total, "INV-4: bob ve exceeds totalVeCurrent");
        assertLe(aliceVe + bobVe, total, "INV-4: sum of user ve exceeds totalVeCurrent");
    }

    // ---- INV-5: Principal conservation ----

    function testFuzz_principalConservation(uint256 seed) public {
        uint256 amt1 = bound(seed, Constants.MIN_LOCK_AMOUNT, 5_000_000e18);
        uint256 amt2 = bound(uint256(keccak256(abi.encode(seed))), Constants.MIN_LOCK_AMOUNT, 5_000_000e18);

        uint256 claimBefore = claim.balanceOf(alice);

        vm.startPrank(alice);
        uint256 t1 = ve.createLock(amt1, 90 days, false);
        allTokenIds.push(t1);
        ve.addToLock(t1, amt2);
        vm.stopPrank();

        assertEq(ve.totalLockedClaim(), amt1 + amt2, "INV-5: totalLockedClaim != sum of deposited amounts");
        assertEq(claim.balanceOf(alice), claimBefore - amt1 - amt2, "INV-5: alice CLAIM balance mismatch");
    }

    // ---- INV-6: Lock field consistency ----

    function testFuzz_lockFieldConsistency(uint256 seed) public {
        uint256 amt = bound(seed, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);
        bool autoMax = seed % 2 == 0;
        uint256 duration = autoMax
            ? Constants.MAX_LOCK_DURATION
            : bound(seed >> 8, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        uint256 tokenId = _createLockAs(alice, amt, duration, autoMax);

        (uint256 amount, uint256 lockEnd, bool am, bool listed) = ve.getLockInfo(tokenId);
        assertTrue(amount > 0, "INV-6: amount is zero for active lock");
        assertTrue(lockEnd > 0, "INV-6: lockEnd is zero for active lock");
        assertEq(am, autoMax, "INV-6: autoMax mismatch");
        assertFalse(listed, "INV-6: fresh lock should not be listed");

        if (autoMax) {
            assertGt(lockEnd, block.timestamp, "INV-6: autoMax lockEnd should be > now");
        }
    }

    // ---- INV-7: Ve decay monotonicity ----

    function testFuzz_veDecayMonotonicity(uint256 seed) public {
        uint256 amt = bound(seed, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);
        _createLockAs(alice, amt, Constants.MAX_LOCK_DURATION, false);

        ve.checkpointGlobalState();
        uint256 veBefore = ve.veBalanceOf(alice);

        vm.warp(block.timestamp + 30 days);
        uint256 veAfter = ve.veBalanceOf(alice);

        assertLt(veAfter, veBefore, "INV-7: non-autoMax ve did not decay after time warp");
    }

    function testFuzz_autoMaxVeStable(uint256 seed) public {
        uint256 amt = bound(seed, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);
        _createLockAs(alice, amt, Constants.MAX_LOCK_DURATION, true);

        uint256 veBefore = ve.veBalanceOf(alice);

        vm.warp(block.timestamp + 180 days);
        uint256 veAfter = ve.veBalanceOf(alice);

        assertEq(veAfter, veBefore, "INV-7: autoMax ve changed after time warp");
    }

    // ---- INV-8: Token ID allocation ----

    function testFuzz_tokenIdMonotonic(uint256 seed) public {
        uint256 amt = bound(seed, Constants.MIN_LOCK_AMOUNT, 500_000e18);

        uint256 prevId = 0;
        for (uint256 j = 0; j < 5; j++) {
            address user = _actor(j);
            vm.prank(user);
            uint256 tid = ve.createLock(amt, 90 days, false);
            assertGt(tid, prevId, "INV-8: token ID not monotonically increasing");
            prevId = tid;
        }
    }

    function test_nextTokenIdMatchesAllocation() public {
        uint256 predicted = ve.nextTokenId();
        vm.prank(alice);
        uint256 actual = ve.createLock(Constants.MIN_LOCK_AMOUNT, 90 days, false);
        assertEq(actual, predicted, "INV-8: nextTokenId() did not match allocated ID");
    }

    // ---- Multi-step state machine (40 random actions) ----

    function testFuzz_stateMachine_allInvariantsHold(uint256 seed) public {
        uint256 numTokens = 0;
        uint256[] memory tokens = new uint256[](40);

        for (uint256 step = 0; step < 40; step++) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = entropy % 6;
            address user = _actor(entropy >> 8);
            uint256 amt = bound(entropy >> 16, Constants.MIN_LOCK_AMOUNT, 1_000_000e18);

            if (action == 0 && numTokens < 32) {
                // Create lock
                bool autoMax = (entropy >> 64) % 3 == 0;
                uint256 dur = autoMax
                    ? Constants.MAX_LOCK_DURATION
                    : bound(entropy >> 72, Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
                vm.prank(user);
                tokens[numTokens] = ve.createLock(amt, dur, autoMax);
                numTokens++;
            } else if (action == 1 && numTokens > 0) {
                // Add to lock
                uint256 idx = (entropy >> 64) % numTokens;
                uint256 tid = tokens[idx];
                try ve.getLockInfo(tid) returns (uint256 a, uint256, bool, bool) {
                    if (a > 0) {
                        address lockOwner = ve.ownerOf(tid);
                        uint256 topup = bound(entropy >> 72, Constants.MIN_TOPUP_AMOUNT, 500_000e18);
                        vm.prank(lockOwner);
                        try ve.addToLock(tid, topup) {} catch {}
                    }
                } catch {}
            } else if (action == 2 && numTokens > 1) {
                // Merge locks (same owner)
                uint256 iA = (entropy >> 64) % numTokens;
                uint256 iB = (entropy >> 72) % numTokens;
                if (iA != iB) {
                    uint256 tA = tokens[iA];
                    uint256 tB = tokens[iB];
                    try ve.getLockInfo(tA) returns (uint256 aA, uint256, bool, bool) {
                        if (aA > 0) {
                            try ve.getLockInfo(tB) returns (uint256 aB, uint256, bool, bool) {
                                if (aB > 0) {
                                    address ownerA = ve.ownerOf(tA);
                                    address ownerB = ve.ownerOf(tB);
                                    if (ownerA == ownerB) {
                                        // v1.0.0: external user merge lives on Furnace; the lock-math
                                        // property under fuzz here is reached via the Furnace-only
                                        // `mergeLocksFor` sibling so the predeploy invariant suite keeps
                                        // exercising the same `_mergeLocksInternal` add-back path.
                                        vm.prank(furnace);
                                        try ve.mergeLocksFor(ownerA, tA, tB) {} catch {}
                                    }
                                }
                            } catch {}
                        }
                    } catch {}
                }
            } else if (action == 3) {
                // Time warp
                uint256 warpDays = bound(entropy >> 64, 1, 60);
                vm.warp(block.timestamp + warpDays * 1 days);
            } else if (action == 4) {
                // Checkpoint
                ve.checkpointGlobalState();
            } else if (action == 5 && numTokens > 0) {
                // Toggle autoMax
                uint256 idx = (entropy >> 64) % numTokens;
                uint256 tid = tokens[idx];
                try ve.getLockInfo(tid) returns (uint256 a, uint256, bool am, bool) {
                    if (a > 0) {
                        address lockOwner = ve.ownerOf(tid);
                        vm.prank(lockOwner);
                        try ve.setAutoMax(tid, !am) {} catch {}
                    }
                } catch {}
            }
        }

        // ---- Assert all invariants after random walk ----

        ve.checkpointGlobalState();

        // INV-1: bias safety
        uint256 cached = ve.totalVeCached();
        assertTrue(cached < type(uint256).max / 2, "INV-1: bias overflow after state machine");

        // INV-3: globalLastTs bounded
        assertLe(ve.globalLastTs(), block.timestamp, "INV-3: globalLastTs > block.timestamp after state machine");

        // INV-4: per-user ve bounds
        uint256 total = ve.totalVeCurrent();
        assertLe(ve.veBalanceOf(alice), total, "INV-4: alice ve > total after state machine");
        assertLe(ve.veBalanceOf(bob), total, "INV-4: bob ve > total after state machine");
        assertLe(ve.veBalanceOf(carol), total, "INV-4: carol ve > total after state machine");

        // INV-5: principal conservation
        uint256 lockedOnChain = ve.totalLockedClaim();
        uint256 sumAmounts = 0;
        for (uint256 i = 0; i < numTokens; i++) {
            try ve.getLockInfo(tokens[i]) returns (uint256 a, uint256, bool, bool) {
                sumAmounts += a;
            } catch {}
        }
        assertEq(lockedOnChain, sumAmounts, "INV-5: totalLockedClaim != sum of lock amounts");
    }
}
