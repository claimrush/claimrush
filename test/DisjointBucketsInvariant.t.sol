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

/// @notice Positive coverage for the disjoint-buckets / debt-accounting invariants
///         maintained by ShareholderRoyalties and LpStakingVault7D. Every external
///         entry boundary along the value-flow paths is asserted, ensuring the
///         invariant holds after each transition rather than only at terminal states.
///
///         ShareholderRoyalties disjoint-buckets invariant:
///           Σ _claimableEthStored(user) + indexedEthOwed + pendingShareholderETH
///             == address(this).balance
///         AND  totalCrystallisedStored == Σ _claimableEthStored(user)
///
///         LpStakingVault7D debt-accounting invariant:
///           totalRewardsCredited <= indexedClaimOwed
///           Σ rewards(user) == totalRewardsCredited
///           indexedClaimOwed + queuedRewards <= claim.balanceOf(vault)
contract DisjointBucketsInvariantTest is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
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

    // ─────────────────────────────────────────────────────────────────────
    // ShareholderRoyalties: disjoint-buckets after every transition
    // ─────────────────────────────────────────────────────────────────────

    function test_shareholderDisjointBucketsAcrossFullValueFlow() public {
        _deployShareholderSurface();
        ve.setTotalVeCached(1_000_000e18);
        ve.setVeBalance(alice, 400_000e18);
        ve.setVeBalance(bob, 400_000e18);
        ve.setVeBalance(carol, 200_000e18);

        _assertShareholderDisjoint("initial empty state");

        // Step 1: takeover credits pendingShareholderETH AND auto-flushes; the
        //         post-state must satisfy the invariant.
        _takeover(7 ether);
        _assertShareholderDisjoint("after takeover #1");

        // Step 2: a manual flush is a no-op when pending was already drained.
        royalties.flushPendingShareholderETH();
        _assertShareholderDisjoint("after manual flush (no-op)");

        // Step 3: each per-user checkpoint debits indexed and credits crystallised
        //         in lockstep.
        royalties.checkpointUser(alice);
        _assertShareholderDisjoint("after alice checkpoint");
        royalties.checkpointUser(bob);
        _assertShareholderDisjoint("after bob checkpoint");
        royalties.checkpointUser(carol);
        _assertShareholderDisjoint("after carol checkpoint");

        // Step 4: alice claims; crystallised drops by alice's stored amount.
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        _assertShareholderDisjoint("after alice claim");

        // Step 5: a second takeover refills pending + auto-flushes.
        _takeover(3 ether);
        _assertShareholderDisjoint("after takeover #2");

        // Step 6: bob and carol checkpoint against the larger ethPerVe.
        royalties.checkpointUser(bob);
        _assertShareholderDisjoint("after bob re-checkpoint");
        royalties.checkpointUser(carol);
        _assertShareholderDisjoint("after carol re-checkpoint");

        // Step 7: bob claims.
        vm.prank(bob);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        _assertShareholderDisjoint("after bob claim");

        // Step 8: carol claims.
        vm.prank(carol);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        _assertShareholderDisjoint("after carol claim");

        // Step 9: alice re-checkpoints and re-claims (against takeover #2 share).
        royalties.checkpointUser(alice);
        _assertShareholderDisjoint("after alice re-checkpoint");
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        _assertShareholderDisjoint("after alice second claim");
    }

    function test_shareholderDisjointBucketsUnderSubResolutionFlushes() public {
        // Smallest-denominator stress: at totalVe = 3 with two 1-wei takeovers, the
        // first auto-flush distributes 0 wei, the second distributes 1 wei. Every
        // step must satisfy the invariant.
        _deployShareholderSurface();
        ve.setTotalVeCached(3);
        ve.setVeBalance(alice, 3);

        _takeover(1);
        _assertShareholderDisjoint("after takeover #1 (1 wei)");

        _takeover(1);
        _assertShareholderDisjoint("after takeover #2 (1 wei)");

        royalties.checkpointUser(alice);
        _assertShareholderDisjoint("after alice checkpoint (clamped credit)");

        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        _assertShareholderDisjoint("after alice claim (pending carry preserved)");
    }

    function test_shareholderTotalCrystallisedMatchesPerUserSum() public {
        _deployShareholderSurface();
        ve.setTotalVeCached(1_000_000e18);
        ve.setVeBalance(alice, 200_000e18);
        ve.setVeBalance(bob, 300_000e18);
        ve.setVeBalance(carol, 500_000e18);

        _takeover(10 ether);
        royalties.checkpointUser(alice);
        royalties.checkpointUser(bob);
        royalties.checkpointUser(carol);

        uint256 perUserSum = royalties.claimableEthStored(alice) + royalties.claimableEthStored(bob)
            + royalties.claimableEthStored(carol);
        assertEq(
            royalties.totalCrystallisedStoredForTest(),
            perUserSum,
            unicode"totalCrystallisedStored aggregator must equal Σ _claimableEthStored"
        );

        // After alice claims, the aggregator drops by alice's stored amount.
        uint256 aliceStored = royalties.claimableEthStored(alice);
        vm.prank(alice);
        royalties.claimShareholder(Constants.SHAREHOLDER_MODE_ETH, 0, 0, false, 0);
        assertEq(
            royalties.totalCrystallisedStoredForTest(),
            perUserSum - aliceStored,
            "aggregator must shrink by alice's stored amount on claim"
        );

        uint256 perUserSumPostAlice = royalties.claimableEthStored(alice) + royalties.claimableEthStored(bob)
            + royalties.claimableEthStored(carol);
        assertEq(
            royalties.totalCrystallisedStoredForTest(),
            perUserSumPostAlice,
            unicode"aggregator must continue to equal Σ stored after the claim"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // LpStakingVault7D: debt-accounting invariant after every transition
    // ─────────────────────────────────────────────────────────────────────

    function test_lpDebtAccountingAcrossFullValueFlow() public {
        _deployLpSurface();
        _assertLpDebtAccounting("initial empty state");

        _stake(alice, 1e18);
        _assertLpDebtAccounting("after alice stake");

        _stake(bob, 2e18);
        _assertLpDebtAccounting("after bob stake");

        _fundLpRewards(300e18);
        _assertLpDebtAccounting("after first reward funding");

        vm.prank(alice);
        vault.claimRewards();
        _assertLpDebtAccounting("after alice claimRewards");

        // Sub-resolution carry forward: 1 wei reward against 3e18 stake yields
        // floor-zero indexedAmount → the wei carries to queuedRewards rather
        // than over-crediting the index.
        _fundLpRewards(1);
        _assertLpDebtAccounting("after sub-resolution dust reward");

        vm.prank(bob);
        vault.claimRewards();
        _assertLpDebtAccounting("after bob claimRewards");

        // A new staker absorbs the queuedRewards on their first stake change.
        _stake(carol, 4e18);
        _assertLpDebtAccounting("after carol stake (queuedRewards drain)");

        _fundLpRewards(700e18);
        _assertLpDebtAccounting("after second reward funding");

        vm.prank(carol);
        vault.claimRewards();
        _assertLpDebtAccounting("after carol claimRewards");

        vm.prank(alice);
        vault.claimRewards();
        _assertLpDebtAccounting("after alice second claimRewards");
    }

    function test_lpDebtAccountingUnderManySubResolutionNotifies() public {
        _deployLpSurface();

        // With staked >> ACC, a 1-wei reward yields rptIncrement == 0 and the wei
        // is carried to `queuedRewards` instead of being indexed. The debt-accounting
        // invariant must hold across every dust notify and the eventual drain.
        _stake(alice, 1e30);
        _assertLpDebtAccounting("after alice large stake");

        for (uint256 i = 0; i < 32; i++) {
            _fundLpRewards(1);
            _assertLpDebtAccounting("after sub-resolution notify");
        }

        // After 32 dust notifies, no rpt bumps occurred, no per-user accrual was
        // credited, and the wei carries sit in `queuedRewards` waiting for a
        // notify large enough to index cleanly.
        assertEq(vault.indexedClaimOwed(), 0, "no rpt bumps allowed for dust-only notifies");
        assertEq(vault.totalRewardsCredited(), 0, "no per-user accrual without indexed pool");
        assertEq(vault.queuedRewards(), 32, "all 32 dust wei sit in queuedRewards");

        // A clean-resolution reward (multiple of staked / ACC = 1e12) absorbs the
        // queued carry alongside the new amount with zero residual dust.
        _fundLpRewards(1e12 - 32);
        _assertLpDebtAccounting("after carry-draining notify");
        assertEq(vault.queuedRewards(), 0, "queued carry fully ingested at the resolution boundary");
        assertEq(vault.indexedClaimOwed(), 1e12, "indexed pool grew by the full combined amount");
    }

    function test_lpTotalRewardsCreditedMatchesPerUserSum() public {
        _deployLpSurface();
        _stake(alice, 1e18);
        _stake(bob, 2e18);
        _fundLpRewards(300e18);

        // Materialise per-user `rewards[user]` via a stake extension, which routes
        // through `_updateReward` before any payout — the per-user delta is
        // tracked into `totalRewardsCredited`.
        _stake(alice, 1e18);
        uint256 aliceRewards = vault.rewards(alice);
        _stake(bob, 1e18);
        uint256 bobRewards = vault.rewards(bob);

        assertEq(
            vault.totalRewardsCredited(),
            aliceRewards + bobRewards,
            unicode"totalRewardsCredited must equal Σ rewards[user]"
        );

        vm.prank(alice);
        vault.claimRewards();
        assertEq(vault.totalRewardsCredited(), bobRewards, "aggregator must shrink by alice's rewards on claim");
        assertEq(
            vault.totalRewardsCredited(),
            vault.rewards(alice) + vault.rewards(bob),
            unicode"aggregator must continue to equal Σ rewards[user] after claim"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    function _assertShareholderDisjoint(string memory label) internal view {
        uint256 perUserSum = royalties.claimableEthStored(alice) + royalties.claimableEthStored(bob)
            + royalties.claimableEthStored(carol);
        uint256 indexedBucket = royalties.indexedEthOwedForTest();
        uint256 pending = royalties.pendingShareholderETH();
        uint256 crystallised = royalties.totalCrystallisedStoredForTest();
        assertEq(crystallised, perUserSum, string.concat(label, unicode": totalCrystallisedStored == Σ stored"));
        assertEq(
            address(royalties).balance,
            crystallised + indexedBucket + pending,
            string.concat(label, ": disjoint-buckets invariant must hold")
        );
    }

    function _assertLpDebtAccounting(string memory label) internal view {
        uint256 indexedPool = vault.indexedClaimOwed();
        uint256 credited = vault.totalRewardsCredited();
        uint256 queued = vault.queuedRewards();
        uint256 vaultClaim = claim.balanceOf(address(vault));
        uint256 perUserSum = vault.rewards(alice) + vault.rewards(bob) + vault.rewards(carol);
        assertEq(perUserSum, credited, string.concat(label, unicode": Σ rewards[user] == totalRewardsCredited"));
        assertLe(credited, indexedPool, string.concat(label, ": totalRewardsCredited <= indexedClaimOwed"));
        assertLe(indexedPool + queued, vaultClaim, string.concat(label, ": indexed + queued <= vault CLAIM custody"));
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
}
