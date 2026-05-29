// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Constants} from "src/lib/Constants.sol";
import {LpStakingVault7D} from "src/vault/LpStakingVault7D.sol";

import {MockAerodromePool} from "./mocks/MockAerodromePool.sol";
import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockContract} from "./mocks/MockContract.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFurnaceLpRewards} from "./mocks/MockFurnaceLpRewards.sol";
import {MockVe} from "./mocks/MockVe.sol";
import {ShareholderRoyaltiesHarness} from "./mocks/ShareholderRoyaltiesHarness.sol";

/// @notice Exact liability replays for the two reward indexes that custody user value.
contract RewardLiabilityExactTest is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mineCore;
    address internal mineMarket;
    address internal furnaceAddr;
    address internal claimToken;

    ShareholderRoyaltiesHarness internal royalties;
    MockVe internal ve;

    MockAerodromePool internal lp;
    MockERC20 internal weth;
    MockERC20 internal claim;
    MockFurnaceLpRewards internal furnace;
    MockAerodromeRouter internal router;
    LpStakingVault7D internal vault;

    function test_shareholderExactBooksEqualCustodyThroughClaims() public {
        _deployShareholderSurface();
        ve.setTotalVeCached(1_000_000e18);
        ve.setVeBalance(alice, 400_000e18);
        ve.setVeBalance(bob, 600_000e18);

        _takeover(10 ether);
        royalties.flushPendingShareholderETH();
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);

        uint256 aliceClaim = royalties.claimableEthStored(alice);
        uint256 bobClaim = royalties.claimableEthStored(bob);
        uint256 pending = royalties.pendingShareholderETH();
        uint256 indexedOwed = royalties.indexedEthOwedForTest();
        uint256 crystallised = royalties.totalCrystallisedStoredForTest();

        // Disjoint-buckets invariant: balance == pending + indexed + crystallised
        assertEq(
            address(royalties).balance, pending + indexedOwed + crystallised, "disjoint-buckets invariant must hold"
        );
        assertEq(crystallised, aliceClaim + bobClaim, unicode"totalCrystallisedStored aggregator equals Σ stored");
        assertEq(aliceClaim, 4 ether, "alice pro-rata liability");
        assertEq(bobClaim, 6 ether, "bob pro-rata liability");
        assertEq(indexedOwed, 0, "checkpointing fully drains indexed bucket on exact-ratio splits");

        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(alice.balance - aliceEthBefore, aliceClaim, "alice payout must equal stored liability");
        assertEq(
            address(royalties).balance,
            royalties.pendingShareholderETH() + royalties.indexedEthOwedForTest()
                + royalties.totalCrystallisedStoredForTest(),
            "disjoint-buckets invariant must stay exact after alice claim"
        );
        assertEq(royalties.totalCrystallisedStoredForTest(), bobClaim, "alice's crystallised stored consumed");

        uint256 bobEthBefore = bob.balance;
        vm.prank(bob);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(bob.balance - bobEthBefore, bobClaim, "bob payout must equal stored liability");
        assertEq(address(royalties).balance, 0, "vault drained after both claims");
        assertEq(royalties.indexedEthOwedForTest(), 0, "indexed liability cleared");
        assertEq(royalties.totalCrystallisedStoredForTest(), 0, "crystallised aggregator cleared");
    }

    function test_shareholderClampedCheckpointDoesNotOverCreditIndexedBucket() public {
        _deployShareholderSurface();
        ve.setTotalVeCached(3);
        ve.setVeBalance(alice, 3);

        // Two sub-resolution takeovers. The first auto-flush distributes 0 wei to the
        // indexed bucket (mulDiv floor); the second distributes 1 wei. The second wei
        // remains in pending as a flush carry.
        _takeover(1);
        _takeover(1);
        royalties.checkpointUser(alice);

        // Disjoint-buckets invariant: the per-user combined-floor is clamped at credit
        // time, so alice's stored credit cannot exceed the indexed pool that backed it.
        // The remaining 1 wei stays in pendingShareholderETH until a later flush can
        // index it cleanly (or sweepDust returns it after the timeout).
        assertEq(address(royalties).balance, 2, "two wei deposited");
        assertEq(royalties.claimableEthStored(alice), 1, "credit clamped to indexed-bucket headroom");
        assertEq(royalties.indexedEthOwedForTest(), 0, "indexed bucket fully drained by clamped checkpoint");
        assertEq(royalties.pendingShareholderETH(), 1, "one wei remains as un-flushed pending carry");
        assertEq(
            royalties.totalCrystallisedStoredForTest(), 1, unicode"totalCrystallisedStored aggregator equals Σ stored"
        );
        assertEq(
            address(royalties).balance,
            royalties.pendingShareholderETH() + royalties.indexedEthOwedForTest()
                + royalties.totalCrystallisedStoredForTest(),
            "disjoint-buckets invariant"
        );

        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        // The stored-claim path consumes only the crystallised bucket; pending is
        // untouched (cross-bucket dipping was an earlier debit-at-consume pattern).
        assertEq(address(royalties).balance, 1, "claim consumes only the crystallised wei");
        assertEq(royalties.pendingShareholderETH(), 1, "pending carry not touched by stored claim");
        assertEq(royalties.indexedEthOwedForTest(), 0, "indexed liability still zero");
        assertEq(royalties.totalCrystallisedStoredForTest(), 0, "alice's crystallised stored consumed");
    }

    function test_lpExactBooksEqualCustodyThroughClaimAndCarry() public {
        _deployLpSurface();
        _stake(alice, 1e18);
        _stake(bob, 2e18);
        _fundLpRewards(300e18);

        assertEq(vault.earned(alice), 100e18, "alice pro-rata liability");
        assertEq(vault.earned(bob), 200e18, "bob pro-rata liability");
        assertEq(vault.queuedRewards(), 0, "no exact-ratio carry");
        _assertLpBooksExact("initial exact reward distribution");

        vm.prank(alice);
        vault.claimRewards();
        assertEq(claim.balanceOf(alice), 100e18, "alice payout");
        assertEq(vault.earned(alice), 0, "alice liability cleared");
        assertEq(vault.earned(bob), 200e18, "bob liability remains");
        _assertLpBooksExact("after alice claim");

        _fundLpRewards(1);
        assertEq(vault.queuedRewards(), 1, "sub-resolution wei carried");
        assertEq(vault.earned(bob), 200e18, "dust carry must not over-credit bob");
        _assertLpBooksExact("after dust carry");

        vm.prank(bob);
        vault.claimRewards();
        assertEq(claim.balanceOf(bob), 200e18, "bob payout");
        assertEq(vault.earned(bob), 0, "bob liability cleared");
        _assertLpBooksExact("after bob claim");
    }

    function _deployShareholderSurface() internal {
        ve = new MockVe();
        furnaceAddr = address(new MockContract());
        mineCore = address(new MockContract());
        mineMarket = address(new MockContract());
        claimToken = address(new MockContract());
        royalties = new ShareholderRoyaltiesHarness(address(ve), owner);

        vm.mockCall(mineCore, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineCore, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineCore, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(mineCore, abi.encodeWithSignature("furnace()"), abi.encode(furnaceAddr));
        vm.mockCall(mineMarket, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(mineMarket, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(mineMarket, abi.encodeWithSignature("royalties()"), abi.encode(address(royalties)));
        vm.mockCall(furnaceAddr, abi.encodeWithSignature("ve()"), abi.encode(address(ve)));
        vm.mockCall(furnaceAddr, abi.encodeWithSignature("claim()"), abi.encode(claimToken));
        vm.mockCall(furnaceAddr, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));
        vm.mockCall(furnaceAddr, abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(furnaceAddr, abi.encodeWithSignature("shareholderRoyalties()"), abi.encode(address(royalties)));
        vm.mockCall(address(ve), abi.encodeWithSignature("furnace()"), abi.encode(furnaceAddr));
        vm.mockCall(address(ve), abi.encodeWithSignature("mineMarket()"), abi.encode(mineMarket));
        vm.mockCall(address(ve), abi.encodeWithSignature("claimToken()"), abi.encode(claimToken));
        vm.mockCall(claimToken, abi.encodeWithSignature("mineCore()"), abi.encode(mineCore));

        vm.prank(owner);
        royalties.setWiring(mineCore, mineMarket, furnaceAddr);
    }

    function _takeover(uint256 amountEth) internal {
        vm.deal(mineCore, amountEth);
        vm.prank(mineCore);
        royalties.onTakeover{value: amountEth}(1);
    }

    function _deployLpSurface() internal {
        weth = new MockERC20("WETH", "WETH");
        claim = new MockERC20("CLAIM", "CLAIM");
        lp = new MockAerodromePool(address(weth), address(claim));
        ve = new MockVe();
        router = new MockAerodromeRouter(address(0xFACA), address(weth));
        router.setPoolFor(address(weth), address(claim), false, address(0xFACA), address(lp));
        furnace = new MockFurnaceLpRewards(address(claim), address(ve));
        vault = new LpStakingVault7D(
            address(lp),
            address(weth),
            address(claim),
            address(ve),
            address(furnace),
            address(router),
            address(0xFACA),
            false,
            address(this)
        );
    }

    function _stake(address user, uint256 amount) internal {
        lp.mint(user, amount);
        vm.startPrank(user);
        lp.approve(address(vault), amount);
        vault.stake(amount);
        vm.stopPrank();
    }

    function _fundLpRewards(uint256 amount) internal {
        claim.mint(address(vault), amount);
        vm.prank(address(furnace));
        vault.notifyRewards(amount);
    }

    function _assertLpBooksExact(string memory label) internal view {
        uint256 knownLiability = vault.earned(alice) + vault.earned(bob) + vault.queuedRewards();
        assertEq(claim.balanceOf(address(vault)), vault.accountedRewardBalance(), label);
        assertEq(vault.accountedRewardBalance(), knownLiability, label);
        assertGe(lp.balanceOf(address(vault)), vault.totalStaked(), label);
    }
}
