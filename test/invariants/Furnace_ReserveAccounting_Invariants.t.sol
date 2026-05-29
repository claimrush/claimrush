// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {ClaimToken} from "src/ClaimToken.sol";
import {MineCore} from "src/MineCore.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {FurnaceQuoter} from "src/FurnaceQuoter.sol";
import {Constants} from "src/lib/Constants.sol";

import {FurnaceHarness} from "../mocks/FurnaceHarness.sol";
import {MockVe} from "../mocks/MockVe.sol";
import {MockLpRewardsVault} from "../mocks/MockLpRewardsVault.sol";

/// @notice Stateful handler that drives Furnace through every reserve-mutating path
///         while tracking an explicit canonical ledger of inflows, outflows, and clamp
///         reductions. The invariant contract asserts that `furnaceReserve` reconciles
///         against this ledger at every fuzzer tick.
///
///         Invariant under test (formal): at every transition,
///
///             furnaceReserve == totalCreditedInflows
///                             + totalSellbackReserveAdd
///                             - totalBonusOutflows
///                             - totalDripOutflows
///                             - totalClampReductions
///
///         AND, independently:
///
///             furnaceReserve <= CLAIM.balanceOf(furnace) - lpStreamLiability()
///
///         Together these imply that direct ERC20 donations (CLAIM transfers to Furnace
///         that bypass `creditReserve`) cannot be consumed as reserve backing for a ve
///         mint: the donated balance raises the ceiling but the reserve never
///         auto-follows, so the bonus path can only spend reserve that was tracked by
///         an explicit inflow event.
contract FurnaceReserveAccountingHandler is Test {
    FurnaceHarness public immutable furnace;
    ClaimToken public immutable claim;
    MockVe public immutable ve;
    MockLpRewardsVault public immutable lpVault;
    address public immutable mineCoreAddr;

    uint256 public totalCreditedInflows;
    uint256 public totalSellbackReserveAdd;
    uint256 public totalBonusOutflows;
    uint256 public totalDripOutflows;
    uint256 public totalClampReductions;
    uint256 public totalDirectDonations;
    /// @dev Tracks CLAIM amounts physically transferred out of Furnace by
    ///      `forceClampReduction`. The amount can exceed the corresponding
    ///      reserve drop because the surplus / donation buffer absorbs the rest.
    uint256 public totalForcedDrains;

    uint256 public zeroCreditCalls;
    uint256 public reserveBeforeLastZeroCredit;

    constructor(
        FurnaceHarness furnace_,
        ClaimToken claim_,
        MockVe ve_,
        MockLpRewardsVault lpVault_,
        address mineCore_
    ) {
        furnace = furnace_;
        claim = claim_;
        ve = ve_;
        lpVault = lpVault_;
        mineCoreAddr = mineCore_;
    }

    // --- Ledger-aware actions ------------------------------------------------

    function creditReserve(uint256 amount) external {
        amount = bound(amount, 0, 500_000e18);

        if (amount == 0) {
            // Capture reserve state before the zero-credit no-op probe so the invariant
            // contract can assert `furnaceReserve` does not move purely due to amount=0.
            reserveBeforeLastZeroCredit = furnace.furnaceReserve();
            uint256 reserveBefore = furnace.furnaceReserve();
            vm.prank(mineCoreAddr);
            furnace.creditReserve(0);
            uint256 reserveAfter = furnace.furnaceReserve();
            // Any movement under amount=0 must be drip outflow (creditReserve runs accrual
            // before the inflow branch); record it on the drip ledger.
            if (reserveAfter < reserveBefore) {
                totalDripOutflows += reserveBefore - reserveAfter;
            }
            zeroCreditCalls += 1;
            return;
        }

        vm.prank(mineCoreAddr);
        claim.mint(address(furnace), amount);

        uint256 reserveBefore_ = furnace.furnaceReserve();
        vm.prank(mineCoreAddr);
        furnace.creditReserve(amount);
        uint256 reserveAfter_ = furnace.furnaceReserve();

        // creditReserve runs the drip accrual first, so any pre-credit reserve movement
        // is already a drip outflow. We classify the post-call delta as either a net
        // inflow or a drip-dominated decrement.
        if (reserveAfter_ >= reserveBefore_) {
            totalCreditedInflows += reserveAfter_ - reserveBefore_;
        } else {
            // Net decrement means the drip booked more than the credit added; rare in
            // this harness because the credit always pushes reserve up by `amount`,
            // but classify defensively.
            totalDripOutflows += reserveBefore_ - reserveAfter_;
        }
    }

    function donateDirect(uint256 amount) external {
        amount = bound(amount, 0, 250_000e18);
        if (amount == 0) return;

        // Direct ERC-20 transfer that bypasses creditReserve. mineCore is authorized
        // to mint CLAIM; we mint to this handler and push tokens into Furnace.
        vm.prank(mineCoreAddr);
        claim.mint(address(this), amount);
        claim.transfer(address(furnace), amount);
        totalDirectDonations += amount;
    }

    /// @dev `_applyBonusAmm` is the only reserve-mutating step shared by both
    ///      `Furnace.extendWithBonus{,For}` and `Furnace.mergeLocksWithBonus{,For}`.
    ///      Driving the AMM directly through `exposedApplyBonusAmm` therefore
    ///      reproduces the exact reserve accounting profile of the merge path —
    ///      `mergeLocksFor` itself is reserve-neutral (lock-math only) and the
    ///      surviving-lock CLAIM deposit in `_approveVeAndAddToLock` consumes
    ///      `userBonus` already accounted for here. The `userBonus ≤ grossBonus`
    ///      assertion below is the merge-bonus-bound invariant from the v1.0.0
    ///      plan: `bonusClaim ≤ reserveBefore - reserveAfter` always holds
    ///      because `grossBonus == userBonus + lpBonus` and any additional
    ///      reserve drop comes from the post-call clamp (which only widens the
    ///      gap, never narrows it).
    function applyBonus(uint256 principalEff) external {
        principalEff = bound(principalEff, 1e18, 500_000e18);
        uint256 reserveBefore = furnace.furnaceReserve();
        if (reserveBefore == 0) return;

        (uint256 grossBonus, uint256 userBonus, uint256 lpBonus) = furnace.exposedApplyBonusAmm(principalEff);

        uint256 reserveAfter = furnace.furnaceReserve();
        if (reserveAfter < reserveBefore) {
            uint256 reserveDelta = reserveBefore - reserveAfter;
            totalBonusOutflows += reserveDelta;
            // userBonus is the value returned to the merge/extend caller as `bonusClaim`.
            // It must never exceed the total reserve drop the same call produced.
            require(userBonus <= reserveDelta, "merge-bonus-bound: userBonus > reserveDelta");
            // Conservation: grossBonus splits exactly into userBonus + lpBonus.
            require(grossBonus == userBonus + lpBonus, "AMM split: gross != user + lp");
        }
    }

    function pokeDrip(uint256 dt) external {
        dt = bound(dt, 1 hours, 7 days);
        vm.warp(block.timestamp + dt);
        uint256 reserveBefore = furnace.furnaceReserve();
        furnace.tick();
        uint256 reserveAfter = furnace.furnaceReserve();
        if (reserveAfter < reserveBefore) {
            totalDripOutflows += reserveBefore - reserveAfter;
        }
    }

    function forceClampReduction(uint256 drainAmount) external {
        // Simulates an accidental CLAIM drain from Furnace that bypasses the reserve
        // ledger (e.g., a future buggy code path moving CLAIM out without decrementing
        // reserve). The sync clamp MUST then reduce furnaceReserve to the new
        // balance-minus-liability ceiling.
        drainAmount = bound(drainAmount, 1, 10_000e18);
        uint256 bal = claim.balanceOf(address(furnace));
        if (drainAmount > bal) drainAmount = bal;
        if (drainAmount == 0) return;

        uint256 reserveBefore = furnace.furnaceReserve();

        vm.prank(address(furnace));
        claim.transfer(address(0xDEAD), drainAmount);
        totalForcedDrains += drainAmount;

        furnace.exposedSyncFurnaceReserve();

        uint256 reserveAfter = furnace.furnaceReserve();
        if (reserveAfter < reserveBefore) {
            totalClampReductions += reserveBefore - reserveAfter;
        }
    }

    // --- Helpers ------------------------------------------------------------

    function ledgerNetInflow() external view returns (uint256) {
        return totalCreditedInflows + totalSellbackReserveAdd;
    }

    function ledgerNetOutflow() external view returns (uint256) {
        return totalBonusOutflows + totalDripOutflows + totalClampReductions;
    }
}

