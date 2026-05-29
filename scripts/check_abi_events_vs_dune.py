#!/usr/bin/env python3
"""Check shipped ABI event argument schemas against the canonical Dune pack doc.

This is a guardrail to prevent ABI drift that breaks:
- Dune decoded event tables
- any indexer that consumes the repo-shipped ABI JSON files

What this check enforces
- event exists in the ABI
- argument *count* matches
- argument *order* matches
- argument *names* match (Dune uses these as decoded column names)

Canonical source (v1.0.0)
- docs/analytics/dune-integration-pack-v1.0.0.md

Usage
  # Base mainnet (default)
  python3 scripts/check_abi_events_vs_dune.py

  # Explicit network
  python3 scripts/check_abi_events_vs_dune.py --network base_sepolia

  # Custom paths
  python3 scripts/check_abi_events_vs_dune.py \
    --docs docs/analytics/dune-integration-pack-v1.0.0.md \
    --abi-dir abis/base_mainnet

Note
- This check is intentionally *name/order* focused. For typed/indexed enforcement, also run:
  python3 scripts/check_abi_event_schema.py --network <network>
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple


@dataclass(frozen=True)
class ExpectedEvent:
    name: str
    args: List[str]


TARGET_CONTRACTS: Tuple[str, ...] = (
    "EntryTokenRegistry",
    "VeClaimNFT",
    "MineCore",
    "ShareholderRoyalties",
    "Furnace",
    "LpStakingVault7D",
    "LaunchController",
    "GenesisLPVault24M",
    "MaintenanceHub",
    "MarketRouter",
    "DelegationHub",
    "ClaimAllHelper",
)


_SECTION_SPLIT_RE = re.compile(r"\n### ")
_EVENT_LINE_RE = re.compile(r"^\s*-\s*`([A-Za-z0-9_]+)\(([^`]*)\)`", re.MULTILINE)
_CONTRACT_NAME_RE = re.compile(r"^([A-Za-z0-9_]+)")


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def normalize_contract_name(section_header: str) -> str:
    """Map a markdown section header like "MarketRouter (marketplace)" -> "MarketRouter"."""

    m = _CONTRACT_NAME_RE.match(section_header.strip())
    return m.group(1) if m else section_header.strip()


def _extract_arg_name(decl: str) -> str:
    """Return just the parameter name from a Solidity-style declaration.

    The Dune pack uses two interchangeable formats inside event signatures:
    - fully-typed:  ``address indexed king``  → ``king``
    - bare-name:    ``king``                 → ``king``

    Splitting on whitespace and taking the last token works for both, because
    the parameter name is always the trailing identifier in a Solidity decl.
    """

    stripped = decl.strip()
    if not stripped:
        return stripped
    return stripped.split()[-1]


def parse_dune_pack(docs_path: Path) -> Dict[str, List[ExpectedEvent]]:
    text = docs_path.read_text(encoding="utf-8")
    parts = _SECTION_SPLIT_RE.split(text)

    by_contract: Dict[str, List[ExpectedEvent]] = {}

    # parts[0] is the preamble before the first "###"
    for sec in parts[1:]:
        header, body = (sec.split("\n", 1) + [""])[:2]
        contract = normalize_contract_name(header)
        if contract not in TARGET_CONTRACTS:
            continue

        events: List[ExpectedEvent] = []
        for m in _EVENT_LINE_RE.finditer(body):
            evt_name = m.group(1)
            arg_blob = m.group(2).strip()
            args = (
                [_extract_arg_name(a) for a in arg_blob.split(",") if a.strip()]
                if arg_blob
                else []
            )
            events.append(ExpectedEvent(evt_name, args))

        by_contract[contract] = events

    return by_contract


def load_abi_events(abi_path: Path) -> Dict[str, List[List[str]]]:
    """Return mapping: eventName -> list of arg-name lists.

    We keep *all* ABI entries for a given event name (in case of overloads). The check passes
    if *any* entry matches the canonical arg-name list.
    """

    abi = json.loads(abi_path.read_text(encoding="utf-8"))
    events: Dict[str, List[List[str]]] = {}

    for item in abi:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "event":
            continue
        name = item.get("name")
        if not name:
            continue

        args = [inp.get("name", "") for inp in item.get("inputs", [])]
        events.setdefault(name, []).append(args)

    return events


def main() -> int:
    ap = argparse.ArgumentParser(description="Check ABI event arg names/order vs Dune pack")
    ap.add_argument(
        "--network",
        default="base_mainnet",
        help="ABI folder name under abis/ (default: base_mainnet)",
    )
    ap.add_argument(
        "--docs",
        default=None,
        help="Path to dune-integration-pack markdown (default: docs/analytics/dune-integration-pack-v1.0.0.md)",
    )
    ap.add_argument(
        "--abi-dir",
        default=None,
        help="Directory containing *.abi.json files (default: abis/<network>)",
    )
    ap.add_argument(
        "--contracts",
        nargs="*",
        default=list(TARGET_CONTRACTS),
        help="Optional list of contract names to check (default: TARGET_CONTRACTS)",
    )

    args = ap.parse_args()

    root = _repo_root()
    docs_path = Path(args.docs) if args.docs else root / "docs" / "analytics" / "dune-integration-pack-v1.0.0.md"
    abi_dir = Path(args.abi_dir) if args.abi_dir else root / "abis" / args.network

    expected = parse_dune_pack(docs_path)

    problems: List[str] = []

    for contract in args.contracts:
        if contract not in expected:
            problems.append(f"{contract}: not found in docs (or not in TARGET_CONTRACTS)")
            continue

        abi_path = abi_dir / f"{contract}.abi.json"
        if not abi_path.exists():
            problems.append(f"{contract}: missing ABI file {abi_path}")
            continue

        abi_events = load_abi_events(abi_path)

        for exp in expected[contract]:
            candidates = abi_events.get(exp.name)
            if not candidates:
                problems.append(f"{contract}: missing event {exp.name} in ABI")
                continue

            if exp.args not in candidates:
                # show the first candidate to make diffs easier to read
                got = candidates[0]
                problems.append(
                    f"{contract}: event {exp.name} args mismatch\n"
                    f"  docs: {exp.args}\n"
                    f"  abi : {got}"
                )

    # ------------------------------------------------------------------
    # Reverse check: warn about ABI events NOT documented in the Dune pack.
    # These are not hard failures (exit-code remains 0) but are printed as
    # warnings so that new events don't silently go undocumented.
    # ------------------------------------------------------------------
    warnings: List[str] = []
    _ADMIN_EVENTS = frozenset({
        "ConfigFrozen", "GuardianChanged",
        "OwnershipTransferStarted", "OwnershipTransferred",
        # Inherited ERC-721 standard events on VeClaimNFT.
        "Approval", "ApprovalForAll", "Transfer",
        # Inherited EIP-712 standard event on DelegationHub.
        "EIP712DomainChanged",
    })

    for contract in args.contracts:
        if contract not in expected:
            continue
        abi_path = abi_dir / f"{contract}.abi.json"
        if not abi_path.exists():
            continue
        abi_events = load_abi_events(abi_path)
        documented_names = {e.name for e in expected[contract]}
        for evt_name in sorted(abi_events.keys()):
            if evt_name in documented_names:
                continue
            if evt_name in _ADMIN_EVENTS:
                continue  # covered by "Common admin transparency" section
            warnings.append(f"{contract}: ABI event {evt_name} not in Dune pack doc")

    if problems:
        print("ABI vs Dune pack mismatches:\n")
        for p in problems:
            print(f"- {p}")
        print(f"\nTotal mismatches: {len(problems)}")

    if warnings:
        print("\nUndocumented ABI events (not in Dune pack):\n")
        for w in warnings:
            print(f"  [warn] {w}")
        print(f"\nTotal undocumented: {len(warnings)}")

    if problems:
        return 1

    print("ABI vs Dune pack: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
