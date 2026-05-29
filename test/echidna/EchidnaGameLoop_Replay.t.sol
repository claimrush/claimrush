// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {EchidnaGameLoop} from "./EchidnaGameLoop.sol";

contract EchidnaGameLoopReplayTest is Test {
    EchidnaGameLoop internal gameLoop;

    function setUp() public {
        gameLoop = new EchidnaGameLoop{value: 10 ether}();
    }

    function testSeededGameLoopCorpusReplaysStaySafe() public {
        gameLoop.action_seedQuoteExecuteDrift();
        gameLoop.action_seedVictimListingGrief();
        gameLoop.action_seedEscrowCycle();
        gameLoop.action_seedExpiredCleanup();
        gameLoop.action_seedPauseLiveness();
        gameLoop.action_seedRejectingKingBuckets();

        assertTrue(gameLoop.echidna_global_claim_liabilities_backed());
        assertTrue(gameLoop.echidna_eth_liabilities_backed());
        assertTrue(gameLoop.echidna_quote_execute_parity());
        assertTrue(gameLoop.echidna_victim_griefing_blocked());
        assertTrue(gameLoop.echidna_pause_liveness_matrix());
        assertTrue(gameLoop.echidna_no_profitable_roundtrip_cycles());
        assertTrue(gameLoop.echidna_closed_offers_hold_no_funds());
        assertTrue(gameLoop.echidna_market_escrow_accounting_exact());
        assertTrue(gameLoop.echidna_listed_state_matches_market());
        assertTrue(gameLoop.echidna_tracked_lock_ownership_safe());
        assertTrue(gameLoop.echidna_current_king_not_protocol_owned());
    }

    function testRepeatedSeedCyclesStaySafe() public {
        for (uint256 i = 0; i < 3; ++i) {
            gameLoop.action_seedQuoteExecuteDrift();
            gameLoop.action_seedVictimListingGrief();
            gameLoop.action_seedEscrowCycle();
            gameLoop.action_seedExpiredCleanup();
            gameLoop.action_seedPauseLiveness();
        }

        assertTrue(gameLoop.echidna_global_claim_liabilities_backed());
        assertTrue(gameLoop.echidna_quote_execute_parity());
        assertTrue(gameLoop.echidna_victim_griefing_blocked());
        assertTrue(gameLoop.echidna_pause_liveness_matrix());
        assertTrue(gameLoop.echidna_market_escrow_accounting_exact());
        assertTrue(gameLoop.echidna_listed_state_matches_market());
        assertTrue(gameLoop.echidna_tracked_lock_ownership_safe());
    }
}
