// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {FurnaceGuardHelper} from "src/FurnaceGuardHelper.sol";
import {Errors} from "src/lib/Errors.sol";

import {FurnaceHarness} from "./mocks/FurnaceHarness.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockEntryTokenRegistry} from "./mocks/MockEntryTokenRegistry.sol";
import {MockLpRewardsVault} from "./mocks/MockLpRewardsVault.sol";
import {VeClaimNFTHarness} from "./mocks/VeClaimNFTHarness.sol";

/// @notice Helper-offload coverage: asserts that the four emergency / rescue shims
///         in `Furnace.sol` are correctly delegated into `FurnaceGuardHelper`.
///         Six focus areas covered, each in its own test group:
///
///         1. **Canonical gate**: Direct (non-delegatecall) invocation of the helper's
///            delegated functions reverts with `NotAuthorized`. Without this gate, anyone
///            could SLOAD/SSTORE into the helper's own storage layout — this is a critical
///            invariant of the offload pattern.
///
///         2. **vm.load slot parity**: The 10 storage slots written by the delegated
///            request / execute paths land in Furnace's storage at the slot indices pinned
///            in `_SLOT_*` constants — not in the helper's storage. `vm.load` directly
///            reads Furnace's storage to confirm.
///
///         3. **Execution slot parity**: After `executeEmergencyVaultRewireDelegated` runs
///            via delegatecall, all 8 stream / vault / request-marker slots have their
///            expected post-execution values.
///
///         4. **Rescue path slot clearing**: `pendingSellSeller[tokenId]` and
///            `lastAutoMaxBonusClaim[tokenId]` are cleared by the delegated rescue path,
///            and the rescue is a no-op double-call (re-attempt reverts ZeroAddress).
///
///         5. **Event topic0 parity** (and emitter address): Events fire with `topic0` =
///            the canonical hash and the emitting `address` is Furnace (not the helper),
///            because the delegatecall preserves `address(this)`.
///
///         6. **Behavioral equivalence**: Failed delegatecall bubbles the ORIGINAL typed
///            error (e.g., `EmergencyRewireAlreadyRequested`) instead of being wrapped in
///            a generic `InvariantViolation`. Tests at this layer pin the bubble path.
contract FurnaceEmergencyDelegatecallCoverageTest is Test {
    ClaimToken internal claim;
    VeClaimNFTHarness internal ve;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    FurnaceQuoter internal furnaceQuoter;
    MockLpRewardsVault internal lpVault;
    ShareholderRoyalties internal royalties;
    FurnaceGuardHelper internal guardHelper;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA11C3);
    address internal mineMarket;
    address internal registry;
    address internal mineCoreRegistry;

    // Storage slot indices for Furnace's emergency-rewire / lp-stream / pending-sell state.
    // Mirrors `_SLOT_*` constants in FurnaceGuardHelper; pinned in
    // SecurityCriticalConstantsPinned.t.sol.
    uint256 internal constant SLOT_LP_REWARDS_VAULT = 58;
    uint256 internal constant SLOT_PENDING_SELL_SELLER = 59;
    uint256 internal constant SLOT_LAST_LP_OVERFLOW_DRIP_UPDATE = 69;
    uint256 internal constant SLOT_LP_STREAM_RATE_PER_SEC = 70;
    uint256 internal constant SLOT_LP_STREAM_PERIOD_FINISH = 71;
    uint256 internal constant SLOT_LP_STREAM_LAST_UPDATE = 72;
    uint256 internal constant SLOT_LP_STREAM_CARRY = 73;
    uint256 internal constant SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER = 74;
    uint256 internal constant SLOT_EMERGENCY_REWIRE_TARGET_VAULT = 75;
    uint256 internal constant SLOT_LAST_AUTOMAX_BONUS_CLAIM = 78;

    function setUp() public {
        claim = new ClaimToken(owner);
        ve = new VeClaimNFTHarness(address(claim), owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        furnaceQuoter = new FurnaceQuoter(address(furnace));
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));
        mineMarket = address(new MockContract());
        registry = address(new MockEntryTokenRegistry());
        mineCoreRegistry = address(new MockEntryTokenRegistry());
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(address(claim)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(furnaceQuoter));
        furnace.setShareholderRoyalties(address(royalties));
        furnace.setMineMarket(mineMarket);
        furnace.setEntryTokenRegistry(registry);
        furnace.setLpRewardsVault(address(lpVault));
        mineCore.setFurnace(address(furnace));
        mineCore.setEntryTokenRegistry(mineCoreRegistry);
        royalties.setWiring(address(mineCore), mineMarket, address(furnace));
        ve.setFurnace(address(furnace));
        ve.setMineMarket(mineMarket);
        vm.stopPrank();

        guardHelper = FurnaceGuardHelper(furnace.exposedGuardHelper());
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _fundLpStream(uint256 amount) internal {
        vm.prank(address(mineCore));
        claim.mint(address(furnace), amount);
        furnace.exposedFundLpStream(amount);
    }

    function _makeReplacementVault() internal returns (MockLpRewardsVault replacement) {
        replacement = new MockLpRewardsVault();
        replacement.setFurnace(address(furnace));
    }

    function _slotAsAddress(uint256 slotIdx) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(furnace), bytes32(slotIdx)))));
    }

    function _slotAsUint(uint256 slotIdx) internal view returns (uint256) {
        return uint256(vm.load(address(furnace), bytes32(slotIdx)));
    }

    // ---------------------------------------------------------------
    // 1. Canonical gate: direct call to delegated functions reverts.
    // ---------------------------------------------------------------

    function testDelegated_RequestEmergencyVaultRewireDirectCallReverts() public {
        // Direct call hits `_requireDelegatecallCanonicalFurnace` which checks
        // `_isCanonicalFurnace(address(this))` — and `address(this)` is the helper
        // itself (not Furnace), so it MUST revert.
        vm.expectRevert(Errors.NotAuthorized.selector);
        guardHelper.requestEmergencyVaultRewire(address(0xBEEF));
    }

    function testDelegated_CancelEmergencyVaultRewireDirectCallReverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        guardHelper.cancelEmergencyVaultRewire();
    }

    function testDelegated_ExecuteEmergencyVaultRewireDirectCallReverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        guardHelper.executeEmergencyVaultRewire();
    }

    function testDelegated_RescuePendingSellNFTDirectCallReverts() public {
        vm.expectRevert(Errors.NotAuthorized.selector);
        guardHelper.rescuePendingSellNFT(1);
    }

    // ---------------------------------------------------------------
    // 2. vm.load slot parity for the request path (slots 74, 75).
    // ---------------------------------------------------------------

    function testDelegated_RequestPath_WritesFurnaceSlots74And75() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        assertEq(_slotAsUint(SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER), 0, "executeAfter pre-state");
        assertEq(_slotAsAddress(SLOT_EMERGENCY_REWIRE_TARGET_VAULT), address(0), "targetVault pre-state");

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));

        // Storage was written through delegatecall; vm.load addresses Furnace's storage,
        // proving the helper's `sstore(_SLOT_*, ...)` lands on Furnace, not on the helper.
        assertEq(
            _slotAsUint(SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER),
            block.timestamp + 7 days,
            "executeAfter slot 74 post-state"
        );
        assertEq(
            _slotAsAddress(SLOT_EMERGENCY_REWIRE_TARGET_VAULT), address(replacement), "targetVault slot 75 post-state"
        );

        // Cross-check via the public getter. If slot parity were broken, Solidity's
        // generated getter would return the original (unchanged) value while vm.load
        // would show the helper's slot, exposing the divergence.
        assertEq(furnace.emergencyVaultRewireExecuteAfter(), block.timestamp + 7 days);
        assertEq(furnace.emergencyVaultRewireTargetVault(), address(replacement));
    }

    // ---------------------------------------------------------------
    // 3. Execute path: 8-slot post-execution parity.
    // ---------------------------------------------------------------

    function testDelegated_ExecutePath_AllEightSlotsCorrectlyZeroedAndRebound() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));

        uint256 executeAfter = furnace.emergencyVaultRewireExecuteAfter();
        vm.warp(executeAfter);

        vm.prank(owner);
        furnace.executeEmergencyVaultRewire();

        // Expected post-state:
        // - lpStreamRatePerSec        = 0   (slot 70)
        // - lpStreamPeriodFinish      = 0   (slot 71)
        // - lpStreamLastUpdate        = now (slot 72)
        // - lpStreamCarry             = 0   (slot 73)
        // - lastLpOverflowDripUpdate  = now (slot 69)
        // - emergencyVaultRewireExecuteAfter = 0   (slot 74)
        // - emergencyVaultRewireTargetVault  = 0   (slot 75)
        // - lpRewardsVault            = replacement (slot 58)
        assertEq(_slotAsUint(SLOT_LP_STREAM_RATE_PER_SEC), 0, "rate (70)");
        assertEq(_slotAsUint(SLOT_LP_STREAM_PERIOD_FINISH), 0, "finish (71)");
        assertEq(_slotAsUint(SLOT_LP_STREAM_LAST_UPDATE), block.timestamp, "stream lastUpdate (72)");
        assertEq(_slotAsUint(SLOT_LP_STREAM_CARRY), 0, "carry (73)");
        assertEq(_slotAsUint(SLOT_LAST_LP_OVERFLOW_DRIP_UPDATE), block.timestamp, "overflow lastUpdate (69)");
        assertEq(_slotAsUint(SLOT_EMERGENCY_REWIRE_EXECUTE_AFTER), 0, "executeAfter cleared (74)");
        assertEq(_slotAsAddress(SLOT_EMERGENCY_REWIRE_TARGET_VAULT), address(0), "targetVault cleared (75)");
        assertEq(_slotAsAddress(SLOT_LP_REWARDS_VAULT), address(replacement), "lpRewardsVault rebound (58)");
    }

    // ---------------------------------------------------------------
    // 4. Rescue path: pendingSellSeller + lastAutoMaxBonusClaim cleared atomically.
    // ---------------------------------------------------------------

    function testDelegated_RescuePath_ClearsBothMappingSlots() public {
        uint256 lockAmount = 10_000e18;
        uint256 duration = 30 days;

        vm.prank(address(mineCore));
        claim.mint(alice, lockAmount);

        vm.startPrank(alice);
        claim.approve(address(ve), lockAmount);
        uint256 tokenId = ve.createLock(lockAmount, duration, false);
        ve.approveForTest(mineMarket, tokenId);
        vm.stopPrank();

        // Canonical sell-flow path that strands the NFT in Furnace.
        vm.prank(mineMarket);
        ve.safeTransferFrom(alice, address(furnace), tokenId);

        // Mapping slot for pendingSellSeller[tokenId] = keccak256(abi.encode(tokenId, slot)).
        bytes32 sellerSlotKey = keccak256(abi.encode(tokenId, SLOT_PENDING_SELL_SELLER));
        bytes32 bonusSlotKey = keccak256(abi.encode(tokenId, SLOT_LAST_AUTOMAX_BONUS_CLAIM));

        address sellerInSlot = address(uint160(uint256(vm.load(address(furnace), sellerSlotKey))));
        assertEq(sellerInSlot, alice, "pendingSellSeller pre-rescue");

        // Seed lastAutoMaxBonusClaim[tokenId] to a non-zero sentinel so the SSTORE-clear
        // by the helper's delegatecall is observable (otherwise the assertion that the
        // slot is zero post-rescue would be vacuous). 0xDEAD also pins slot key parity:
        // if `_SLOT_LAST_AUTOMAX_BONUS_CLAIM` were misnumbered, the seeded value would
        // remain (or worse, land on an unrelated slot).
        vm.store(address(furnace), bonusSlotKey, bytes32(uint256(0xDEAD)));
        assertEq(uint256(vm.load(address(furnace), bonusSlotKey)), 0xDEAD, "bonus slot seeded");

        vm.prank(owner);
        furnace.rescuePendingSellNFT(tokenId);

        // Both mapping slots cleared in Furnace's storage by the delegated SSTORE.
        assertEq(
            uint256(vm.load(address(furnace), sellerSlotKey)),
            0,
            "pendingSellSeller mapping slot cleared by delegatecall"
        );
        assertEq(
            uint256(vm.load(address(furnace), bonusSlotKey)),
            0,
            "lastAutoMaxBonusClaim mapping slot cleared by delegatecall"
        );

        // Re-attempt is a no-op zero-address revert (no double-rescue surface).
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.rescuePendingSellNFT(tokenId);
    }

    // ---------------------------------------------------------------
    // 5. Event topic0 parity + emitter-address parity (delegatecall semantics).
    // ---------------------------------------------------------------

    function testDelegated_RequestEmits_TopicAndEmitterAddressMatchFurnace() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.recordLogs();
        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("EmergencyVaultRewireRequested(address,uint256,uint256)")) {
                assertEq(logs[i].emitter, address(furnace), "event emitter must be Furnace, not helper");
                // address(replacement) is indexed → topics[1].
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(replacement), "indexed vault topic");
                found = true;
            }
        }
        assertTrue(found, "EmergencyVaultRewireRequested event with pinned topic0 must be present");
    }

    function testDelegated_ExecuteEmits_BothExpectedTopicsFromFurnace() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));
        vm.warp(furnace.emergencyVaultRewireExecuteAfter());

        vm.recordLogs();
        vm.prank(owner);
        furnace.executeEmergencyVaultRewire();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawSet;
        bool sawExec;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("LpRewardsVaultSet(address,address)")) {
                assertEq(logs[i].emitter, address(furnace), "LpRewardsVaultSet emitter");
                sawSet = true;
            }
            if (logs[i].topics[0] == keccak256("EmergencyVaultRewireExecuted(address,uint256)")) {
                assertEq(logs[i].emitter, address(furnace), "EmergencyVaultRewireExecuted emitter");
                sawExec = true;
            }
        }
        assertTrue(sawSet, "LpRewardsVaultSet topic0 + emitter parity");
        assertTrue(sawExec, "EmergencyVaultRewireExecuted topic0 + emitter parity");
    }

    // ---------------------------------------------------------------
    // 6. Behavioral equivalence: failed delegatecall bubbles the typed error.
    //    Tests pin the `_delegateToHelperOrBubble` revert-payload contract.
    // ---------------------------------------------------------------

    function testDelegated_BubblesTypedError_AlreadyRequested() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();
        MockLpRewardsVault replacement2 = _makeReplacementVault();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));

        // Without the bubble, the shim would surface a generic InvariantViolation. With
        // the bubble, the original typed selector reaches the test surface.
        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireAlreadyRequested.selector);
        furnace.requestEmergencyVaultRewire(address(replacement2));
    }

    function testDelegated_BubblesTypedError_NotRequestedOnCancel() public {
        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireNotRequested.selector);
        furnace.cancelEmergencyVaultRewire();
    }

    function testDelegated_BubblesTypedError_DelayNotMet() public {
        _fundLpStream(50_000e18);
        MockLpRewardsVault replacement = _makeReplacementVault();

        vm.prank(owner);
        furnace.requestEmergencyVaultRewire(address(replacement));

        // Skip warp; execute MUST revert delay-not-met (typed).
        vm.prank(owner);
        vm.expectRevert(Errors.EmergencyRewireDelayNotMet.selector);
        furnace.executeEmergencyVaultRewire();
    }

    function testDelegated_BubblesTypedError_ZeroAddressOnRescueOfUnsetSlot() public {
        // No NFT was stuck → pendingSellSeller[42] == 0 → ZeroAddress.
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        furnace.rescuePendingSellNFT(42);
    }
}
