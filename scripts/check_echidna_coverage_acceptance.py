#!/usr/bin/env python3
"""Acceptance gate for Echidna logs.

For the cross-contract GameLoop harness, a clean process exit is not enough.
The launch gate also requires the seeded adversarial corpus to replay, all
critical properties/actions to pass, an end-of-run marker, and minimum coverage.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME_LOOP_HARNESS = ROOT / "test/echidna/EchidnaGameLoop.sol"
HARNESS_PROPERTY_RE = re.compile(r"^    function (echidna_\w+)\(", re.MULTILINE)
HARNESS_ACTION_RE = re.compile(r"^    function (action_\w+)\(", re.MULTILINE)

GAME_LOOP_PROPERTIES = [
    "echidna_global_claim_liabilities_backed",
    "echidna_eth_liabilities_backed",
    "echidna_quote_execute_parity",
    "echidna_victim_griefing_blocked",
    "echidna_pause_liveness_matrix",
    "echidna_no_profitable_roundtrip_cycles",
    "echidna_closed_offers_hold_no_funds",
    "echidna_market_escrow_accounting_exact",
    "echidna_listed_state_matches_market",
    "echidna_tracked_lock_ownership_safe",
    "echidna_current_king_not_protocol_owned",
]

GAME_LOOP_ACTIONS = [
    "action_takeoverAs",
    "action_enterWithQuote",
    "action_extendWithQuote",
    "action_claimAutoMaxWithQuote",
    "action_enterSellRoundTripCannotProfit",
    "action_extendSellRoundTripCannotProfit",
    "action_mergeSellRoundTripCannotProfit",
    "action_listActorLock",
    "action_delistActorLock",
    "action_sellActorLockWithQuote",
    "action_sellListedByKeeperWithQuote",
    "action_createEscrow",
    "action_cancelEscrow",
    "action_executeEscrow",
    "action_cancelExpiredEscrowAsKeeper",
    "action_escrowCancelRoundTripNoLoss",
    "action_escrowExecuteSellRoundTripCannotProfit",
    "action_cancelExpiredListingAsKeeper",
    "action_attackerCannotMutateVictimLock",
    "action_permissionlessAutoMaxCannotDamageVictim",
    "action_pauseLivenessProbe",
    "action_seedQuoteExecuteDrift",
    "action_seedVictimListingGrief",
    "action_seedEscrowCycle",
    "action_seedNoFreeClaimCycles",
    "action_seedExpiredCleanup",
    "action_seedPauseLiveness",
    "action_seedRejectingKingBuckets",
]

GAME_LOOP_SEED_PREFIXES = [
    "001_quote_execute_drift",
    "002_victim_griefing",
    "003_pause_liveness",
    "004_escrow_cycle",
    "005_rejecting_king_buckets",
    "006_expired_cleanup",
]

FAIL_RE = re.compile(
    r"(^echidna_.*: failing|^assertion in.*: failed!|^FAILED|Deploying the contract.*failed)",
    re.MULTILINE,
)
END_RE = re.compile(r"^\[[0-9-]+ [0-9:.]+\] (Saving coverage|Reached test limit|Reached time limit)", re.MULTILINE)
COV_RE = re.compile(r"(?:Unique instructions:\s*|cov:\s*)(\d+)")


def _passing_name_present(text: str, name: str) -> bool:
    return re.search(rf"^{re.escape(name)}(?:\([^)]*\))?: passing$", text, re.MULTILINE) is not None


def _max_coverage(text: str) -> int:
    values = [int(m.group(1)) for m in COV_RE.finditer(text)]
    return max(values) if values else 0


def _self_check_game_loop_constants() -> list[str]:
    """Assert GAME_LOOP_PROPERTIES and GAME_LOOP_ACTIONS exactly mirror the harness."""
    if not GAME_LOOP_HARNESS.exists():
        return [f"harness not found at {GAME_LOOP_HARNESS.relative_to(ROOT)}"]
    text = GAME_LOOP_HARNESS.read_text(encoding="utf-8")
    harness_properties = HARNESS_PROPERTY_RE.findall(text)
    harness_actions = HARNESS_ACTION_RE.findall(text)

    issues: list[str] = []
    if harness_properties != GAME_LOOP_PROPERTIES:
        missing = [n for n in harness_properties if n not in GAME_LOOP_PROPERTIES]
        extra = [n for n in GAME_LOOP_PROPERTIES if n not in harness_properties]
        if missing:
            issues.append(f"GAME_LOOP_PROPERTIES missing: {', '.join(missing)}")
        if extra:
            issues.append(f"GAME_LOOP_PROPERTIES lists entries not declared in harness: {', '.join(extra)}")
        if not missing and not extra:
            issues.append("GAME_LOOP_PROPERTIES order differs from harness declaration order")
    if harness_actions != GAME_LOOP_ACTIONS:
        missing = [n for n in harness_actions if n not in GAME_LOOP_ACTIONS]
        extra = [n for n in GAME_LOOP_ACTIONS if n not in harness_actions]
        if missing:
            issues.append(f"GAME_LOOP_ACTIONS missing: {', '.join(missing)}")
        if extra:
            issues.append(f"GAME_LOOP_ACTIONS lists entries not declared in harness: {', '.join(extra)}")
        if not missing and not extra:
            issues.append("GAME_LOOP_ACTIONS order differs from harness declaration order")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, nargs="?")
    parser.add_argument("--contract", default="")
    parser.add_argument("--mode", choices=["property", "assertion"], default="property")
    parser.add_argument("--min-unique", type=int, default=0)
    parser.add_argument("--require-game-loop-seeds", action="store_true")
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="Verify GAME_LOOP_PROPERTIES/ACTIONS match the harness and exit.",
    )
    args = parser.parse_args()

    if args.self_check:
        issues = _self_check_game_loop_constants()
        if issues:
            for issue in issues:
                print(f"[echidna-acceptance] ERROR: self-check: {issue}", file=sys.stderr)
            print(f"[echidna-acceptance] FAIL: {len(issues)} self-check issue(s)", file=sys.stderr)
            return 1
        print(
            f"[echidna-acceptance] OK: self-check "
            f"({len(GAME_LOOP_PROPERTIES)} properties, {len(GAME_LOOP_ACTIONS)} actions)"
        )
        return 0

    if args.log is None:
        print("[echidna-acceptance] ERROR: log path is required unless --self-check is set", file=sys.stderr)
        return 2

    text = args.log.read_text(encoding="utf-8", errors="replace")
    errors: list[str] = []

    if FAIL_RE.search(text):
        errors.append("explicit Echidna failure marker found")
    if not END_RE.search(text):
        errors.append("missing end-of-run marker")

    coverage = _max_coverage(text)
    if args.min_unique and coverage < args.min_unique:
        errors.append(f"coverage {coverage} below required {args.min_unique} unique instructions")

    if args.contract == "EchidnaGameLoop":
        names = GAME_LOOP_PROPERTIES if args.mode == "property" else GAME_LOOP_ACTIONS
        for name in names:
            if not _passing_name_present(text, name):
                errors.append(f"missing passing marker for {name}")

        if args.require_game_loop_seeds:
            for seed in GAME_LOOP_SEED_PREFIXES:
                if seed not in text:
                    errors.append(f"seed corpus path not replayed: {seed}")

    if errors:
        for err in errors:
            print(f"[echidna-acceptance] ERROR: {args.log}: {err}", file=sys.stderr)
        print(f"[echidna-acceptance] FAIL: {len(errors)} issue(s)", file=sys.stderr)
        return 1

    print(f"[echidna-acceptance] OK: {args.log} (coverage={coverage})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
