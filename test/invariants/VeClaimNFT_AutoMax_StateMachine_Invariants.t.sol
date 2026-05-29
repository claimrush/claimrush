// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";

import {VeClaimNFTHarness} from "../mocks/VeClaimNFTHarness.sol";
import {MockShareholderRoyaltiesCheckpoint} from "../mocks/MockShareholderRoyaltiesCheckpoint.sol";

/// @notice State-machine style invariants for VeClaimNFT AutoMax semantics.
/// @dev CI MUST include this file (see Makefile `test-invariants`).
contract VeClaimNFT_AutoMax_StateMachine_Invariants is Test {
    ClaimToken public claim;
    VeClaimNFTHarness internal ve;

    address internal owner;

    address[] internal actors;
    mapping(address => uint256[]) internal owned; // tokenIds we believe may be owned by actor

    function setUp() public {
        vm.txGasPrice(0);
        owner = makeAddr("owner");

        vm.startPrank(owner);
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);

        // Wire a mock furnace so _resolveShareholderRoyalties() can find ShareholderRoyalties.
        MockShareholderRoyaltiesCheckpoint srMock = new MockShareholderRoyaltiesCheckpoint();
        address mockFurnace = address(new MockShareholderRoyaltiesCheckpoint()); // any contract
        address mockMineCore = makeAddr("mockMineCore");
        vm.etch(mockMineCore, hex"00");
        vm.mockCall(mockFurnace, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(srMock)));
        vm.mockCall(mockFurnace, abi.encodeWithSignature("mineCore()"), abi.encode(mockMineCore));
        vm.mockCall(mockFurnace, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mockFurnace, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mockMineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mockMineCore, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mockMineCore, abi.encodeWithSignature("furnace()"), abi.encode(mockFurnace));
        vm.mockCall(mockMineCore, abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(mockMineCore, abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));
        claim.setMineCore(mockMineCore);
        ve.setFurnace(mockFurnace);
        vm.stopPrank();

        // Allow this test contract to mint CLAIM for fuzzing.
        vm.mockCall(address(this), abi.encodeWithSignature("emissionStartTime()"), abi.encode(uint256(1)));
        vm.mockCall(address(this), abi.encodeWithSignature("GENESIS_ACCRUAL_DURATION()"), abi.encode(uint256(604800)));
        vm.prank(owner);
        claim.setMineCore(address(this));

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));

        for (uint256 i = 0; i < actors.length; ++i) {
            vm.prank(actors[i]);
            claim.approve(address(ve), type(uint256).max);
        }
    }

    function testFuzz_stateMachine_autoMax_invariants(uint256 seed) public {
        uint256 steps = 24;
        for (uint256 i = 0; i < steps; ++i) {
            bytes32 h = keccak256(abi.encode(seed, i));

            // Occasionally advance time (affects decays + expiry).
            if ((uint256(h) & 3) == 0) {
                vm.warp(block.timestamp + 1 + (uint256(h >> 16) % 1 days));
            }

            address actor = actors[uint256(uint8(uint256(h >> 8))) % actors.length];
            uint8 action = uint8(uint256(h) % 6);

            if (action == 0) {
                _tryCreateLock(actor, h);
            } else if (action == 1) {
                _tryAddToLock(actor, h);
            } else if (action == 2) {
                _tryToggleAutoMax(actor, h);
            } else if (action == 3) {
                _tryExtendLock(actor, h);
            } else if (action == 4) {
                _tryUnlock(actor, h);
            } else {
                _tryCreateLockInvalidAutoMaxDuration(actor);
            }

            _assertAutoMaxInvariants();
        }

        _assertAutoMaxInvariants();
    }

    // ------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------

    function _tryCreateLock(address actor, bytes32 h) internal {
        uint256 amount = bound(uint256(h), Constants.MIN_LOCK_AMOUNT, 200_000e18);
        bool autoMax = (uint256(h >> 64) & 1) == 1;
        uint256 duration = autoMax
            ? Constants.MAX_LOCK_DURATION
            : bound(uint256(h >> 128), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        // Fund actor
        claim.mint(actor, amount);

        vm.prank(actor);
        try ve.createLock(amount, duration, autoMax) returns (uint256 tokenId) {
            owned[actor].push(tokenId);
        } catch {
            // Ignore; state machine expects some reverts when close to caps.
        }
    }

    function _pickOwnedToken(address actor, uint256 salt) internal view returns (uint256 tokenId) {
        uint256[] storage ids = owned[actor];
        if (ids.length == 0) return 0;
        tokenId = ids[salt % ids.length];
    }

    function _tryAddToLock(address actor, bytes32 h) internal {
        uint256 tokenId = _pickOwnedToken(actor, uint256(h));
        if (tokenId == 0) return;

        address actualOwner = _ownerOrZero(tokenId);
        if (actualOwner != actor) return;

        uint256 amount = bound(uint256(h >> 32), 1e18, 50_000e18);
        claim.mint(actor, amount);

        vm.prank(actor);
        try ve.addToLock(tokenId, amount) {} catch {}
    }

    function _tryToggleAutoMax(address actor, bytes32 h) internal {
        uint256 tokenId = _pickOwnedToken(actor, uint256(h));
        if (tokenId == 0) return;
        if (_ownerOrZero(tokenId) != actor) return;

        bool enabled = (uint256(h >> 96) & 1) == 1;

        vm.prank(actor);
        try ve.setAutoMax(tokenId, enabled) {} catch {}
    }

    function _tryExtendLock(address actor, bytes32 h) internal {
        uint256 tokenId = _pickOwnedToken(actor, uint256(h));
        if (tokenId == 0) return;
        if (_ownerOrZero(tokenId) != actor) return;

        uint256 additional = 1 + (uint256(h >> 120) % (30 days));
        (, uint256 oldEnd,,) = ve.getLockInfo(tokenId);
        uint256 newEnd = oldEnd + additional;

        vm.prank(ve.furnace());
        try ve.extendLockToFor(actor, tokenId, newEnd) {} catch {}
    }

    function _tryUnlock(address actor, bytes32 h) internal {
        uint256 tokenId = _pickOwnedToken(actor, uint256(h));
        if (tokenId == 0) return;
        if (_ownerOrZero(tokenId) != actor) return;

        vm.prank(actor);
        try ve.unlock(tokenId) {} catch {}
    }

    function _tryCreateLockInvalidAutoMaxDuration(address actor) internal {
        // AutoMax is only valid at MAX_LOCK_DURATION.
        uint256 amount = Constants.MIN_LOCK_AMOUNT;
        claim.mint(actor, amount);

        vm.startPrank(actor);
        vm.expectRevert(Errors.InvalidDuration.selector);
        ve.createLock(amount, Constants.MAX_LOCK_DURATION - 1, true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------

    function _assertAutoMaxInvariants() internal view {
        uint256 nowTs = block.timestamp;

        for (uint256 i = 0; i < actors.length; ++i) {
            address actor = actors[i];

            uint256 sumAutoMaxAmounts = 0;

            uint256[] storage ids = owned[actor];
            for (uint256 j = 0; j < ids.length; ++j) {
                uint256 tokenId = ids[j];
                if (tokenId == 0) continue;

                if (_ownerOrZero(tokenId) != actor) continue;

                (uint256 amt, uint256 effectiveEnd, bool autoMax, bool listed) = ve.getLockInfo(tokenId);
                listed; // silence unused warning in case we add more checks later

                // If autoMax is enabled, ve contribution is 1:1 and effective end is always now+MAX.
                if (autoMax && amt != 0) {
                    assertEq(effectiveEnd, nowTs + Constants.MAX_LOCK_DURATION, "autoMax effectiveEnd");
                    sumAutoMaxAmounts += amt;
                } else if (!autoMax && amt != 0) {
                    // Non-autoMax effective end should never exceed now+MAX by spec.
                    assertLe(effectiveEnd, nowTs + Constants.MAX_LOCK_DURATION, "non-autoMax end cap");
                }
            }

            // veBalanceOf includes decaying locks too, so it must be >= sum(autoMax amounts).
            uint256 veBal = ve.veBalanceOf(actor);
            assertGe(veBal, sumAutoMaxAmounts, "veBalance >= sumAutoMax");
        }
    }

    function _ownerOrZero(uint256 tokenId) internal view returns (address) {
        try ve.ownerOf(tokenId) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }
}

