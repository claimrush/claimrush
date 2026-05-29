#!/usr/bin/env python3
"""Validate shipped ABIs against the canonical Dune event schema doc.

This guards against ABI drift that would silently break:
- Dune decoded tables
- subgraph mappings
- downstream event decoding

Usage:
  python3 scripts/check_abis_vs_dune_pack.py \
    --docs docs/analytics/dune-integration-pack-v1.0.0.md \
    --abi-dir abis/base_mainnet

The check is intentionally strict about:
- event existence
- argument *order*
- argument *names*

It does NOT validate types (the Dune pack does not encode types).
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
_PLACEHOLDER_RE = re.compile(r"^<<<([A-Za-z0-9_]+)>>>")


def _arg_name_from_doc_chunk(chunk: str) -> str:
    """Extract the bare arg name from a doc-side arg chunk.

    The Dune pack mixes two equally-valid Solidity-style formats per event:

    1. Full event signature  : ``Takeover(uint256 indexed reignId, address king)``
    2. Name-only summary form: ``Takeover(reignId, king)``

    The ABI side (loaded from `abis/<network>/*.abi.json`) only carries names.
    To compare apples-to-apples we strip everything before the final
    whitespace-separated token, which leaves the bare argument name in both
    formats. Examples:

    - ``"uint256 indexed reignId"`` -> ``"reignId"``
    - ``"address king"``            -> ``"king"``
    - ``"bytes32[] indexed kings"`` -> ``"kings"``
    - ``"reignId"``                 -> ``"reignId"`` (already plain)

    Anonymous Solidity args (e.g. ``Foo(uint256)`` with no name) collapse to
    the type token (``"uint256"``); the corresponding ABI entry has
    ``inputs[].name == ""`` so they will mismatch as expected and the gate
    will surface the missing name.
    """
    cleaned = chunk.strip()
    if not cleaned:
        return ""
    return cleaned.rsplit(None, 1)[-1]


def normalize_contract_name(section_header: str) -> str:
    """Map a markdown section header like "MarketRouter (marketplace)" -> "MarketRouter".

    Also handles angle-bracket placeholders like "<<<MARKETROUTER>>>" -> "MarketRouter".
    """
    header = section_header.strip()

    # Handle <<<PLACEHOLDER>>> syntax (case-insensitive matching to TARGET_CONTRACTS)
    placeholder_match = _PLACEHOLDER_RE.match(header)
    if placeholder_match:
        placeholder_name = placeholder_match.group(1)
        # Try to find a case-insensitive match in TARGET_CONTRACTS
        for contract in TARGET_CONTRACTS:
            if contract.upper() == placeholder_name.upper():
                return contract
        # If no match, return the placeholder as-is (will be caught as "not in TARGET_CONTRACTS")
        return placeholder_name

    m = _CONTRACT_NAME_RE.match(header)
    return m.group(1) if m else header


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
            if arg_blob:
                args = [_arg_name_from_doc_chunk(a) for a in arg_blob.split(",")]
                args = [a for a in args if a]
            else:
                args = []
            events.append(ExpectedEvent(evt_name, args))

        by_contract[contract] = events

    return by_contract


def load_abi_events(abi_path: Path) -> Dict[str, List[List[str]]]:
    """Return mapping: eventName -> list of arg-name lists.

    We keep *all* ABI entries for a given event name (in case of overloads).
    The check passes if *any* entry matches the canonical arg-name list.
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
    ap = argparse.ArgumentParser(description="Check ABI event argument names/order vs Dune pack")
    ap.add_argument("--docs", required=True, help="Path to dune-integration-pack markdown")
    ap.add_argument("--abi-dir", required=True, help="Directory containing *.abi.json files")
    ap.add_argument(
        "--contracts",
        nargs="*",
        default=list(TARGET_CONTRACTS),
        help="Optional list of contract names to check (default: all in TARGET_CONTRACTS)",
    )
    args = ap.parse_args()

    docs_path = Path(args.docs)
    abi_dir = Path(args.abi_dir)

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
        # Common admin transparency (all Ownable2Step contracts)
        "ConfigFrozen", "GuardianChanged",
        "OwnershipTransferStarted", "OwnershipTransferred",
        # Inherited ERC-721 standard events (VeClaimNFT inherits from OZ ERC721)
        "Approval", "ApprovalForAll", "Transfer",
        # Inherited EIP-712 standard event (DelegationHub)
        "EIP712DomainChanged",
        # Admin wiring events (address-changed setters, not analytics-relevant)
        "ClaimAllHelperChanged", "DelegationHubChanged",
        # Operational monitoring / best-effort failure events
        "FurnaceCreditReserveFailed", "ShareholderAutoCompoundFailed",
        "NearSlippageLimitEntry",
        # MineCore operational events (king ETH crediting, pending withdrawals)
        "KingEthCredited", "PendingClaimWithdrawn",
        # ShareholderRoyalties dust sweep (admin housekeeping)
        "DustSwept",
        # LaunchController genesis-only events (one-time deployment)
        "DeploymentValidated", "TokenSwept",
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
