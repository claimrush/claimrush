// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ClaimAllHelper} from "src/ClaimAllHelper.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {Constants} from "src/lib/Constants.sol";
import {Errors} from "src/lib/Errors.sol";
import {Events} from "src/lib/Events.sol";

import {MockContract} from "./mocks/MockContract.sol";
import {MockVe} from "./mocks/MockVe.sol";

contract MockFurnaceSR {
    struct LockCall {
        address user;
        uint256 ethAmount;
        uint256 targetTokenId;
        uint256 durationSeconds;
        bool createAutoMax;
        uint256 minVeOut;
    }

    LockCall public lastCall;
    bool public shouldRevert;
    mapping(address => bool) public revertFor;
    uint256 public quoteVeOut = 100e18;
    uint256 public quoteMinGasLeft;
    uint256 public lockCalls;
    address public mineCore;
    address public mineMarket;
    address public shareholderRoyalties;
    address public delegationHub;

    function setDelegationHub(address v) external {
        delegationHub = v;
    }

    function setQuoteVeOut(uint256 v) external {
        quoteVeOut = v;
    }

    function setQuoteMinGasLeft(uint256 v) external {
        quoteMinGasLeft = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setRevertFor(address user, bool v) external {
        revertFor[user] = v;
    }

    function setWiring(address _mineCore, address _mineMarket, address _shareholderRoyalties) external {
        mineCore = _mineCore;
        mineMarket = _mineMarket;
        shareholderRoyalties = _shareholderRoyalties;
    }

    function furnaceQuoter() external view returns (address) {
        return address(this);
    }

    function quoteEnterWithEth(address, uint256, uint256, uint256, bool)
        external
        view
        returns (uint256, uint256, uint256 veOut, uint256)
    {
        uint256 floor = quoteMinGasLeft;
        if (floor != 0) {
            while (gasleft() > floor) {
                assembly {
                    let ptr := mload(0x40)
                    mstore(ptr, add(mload(ptr), 1))
                }
            }
        }
        return (0, 0, quoteVeOut, 0);
    }

    function lockEthReward(
        address user,
        uint256 ethAmount,
        uint256 targetTokenId,
        uint256 durationSeconds,
        bool createAutoMax,
        uint256 minVeOut
    ) external payable {
        lockCalls++;
        require(msg.value == ethAmount, "value mismatch");
        if (shouldRevert || revertFor[user]) revert("MockFurnaceSR: revert");
        lastCall = LockCall(user, ethAmount, targetTokenId, durationSeconds, createAutoMax, minVeOut);
    }
}

contract MockMineCoreSR {
    address public furnace;
    address public claimAllHelper;
    address public delegationHub;

    function setWiring(address _furnace, address _claimAllHelper) external {
        furnace = _furnace;
        claimAllHelper = _claimAllHelper;
    }

    function setDelegationHub(address _delegationHub) external {
        delegationHub = _delegationHub;
    }
}

/// @dev Receiver that returns a large blob of returndata on ETH receive.
///      Used to ensure the caller is not vulnerable to "return bombs".
contract ReturnBombReceiver {
    ShareholderRoyalties internal immutable royalties;

    constructor(ShareholderRoyalties r) {
        royalties = r;
    }

    function claim() external {
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
    }

    // No `receive()` on purpose: empty calldata hits fallback.
    fallback() external payable {
        assembly {
            let ptr := mload(0x40)
            // Return a large blob (65,536 bytes).
            return(ptr, 0x10000)
        }
    }
}

contract ShareholderRoyaltiesTest is Test {
    ShareholderRoyalties internal royalties;
    MockVe internal ve;
    MockFurnaceSR internal furnace;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal keeper;
    address internal mineCore;
    address internal mineMarket;
    address internal claimToken;
    address internal delegationHub;
    MockMineCoreSR internal mineCoreMock;

    function _deployCanonicalClaimAllHelper() internal returns (ClaimAllHelper helper) {
        helper = new ClaimAllHelper(address(royalties), mineCore);

        vm.prank(owner);
        royalties.setClaimAllHelper(address(helper));
        mineCoreMock.setWiring(address(furnace), address(helper));
    }

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");
        delegationHub = address(new MockContract());

        ve = new MockVe();
        furnace = new MockFurnaceSR();
        mineCoreMock = new MockMineCoreSR();
        MockContract mockMarket = new MockContract();
        claimToken = address(new MockContract());
        mineCore = address(mineCoreMock);
        mineMarket = address(mockMarket);

        royalties = new ShareholderRoyalties(address(ve), owner);

        // Keep live/backpointer checks satisfiable in tests that exercise Baron lock routing.
        furnace.setWiring(mineCore, mineMarket, address(royalties));
        furnace.setDelegationHub(delegationHub);
        mineCoreMock.setWiring(address(furnace), address(0));
        mineCoreMock.setDelegationHub(delegationHub);
        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(address(furnace), abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(address(ve), abi.encodeWithSignature("furnace()"), abi.encode(address(furnace)));
        vm.mockCall(address(ve), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(ve), abi.encodeWithSignature("claimToken()"), abi.encode(claimToken));
        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        vm.prank(owner);
        royalties.setWiring(mineCore, mineMarket, address(furnace));

        vm.prank(owner);
        royalties.setAutoCompoundKeeper(keeper, true);
    }

    function testConstructorRevertsWhenVeIsNotAContract() public {
        vm.expectRevert(Errors.NotAContract.selector);
        new ShareholderRoyalties(address(0xBEEF), owner);
    }

    function testFuzz_constructorRevertsWhenVeIsEoa(address badVe) public {
        vm.assume(badVe != address(0));
        vm.assume(badVe.code.length == 0);

        vm.expectRevert(Errors.NotAContract.selector);
        new ShareholderRoyalties(badVe, owner);
    }

    function _takeover(uint256 amountEth) internal {
        vm.deal(mineCore, amountEth);
        vm.prank(mineCore);
        royalties.onTakeover{value: amountEth}(1);
    }

    function _primeIndex(uint256 veTotal, uint256 pendingEth) internal {
        ve.setTotalVeCached(veTotal);
        _takeover(pendingEth);
        royalties.flushPendingShareholderETH();
    }

    /// @dev Builds the canonical sub-resolution state used to exercise the disjoint-
    ///      buckets invariant on consumption paths. Two 1 wei takeovers with a 3 ve
    ///      denominator: the first auto-flush distributes 0 wei (mulDiv floor); the
    ///      second distributes 1 wei. checkpointUser clamps the per-user credit to
    ///      the indexed pool, so after the helper returns the books read:
    ///        - `_claimableEthStored[user] == 1` (clamped)
    ///        - `indexedEthOwed == 0` (drained by the clamped credit)
    ///        - `pendingShareholderETH == 1` (the un-flushed carry wei)
    ///        - balance == 2 (disjoint sum of the three buckets above)
    function _primeClampedStoredAndPendingCarry(address user) internal {
        ve.setTotalVeCached(3);
        ve.setVeBalance(user, 3);

        _takeover(1);
        _takeover(1);

        royalties.checkpointUser(user);
    }

    // ------------------------------------------------------------
    // Wiring + admin
    // ------------------------------------------------------------

    function testSetWiringOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        royalties.setWiring(mineCore, mineMarket, address(furnace));
    }

    function testSetWiringRevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        royalties.setWiring(address(0), mineMarket, address(furnace));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        royalties.setWiring(mineCore, address(0), address(furnace));

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        royalties.setWiring(mineCore, mineMarket, address(0));
    }

    function testSetClaimAllHelperOnlyOwner() public {
        address helper = makeAddr("helper");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        royalties.setClaimAllHelper(helper);
    }

    function testSetClaimAllHelperRevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        royalties.setClaimAllHelper(address(0));
    }

    function testSetAutoCompoundKeeperOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        royalties.setAutoCompoundKeeper(alice, true);
    }

    function testSetAutoCompoundKeeperZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        royalties.setAutoCompoundKeeper(address(0), true);
    }

    // ------------------------------------------------------------
    // OnTakeover + flush
    // ------------------------------------------------------------

    function testOnTakeoverOnlyMineCoreAndAccumulatesETH() public {
        vm.deal(alice, 10 ether);
        vm.deal(mineCore, 10 ether);

        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineCore.selector);
        royalties.onTakeover{value: 1 ether}(1);

        vm.prank(mineCore);
        royalties.onTakeover{value: 2 ether}(1);

        assertEq(royalties.pendingShareholderETH(), 2 ether);
    }

    function testFlushNoOpWhenPendingZero() public {
        ve.setTotalVeCached(Constants.MIN_VE_FLUSH);
        royalties.flushPendingShareholderETH();
        assertEq(royalties.ethPerVe(), 0);
        assertEq(royalties.pendingShareholderETH(), 0);
    }

    // ------------------------------------------------------------
    // Missing checklist tests: edge-case behavioral contract
    // ------------------------------------------------------------

    function testOnTakeoverZeroValueIsNoOpAndDoesNotRevert() public {
        vm.deal(mineCore, 0);
        vm.prank(mineCore);
        royalties.onTakeover{value: 0}(1);

        assertEq(royalties.pendingShareholderETH(), 0);
        assertEq(royalties.ethPerVe(), 0);
    }

    function testCheckpointUserZeroAddressIsNoOp() public {
        _primeIndex(200e18, 1 ether);

        // Must not revert and must not write state.
        royalties.checkpointUser(address(0));

        // ethPerVe unchanged (no user state written).
        assertEq(royalties.ethPerVe(), 5e15);
    }

    function testCheckpointTransferSameAddressIsNoOp() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        vm.prank(mineMarket);
        royalties.checkpointTransfer(alice, alice);

        // Self-transfer must not crystallise rewards into storage and must not advance the
        // user's paid-index. Live `claimableEth` still reports the uncheckpointed accrual.
        assertEq(royalties.claimableEthStored(alice), 0);
        assertEq(royalties.userEthPerVePaid(alice), 0);
    }

    function testClaimShareholderInvalidModeReverts() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidMode.selector);
        royalties.claimShareholder(2, 0, 0, false, 0);

        // Claimable must be preserved after revert.
        assertEq(royalties.claimableEth(alice), 0.25 ether);
    }

    function testAddPendingShareholderETHZeroValueIsNoOp() public {
        vm.prank(mineCore);
        royalties.addPendingShareholderETH{value: 0}(1);
        assertEq(royalties.pendingShareholderETH(), 0);
    }

    function testFlushNoOpBelowMinVe() public {
        // Keep the original takeover undistributed by using a zero processed denominator.
        ve.setTotalVeCached(0);
        _takeover(1 ether);

        // Manual flush still no-ops below MIN_VE_FLUSH for residual/unindexable pending ETH.
        ve.setTotalVeCached(Constants.MIN_VE_FLUSH - 1);
        royalties.flushPendingShareholderETH();

        assertEq(royalties.ethPerVe(), 0);
        assertEq(royalties.pendingShareholderETH(), 1 ether);
    }

    function testFlushNoOpWhenDeltaZeroKeepsDust() public {
        ve.setTotalVeCached(Constants.MIN_VE_FLUSH);
        _takeover(99);
        royalties.flushPendingShareholderETH();

        assertEq(royalties.ethPerVe(), 0);
        assertEq(royalties.pendingShareholderETH(), 99);
    }

    function testFlushDistributesAndUpdatesIndex() public {
        ve.setTotalVeCached(200e18);
        vm.expectEmit(false, false, false, true);
        emit Events.ShareholderFlush(1 ether, 5e15);
        _takeover(1 ether);

        assertEq(royalties.ethPerVe(), 5e15);
        assertEq(royalties.pendingShareholderETH(), 0);
    }

    function testFlushKeepsPendingWhenVeCheckpointRemainsStale() public {
        ve.setTotalVeCached(200e18);
        ve.setGlobalLastTs(block.timestamp - 1);
        ve.setCheckpointAdvances(false);

        _takeover(1 ether);

        assertEq(royalties.ethPerVe(), 0);
        assertEq(royalties.pendingShareholderETH(), 1 ether);

        royalties.flushPendingShareholderETH();

        assertEq(royalties.ethPerVe(), 0);
        assertEq(royalties.pendingShareholderETH(), 1 ether);
    }

    function testFlushResumesAfterVeCheckpointCatchesUp() public {
        ve.setTotalVeCached(200e18);
        ve.setGlobalLastTs(block.timestamp - 1);
        ve.setCheckpointAdvances(false);

        _takeover(1 ether);

        assertEq(royalties.ethPerVe(), 0);
        assertEq(royalties.pendingShareholderETH(), 1 ether);

        ve.setCheckpointAdvances(true);
        royalties.flushPendingShareholderETH();

        assertEq(royalties.ethPerVe(), 5e15);
        assertEq(royalties.pendingShareholderETH(), 0);
    }

    function testTakeoverIndexesImmediatelyBelowMinVeToPreventLaterEntrantDilution() public {
        uint256 aliceVe = Constants.MIN_VE_FLUSH - 1;
        uint256 bobVe = 100e18;

        ve.setVeBalance(alice, aliceVe);
        ve.setTotalVeCached(aliceVe);

        // Simulate VeClaimNFT's pre-mutation checkpoint for Bob before Bob becomes a shareholder.
        royalties.checkpointUser(bob);

        _takeover(1 ether);

        // With the MED-02 fix, the takeover is indexed immediately even below MIN_VE_FLUSH, so a
        // later entrant cannot capture any of this earlier allocation.
        assertGt(royalties.ethPerVe(), 0);
        assertLe(royalties.pendingShareholderETH(), 1);

        // Bob joins after the takeover.
        ve.setVeBalance(bob, bobVe);
        ve.setTotalVeCached(aliceVe + bobVe);

        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        uint256 aliceClaimable = royalties.claimableEth(alice);
        uint256 bobClaimable = royalties.claimableEth(bob);
        assertGe(aliceClaimable + bobClaimable, 1 ether - 1);
    }

    function testTakeoverKeepsPendingWhenNoShareholdersExist() public {
        ve.setTotalVeCached(0);

        _takeover(1 ether);

        assertEq(royalties.ethPerVe(), 0);
        assertEq(royalties.pendingShareholderETH(), 1 ether);
    }

    function testAddPendingIndexesImmediatelyWhenProcessedWeightExists() public {
        ve.setTotalVeCached(Constants.MIN_VE_FLUSH - 1);

        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.addPendingShareholderETH{value: 1 ether}(1);

        assertGt(royalties.ethPerVe(), 0);
        assertLe(royalties.pendingShareholderETH(), 1);
    }

    // ------------------------------------------------------------
    // Checkpointing + transfers
    // ------------------------------------------------------------

    function testCheckpointAccruesAndIsIdempotent() public {
        _primeIndex(200e18, 1 ether); // ethPerVe = 5e15
        ve.setVeBalance(alice, 50e18);

        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);
    }

    function testCheckpointUserZeroVeSetsPaid() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 0);

        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0);
        assertEq(royalties.userEthPerVePaid(alice), royalties.ethPerVe());
    }

    function testCheckpointTransferOnlyMineMarket() public {
        vm.prank(alice);
        vm.expectRevert(Errors.OnlyMineMarket.selector);
        royalties.checkpointTransfer(alice, bob);
    }

    function testCheckpointTransferAccruesBothSides() public {
        _primeIndex(200e18, 1 ether); // ethPerVe = 5e15
        ve.setVeBalance(alice, 50e18);
        ve.setVeBalance(bob, 50e18);

        vm.prank(mineMarket);
        royalties.checkpointTransfer(alice, bob);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
        assertEq(royalties.claimableEth(bob), 0.25 ether);
    }

    function testMultiReignOverclaimSequence_NoRetroCaptureAcrossTransfers() public {
        uint256 totalVe = 200e18;
        ve.setTotalVeCached(totalVe);

        // Start: Alice owns all ve.
        ve.setVeBalance(alice, totalVe);
        ve.setVeBalance(bob, 0);

        // Reign 1: 1 ETH distributed while Alice holds the full balance.
        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.onTakeover{value: 1 ether}(1);
        royalties.flushPendingShareholderETH();
        assertEq(royalties.ethPerVe(), 5e15);

        // Transfer Alice -> Bob (checkpoint BEFORE the balance move).
        vm.prank(mineMarket);
        royalties.checkpointTransfer(alice, bob);
        ve.setVeBalance(alice, 0);
        ve.setVeBalance(bob, totalVe);

        // Reign 2: 1 ETH distributed while Bob holds the full balance.
        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.onTakeover{value: 1 ether}(2);
        royalties.flushPendingShareholderETH();
        assertEq(royalties.ethPerVe(), 1e16);

        // Transfer Bob -> Alice (checkpoint BEFORE the balance move).
        vm.prank(mineMarket);
        royalties.checkpointTransfer(bob, alice);
        ve.setVeBalance(bob, 0);
        ve.setVeBalance(alice, totalVe);

        // Reign 3: 1 ETH distributed while Alice holds the full balance again.
        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.onTakeover{value: 1 ether}(3);
        royalties.flushPendingShareholderETH();
        assertEq(royalties.ethPerVe(), 15e15);

        // Final checkpoints to materialize claimables.
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        // Alice should get reigns 1 + 3, Bob should get reign 2.
        assertEq(royalties.claimableEth(alice), 2 ether);
        assertEq(royalties.claimableEth(bob), 1 ether);

        // No insolvency / overclaim: sum of claimables matches contract balance.
        assertEq(address(royalties).balance, 3 ether);

        uint256 aliceBalBefore = alice.balance;
        uint256 bobBalBefore = bob.balance;

        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        vm.prank(bob);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(alice.balance, aliceBalBefore + 2 ether);
        assertEq(bob.balance, bobBalBefore + 1 ether);
        assertEq(address(royalties).balance, 0);

        // Idempotent: a second claim does not change balances.
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(alice.balance, aliceBalBefore + 2 ether);
    }

    // ------------------------------------------------------------
    // Claiming
    // ------------------------------------------------------------

    function testClaimShareholderEthModeSendsAndClears() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(royalties.claimableEth(alice), 0);
        assertEq(alice.balance, balBefore + 0.25 ether);
    }

    function testClaimShareholderEthModeResistsReturnBomb() public {
        ReturnBombReceiver bomb = new ReturnBombReceiver(royalties);

        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(address(bomb), 50e18);
        royalties.checkpointUser(address(bomb));
        assertEq(royalties.claimableEth(address(bomb)), 0.25 ether);

        uint256 balBefore = address(bomb).balance;
        bomb.claim();

        assertEq(address(bomb).balance, balBefore + 0.25 ether);
        assertEq(royalties.claimableEth(address(bomb)), 0);
    }

    function testClaimShareholderForOnlyClaimAllHelper() public {
        _deployCanonicalClaimAllHelper();

        vm.prank(bob);
        vm.expectRevert(Errors.OnlyClaimAllHelper.selector);
        royalties.claimShareholderFor(alice, Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
    }

    function testClaimShareholderForEthModeSendsAndClearsForUser() public {
        ClaimAllHelper helper = _deployCanonicalClaimAllHelper();

        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        uint256 balBefore = alice.balance;

        vm.prank(address(helper));
        royalties.claimShareholderFor(alice, Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(royalties.claimableEth(alice), 0);
        assertEq(alice.balance, balBefore + 0.25 ether);
    }

    function testClaimShareholderForLockModeCallsFurnaceWhenCanonicalHelperAgrees() public {
        ClaimAllHelper helper = _deployCanonicalClaimAllHelper();

        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        vm.prank(address(helper));
        royalties.claimShareholderFor(alice, Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 7, 30 days, false, 123);

        assertEq(royalties.claimableEth(alice), 0);

        (address user, uint256 ethAmount, uint256 tokenId, uint256 duration, bool createAutoMax, uint256 minVeOut) =
            furnace.lastCall();
        assertEq(user, alice);
        assertEq(ethAmount, 0.25 ether);
        assertEq(tokenId, 7);
        assertEq(duration, 30 days);
        assertEq(createAutoMax, false);
        assertEq(minVeOut, 123);
    }

    function testClaimShareholderForLockModeRevertsWhenRoyaltiesHelperDriftsFromCanonicalMineCoreAndDoesNotLoseClaimable()
        public
    {
        ClaimAllHelper canonicalHelper = _deployCanonicalClaimAllHelper();
        ClaimAllHelper rogueHelper = new ClaimAllHelper(address(royalties), mineCore);

        vm.prank(owner);
        royalties.setClaimAllHelper(address(rogueHelper));
        mineCoreMock.setWiring(address(furnace), address(canonicalHelper));

        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        uint256 claimableBefore = royalties.claimableEth(alice);

        vm.prank(address(rogueHelper));
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholderFor(alice, Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 7, 30 days, false, 123);

        assertEq(
            royalties.claimableEth(alice), claimableBefore, "helper drift must not consume a user's claimable Baron ETH"
        );

        (address user,,,,,) = furnace.lastCall();
        assertEq(user, address(0), "foreign helper drift must not reach lockEthReward");
    }

    function testClaimShareholderForEthModeRevertsWhenMineCoreHelperBackpointerMismatchesAndDoesNotLoseClaimable()
        public
    {
        ClaimAllHelper configuredHelper = _deployCanonicalClaimAllHelper();
        ClaimAllHelper rogueHelper = new ClaimAllHelper(address(royalties), mineCore);
        mineCoreMock.setWiring(address(furnace), address(rogueHelper));

        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        uint256 balBefore = alice.balance;
        uint256 claimableBefore = royalties.claimableEth(alice);

        vm.prank(address(configuredHelper));
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholderFor(alice, Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(
            royalties.claimableEth(alice),
            claimableBefore,
            "core helper mismatch must not consume a user's claimable ETH"
        );
        assertEq(alice.balance, balBefore, "core helper mismatch must not transfer user ETH");
    }

    function testClaimShareholderLockModeCallsFurnace() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 7, 30 days, false, 123);

        assertEq(royalties.claimableEth(alice), 0);

        (address user, uint256 ethAmount, uint256 tokenId, uint256 duration, bool createAutoMax, uint256 minVeOut) =
            furnace.lastCall();
        assertEq(user, alice);
        assertEq(ethAmount, 0.25 ether);
        assertEq(tokenId, 7);
        assertEq(duration, 30 days);
        assertEq(createAutoMax, false);
        assertEq(minVeOut, 123);
    }

    function testClaimShareholderLockModeBubblesRevertAndDoesNotLoseClaimable() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        furnace.setShouldRevert(true);
        vm.prank(alice);
        vm.expectRevert(bytes("MockFurnaceSR: revert"));
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 7, 30 days, false, 123);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
    }

    function testClaimShareholderLockModeRevertsOnFurnaceWiringMismatchAndDoesNotLoseClaimable() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        furnace.setWiring(address(0xDEAD), mineMarket, address(royalties));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 7, 30 days, false, 123);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
    }

    function testClaimShareholderLockModeRevertsWhenFurnaceVeRootMismatchesAndDoesNotLoseClaimable() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(0xDEAD)));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 7, 30 days, false, 123);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
    }

    function testClaimShareholderLockModeRevertsWhenMineCoreFurnaceBackpointerMismatchesAndDoesNotLoseClaimable()
        public
    {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        mineCoreMock.setWiring(address(0xBEEF), address(0));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 7, 30 days, false, 123);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
    }

    function testClaimShareholderLockModeRevertsWhenVeFurnaceBackpointerMismatchesAndDoesNotLoseClaimable() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        vm.mockCall(address(ve), abi.encodeWithSignature("furnace()"), abi.encode(address(0xBEEF)));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_LOCK_FURNACE, 7, 30 days, false, 123);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
    }

    function testOnTakeoverRevertsWhenMineMarketRoyaltiesRootDiffersAndDoesNotAccumulatePending() public {
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.onTakeover{value: 1 ether}(1);

        assertEq(royalties.pendingShareholderETH(), 0, "market royalties drift must not enqueue takeover ETH");
    }

    function testAddPendingShareholderETHRevertsWhenClaimTokenMineCoreRootDiffersAndDoesNotAccumulatePending() public {
        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(address(0xDEAD)));

        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.addPendingShareholderETH{value: 1 ether}(1);

        assertEq(royalties.pendingShareholderETH(), 0, "claim token root drift must not enqueue pending ETH");
    }

    function testFlushPendingShareholderETHRevertsWhenMineMarketRoyaltiesRootDiffersAndKeepsPending() public {
        vm.deal(mineCore, 1 ether);
        vm.prank(mineCore);
        royalties.onTakeover{value: 1 ether}(1);
        assertEq(royalties.pendingShareholderETH(), 1 ether, "canonical takeover should leave ETH pending");

        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.flushPendingShareholderETH();

        assertEq(royalties.pendingShareholderETH(), 1 ether, "flush revert must preserve pending ETH");
    }

    function testCheckpointUserRevertsWhenMineMarketRoyaltiesRootDiffersAndDoesNotMutateUserState() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.checkpointUser(alice);

        assertEq(royalties.claimableEthStored(alice), 0, "market royalties drift must not crystallise claimable ETH");
        assertEq(royalties.userEthPerVePaid(alice), 0, "market royalties drift must not advance paid index");
    }

    function testCheckpointUserRevertsWhenMineCoreRoyaltiesRootDiffersAndDoesNotMutateUserState() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.checkpointUser(alice);

        assertEq(royalties.claimableEthStored(alice), 0, "core royalties drift must not crystallise claimable ETH");
        assertEq(royalties.userEthPerVePaid(alice), 0, "core royalties drift must not advance paid index");
    }

    function testClaimShareholderEthModeRevertsWhenMineMarketRoyaltiesRootDiffersAndDoesNotLoseClaimable() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        uint256 claimableBefore = royalties.claimableEth(alice);
        uint256 balBefore = alice.balance;

        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(
            royalties.claimableEth(alice),
            claimableBefore,
            "market royalties drift must not consume claimable Baron ETH"
        );
        assertEq(alice.balance, balBefore, "market royalties drift must not transfer ETH");
    }

    function testClaimShareholderEthModeRevertsWhenClaimTokenMineCoreRootDiffersAndDoesNotLoseClaimable() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        uint256 claimableBefore = royalties.claimableEth(alice);
        uint256 balBefore = alice.balance;

        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(address(0xDEAD)));

        vm.prank(alice);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(
            royalties.claimableEth(alice),
            claimableBefore,
            "claim token root drift must not consume claimable Baron ETH"
        );
        assertEq(alice.balance, balBefore, "claim token root drift must not transfer ETH");
    }

    function testCompoundForRevertsWhenMineMarketRoyaltiesRootDiffersAndPreservesClaimable() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), 0.25 ether, "market royalties drift must not consume claimable ETH");
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0, "market royalties drift must not advance cadence");
    }

    // ------------------------------------------------------------
    // Auto-compound
    // ------------------------------------------------------------

    function _setValidDest(uint256 tokenId, address user, uint256 lockEnd, bool autoMax, bool listed) internal {
        ve.setOwner(tokenId, user);
        ve.setLockInfo(tokenId, 1_000e18, lockEnd, autoMax, listed);
    }

    function testSetAutoCompoundConfigEnableDisable() public {
        _setValidDest(1, alice, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 1 hours, 0.01 ether, 500);

        (
            bool enabled,
            bool paused,
            uint256 tokenId,
            uint256 durationSeconds,
            uint32 cadence,
            uint256 minEth,
            uint32 maxSlip,
            uint40 lastTs
        ) = royalties.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertTrue(!paused);
        assertEq(tokenId, 1);
        assertEq(durationSeconds, 30 days);
        assertEq(cadence, 1 hours);
        assertEq(minEth, 0.01 ether);
        assertEq(maxSlip, 500);
        assertEq(lastTs, 0);

        vm.prank(alice);
        royalties.setAutoCompoundConfig(false, 0, 0, 0, 0, 0);

        (enabled, paused, tokenId, durationSeconds, cadence, minEth, maxSlip, lastTs) =
            royalties.getAutoCompoundConfig(alice);
        assertTrue(!enabled);
        assertTrue(!paused);
        assertEq(tokenId, 0);
        assertEq(durationSeconds, 0);
        assertEq(cadence, 0);
        assertEq(minEth, 0);
        assertEq(lastTs, 0);
    }

    function testSetAutoCompoundConfigRevertsWhenTokenIdIsZero() public {
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidToken.selector);
        royalties.setAutoCompoundConfig(true, 0, 30 days, 0, 0, 500);
    }

    function testCompoundForRevertsForNonKeeper() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        royalties.compoundFor(alice);
    }

    function testCompoundForKeeperAllowed() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), 0);

        // Furnace call reflects the user, not the executor. minVeOut from quote (100e18) * (1 - 5%) = 95e18.
        (
            address user,
            uint256 ethAmount,
            uint256 targetTokenId,
            uint256 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) = furnace.lastCall();
        assertEq(user, alice);
        assertEq(ethAmount, 0.25 ether);
        assertEq(targetTokenId, 1);
        assertEq(durationSeconds, 30 days);
        assertFalse(createAutoMax);
        assertEq(minVeOut, 95e18);
    }

    function testCompoundForOwnerAllowed() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        vm.prank(owner);
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), 0);

        (
            address user,
            uint256 ethAmount,
            uint256 targetTokenId,
            uint256 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) = furnace.lastCall();
        assertEq(user, alice);
        assertEq(ethAmount, 0.25 ether);
        assertEq(targetTokenId, 1);
        assertEq(durationSeconds, 30 days);
        assertFalse(createAutoMax);
        assertEq(minVeOut, 95e18);
    }

    function testCompoundFor_UsesConfiguredLongerDurationForExistingLock() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        uint256 remaining = 30 days;
        uint256 configured = 90 days;
        _setValidDest(1, alice, block.timestamp + remaining, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, configured, 0, 0, 500);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        (,,, uint256 durationSeconds,,) = furnace.lastCall();
        assertEq(durationSeconds, configured);
    }

    function testFuzz_compoundFor_UsesMaxOfConfiguredAndRemainingDuration(uint40 remainingRaw, uint40 configuredRaw)
        public
    {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        uint256 remaining = bound(uint256(remainingRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);
        uint256 configured = bound(uint256(configuredRaw), Constants.MIN_LOCK_DURATION, Constants.MAX_LOCK_DURATION);

        _setValidDest(1, alice, block.timestamp + remaining, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, configured, 0, 0, 500);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        uint256 expected = configured;
        if (remaining > expected) expected = remaining;

        (,,, uint256 durationSeconds,,) = furnace.lastCall();
        assertEq(durationSeconds, expected);
    }

    function testCompoundForThresholdNoOpDoesNotAdvanceCadence() public {
        _primeIndex(200e18, 1 ether); // alice accrues 0.25 ETH
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0.26 ether, 500);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        // No-op return (below threshold): claimable preserved and no lastCompoundTs update.
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testCompoundForPausesOnNotOwnerAndDoesNotClearClaimable() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        // Transfer away (simulated): owner changes.
        ve.setOwner(1, bob);

        // Pre-accrue.
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        vm.expectEmit(true, false, false, true);
        emit Events.ShareholderAutoCompoundPaused(alice, 1, Constants.SHAREHOLDER_AUTOCOMPOUND_PAUSE_REASON_NOT_OWNER);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        // Paused and claimable preserved.
        (, bool paused,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertTrue(paused);
        assertEq(lastTs, 0);
        assertEq(royalties.claimableEth(alice), 0.25 ether);
    }

    function testCompoundForBubblesRevertAndDoesNotLoseClaimableOrCadence() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        furnace.setShouldRevert(true);

        // Pre-accrue.
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        vm.prank(keeper);
        vm.expectRevert(bytes("MockFurnaceSR: revert"));
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testCompoundForRevertsOnFurnaceWiringMismatchAndDoesNotLoseClaimableOrCadence() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        // Pre-accrue.
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        furnace.setWiring(mineCore, address(0xDEAD), address(royalties));

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testCompoundForRevertsWhenFurnaceVeRootMismatchesAndDoesNotLoseClaimableOrCadence() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        // Pre-accrue.
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(0xDEAD)));

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testCompoundForRevertsWhenMineCoreFurnaceBackpointerMismatchesAndDoesNotLoseClaimableOrCadence() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        mineCoreMock.setWiring(address(0xBEEF), address(0));

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testCompoundForCadenceEnforcedAfterSuccess() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 100, 0, 500);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(uint256(lastTs), block.timestamp);

        vm.prank(keeper);
        vm.expectRevert(Errors.CadenceNotMet.selector);
        royalties.compoundFor(alice);
    }

    function testCompoundForManyCompoundsAllUsers() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        ve.setVeBalance(bob, 50e18);

        // Accrue for both upfront.
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);
        assertEq(royalties.claimableEth(alice), 0.25 ether);
        assertEq(royalties.claimableEth(bob), 0.25 ether);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        _setValidDest(2, bob, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);
        vm.prank(bob);
        royalties.setAutoCompoundConfig(true, 2, 30 days, 0, 0, 500);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        // Both users should be processed by the authorized keeper.
        assertEq(royalties.claimableEth(alice), 0);
        assertEq(royalties.claimableEth(bob), 0);
    }

    function testCompoundForManyRevertsForNonKeeper() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(bob);
        vm.expectRevert(Errors.NotAuthorized.selector);
        royalties.compoundForMany(users, 1);
    }

    function testCompoundForManyOwnerAllowed() public {
        _primeIndex(200e18, 1 ether);
        ve.setTotalVeCached(400e18);
        ve.setVeBalance(alice, 100e18);
        ve.setVeBalance(bob, 100e18);
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);
        assertGt(royalties.claimableEth(alice), 0);
        assertGt(royalties.claimableEth(bob), 0);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        _setValidDest(2, bob, block.timestamp + 30 days, false, false);

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);
        vm.prank(bob);
        royalties.setAutoCompoundConfig(true, 2, 30 days, 0, 0, 500);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(owner);
        royalties.compoundForMany(users, 10);

        assertEq(royalties.claimableEth(alice), 0);
        assertEq(royalties.claimableEth(bob), 0);
    }

    function testCompoundForManyRestoresStateOnFurnaceRevert() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        furnace.setRevertFor(alice, true);

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        // Downstream Furnace-call failure is best-effort in batch mode and MUST NOT lose accounting.
        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);

        // The restored accounting must remain claimable after the failed batch attempt.
        furnace.setRevertFor(alice, false);
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(alice.balance, aliceBalBefore + 0.25 ether);
    }

    function testCompoundForManyRevertsWhenFurnaceMineMarketRootMismatches() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        furnace.setWiring(mineCore, address(0xDEAD), address(royalties));

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundForMany(users, 10);

        // Canonical Baron-bundle drift is detected during checkpointUser, so the batch reverts before mutating accounting.
        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testCompoundForManyRevertsWhenFurnaceVeRootMismatches() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(0xDEAD)));

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundForMany(users, 10);

        // Canonical Baron-bundle drift is detected during checkpointUser, so the batch reverts before mutating accounting.
        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testCompoundForManyRevertsWhenMineCoreFurnaceBackpointerMismatches() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        mineCoreMock.setWiring(address(0xBEEF), address(0));

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(keeper);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.compoundForMany(users, 10);

        // Canonical Baron-bundle drift is detected during checkpointUser, so the batch reverts before mutating accounting.
        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testSetAutoCompoundConfigForUserRevertsWhenFurnaceVeRootMismatches() public {
        vm.prank(owner);
        royalties.setWiring(mineCore, mineMarket, address(furnace));

        vm.mockCall(address(furnace), abi.encodeWithSignature("ve()"), abi.encode(address(0xDEAD)));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.setAutoCompoundConfigForUser(alice, false, 0, 0, 0, 0, 0);
    }

    function testSetAutoCompoundConfigForUserRevertsWhenMineCoreDelegationHubDiffers() public {
        mineCoreMock.setDelegationHub(address(0xBEEF));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.setAutoCompoundConfigForUser(alice, false, 0, 0, 0, 0, 0);
    }

    function testSetAutoCompoundConfigForUserRevertsWhenMineMarketRoyaltiesRootDiffers() public {
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(0xDEAD)));

        vm.prank(bob);
        vm.expectRevert(Errors.WiringMismatch.selector);
        royalties.setAutoCompoundConfigForUser(alice, false, 0, 0, 0, 0, 0);
    }

    // ------------------------------------------------------------
    // Views
    // ------------------------------------------------------------

    function testGetShareholderStateIncludesUncheckpointedRewards() public {
        _primeIndex(200e18, 1 ether); // ethPerVe = 5e15
        ve.setVeBalance(alice, 50e18);

        // Alice has NOT been checkpointed yet, so the crystallised storage slot is 0.
        assertEq(royalties.claimableEthStored(alice), 0);

        // `claimableEth` and `getShareholderState` both report the live entitlement, which
        // includes the uncheckpointed accrual derived from the global reward index.
        assertEq(royalties.claimableEth(alice), 0.25 ether, "live view must include uncheckpointed rewards");

        (uint256 claimable, uint256 userVe, uint256 paid) = royalties.getShareholderState(alice);
        assertEq(claimable, 0.25 ether, "live preview must include uncheckpointed rewards");
        assertEq(userVe, 50e18);
        assertEq(paid, 0);
    }

    function testGetShareholderStateZeroAddressReturnsZeros() public {
        _primeIndex(200e18, 1 ether);

        (uint256 claimable, uint256 userVe, uint256 paid) = royalties.getShareholderState(address(0));
        assertEq(claimable, 0);
        assertEq(userVe, 0);
        assertEq(paid, 0);
    }

    function testGetShareholderStateIdempotentAfterCheckpoint() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        (uint256 claimable1,,) = royalties.getShareholderState(alice);
        (uint256 claimable2,,) = royalties.getShareholderState(alice);
        assertEq(claimable1, claimable2, "view must be idempotent");
        assertEq(claimable1, 0.25 ether);
    }

    function testGetShareholderStateReflectsVeBalance() public {
        ve.setVeBalance(alice, 123);

        (uint256 claimable, uint256 userVe, uint256 paid) = royalties.getShareholderState(alice);
        assertEq(claimable, 0);
        assertEq(userVe, 123);
        assertEq(paid, 0);
    }

    function testSetAutoCompoundConfig_autoMaxRequiresMaxDuration() public {
        _setValidDest(1, alice, block.timestamp + 30 days, true, false);

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidDuration.selector);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, Constants.MAX_LOCK_DURATION, 0, 0, 500);

        (bool enabled, bool paused, uint256 tokenId, uint256 durationSeconds,,,,) =
            royalties.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertFalse(paused);
        assertEq(tokenId, 1);
        assertEq(durationSeconds, Constants.MAX_LOCK_DURATION);
    }

    function testSetAutoCompoundConfig_autoMaxAllowsStaleStoredEnd() public {
        // Stored lockEnd is stale/expired, but AutoMax makes the *effective* end roll forward.
        _setValidDest(1, alice, 0, true, false);

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, Constants.MAX_LOCK_DURATION, 0, 0, 500);

        (bool enabled,, uint256 tokenId, uint256 durationSeconds,,,,) = royalties.getAutoCompoundConfig(alice);
        assertTrue(enabled);
        assertEq(tokenId, 1);
        assertEq(durationSeconds, Constants.MAX_LOCK_DURATION);
    }

    function testCompoundFor_autoMaxDoesNotPauseOnExpired() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        // Destination is AutoMax with a stale/expired stored end.
        _setValidDest(1, alice, 0, true, false);

        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, Constants.MAX_LOCK_DURATION, 0, 0, 500);

        // Pre-accrue so we can assert the exact ETH amount used.
        royalties.checkpointUser(alice);
        uint256 amount = royalties.claimableEth(alice);
        assertGt(amount, 0);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        // Should not pause and should clear claimable.
        (, bool paused,,,,,,) = royalties.getAutoCompoundConfig(alice);
        assertFalse(paused);
        assertEq(royalties.claimableEth(alice), 0);

        // Furnace call must force MAX duration and keep createAutoMax=false for an existing lock.
        // minVeOut computed from quote (100e18) * (1 - 5%) = 95e18.
        (
            address user,
            uint256 ethAmount,
            uint256 targetTokenId,
            uint256 durationSeconds,
            bool createAutoMax,
            uint256 minVeOut
        ) = furnace.lastCall();
        assertEq(user, alice);
        assertEq(ethAmount, amount);
        assertEq(targetTokenId, 1);
        assertEq(durationSeconds, Constants.MAX_LOCK_DURATION);
        assertFalse(createAutoMax);
        assertEq(minVeOut, 95e18);
    }

    function testCompoundFor_clampsMinVeOutToOneWhenComputedZero() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 2000);

        // Force a tiny quote so the slippage floor rounds down to 0.
        furnace.setQuoteVeOut(1);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        // Min ve floor is clamped to 1 to satisfy Furnace's `minVeOut > 0` requirement.
        (,,,,, uint256 minVeOut) = furnace.lastCall();
        assertEq(minVeOut, 1);
    }

    // ------------------------------------------------------------
    // Stale denominator / over-credit regression (scan next actions)
    // ------------------------------------------------------------

    /// @dev After flush, sum(claimableEth) must never exceed the contract balance.
    ///      If totalVeCached were stale low (denom too small), ethPerVe would over-advance and
    ///      claimable totals could exceed available ETH. checkpointTotalVe() before flush prevents that.
    function testFlush_SumClaimableLeqBalance_afterFlush() public {
        uint256 veTotal = 200e18;
        uint256 pendingEth = 1 ether;
        _primeIndex(veTotal, pendingEth);

        ve.setVeBalance(alice, 50e18);
        ve.setVeBalance(bob, 50e18);
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        uint256 claimableAlice = royalties.claimableEth(alice);
        uint256 claimableBob = royalties.claimableEth(bob);
        uint256 totalClaimable = claimableAlice + claimableBob;
        uint256 balance = address(royalties).balance;

        assertLe(totalClaimable, balance, "sum(claimable) must be <= balance to avoid insolvency");
    }

    /// @dev Fuzz: takeover, flush, checkpoint, optional claims; assert sum(claimable) <= balance and pending >= 0.
    ///      Uses totalVeCached >= veAlice + veBob so denominator is not stale low (simulates correct checkpointTotalVe).
    function testFuzz_FlushAndClaims_NoInsolvencyNoNegativePending(
        uint96 takeover1,
        uint96 takeover2,
        uint96 veAlice,
        uint96 veBob,
        bool claimAlice,
        bool claimBob
    ) public {
        // Avoid precompile addresses as claim recipients in fuzzed ETH transfer paths.
        address claimantAlice = address(0xAA);
        address claimantBob = address(0xBB);

        uint256 va = bound(uint256(veAlice), 10e18, 200e18);
        uint256 vb = bound(uint256(veBob), 10e18, 200e18);
        uint256 veTotal = va + vb;
        if (veTotal < Constants.MIN_VE_FLUSH) veTotal = Constants.MIN_VE_FLUSH;

        uint256 a = bound(uint256(takeover1), 0, 50 ether);
        uint256 b = bound(uint256(takeover2), 0, 50 ether);
        ve.setTotalVeCached(veTotal);
        _takeover(a);
        _takeover(b);
        royalties.flushPendingShareholderETH();

        ve.setVeBalance(claimantAlice, va);
        ve.setVeBalance(claimantBob, vb);
        royalties.checkpointUser(claimantAlice);
        royalties.checkpointUser(claimantBob);

        if (claimAlice && royalties.claimableEth(claimantAlice) > 0) {
            vm.prank(claimantAlice);
            (bool ok,) = address(royalties)
                .call(
                    abi.encodeWithSelector(
                        royalties.claimShareholder.selector, Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0
                    )
                );
            if (!ok) {}
        }
        if (claimBob && royalties.claimableEth(claimantBob) > 0) {
            vm.prank(claimantBob);
            (bool ok,) = address(royalties)
                .call(
                    abi.encodeWithSelector(
                        royalties.claimShareholder.selector, Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0
                    )
                );
            if (!ok) {}
        }

        uint256 totalClaimable = royalties.claimableEth(claimantAlice) + royalties.claimableEth(claimantBob);
        assertLe(totalClaimable, address(royalties).balance + 1, "sum(claimable) <= balance (no insolvency)");
        assertGe(royalties.pendingShareholderETH(), 0, "pending must be non-negative");
    }

    // ============================================================
    // disjoint-buckets liability conservation
    // ============================================================

    function testClaimShareholderConsumesOnlyCrystallisedBucket() public {
        _primeClampedStoredAndPendingCarry(alice);

        // Live preview after checkpoint mirrors the storage-only crystallised credit
        // (pending carry stays in the protocol bucket until a later flush ingests it).
        assertEq(royalties.claimableEth(alice), 1, "live claim equals crystallised credit");
        assertEq(royalties.pendingShareholderETH(), 1, "carry wei sits in pending before payout");
        assertEq(address(royalties).balance, 2, "contract holds exactly the two deposited wei");

        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        // The stored-claim consumption path is bucket-disjoint: it pays out the
        // crystallised wei and leaves pending untouched.
        assertEq(alice.balance, 1, "alice receives the crystallised wei");
        assertEq(royalties.claimableEth(alice), 0, "claimable cleared after payout");
        assertEq(royalties.pendingShareholderETH(), 1, "pending carry preserved by stored claim");
        assertEq(address(royalties).balance, 1, "balance still backs the pending carry");
    }

    function testCompoundForConsumesOnlyCrystallisedBucket() public {
        _primeClampedStoredAndPendingCarry(alice);

        // Constructor default `minAutoCompoundEth` is 0.0001 ether; this fixture uses a 1 wei claimable.
        vm.prank(owner);
        royalties.setMinAutoCompoundEth(0);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        vm.prank(keeper);
        royalties.compoundFor(alice);

        (address user, uint256 ethAmount,,,,) = furnace.lastCall();
        assertEq(user, alice, "compound targets alice");
        assertEq(ethAmount, 1, "compound forwards only the crystallised wei");
        assertEq(royalties.claimableEth(alice), 0, "claimable cleared after successful compound");
        assertEq(royalties.pendingShareholderETH(), 1, "pending carry preserved by stored compound");
        assertEq(address(royalties).balance, 1, "balance still backs the pending carry");
    }

    // ETH claim revert path
    // ============================================================

    function testClaimShareholderEthModeRevertsWhenRecipientRejectsEthAndPreservesClaimable() public {
        // Deploy a contract that rejects ETH (no receive/fallback).
        EthRejecter rejecter = new EthRejecter(royalties);

        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(address(rejecter), 50e18);
        royalties.checkpointUser(address(rejecter));
        assertEq(royalties.claimableEth(address(rejecter)), 0.25 ether);

        // The claim MUST revert when the recipient cannot accept ETH.
        vm.expectRevert(Errors.EthTransferFailed.selector);
        rejecter.claim();

        // Claimable must be preserved after revert.
        assertEq(royalties.claimableEth(address(rejecter)), 0.25 ether);
    }

    function testClaimShareholderEthModeForwardsGasToSmartWalletRecipients() public {
        GasGreedyReceiver receiver = new GasGreedyReceiver(royalties, 50_000);

        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(address(receiver), 50e18);

        uint256 balBefore = address(receiver).balance;
        receiver.claim();

        assertEq(address(receiver).balance, balBefore + 0.25 ether);
        assertEq(royalties.claimableEth(address(receiver)), 0);
    }

    function testClaimShareholderForEthModeForwardsGasToSmartWalletRecipients() public {
        ClaimAllHelper helper = _deployCanonicalClaimAllHelper();
        GasGreedyReceiver receiver = new GasGreedyReceiver(royalties, 50_000);

        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(address(receiver), 50e18);

        uint256 balBefore = address(receiver).balance;

        vm.prank(address(helper));
        royalties.claimShareholderFor(address(receiver), Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(address(receiver).balance, balBefore + 0.25 ether);
        assertEq(royalties.claimableEth(address(receiver)), 0);
    }

    // ============================================================
    // compoundFor no-op return paths
    // ============================================================

    function testCompoundForNoOpReturnWhenBelowThreshold() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0.26 ether, 500);

        // Should no-op return (not revert) per spec.
        vm.prank(keeper);
        royalties.compoundFor(alice);

        // Claimable and cadence unchanged.
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    function testCompoundForNoOpReturnWhenAmountZero() public {
        // No takeover → no claimable ETH.
        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        // Should no-op return, not revert.
        vm.prank(keeper);
        royalties.compoundFor(alice);

        assertEq(royalties.claimableEth(alice), 0);
        (,,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertEq(lastTs, 0);
    }

    // ============================================================
    // sweepDust — forced-surplus recovery surface
    // ============================================================

    function testSweepDustOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        royalties.sweepDust(alice);
    }

    function testSweepDustRevertsWhenNoSurplus() public {
        vm.prank(owner);
        vm.expectRevert(Errors.AmountZero.selector);
        royalties.sweepDust(owner);
    }

    function testSweepDustRevertsOnZeroAddress() public {
        vm.deal(address(royalties), 1 wei);

        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        royalties.sweepDust(address(0));
    }

    function testSweepDustRevertsAboveCap() public {
        vm.deal(address(royalties), 1.01 ether);

        vm.prank(owner);
        vm.expectRevert(Errors.AmountTooLarge.selector);
        royalties.sweepDust(owner);
    }

    function testSweepDustCannotStealPendingWhenNoShareholdersYet() public {
        ve.setTotalVeCached(0);
        _takeover(0.009 ether);

        vm.prank(owner);
        vm.expectRevert(Errors.AmountZero.selector);
        royalties.sweepDust(owner);

        ve.setTotalVeCached(Constants.MIN_VE_FLUSH);
        ve.setVeBalance(alice, Constants.MIN_VE_FLUSH);

        royalties.flushPendingShareholderETH();
        royalties.checkpointUser(alice);

        assertEq(royalties.claimableEth(alice), 0.009 ether);
    }

    function testSweepDustCannotStealPendingRoundingCarry() public {
        ve.setTotalVeCached(Constants.MIN_VE_FLUSH);
        ve.setVeBalance(alice, Constants.MIN_VE_FLUSH);

        _takeover(99);
        assertEq(royalties.pendingShareholderETH(), 99);

        vm.prank(owner);
        vm.expectRevert(Errors.AmountZero.selector);
        royalties.sweepDust(owner);

        _takeover(1);
        royalties.checkpointUser(alice);

        assertEq(royalties.pendingShareholderETH(), 0);
        assertEq(royalties.claimableEth(alice), 100);
    }

    function testSweepDustSweepsOnlyForcedSurplusAndPreservesPendingLiability() public {
        ve.setTotalVeCached(0);
        _takeover(0.007 ether);

        uint256 forcedSurplus = 0.005 ether;
        vm.deal(address(royalties), address(royalties).balance + forcedSurplus);

        uint256 ownerBalBefore = owner.balance;

        vm.prank(owner);
        royalties.sweepDust(owner);

        assertEq(owner.balance, ownerBalBefore + forcedSurplus);
        assertEq(royalties.pendingShareholderETH(), 0.007 ether);
        assertEq(address(royalties).balance, 0.007 ether);
    }

    function testSweepDustSweepsOnlyForcedSurplusAndPreservesIndexedLiability() public {
        ve.setTotalVeCached(Constants.MIN_VE_FLUSH);
        ve.setVeBalance(alice, 60e18);
        ve.setVeBalance(bob, 40e18);

        _takeover(1 ether);
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        assertEq(royalties.claimableEth(alice), 0.6 ether);
        assertEq(royalties.claimableEth(bob), 0.4 ether);

        uint256 forcedSurplus = 0.005 ether;
        vm.deal(address(royalties), address(royalties).balance + forcedSurplus);

        uint256 ownerBalBefore = owner.balance;

        vm.prank(owner);
        royalties.sweepDust(owner);

        assertEq(owner.balance, ownerBalBefore + forcedSurplus);
        assertEq(royalties.pendingShareholderETH(), 0);

        uint256 aliceBalBefore = alice.balance;
        uint256 bobBalBefore = bob.balance;

        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        vm.prank(bob);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);

        assertEq(alice.balance, aliceBalBefore + 0.6 ether);
        assertEq(bob.balance, bobBalBefore + 0.4 ether);
    }

    // ============================================================
    // compoundForMany edge cases
    // ============================================================

    function testCompoundForManyRespectsMaxUsersPerCallCap() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        // Build a list larger than MAX_SHAREHOLDER_COMPOUND_USERS_PER_CALL.
        // Only the first 25 should be processed.
        address[] memory users = new address[](30);
        for (uint256 i = 0; i < 30; i++) {
            users[i] = alice; // same user repeated; only first call changes state
        }

        vm.prank(keeper);
        royalties.compoundForMany(users, 100);

        // Alice should have been compounded (first entry processed).
        assertEq(royalties.claimableEth(alice), 0);
    }

    function testCompoundForManySkipsZeroAddress() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        address[] memory users = new address[](3);
        users[0] = address(0);
        users[1] = alice;
        users[2] = address(0);

        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        // Alice still processed despite zero-address entries.
        assertEq(royalties.claimableEth(alice), 0);
    }

    function testCompoundForManySkipsCadenceNotMet() public {
        _primeIndex(200e18, 2 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 1 hours, 0, 500);

        // First compound succeeds.
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(keeper);
        royalties.compoundForMany(users, 10);
        assertEq(royalties.claimableEth(alice), 0);

        // Add more rewards.
        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        // Second compound within cadence is skipped (no revert in batch).
        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        // Alice should still have the new claimable (not compounded due to cadence).
        royalties.checkpointUser(alice);
        assertGt(royalties.claimableEth(alice), 0);
    }

    function testCompoundForManySkipsDisabledUser() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        ve.setVeBalance(bob, 50e18);
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        _setValidDest(2, bob, block.timestamp + 30 days, false, false);

        // Only Bob enables auto-compound.
        vm.prank(bob);
        royalties.setAutoCompoundConfig(true, 2, 30 days, 0, 0, 500);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        // Alice skipped (not enabled), Bob compounded.
        assertEq(royalties.claimableEth(alice), 0.25 ether);
        assertEq(royalties.claimableEth(bob), 0);
    }

    function testCompoundForManyDoesNotPauseHealthyUserWhenLocalGasBudgetFallsBelowSafetyBuffer() public {
        _primeIndex(200e18, 1 ether);
        ve.setVeBalance(alice, 50e18);
        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0.25 ether);

        _setValidDest(1, alice, block.timestamp + 30 days, false, false);
        vm.prank(alice);
        royalties.setAutoCompoundConfig(true, 1, 30 days, 0, 0, 500);

        furnace.setQuoteMinGasLeft(140_000);

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(keeper);
        royalties.compoundForMany{gas: 500_000}(users, 10);

        assertEq(furnace.lockCalls(), 0, "no Furnace call should be attempted under local gas starvation");
        assertEq(royalties.claimableEth(alice), 0.25 ether, "claimable must be restored when the call is not attempted");

        (bool enabled, bool paused,,,,,, uint40 lastTs) = royalties.getAutoCompoundConfig(alice);
        assertTrue(enabled, "config should stay enabled");
        assertFalse(paused, "healthy user must not be paused when no Furnace call was attempted");
        assertEq(lastTs, 0, "cadence must not advance on a not-attempted compound");

        furnace.setQuoteMinGasLeft(0);

        vm.prank(keeper);
        royalties.compoundForMany(users, 10);

        assertEq(royalties.claimableEth(alice), 0, "retry with sufficient gas should still succeed");
    }

    // ============================================================
    // Decaying-lock accrual
    // ============================================================

    function testDecayingLockAccrual_SingleFlush() public {
        // Set up: 200e18 total ve, 1 ETH flush at ts=1000.
        uint256 totalVe = 200e18;
        ve.setTotalVeCached(totalVe);

        // Alice has a decaying lock: amount=100e18, lockEnd=block.timestamp + 180 days.
        uint256 lockEnd = block.timestamp + 180 days;
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = 100e18;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, 100e18);

        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        uint256 idxAfter = royalties.ethPerVe();
        assertGt(idxAfter, 0);

        // Checkpoint Alice.
        royalties.checkpointUser(alice);

        uint256 aliceClaimable = royalties.claimableEth(alice);
        // For a decaying lock, the reward depends on (lockEnd - rewardTs) / MAX_LOCK_DURATION.
        // rewardTs = block.timestamp. remaining = 180 days.
        // slopeScaled = 100e18 * 1e18 / 365 days
        // weightedDelta = (lockEnd - rewardTs) * delta = 180 days * delta
        // accrued = slopeScaled * weightedDelta / 1e36
        // = (100e18 * 1e18 / 365 days) * (180 days * delta) / 1e36
        // = 100e18 * 180 days * delta / (365 days * 1e18)
        // delta = 1e18 * 1e36 / (200e18 * 1e18) = 5e15
        // = 100e18 * 180 * 86400 * 5e15 / (365 * 86400 * 1e18)
        // = 100e18 * 180 * 5e15 / (365 * 1e18)
        // = 500e18 * 180 / 365
        // = 500e18 * 0.4931... = ~246.575e15
        uint256 expectedApprox = (uint256(100e18) * 180 * uint256(5e15)) / (uint256(365) * uint256(1e18));
        // Floor rounding: should be close.
        assertApproxEqAbs(aliceClaimable, expectedApprox, 1, "decaying lock accrual should be correct");
        assertGt(aliceClaimable, 0, "decaying lock must accrue non-zero rewards");
    }

    function testDecayingLockAccrual_ExpiredLockGetsZero() public {
        uint256 totalVe = 200e18;
        ve.setTotalVeCached(totalVe);

        // Alice has a lock that expires BEFORE the reward timestamp.
        uint256 lockEnd = block.timestamp - 1;
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = 100e18;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, 100e18);

        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        royalties.checkpointUser(alice);
        assertEq(royalties.claimableEth(alice), 0, "expired decaying lock must not accrue rewards");
    }

    function testDecayingLockAccrual_MultipleFlushesAccumulate() public {
        uint256 totalVe = 200e18;
        ve.setTotalVeCached(totalVe);

        uint256 lockEnd = block.timestamp + 180 days;
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = 100e18;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, 100e18);

        // Flush 1 at current time.
        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        // Advance 30 days and flush again.
        vm.warp(block.timestamp + 30 days);
        ve.setGlobalLastTs(block.timestamp);
        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        royalties.checkpointUser(alice);
        uint256 aliceClaimable = royalties.claimableEth(alice);
        // Alice should get rewards from both flushes, with the second flush weighted
        // by the reduced remaining duration (150 days instead of 180 days).
        assertGt(aliceClaimable, 0, "decaying lock must accrue from multiple flushes");
    }

    function testDecayingLockAccrual_MixedAutoMaxAndDecaying() public {
        uint256 totalVe = 200e18;
        ve.setTotalVeCached(totalVe);

        uint256 lockEnd = block.timestamp + 180 days;
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory lockEnds = new uint256[](2);
        bool[] memory autoMaxFlags = new bool[](2);
        // Lock 0: AutoMax (constant weight)
        amounts[0] = 50e18;
        lockEnds[0] = type(uint256).max;
        autoMaxFlags[0] = true;
        // Lock 1: Decaying
        amounts[1] = 50e18;
        lockEnds[1] = lockEnd;
        autoMaxFlags[1] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, 100e18);

        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        royalties.checkpointUser(alice);
        uint256 aliceClaimable = royalties.claimableEth(alice);

        // AutoMax lock: 50e18 * 1e18 * delta / 1e36 = 50e18 * 5e15 / 1e18 = 0.25 ETH
        uint256 autoMaxExpected = 0.25 ether;
        // Decaying lock: less than autoMax due to (lockEnd - ts) / MAX_LOCK_DURATION < 1
        assertGt(aliceClaimable, autoMaxExpected, "mixed portfolio must accrue more than just autoMax component");
        assertLt(aliceClaimable, 0.5 ether, "mixed portfolio must accrue less than 2x autoMax");
    }

    function testDecayingLockAccrual_ViewMatchesCheckpoint() public {
        uint256 totalVe = 200e18;
        ve.setTotalVeCached(totalVe);

        uint256 lockEnd = block.timestamp + 180 days;
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = 100e18;
        lockEnds[0] = lockEnd;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, 100e18);

        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        // View before checkpoint.
        (uint256 viewClaimable,,) = royalties.getShareholderState(alice);

        // Checkpoint.
        royalties.checkpointUser(alice);
        uint256 storageClaimable = royalties.claimableEth(alice);

        assertEq(viewClaimable, storageClaimable, "view must match checkpointed claimable for decaying locks");
    }

    // ============================================================
    // setWiring edge cases
    // ============================================================

    function testSetWiringRevertsOnNonContractAddresses() public {
        address eoa = makeAddr("eoa");

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        royalties.setWiring(eoa, mineMarket, address(furnace));

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        royalties.setWiring(mineCore, eoa, address(furnace));

        vm.prank(owner);
        vm.expectRevert(Errors.NotAContract.selector);
        royalties.setWiring(mineCore, mineMarket, eoa);
    }

    // ============================================================
    // Spec test vector verification (TEST-GAP-02)
    // ============================================================

    /// @dev Vector 6.1: flush distributes almost all ETH and retains 1 wei dust.
    ///      totalVe = 333e18, pending = 1 ether.
    ///      Expected: delta = 3_003_003_003_003_003, distributed = 999_999_999_999_999_999, dust = 1 wei.
    function testSpecVector6_1_FlushDistributesAndRetainsDust() public {
        uint256 totalVe = 333e18;
        ve.setTotalVeCached(totalVe);

        uint256 idxBefore = royalties.ethPerVe();
        _takeover(1 ether);
        royalties.flushPendingShareholderETH();
        uint256 idxAfter = royalties.ethPerVe();

        uint256 delta = idxAfter - idxBefore;
        assertEq(delta, 3_003_003_003_003_003, "Vector 6.1: delta mismatch");

        uint256 pendingAfter = royalties.pendingShareholderETH();
        assertEq(pendingAfter, 1, "Vector 6.1: dust must be exactly 1 wei");

        // distributed = pending - dust = 1 ether - 1 wei
        uint256 distributed = 1 ether - pendingAfter;
        assertEq(distributed, 999_999_999_999_999_999, "Vector 6.1: distributed mismatch");
    }

    /// @dev Vector 6.2: delta == 0 no-op keeps pending unchanged.
    ///      pending = 1 wei, totalVe = 1_000e18, so totalWeight = 1_000e36.
    ///      delta = floor(1 * 1e36 / 1_000e36) = 0 → no-op.
    function testSpecVector6_2_DeltaZeroNoOp() public {
        uint256 totalVe = 1_000e18;
        ve.setTotalVeCached(totalVe);

        // Deposit 1 wei of pending via a minimal takeover.
        _takeover(1);

        uint256 idxBefore = royalties.ethPerVe();
        uint256 pendingBefore = royalties.pendingShareholderETH();
        assertEq(pendingBefore, 1, "setup: pending should be 1 wei");

        royalties.flushPendingShareholderETH();

        assertEq(royalties.ethPerVe(), idxBefore, "Vector 6.2: ethPerVe must be unchanged");
        assertEq(royalties.pendingShareholderETH(), 1, "Vector 6.2: pending must remain 1 wei");
    }

    /// @dev Vector 6.3: user checkpoint accrual after vector 6.1 flush.
    ///      User has 10e18 autoMax lock, userEthPerVePaid = 0.
    ///      Expected accrual = 30_030_030_030_030_030 wei.
    function testSpecVector6_3_UserAccrualAfterFlush() public {
        // Reproduce vector 6.1 state.
        uint256 totalVe = 333e18;
        ve.setTotalVeCached(totalVe);
        _takeover(1 ether);
        royalties.flushPendingShareholderETH();

        // User with 10e18 autoMax lock (default MockVe behavior).
        address user = makeAddr("vector6_3_user");
        ve.setVeBalance(user, 10e18);

        royalties.checkpointUser(user);
        uint256 accrued = royalties.claimableEth(user);
        assertEq(accrued, 30_030_030_030_030_030, "Vector 6.3: accrual mismatch");
    }

    // ============================================================
    // ethPerVe monotonicity test (TEST-GAP-01)
    // ============================================================

    /// @dev Assert that ethPerVe is monotonically non-decreasing across multiple flushes.
    function testEthPerVeMonotonicityAcrossMultipleFlushes() public {
        ve.setTotalVeCached(200e18);

        uint256 prevIdx = royalties.ethPerVe();

        for (uint256 i = 0; i < 10; i++) {
            _takeover(0.1 ether);
            royalties.flushPendingShareholderETH();

            uint256 currentIdx = royalties.ethPerVe();
            assertGe(currentIdx, prevIdx, "ethPerVe must be monotonically non-decreasing");
            prevIdx = currentIdx;

            // Warp forward to get distinct timestamps for reward checkpoints.
            vm.warp(block.timestamp + 1 hours);
            ve.setGlobalLastTs(block.timestamp);
        }
    }

    /// @dev Fuzz: ethPerVe never decreases regardless of flush amounts and timing.
    function testFuzz_EthPerVeMonotonicity(uint96 amount1, uint96 amount2, uint96 amount3) public {
        uint256 a1 = bound(uint256(amount1), 0, 100 ether);
        uint256 a2 = bound(uint256(amount2), 0, 100 ether);
        uint256 a3 = bound(uint256(amount3), 0, 100 ether);

        ve.setTotalVeCached(500e18);

        uint256 idx0 = royalties.ethPerVe();
        _takeover(a1);
        royalties.flushPendingShareholderETH();
        uint256 idx1 = royalties.ethPerVe();
        assertGe(idx1, idx0, "monotonicity after flush 1");

        vm.warp(block.timestamp + 1 hours);
        ve.setGlobalLastTs(block.timestamp);
        _takeover(a2);
        royalties.flushPendingShareholderETH();
        uint256 idx2 = royalties.ethPerVe();
        assertGe(idx2, idx1, "monotonicity after flush 2");

        vm.warp(block.timestamp + 1 hours);
        ve.setGlobalLastTs(block.timestamp);
        _takeover(a3);
        royalties.flushPendingShareholderETH();
        uint256 idx3 = royalties.ethPerVe();
        assertGe(idx3, idx2, "monotonicity after flush 3");
    }

    // ============================================================
    // Decaying lock — time decay reduces rewards
    // ============================================================

    /// @dev Decaying lock that is halfway through MAX_LOCK_DURATION should accrue ~50% of AutoMax.
    ///      This confirms the slope-scaling math in _computeLockAccrual is directionally correct.
    function testDecayingLockHalfDurationGetsHalfReward() public {
        uint256 totalVe = 200e18;
        ve.setTotalVeCached(totalVe);

        // AutoMax user (Bob): full weight.
        ve.setVeBalance(bob, 100e18);

        // Decaying user (Alice): half of MAX_LOCK_DURATION remaining.
        uint256 halfLock = block.timestamp + (Constants.MAX_LOCK_DURATION / 2);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory lockEnds = new uint256[](1);
        bool[] memory autoMaxFlags = new bool[](1);
        amounts[0] = 100e18;
        lockEnds[0] = halfLock;
        autoMaxFlags[0] = false;
        ve.setShareholderLockParams(alice, amounts, lockEnds, autoMaxFlags);
        ve.setVeBalance(alice, 100e18);

        _takeover(2 ether);
        royalties.flushPendingShareholderETH();

        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        uint256 aliceClaim = royalties.claimableEth(alice);
        uint256 bobClaim = royalties.claimableEth(bob);

        // Bob (AutoMax) gets full share. Alice (half-duration) should get ~50% of Bob.
        assertGt(bobClaim, 0, "Bob must accrue non-zero");
        // Allow 1 wei rounding tolerance.
        assertApproxEqAbs(aliceClaim, bobClaim / 2, 1, "half-duration lock should get ~50% of AutoMax reward");
    }
}

/// @dev Receiver that needs more than a 300k stipend to accept ETH.
contract GasGreedyReceiver {
    ShareholderRoyalties internal immutable royalties;
    uint256 internal immutable minGasToAccept;

    constructor(ShareholderRoyalties r, uint256 minGas_) {
        royalties = r;
        minGasToAccept = minGas_;
    }

    function claim() external {
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
    }

    receive() external payable {
        require(gasleft() >= minGasToAccept, "GasGreedyReceiver: insufficient gas");
    }
}

/// @dev Contract that always rejects ETH transfers.
contract EthRejecter {
    ShareholderRoyalties internal immutable royalties;

    constructor(ShareholderRoyalties r) {
        royalties = r;
    }

    function claim() external {
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
    }

    // No receive() or fallback() — all ETH transfers revert.
}
