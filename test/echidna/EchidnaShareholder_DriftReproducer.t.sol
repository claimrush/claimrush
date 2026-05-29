// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {EchidnaShareholder} from "./EchidnaShareholder.sol";
import {ShareholderRoyalties} from "src/ShareholderRoyalties.sol";
import {VeClaimNFT} from "src/VeClaimNFT.sol";
import {MineCoreHarness} from "../mocks/MineCoreHarness.sol";

contract HarnessProbe is EchidnaShareholder {
    constructor() payable {}

    function probeRoyalties() external view returns (address) {
        return address(royalties);
    }

    function probeVe() external view returns (address) {
        return address(ve);
    }

    function probeMineCore() external view returns (address) {
        return address(mineCore);
    }

    function probeFurnace() external view returns (address) {
        return address(furnace);
    }

    function probeActor(uint256 i) external view returns (address) {
        return actors[i];
    }
}

/// @notice Deterministic replay of a previously-noisy Shareholder accrual trace,
///         pinned here as a positive regression: under the disjoint-buckets
///         invariant, both `physical_solvency` and `disjoint_buckets_exact` MUST
///         hold strictly across the trace.
///
///         Trace from echidna-corpora/Shareholder/reproducers/1577649202065484763.txt:
///         the two `enterFurnace` actions execute in the same block (delays are
///         zero), then 51031 sec elapses, then a takeover deposits
///         `value=0x39b0e275036ff` wei, then 120297 sec elapses, then `flush()` is a
///         no-op (pending was drained in the takeover-tail flush already).
contract ShareholderM5DriftReproducer is Test {
    HarnessProbe internal h;

    function setUp() public {
        h = new HarnessProbe{value: 10 ether}();
    }

    function testReproduceDrift() public {
        ShareholderRoyalties royalties = ShareholderRoyalties(payable(_royalties()));
        VeClaimNFT ve = VeClaimNFT(_ve());

        console2.log("=== INITIAL STATE ===");
        _logState(royalties, ve);

        h.action_enterFurnace(519074788488258500021498, 534214825995072961804446367128);
        h.action_enterFurnace(5100127216112401552311918, 5914299489888195);
        console2.log("=== AFTER 2x enterFurnace (same block) ===");
        _logLocks(ve);
        _logState(royalties, ve);

        // wait 51031 sec, 1 block
        vm.warp(block.timestamp + 51031);
        vm.roll(block.number + 1);

        // takeover with value=0x39b0e275036ff
        uint256 takeoverValue = 0x39b0e275036ff;
        vm.deal(address(h), address(h).balance + takeoverValue);
        h.action_takeover{value: takeoverValue}();
        console2.log("=== AFTER takeover (auto-flush in takeover tail) ===");
        _logState(royalties, ve);

        // wait 120297 sec, 1 block
        vm.warp(block.timestamp + 120297);
        vm.roll(block.number + 1);

        h.action_flush();
        console2.log("=== AFTER explicit flush ===");
        _logState(royalties, ve);

        console2.log("=== PROPERTY CHECK ===");
        uint256 claimableThis = royalties.claimableEth(address(h));
        uint256 pending = royalties.pendingShareholderETH();
        uint256 balance = address(royalties).balance;
        console2.log("claimableEth(harness) :", claimableThis);
        console2.log("pendingShareholderETH :", pending);
        console2.log("balance               :", balance);
        console2.log("sum (claim+pend)      :", claimableThis + pending);
        console2.log("delta (sum-balance)   :", int256(claimableThis + pending) - int256(balance));

        bool physical = h.echidna_shareholder_physical_solvency();
        bool disjoint = h.echidna_shareholder_disjoint_buckets_exact();
        bool aggregator = h.echidna_total_crystallised_matches_sum();
        console2.log("physical_solvency       :", physical);
        console2.log("disjoint_buckets_exact  :", disjoint);
        console2.log("crystallised_matches_sum:", aggregator);

        // STRICT physical solvency: stored + pending fit inside balance.
        assertTrue(physical, "stored claimable + pending must fit inside balance");
        // STRICT disjoint-buckets identity: stored + indexed + pending == balance.
        assertTrue(disjoint, "disjoint-buckets identity must hold exactly");
        // STRICT O(1) aggregator agreement: totalCrystallisedStored == Σ stored.
        assertTrue(aggregator, unicode"totalCrystallisedStored must equal Σ stored");
    }

    function _logLocks(VeClaimNFT ve) internal view {
        (uint256[] memory amounts, uint256[] memory lockEnds, bool[] memory autoMaxFlags) =
            ve.getShareholderLockParams(address(h));
        console2.log("--- locks of harness ---");
        for (uint256 i = 0; i < amounts.length; ++i) {
            console2.log("lock[i]: amount, lockEnd, autoMax:");
            console2.log(i);
            console2.log(amounts[i]);
            console2.log(lockEnds[i]);
            console2.log(autoMaxFlags[i] ? 1 : 0);
        }
        console2.log("totalVeBiasScaled:", ve.totalVeBiasScaled());
        console2.log("globalLastTs    :", ve.globalLastTs());
    }

    function _logState(ShareholderRoyalties royalties, VeClaimNFT) internal view {
        console2.log("block.timestamp:", block.timestamp);
        console2.log("royalties.balance:", address(royalties).balance);
        console2.log("pendingShareholderETH:", royalties.pendingShareholderETH());
    }

    function _royalties() internal view returns (address) {
        return h.probeRoyalties();
    }

    function _ve() internal view returns (address) {
        return h.probeVe();
    }
}

