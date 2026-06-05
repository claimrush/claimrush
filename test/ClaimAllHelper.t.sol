// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";
import {DelegationPermissions} from "src/lib/DelegationPermissions.sol";
import {DelegationActionTypes} from "src/lib/DelegationActionTypes.sol";

contract MockRoyaltiesForClaimAll {
    error ForcedRevert();

    address public mineCore;
    address public claimAllHelper;
    address public furnace;

    uint256 public calls;
    uint8 public lastMode;
    uint256 public lastTargetTokenId;
    uint256 public lastDurationSeconds;
    bool public lastCreateAutoMax;
    uint256 public lastMinVeOut;
    address public lastUser;
    address public lastCaller;
    address public lastRecipient;

    uint256 public routeToCalls;

    bool public shouldRevert;

    function setMineCore(address v) external {
        mineCore = v;
    }

    function setClaimAllHelper(address v) external {
        claimAllHelper = v;
    }

    function setFurnace(address v) external {
        furnace = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function claimShareholder(
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external {
        // Included so this mock is usable for direct calls too.
        if (shouldRevert) revert ForcedRevert();
        calls += 1;
        lastUser = msg.sender;
        lastMode = mode;
        lastTargetTokenId = targetTokenId;
        lastDurationSeconds = durationSeconds;
        lastCreateAutoMax = createAutoMax;
        lastMinVeOut = minVeOut;
        lastCaller = msg.sender;
    }

    function claimShareholderFor(
        address user,
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external {
        if (shouldRevert) revert ForcedRevert();
        calls += 1;
        lastUser = user;
        lastMode = mode;
        lastTargetTokenId = targetTokenId;
        lastDurationSeconds = durationSeconds;
        lastCreateAutoMax = createAutoMax;
        lastMinVeOut = minVeOut;
        lastCaller = msg.sender;
    }

    function claimShareholderForTo(address user, address payable to) external {
        if (shouldRevert) revert ForcedRevert();
        routeToCalls += 1;
        lastUser = user;
        lastRecipient = to;
        lastCaller = msg.sender;
    }
}

contract MockMineCoreForClaimAll {
    error ForcedRevert();

    address public royalties;
    address public claimAllHelper;
    address public delegationHub;
    address public furnace;

    uint256 public withdrawCalls;
    address public lastUser;
    address public lastCaller;

    bool public shouldRevert;
    bool public shouldFailEthTransfer;

    function setRoyalties(address v) external {
        royalties = v;
    }

    function setClaimAllHelper(address v) external {
        claimAllHelper = v;
    }

    function setDelegationHub(address v) external {
        delegationHub = v;
    }

    function setFurnace(address v) external {
        furnace = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setShouldFailEthTransfer(bool v) external {
        shouldFailEthTransfer = v;
    }

    function withdrawKingBalance() external {
        if (shouldRevert) revert ForcedRevert();
        if (shouldFailEthTransfer) revert Errors.EthTransferFailed();
        withdrawCalls += 1;
        lastUser = msg.sender;
        lastCaller = msg.sender;
    }

    function withdrawKingBalanceFor(address user) external {
        if (shouldRevert) revert ForcedRevert();
        if (shouldFailEthTransfer) revert Errors.EthTransferFailed();
        withdrawCalls += 1;
        lastUser = user;
        lastCaller = msg.sender;
    }
}

contract MockMineCoreOrderCheckForClaimAll {
    error RoyaltiesNotCalledFirst();

    address public royalties;
    address public claimAllHelper;
    address public delegationHub;

    uint256 public withdrawCalls;
    address public lastCaller;

    constructor(address _royalties) {
        royalties = _royalties;
    }

    function setClaimAllHelper(address v) external {
        claimAllHelper = v;
    }

    function setDelegationHub(address v) external {
        delegationHub = v;
    }

    function withdrawKingBalance() external {
        if (MockRoyaltiesForClaimAll(royalties).calls() == 0) revert RoyaltiesNotCalledFirst();
        withdrawCalls += 1;
        lastCaller = msg.sender;
    }

    function withdrawKingBalanceFor(
        address /*user*/
    )
        external
    {
        if (MockRoyaltiesForClaimAll(royalties).calls() == 0) revert RoyaltiesNotCalledFirst();
        withdrawCalls += 1;
        lastCaller = msg.sender;
    }
}

contract ReenteringRoyaltiesForClaimAll {
    address public mineCore;
    address public claimAllHelper;
    address public furnace;

    bool public reenterAttempted;
    bool public reenterSucceeded;

    ClaimAllHelper public helper;

    function setMineCore(address v) external {
        mineCore = v;
    }

    function setClaimAllHelper(address v) external {
        claimAllHelper = v;
    }

    function setFurnace(address v) external {
        furnace = v;
    }

    function setHelper(address h) external {
        helper = ClaimAllHelper(h);
    }

    function claimShareholder(
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external {
        reenterAttempted = true;

        // The helper MUST be nonReentrant; this should always fail.
        try helper.claimAll(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut) {
            reenterSucceeded = true;
        } catch {
            // swallow
        }
    }

    function claimShareholderFor(
        address,
        /*user*/
        uint8 mode,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external {
        reenterAttempted = true;

        // The helper MUST be nonReentrant; this should always fail.
        try helper.claimAll(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut) {
            reenterSucceeded = true;
        } catch {
            // swallow
        }
    }
}

contract MockFurnaceForClaimAll {
    address public mineCore;
    address public shareholderRoyalties;
    address public delegationHub;

    function setMineCore(address v) external {
        mineCore = v;
    }

    function setShareholderRoyalties(address v) external {
        shareholderRoyalties = v;
    }

    function setDelegationHub(address v) external {
        delegationHub = v;
    }
}

contract MockDelegationHubForClaimAll {
    bool public authorized;

    function setAuthorized(bool v) external {
        authorized = v;
    }

    function isAuthorized(address, address, uint256) external view returns (bool) {
        return authorized;
    }
}

/// @dev Permission-aware mock that checks specific bits, mirroring real DelegationHub logic.
contract PermissionAwareDelegationHubMock {
    mapping(address user => mapping(address delegate => uint256)) internal _perms;

    function grantPerms(address user, address delegate, uint256 perms) external {
        _perms[user][delegate] = perms;
    }

    function isAuthorized(address user, address delegate, uint256 requiredPerms) external view returns (bool) {
        if (user == delegate) return false;
        if (requiredPerms == 0) return false;
        return (_perms[user][delegate] & requiredPerms) == requiredPerms;
    }
}

contract ClaimAllHelperTest is Test {
    ClaimAllHelper internal helper;
    MockRoyaltiesForClaimAll internal royalties;
    MockMineCoreForClaimAll internal mineCore;
    MockFurnaceForClaimAll internal furnace;
    MockDelegationHubForClaimAll internal delegationHub;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        royalties = new MockRoyaltiesForClaimAll();
        mineCore = new MockMineCoreForClaimAll();
        furnace = new MockFurnaceForClaimAll();
        delegationHub = new MockDelegationHubForClaimAll();
        helper = new ClaimAllHelper(address(royalties), address(mineCore));

        _wireCanonical(address(royalties), address(mineCore), address(furnace), address(helper), address(delegationHub));
    }

    function _wireCanonical(address sr, address core, address f, address h, address hub) internal {
        MockRoyaltiesForClaimAll(sr).setMineCore(core);
        MockRoyaltiesForClaimAll(sr).setClaimAllHelper(h);
        MockRoyaltiesForClaimAll(sr).setFurnace(f);

        MockMineCoreForClaimAll(core).setRoyalties(sr);
        MockMineCoreForClaimAll(core).setClaimAllHelper(h);
        MockMineCoreForClaimAll(core).setDelegationHub(hub);
        MockMineCoreForClaimAll(core).setFurnace(f);

        MockFurnaceForClaimAll(f).setMineCore(core);
        MockFurnaceForClaimAll(f).setShareholderRoyalties(sr);
        MockFurnaceForClaimAll(f).setDelegationHub(hub);
    }

    function _etch7702(address target, address delegate) internal {
        vm.etch(target, abi.encodePacked(hex"EF0100", delegate));
        assertEq(target.code.length, 23, "7702 designator must be exactly 23 bytes");
    }

    function testConstructorRevertsOnZeroAddresses() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ClaimAllHelper(address(0), address(1));

        vm.expectRevert(Errors.ZeroAddress.selector);
        new ClaimAllHelper(address(1), address(0));
    }

    function testConstructorRevertsOnNonContracts() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new ClaimAllHelper(address(0xBEEF), address(mineCore));

        vm.expectRevert(Errors.NotAContract.selector);
        new ClaimAllHelper(address(royalties), address(0xCAFE));
    }

    function testConstructorRevertsOnDelegatedEoaRoyaltiesRoot() public {
        address delegatedEoa = address(0x77020001);
        _etch7702(delegatedEoa, address(this));

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new ClaimAllHelper(delegatedEoa, address(mineCore));
    }

    function testConstructorRevertsOnDelegatedEoaMineCoreRoot() public {
        address delegatedEoa = address(0x77020002);
        _etch7702(delegatedEoa, address(this));

        vm.expectRevert(Errors.DelegatedEOA.selector);
        new ClaimAllHelper(address(royalties), delegatedEoa);
    }

    function testClaimAllInEthModeForwardsToRoyaltiesAndMineCore() public {
        uint8 mode = 0;
        uint256 targetTokenId = 0;
        uint256 durationSeconds = 0;
        bool createAutoMax = false;
        uint256 minVeOut = 0;

        vm.prank(alice);
        helper.claimAll(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);

        assertEq(royalties.calls(), 1);
        assertEq(royalties.lastMode(), mode);
        assertEq(royalties.lastTargetTokenId(), targetTokenId);
        assertEq(royalties.lastDurationSeconds(), durationSeconds);
        assertEq(royalties.lastCreateAutoMax(), createAutoMax);
        assertEq(royalties.lastMinVeOut(), minVeOut);
        assertEq(royalties.lastUser(), alice);
        assertEq(royalties.lastCaller(), address(helper));

        assertEq(mineCore.withdrawCalls(), 1);
        assertEq(mineCore.lastUser(), alice);
        assertEq(mineCore.lastCaller(), address(helper));
    }

    function testClaimAllInLockFurnaceModeForwardsToRoyaltiesAndMineCore() public {
        uint8 mode = 1;
        uint256 targetTokenId = 1234;
        uint256 durationSeconds = 30 days;
        bool createAutoMax = true;
        uint256 minVeOut = 123;

        vm.prank(alice);
        helper.claimAll(mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);

        assertEq(royalties.calls(), 1);
        assertEq(royalties.lastMode(), mode);
        assertEq(royalties.lastTargetTokenId(), targetTokenId);
        assertEq(royalties.lastDurationSeconds(), durationSeconds);
        assertEq(royalties.lastCreateAutoMax(), createAutoMax);
        assertEq(royalties.lastMinVeOut(), minVeOut);
        assertEq(royalties.lastUser(), alice);
        assertEq(royalties.lastCaller(), address(helper));

        assertEq(mineCore.withdrawCalls(), 1);
        assertEq(mineCore.lastUser(), alice);
        assertEq(mineCore.lastCaller(), address(helper));
    }

    function testClaimAllCallsRoyaltiesThenMineCore_OrderEnforced() public {
        MockRoyaltiesForClaimAll r = new MockRoyaltiesForClaimAll();
        MockMineCoreOrderCheckForClaimAll m = new MockMineCoreOrderCheckForClaimAll(address(r));
        ClaimAllHelper h = new ClaimAllHelper(address(r), address(m));

        r.setMineCore(address(m));
        r.setClaimAllHelper(address(h));
        m.setClaimAllHelper(address(h));

        vm.prank(alice);
        h.claimAll(0, 0, 0, false, 0);

        assertEq(r.calls(), 1);
        assertEq(m.withdrawCalls(), 1);
    }

    function testClaimAllNonReentrant_BlocksReentry() public {
        ReenteringRoyaltiesForClaimAll r = new ReenteringRoyaltiesForClaimAll();
        MockMineCoreForClaimAll m = new MockMineCoreForClaimAll();
        ClaimAllHelper h = new ClaimAllHelper(address(r), address(m));
        r.setHelper(address(h));
        r.setMineCore(address(m));
        r.setClaimAllHelper(address(h));
        m.setRoyalties(address(r));
        m.setClaimAllHelper(address(h));

        vm.prank(alice);
        h.claimAll(0, 0, 0, false, 0);

        assertTrue(r.reenterAttempted());
        assertFalse(r.reenterSucceeded());
        assertEq(m.withdrawCalls(), 1);
    }

    function testClaimAllRevertsIfRoyaltiesReverts_NoPartialClaims() public {
        royalties.setShouldRevert(true);

        vm.prank(alice);
        vm.expectRevert(MockRoyaltiesForClaimAll.ForcedRevert.selector);
        helper.claimAll(0, 0, 0, false, 0);

        // No partial effects.
        assertEq(royalties.calls(), 0);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimAllEmitsWhenKingWithdrawEthTransferFails_BaronStillClaimed() public {
        mineCore.setShouldFailEthTransfer(true);

        vm.expectEmit(true, false, false, false, address(helper));
        emit Events.KingWithdrawalFailed(alice, "");

        vm.prank(alice);
        helper.claimAll(0, 0, 0, false, 0);

        assertEq(royalties.calls(), 1);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    /// @notice The Baron leg lands and the King leg's `EthTransferFailed` is swallowed
    ///         into a `KingWithdrawalFailed` event. The user's pending King balance
    ///         remains claimable by a follow-up call once the underlying ETH transfer
    ///         path is restored (e.g. EOA recipient becomes available again, contract
    ///         recipient adds a `receive()`).
    function testClaimAllPartialFailureLeavesKingBalanceRecoverable() public {
        mineCore.setShouldFailEthTransfer(true);

        vm.prank(alice);
        helper.claimAll(0, 0, 0, false, 0);
        assertEq(royalties.calls(), 1, "Baron leg lands on the partial-failure path");
        assertEq(mineCore.withdrawCalls(), 0, "King leg failed and recorded zero successful withdrawals");

        mineCore.setShouldFailEthTransfer(false);

        vm.prank(alice);
        helper.claimAll(0, 0, 0, false, 0);
        assertEq(royalties.calls(), 2, "Baron leg lands again on the recovery call");
        assertEq(mineCore.withdrawCalls(), 1, "King leg lands once recovered");
        assertEq(mineCore.lastUser(), alice, "King leg recovered for the original caller");
    }

    function testClaimAllBubblesUnexpectedMineCoreRevert_NoPartialClaims() public {
        mineCore.setShouldRevert(true);

        vm.prank(alice);
        vm.expectRevert(MockMineCoreForClaimAll.ForcedRevert.selector);
        helper.claimAll(0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimAllRevertsWhenMineCoreRoyaltiesRootMismatches() public {
        MockRoyaltiesForClaimAll otherRoyalties = new MockRoyaltiesForClaimAll();
        mineCore.setRoyalties(address(otherRoyalties));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.claimAll(0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimShareholderForUserRevertsWhenFurnaceDelegationHubDiffers() public {
        delegationHub.setAuthorized(true);
        MockDelegationHubForClaimAll otherHub = new MockDelegationHubForClaimAll();
        otherHub.setAuthorized(true);
        furnace.setDelegationHub(address(otherHub));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.claimShareholderForUser(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0);
    }

    function testWithdrawKingBalanceForUserRevertsWhenMineCoreDelegationHubDiffersFromCanonicalFurnaceHub() public {
        delegationHub.setAuthorized(true);
        MockDelegationHubForClaimAll otherHub = new MockDelegationHubForClaimAll();
        otherHub.setAuthorized(true);
        mineCore.setDelegationHub(address(otherHub));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.withdrawKingBalanceForUser(alice);

        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimAllForRevertsWhenMineCoreFurnaceDiffersFromShareholderRoyaltiesFurnace() public {
        delegationHub.setAuthorized(true);
        MockFurnaceForClaimAll otherFurnace = new MockFurnaceForClaimAll();
        otherFurnace.setMineCore(address(mineCore));
        otherFurnace.setShareholderRoyalties(address(royalties));
        otherFurnace.setDelegationHub(address(delegationHub));
        mineCore.setFurnace(address(otherFurnace));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.claimAllFor(alice, 1, 77, 180 days, true, 42);

        assertEq(royalties.calls(), 0);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testWithdrawKingBalanceForUserRevertsWhenHelperBackpointerMissing() public {
        delegationHub.setAuthorized(true);
        mineCore.setClaimAllHelper(address(0xBEEF));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.withdrawKingBalanceForUser(alice);

        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimAllForDelegatedSucceedsWhenLiveWiringAndHubsAgree() public {
        delegationHub.setAuthorized(true);

        // Delegated bundle path is ETH-only by design: P_CLAIM_ALL_FOR authorizes
        // the bot to collect Baron ETH + withdraw King ETH, never to spend the
        // shareholder's ETH locking a fresh veCLAIM position. Self-locking is
        // available via `claimAll(mode, ...)` from the user's own address.
        vm.prank(bob);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 1);
        assertEq(royalties.lastUser(), alice);
        assertEq(royalties.lastMode(), 0);
        assertEq(royalties.lastTargetTokenId(), 0);
        assertEq(mineCore.withdrawCalls(), 1);
        assertEq(mineCore.lastUser(), alice);
    }

    /// @notice Delegated `claimAllFor` rejects every non-zero `mode`. The bot can
    ///         only collect Baron ETH and withdraw King ETH on the user's behalf.
    function testClaimAllFor_RevertsOnNonEthMode() public {
        delegationHub.setAuthorized(true);

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimAllFor(alice, 1, 77, 180 days, true, 42);

        assertEq(royalties.calls(), 0);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    /// @notice Delegated entry-point variant of the recovery semantic. The Baron leg
    ///         lands for the target user. The King leg's `EthTransferFailed` revert is
    ///         swallowed into a `KingWithdrawalFailed` event. The user's pending King
    ///         balance is recoverable through a follow-up delegated or self-call once
    ///         the underlying ETH transfer path is restored.
    function testClaimAllForDelegatedPartialFailureLeavesKingBalanceRecoverable() public {
        delegationHub.setAuthorized(true);
        mineCore.setShouldFailEthTransfer(true);

        vm.expectEmit(true, false, false, false, address(helper));
        emit Events.KingWithdrawalFailed(alice, "");

        vm.prank(bob);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 1, "Baron leg lands on the partial-failure path (delegated)");
        assertEq(royalties.lastUser(), alice, "Baron leg credits the target user, not the delegate");
        assertEq(mineCore.withdrawCalls(), 0, "King leg recorded zero successful withdrawals");

        mineCore.setShouldFailEthTransfer(false);

        vm.prank(bob);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 2, "Baron leg lands again on the recovery call");
        assertEq(mineCore.withdrawCalls(), 1, "King leg lands once recovered (delegated)");
        assertEq(mineCore.lastUser(), alice, "King leg recovered for the target user");
    }

    /// @notice Delegated entry-point variant of the bubble-up control: any non
    ///         `EthTransferFailed` revert from the King leg propagates rather than
    ///         being swallowed. Without this control a buggy MineCore could cause
    ///         silent partial state under delegated bundles.
    function testClaimAllForDelegatedBubblesUnexpectedMineCoreRevert_NoPartialClaims() public {
        delegationHub.setAuthorized(true);
        mineCore.setShouldRevert(true);

        vm.prank(bob);
        vm.expectRevert(MockMineCoreForClaimAll.ForcedRevert.selector);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0, "Baron leg must not persist on bubbled-up King revert");
        assertEq(mineCore.withdrawCalls(), 0, "King leg must not persist on bubbled-up revert");
    }

    function testClaimShareholderForUserDelegatedSucceedsWhenLiveWiringAndHubsAgree() public {
        delegationHub.setAuthorized(true);

        // Delegated `claimShareholderForUser` is ETH-only: P_CLAIM_SHAREHOLDER_FOR
        // authorizes the bot to collect Baron ETH on the user's behalf, never to
        // spend that ETH locking a fresh veCLAIM position. Self-locking remains
        // available via `claimShareholderFor` from the user's own address.
        vm.prank(bob);
        helper.claimShareholderForUser(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 1);
        assertEq(royalties.lastUser(), alice);
        assertEq(royalties.lastMode(), 0);
        assertEq(royalties.lastTargetTokenId(), 0);
        assertEq(royalties.lastDurationSeconds(), 0);
        assertEq(royalties.lastCreateAutoMax(), false);
        assertEq(royalties.lastMinVeOut(), 0);
        assertEq(royalties.lastCaller(), address(helper));
        assertEq(mineCore.withdrawCalls(), 0);
    }

    /// @notice Delegated `claimShareholderForUser` rejects every non-zero `mode`.
    function testClaimShareholderForUser_RevertsOnNonEthMode() public {
        delegationHub.setAuthorized(true);

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimShareholderForUser(alice, 1, 77, 180 days, true, 42);

        assertEq(royalties.calls(), 0);
    }

    function testWithdrawKingBalanceForUserDelegatedSucceedsWhenLiveWiringAndHubsAgree() public {
        delegationHub.setAuthorized(true);

        vm.prank(bob);
        helper.withdrawKingBalanceForUser(alice);

        assertEq(mineCore.withdrawCalls(), 1);
        assertEq(mineCore.lastUser(), alice);
        assertEq(mineCore.lastCaller(), address(helper));
        assertEq(royalties.calls(), 0);
    }

    function testFuzz_claimShareholderForUserRevertsOnFurnaceHubDriftRegardlessOfParams(
        uint8 mode,
        uint256 targetTokenId,
        uint64 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) public {
        delegationHub.setAuthorized(true);
        MockDelegationHubForClaimAll otherHub = new MockDelegationHubForClaimAll();
        otherHub.setAuthorized(true);
        furnace.setDelegationHub(address(otherHub));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.claimShareholderForUser(alice, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    function testFuzz_claimShareholderForUserRevertsWhenMineCoreFurnaceDriftsRegardlessOfParams(
        uint8 mode,
        uint256 targetTokenId,
        uint64 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) public {
        delegationHub.setAuthorized(true);
        MockFurnaceForClaimAll otherFurnace = new MockFurnaceForClaimAll();
        otherFurnace.setMineCore(address(mineCore));
        otherFurnace.setShareholderRoyalties(address(royalties));
        otherFurnace.setDelegationHub(address(delegationHub));
        mineCore.setFurnace(address(otherFurnace));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.claimShareholderForUser(alice, mode, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }

    // --- Self-call prevention ---

    function testClaimShareholderForUser_RevertsOnSelfCall() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimShareholderForUser(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0);
    }

    function testWithdrawKingBalanceForUser_RevertsOnSelfCall() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.withdrawKingBalanceForUser(alice);

        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimAllFor_RevertsOnSelfCall() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    // --- Permission separation ---

    function testClaimAllFor_RevertsWhenDelegateHasIndividualPermsButNotClaimAllFor() public {
        PermissionAwareDelegationHubMock permHub = new PermissionAwareDelegationHubMock();
        // Grant both individual perms but NOT P_CLAIM_ALL_FOR.
        permHub.grantPerms(
            alice, bob, DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR | DelegationPermissions.P_WITHDRAW_KING_BUCKET_FOR
        );

        _wireCanonical(address(royalties), address(mineCore), address(furnace), address(helper), address(permHub));

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimShareholderForUser_RevertsWhenDelegateHasOnlyClaimAllForPerm() public {
        PermissionAwareDelegationHubMock permHub = new PermissionAwareDelegationHubMock();
        // Grant only P_CLAIM_ALL_FOR, not P_CLAIM_SHAREHOLDER_FOR.
        permHub.grantPerms(alice, bob, DelegationPermissions.P_CLAIM_ALL_FOR);

        _wireCanonical(address(royalties), address(mineCore), address(furnace), address(helper), address(permHub));

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimShareholderForUser(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0);
    }

    function testWithdrawKingBalanceForUser_RevertsWhenDelegateHasOnlyClaimAllForPerm() public {
        PermissionAwareDelegationHubMock permHub = new PermissionAwareDelegationHubMock();
        // Grant only P_CLAIM_ALL_FOR, not P_WITHDRAW_KING_BUCKET_FOR.
        permHub.grantPerms(alice, bob, DelegationPermissions.P_CLAIM_ALL_FOR);

        _wireCanonical(address(royalties), address(mineCore), address(furnace), address(helper), address(permHub));

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.withdrawKingBalanceForUser(alice);

        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimAllFor_SucceedsWithExactClaimAllForPerm() public {
        PermissionAwareDelegationHubMock permHub = new PermissionAwareDelegationHubMock();
        permHub.grantPerms(alice, bob, DelegationPermissions.P_CLAIM_ALL_FOR);

        _wireCanonical(address(royalties), address(mineCore), address(furnace), address(helper), address(permHub));

        vm.prank(bob);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 1);
        assertEq(royalties.lastUser(), alice);
        assertEq(mineCore.withdrawCalls(), 1);
        assertEq(mineCore.lastUser(), alice);
    }

    // --- claimAllFor king withdrawal failure emits event ---

    function testClaimAllFor_EmitsKingWithdrawalFailedWhenKingWithdrawEthTransferFails() public {
        delegationHub.setAuthorized(true);
        mineCore.setShouldFailEthTransfer(true);

        vm.expectEmit(true, false, false, false, address(helper));
        emit Events.KingWithdrawalFailed(alice, "");

        vm.prank(bob);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 1);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    function testClaimAllFor_BubblesUnexpectedMineCoreRevert() public {
        delegationHub.setAuthorized(true);
        mineCore.setShouldRevert(true);

        vm.prank(bob);
        vm.expectRevert(MockMineCoreForClaimAll.ForcedRevert.selector);
        helper.claimAllFor(alice, 0, 0, 0, false, 0);

        assertEq(royalties.calls(), 0);
        assertEq(mineCore.withdrawCalls(), 0);
    }

    // --- claimShareholderToCallerForUser (route Baron ETH to the looping bot) ---

    function _grantRouteToCaller(address user, address delegate) internal returns (PermissionAwareDelegationHubMock) {
        PermissionAwareDelegationHubMock permHub = new PermissionAwareDelegationHubMock();
        permHub.grantPerms(
            user,
            delegate,
            DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR | DelegationPermissions.P_ROUTE_SHAREHOLDER_ETH_TO_CALLER
        );
        _wireCanonical(address(royalties), address(mineCore), address(furnace), address(helper), address(permHub));
        return permHub;
    }

    function testClaimShareholderToCallerForUser_RoutesEthToCallerAndAttributesToUser() public {
        _grantRouteToCaller(alice, bob);

        vm.prank(bob);
        helper.claimShareholderToCallerForUser(alice);

        assertEq(royalties.routeToCalls(), 1, "route-to-caller leg lands exactly once");
        assertEq(royalties.lastUser(), alice, "claim is attributed to the user");
        assertEq(royalties.lastRecipient(), bob, "ETH is routed to the caller (looping bot)");
        assertEq(royalties.lastCaller(), address(helper), "only the canonical helper calls the royalties contract");
        assertEq(mineCore.withdrawCalls(), 0, "King leg is untouched");
    }

    function testClaimShareholderToCallerForUser_EmitsDelegationSessionUsed() public {
        _grantRouteToCaller(alice, bob);

        vm.expectEmit(true, true, true, true, address(helper));
        emit Events.DelegationSessionUsed(
            alice,
            bob,
            DelegationActionTypes.CLAIM_SHAREHOLDER_TO_CALLER_FOR,
            DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR | DelegationPermissions.P_ROUTE_SHAREHOLDER_ETH_TO_CALLER,
            0,
            block.timestamp
        );

        vm.prank(bob);
        helper.claimShareholderToCallerForUser(alice);
    }

    function testClaimShareholderToCallerForUser_RevertsOnSelfCall() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimShareholderToCallerForUser(alice);

        assertEq(royalties.routeToCalls(), 0);
    }

    function testClaimShareholderToCallerForUser_RevertsOnZeroAddressUser() public {
        vm.prank(bob);
        vm.expectRevert(Errors.ZeroAddress.selector);
        helper.claimShareholderToCallerForUser(address(0));

        assertEq(royalties.routeToCalls(), 0);
    }

    function testClaimShareholderToCallerForUser_RevertsWhenMissingRouteBit() public {
        PermissionAwareDelegationHubMock permHub = new PermissionAwareDelegationHubMock();
        // Claim-for is granted, but the value-redirect bit is not.
        permHub.grantPerms(alice, bob, DelegationPermissions.P_CLAIM_SHAREHOLDER_FOR);
        _wireCanonical(address(royalties), address(mineCore), address(furnace), address(helper), address(permHub));

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimShareholderToCallerForUser(alice);

        assertEq(royalties.routeToCalls(), 0);
    }

    function testClaimShareholderToCallerForUser_RevertsWhenMissingClaimBit() public {
        PermissionAwareDelegationHubMock permHub = new PermissionAwareDelegationHubMock();
        // Value-redirect bit alone is insufficient without the claim-for authority.
        permHub.grantPerms(alice, bob, DelegationPermissions.P_ROUTE_SHAREHOLDER_ETH_TO_CALLER);
        _wireCanonical(address(royalties), address(mineCore), address(furnace), address(helper), address(permHub));

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        helper.claimShareholderToCallerForUser(alice);

        assertEq(royalties.routeToCalls(), 0);
    }

    function testClaimShareholderToCallerForUser_RevertsWhenFurnaceDelegationHubDiffers() public {
        _grantRouteToCaller(alice, bob);
        MockDelegationHubForClaimAll otherHub = new MockDelegationHubForClaimAll();
        otherHub.setAuthorized(true);
        furnace.setDelegationHub(address(otherHub));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        helper.claimShareholderToCallerForUser(alice);

        assertEq(royalties.routeToCalls(), 0);
    }
}