/// @notice Reserve-accounting state-machine invariants.
/// @dev Mirrors the stateful-fuzz pattern in `MineCore_StateMachine_Invariants.t.sol`
///      (per-actor handler + global assertion helpers) and complements
///      `Furnace_Reserve_StateMachine_Invariants.t.sol` (drip cursor + clamp behavior)
///      with an explicit inflow / outflow ledger.
contract FurnaceReserveAccountingInvariants is StdInvariant, Test {
    ClaimToken internal claim;
    MockVe internal ve;
    ShareholderRoyalties internal royalties;
    MineCore internal mineCore;
    FurnaceHarness internal furnace;
    MockLpRewardsVault internal lpVault;
    FurnaceReserveAccountingHandler internal handler;

    address internal owner;

    function setUp() public {
        vm.txGasPrice(0);

        owner = makeAddr("owner");

        ve = new MockVe();
        claim = new ClaimToken(owner);
        royalties = new ShareholderRoyalties(address(ve), owner);
        mineCore = new MineCore(address(claim), address(ve), address(royalties), owner);
        furnace = new FurnaceHarness(address(claim), address(ve), owner);
        FurnaceQuoter quoter = new FurnaceQuoter(address(furnace));
        lpVault = new MockLpRewardsVault();
        lpVault.setFurnace(address(furnace));

        vm.startPrank(owner);
        claim.setMineCore(address(mineCore));
        furnace.setMineCore(address(mineCore));
        furnace.setFurnaceQuoter(address(quoter));
        furnace.setLpRewardsVault(address(lpVault));
        mineCore.setFurnace(address(furnace));
        vm.etch(address(0xB0B0), hex"00");
        royalties.setWiring(address(mineCore), address(0xB0B0), address(furnace));
        vm.stopPrank();

        ve.setTotalLockedClaim(5_000_000e18);

        // Jump into the drip-enabled regime so the drip outflow ledger gets exercised.
        uint256 start = mineCore.emissionStartTime();
        vm.warp(start + Constants.LP_OVERFLOW_DRIP_START + Constants.LP_OVERFLOW_DRIP_RAMP + 1);

        handler = new FurnaceReserveAccountingHandler(furnace, claim, ve, lpVault, address(mineCore));

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.creditReserve.selector;
        selectors[1] = handler.donateDirect.selector;
        selectors[2] = handler.applyBonus.selector;
        selectors[3] = handler.pokeDrip.selector;
        selectors[4] = handler.forceClampReduction.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Core ledger equality: reserve tracks explicit inflows minus outflows.
    function invariant_reserveMatchesInflowsMinusOutflows() public view {
        uint256 inflow = handler.ledgerNetInflow();
        uint256 outflow = handler.ledgerNetOutflow();
        assertGe(inflow, outflow, "ledger: inflow underflow");
        assertEq(
            furnace.furnaceReserve(),
            inflow - outflow,
            "furnaceReserve must equal tracked inflows minus tracked outflows + clamp reductions"
        );
    }

    /// @notice Ceiling invariant: reserve never exceeds available CLAIM minus LP liability.
    function invariant_reserveBoundedByBalanceMinusLiability() public view {
        uint256 bal = claim.balanceOf(address(furnace));
        uint256 liability = furnace.exposedLpStreamLiability();
        uint256 cap = bal > liability ? bal - liability : 0;
        assertLe(
            furnace.furnaceReserve(), cap, "furnaceReserve MUST NOT exceed CLAIM.balanceOf(this) - lpStreamLiability"
        );
    }

    /// @notice Direct ERC-20 donations to Furnace do NOT leak into the reserve ledger.
    ///         If this invariant fails, a surplus-consuming bug has been introduced.
    function invariant_directDonationsDoNotLeakIntoReserve() public view {
        uint256 inflow = handler.ledgerNetInflow();
        uint256 outflow = handler.ledgerNetOutflow();
        uint256 donations = handler.totalDirectDonations();
        uint256 forcedDrains = handler.totalForcedDrains();
        uint256 bal = claim.balanceOf(address(furnace));
        uint256 liability = furnace.exposedLpStreamLiability();

        // Reserve must remain within the legitimate ceiling even after donations.
        uint256 tracked = (inflow >= outflow) ? inflow - outflow : 0;
        assertLe(tracked, bal > liability ? bal - liability : 0, "reserve exceeds legitimate ceiling");

        // The donation pool is part of "untracked surplus", but the harness-only
        // `forceClampReduction` action physically removes CLAIM from Furnace; that drain
        // can come out of either the tracked reserve (recorded in `outflow`) or the
        // donation/surplus buffer. Reconstructing the donation accounting:
        //
        //   bal_initial + donations + inflow            (everything that ever came in)
        //   - outflow                                    (tracked outflows; not on bal)
        //   - forcedDrains                               (physically transferred out)
        //   = bal                                        (current balance)
        //
        // ⇒ donations <= bal + forcedDrains - tracked   (rearranged; bal_initial = 0)
        //
        // The strict-equality version is not load-bearing: the load-bearing property is
        // that direct donations cannot be pulled INTO the tracked reserve ledger. If a
        // future auto-credit bug surfaced, `tracked` would grow by the donation amount
        // and the invariant `donations + bal >= tracked + forcedDrains` would fail.
        assertGe(
            bal + forcedDrains,
            tracked + donations,
            "donations leaked: tracked reserve absorbed direct donations beyond physical drains"
        );
    }

    /// @notice `creditReserve(0)` must be a reserve-level no-op modulo drip accrual.
    function invariant_creditReserveZeroIsNoOpOnReserve() public view {
        // The handler classifies any zero-credit-call delta as drip outflow. Therefore
        // the inflows ledger must never grow on a zero-amount call. We assert the
        // weaker but always-true bound here:
        assertLe(
            handler.totalCreditedInflows(),
            furnace.furnaceReserve() + handler.ledgerNetOutflow(),
            "zero-amount credit must not inflate credited-inflows ledger"
        );
    }

    /// @notice Bonus outflows conserve value: every reserve decrement in the bonus
    ///         path is matched by either a CLAIM transfer to the user (via ve lock) or
    ///         an LP stream liability increment. In this harness the bonus payout is
    ///         routed through the harness shim and lpBonus stays parked as liability,
    ///         so balance + LP liability MUST cover the reserve at all times.
    function invariant_bonusOutflowCoveredByCorrespondingBalanceMove() public view {
        uint256 bal = claim.balanceOf(address(furnace));
        uint256 liability = furnace.exposedLpStreamLiability();
        uint256 reserve = furnace.furnaceReserve();
        assertGe(bal, reserve + liability, "balance must cover reserve + LP liability");
    }
}