/// @notice Deterministic replay of a 7-call sequence from
///         echidna-corpora/Shareholder/reproducers-unshrunk/4984957460098934778.txt,
///         pinned here as a positive regression: under the disjoint-buckets
///         invariant, `physical_solvency`, `disjoint_buckets_exact`, and the
///         `totalCrystallisedStored` aggregator MUST hold strictly across the trace.
///
///         The sequence, with the `from:` actor map:
///           1. action_enterFurnace(952, ~max) from 0x40000          - creates harness ve lock #1
///           2. action_flush()                  from 0x20000          - no pending → no-op
///           3. action_claimShareholder()       from 0x40000  +145s   - stored=0 → no-op
///           4. action_takeover()               from 0x20000  +318775s value=0xc17a4f5805205af8
///           5. action_setAutoCompoundConfig(65) from 0x40000 +165059s reverts (tokenId=0) → no-op
///           6. action_claimShareholderAndLock(1310904) from 0x40000 +122375s stored=0 → no-op
///           7. action_enterFurnace(huge, huge) from 0x30000 +100002s - creates harness ve lock #2
///
///         The property check after step 7:
///           Σ claimableEthStored(actors[0..2]) + claimableEthStored(harness) + indexedEthOwed
///             + pendingShareholderETH == address(royalties).balance
contract ShareholderPhysicalSolvencyReproducer is Test {
    HarnessProbe internal h;

    function setUp() public {
        h = new HarnessProbe{value: 30 ether}();
    }

    function testReplayPhysicalSolvencyViolation() public {
        ShareholderRoyalties royalties = ShareholderRoyalties(payable(h.probeRoyalties()));
        VeClaimNFT ve = VeClaimNFT(h.probeVe());

        console2.log("=== INITIAL STATE ===");
        _logState(royalties, ve);

        // Step 1: from 0x40000, delay=0x270f sec / 0x73b3 blocks
        // (initial step: just apply the leading delay before the first call)
        vm.warp(block.timestamp + 0x270f);
        vm.roll(block.number + 0x73b3);
        h.action_enterFurnace(952, 115792089237316195423570985008687907853269984665640564039457584007913129638933);
        console2.log("=== AFTER step 1 (enterFurnace 952) ===");
        _logState(royalties, ve);
        _logActors(royalties);

        // Step 2: from 0x20000, delay=0/0
        h.action_flush();
        console2.log("=== AFTER step 2 (flush) ===");
        _logState(royalties, ve);
        _logActors(royalties);

        // Step 3: from 0x40000, delay=0x91 sec / 0xa2a9 blocks
        vm.warp(block.timestamp + 0x91);
        vm.roll(block.number + 0xa2a9);
        h.action_claimShareholder();
        console2.log("=== AFTER step 3 (claimShareholder) ===");
        _logState(royalties, ve);
        _logActors(royalties);

        // Step 4: from 0x20000, delay=0x4dd37 sec / 0x4009 blocks, value=0xc17a4f5805205af8
        vm.warp(block.timestamp + 0x4dd37);
        vm.roll(block.number + 0x4009);
        uint256 takeoverValue = 0xc17a4f5805205af8;
        vm.deal(address(h), address(h).balance + takeoverValue);
        h.action_takeover{value: takeoverValue}();
        console2.log("=== AFTER step 4 (takeover) ===");
        _logState(royalties, ve);
        _logActors(royalties);

        // Step 5: from 0x40000, delay=0x284c3 sec / 0xb49f blocks
        vm.warp(block.timestamp + 0x284c3);
        vm.roll(block.number + 0xb49f);
        h.action_setAutoCompoundConfig(65);
        console2.log("=== AFTER step 5 (setAutoCompoundConfig) ===");
        _logState(royalties, ve);
        _logActors(royalties);

        // Step 6: from 0x40000, delay=0x1de07 sec / 0x752e blocks
        vm.warp(block.timestamp + 0x1de07);
        vm.roll(block.number + 0x752e);
        h.action_claimShareholderAndLock(1310904);
        console2.log("=== AFTER step 6 (claimShareholderAndLock) ===");
        _logState(royalties, ve);
        _logActors(royalties);

        // Step 7: from 0x30000, delay=0x186a2 sec / 0xa4f blocks
        vm.warp(block.timestamp + 0x186a2);
        vm.roll(block.number + 0xa4f);
        h.action_enterFurnace(
            96196309503001578776866729788287000907551939928239535378143063949213176654720,
            31502950120403373656680562292651291202232480469215639352532357647700458635808
        );
        console2.log("=== AFTER step 7 (enterFurnace huge) ===");
        _logState(royalties, ve);
        _logActors(royalties);

        console2.log("=== FINAL PROPERTY CHECK ===");
        bool physical = h.echidna_shareholder_physical_solvency();
        bool disjoint = h.echidna_shareholder_disjoint_buckets_exact();
        bool aggregator = h.echidna_total_crystallised_matches_sum();
        bool pendingLeqBalance = h.echidna_pending_leq_balance();
        console2.log("physical_solvency       :", physical);
        console2.log("disjoint_buckets_exact  :", disjoint);
        console2.log("crystallised_matches_sum:", aggregator);
        console2.log("pending_leq_balance     :", pendingLeqBalance);

        // Diagnostic logs on failure surface the per-bucket numbers to make the
        // delta visible at a glance.
        if (!physical || !disjoint || !aggregator) {
            uint256 totalStored = royalties.claimableEthStored(h.probeActor(0))
                + royalties.claimableEthStored(h.probeActor(1)) + royalties.claimableEthStored(h.probeActor(2))
                + royalties.claimableEthStored(address(h));
            uint256 indexedBucket = royalties.indexedEthOwed();
            uint256 pending = royalties.pendingShareholderETH();
            uint256 crystallised = royalties.totalCrystallisedStored();
            uint256 balance = address(royalties).balance;
            console2.log("totalStored        :", totalStored);
            console2.log("indexed            :", indexedBucket);
            console2.log("pending            :", pending);
            console2.log("crystallised aggr  :", crystallised);
            console2.log("balance            :", balance);
            console2.log("disjoint excess    :", int256(totalStored + indexedBucket + pending) - int256(balance));
        }

        // STRICT physical solvency.
        assertTrue(physical, "stored claimable + pending must fit inside balance");
        // STRICT disjoint-buckets identity.
        assertTrue(disjoint, "disjoint-buckets identity must hold exactly");
        // STRICT O(1) aggregator agreement.
        assertTrue(aggregator, unicode"totalCrystallisedStored must equal Σ stored");
        // STRICT pending vs balance.
        assertTrue(pendingLeqBalance, "pending must never exceed contract balance");
    }

    function _logActors(ShareholderRoyalties royalties) internal view {
        console2.log("--- claimableEthStored per actor ---");
        for (uint256 i = 0; i < 3; ++i) {
            address a = h.probeActor(i);
            console2.log("actor:", a);
            console2.log("  stored:", royalties.claimableEthStored(a));
        }
        console2.log("harness stored:", royalties.claimableEthStored(address(h)));
    }

    function _logState(ShareholderRoyalties royalties, VeClaimNFT ve) internal view {
        console2.log("block.timestamp:", block.timestamp);
        console2.log("royalties.balance:", address(royalties).balance);
        console2.log("pendingShareholderETH:", royalties.pendingShareholderETH());
        console2.log("totalVeBiasScaled:", ve.totalVeBiasScaled());
        console2.log("globalLastTs:", ve.globalLastTs());
    }
}
