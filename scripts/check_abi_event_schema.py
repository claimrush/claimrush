#!/usr/bin/env python3
"""Check ABI event signatures match the v1.0.0 canonical spec.

Why this exists
- Offchain decoders (Dune, subgraphs) require deterministic event shapes.
- ABI drift (arg order/type/indexed flags) breaks decoding.

Canonical sources
- docs/spec/spec-v1.0.0.md §11.2 (typed signatures + indexed flags)
- docs/spec/maintenance-hub-spec-v1.0.0.md (MaintenanceHub.Poked)

Usage
  python3 scripts/check_abi_event_schema.py --network base_mainnet

Exit code
- 0 if all checked events match
- 1 if any mismatch is found
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


@dataclass(frozen=True)
class CanonicalInput:
    type: str
    indexed: bool


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _extract_section(text: str, start_pat: str, end_pat: str) -> str:
    m = re.search(start_pat + r"(.*?)" + end_pat, text, flags=re.S)
    if not m:
        raise ValueError(f"Section not found using start={start_pat!r} end={end_pat!r}")
    return m.group(1)


def _parse_event_sig(sig: str) -> tuple[str, List[CanonicalInput]]:
    """Parse `event Name(type indexed? name, ...)` into canonical inputs.

    Note: we ignore parameter names entirely; decoding depends on (order, types, indexed flags).
    """

    sig = sig.strip()
    # remove trailing semicolon if present
    sig = sig.rstrip(";")

    m = re.match(r"^event\s+([A-Za-z0-9_]+)\s*\((.*)\)\s*$", sig)
    if not m:
        raise ValueError(f"Unparseable event signature: {sig!r}")

    name = m.group(1)
    params = m.group(2).strip()

    if params == "":
        return name, []

    inputs: List[CanonicalInput] = []
    # split by commas not inside parentheses (no tuples expected in events here)
    parts = [p.strip() for p in params.split(",")]
    for p in parts:
        # Example: `address indexed user` or `uint256 amountEth`
        # Keep it permissive: type is first token, "indexed" is optional.
        tokens = p.split()
        if len(tokens) < 2:
            raise ValueError(f"Bad param fragment: {p!r} in {sig!r}")
        typ = tokens[0]
        indexed = "indexed" in tokens[1:]
        inputs.append(CanonicalInput(type=typ, indexed=indexed))

    return name, inputs


def _load_canonical_events_from_spec(spec_path: Path) -> Dict[str, Dict[str, List[CanonicalInput]]]:
    text = spec_path.read_text(encoding="utf-8")

    # §11.2 events list
    section = _extract_section(
        text,
        r"### 11\.2 Events \(for analytics\)\n",
        r"\n### 11\.3",
    )

    canonical: Dict[str, Dict[str, List[CanonicalInput]]] = {}
    current_group: Optional[str] = None

    for raw in section.splitlines():
        line = raw.strip()

        # group header like: - **EntryTokenRegistry** (allowlist + routing transparency)
        if line.startswith("- **"):
            g = re.sub(r"^- \*\*", "", line)
            g = g.split("**", 1)[0]
            current_group = g.strip()
            canonical.setdefault(current_group, {})
            continue

        if "`event " not in line:
            continue

        # extract content between backticks
        m = re.search(r"`(event\s+[^`]+)`", line)
        if not m:
            continue

        if not current_group:
            raise ValueError(f"Found event without group header: {line!r}")

        event_sig = m.group(1)
        event_name, inputs = _parse_event_sig(event_sig)
        canonical[current_group][event_name] = inputs

    return canonical


def _load_canonical_events_for_maintenance_hub(mh_spec_path: Path) -> Dict[str, Dict[str, List[CanonicalInput]]]:
    text = mh_spec_path.read_text(encoding="utf-8")

    # Find the Events section line that contains `Poked(...)`
    # Example:
    # - `Poked(address caller, uint256 offersAttempted, ...)`
    m = re.search(r"`Poked\(([^`]+)\)`", text)
    if not m:
        raise ValueError("Could not find `Poked(...)` signature in maintenance hub spec")

    sig_inside = m.group(1)
    event_sig = f"event Poked({sig_inside});"
    name, inputs = _parse_event_sig(event_sig)

    return {"MaintenanceHub": {name: inputs}}


def _load_abi_events(abi_path: Path) -> Dict[str, List[dict]]:
    abi = json.loads(abi_path.read_text(encoding="utf-8"))
    events: Dict[str, List[dict]] = {}
    for item in abi:
        if item.get("type") != "event":
            continue
        events.setdefault(item.get("name"), []).append(item)
    return events


def _compare_event(contract: str, event: str, expected: List[CanonicalInput], actual_event: dict) -> List[str]:
    errs: List[str] = []

    actual_inputs = actual_event.get("inputs", [])

    if len(actual_inputs) != len(expected):
        errs.append(
            f"{contract}.{event}: arg count mismatch (expected {len(expected)}, got {len(actual_inputs)})"
        )
        return errs

    for i, (exp, act) in enumerate(zip(expected, actual_inputs)):
        act_type = act.get("type")
        act_indexed = bool(act.get("indexed", False))

        if act_type != exp.type:
            errs.append(
                f"{contract}.{event}[{i}]: type mismatch (expected {exp.type}, got {act_type})"
            )

        if act_indexed != exp.indexed:
            errs.append(
                f"{contract}.{event}[{i}]: indexed mismatch (expected {exp.indexed}, got {act_indexed})"
            )

    return errs


def main() -> int:
    parser = argparse.ArgumentParser(description="Check ABI event signatures match v1.0.0 canonical spec")
    parser.add_argument(
        "--network",
        default="base_mainnet",
        help="ABI folder name under abis/ (default: base_mainnet)",
    )
    parser.add_argument(
        "--abi-dir",
        default=None,
        help="Override ABI directory (defaults to abis/<network>)",
    )

    args = parser.parse_args()

    root = _repo_root()

    abi_dir = Path(args.abi_dir) if args.abi_dir else root / "abis" / args.network

    # Canonical sources
    spec_path = root / "docs" / "spec" / "spec-v1.0.0.md"
    mh_spec_path = root / "docs" / "spec" / "maintenance-hub-spec-v1.0.0.md"

    canonical = _load_canonical_events_from_spec(spec_path)
    canonical.update(_load_canonical_events_for_maintenance_hub(mh_spec_path))

    # Only check contracts that should have ABI files.
    # Ignore helper headings like "Common admin / transparency".
    expected_contracts = [
        "EntryTokenRegistry",
        "VeClaimNFT",
        "MineCore",
        "ShareholderRoyalties",
        "Furnace",
        "LpStakingVault7D",
        "LaunchController",
        "GenesisLPVault24M",
        "MarketRouter",
        "MaintenanceHub",
    ]

    errors: List[str] = []

    for contract in expected_contracts:
        if contract not in canonical:
            errors.append(f"Missing canonical event spec for contract: {contract}")
            continue

        abi_path = abi_dir / f"{contract}.abi.json"
        if not abi_path.exists():
            errors.append(f"Missing ABI file: {abi_path}")
            continue

        abi_events = _load_abi_events(abi_path)

        for event_name, exp_inputs in canonical[contract].items():
            matches = abi_events.get(event_name, [])
            if not matches:
                errors.append(f"{contract}.{event_name}: missing from ABI")
                continue

            # If multiple events share a name (overloads), compare against all and accept if any matches.
            per_match_errors: List[List[str]] = []
            for ev in matches:
                ev_errs = _compare_event(contract, event_name, exp_inputs, ev)
                if not ev_errs:
                    per_match_errors = []
                    break
                per_match_errors.append(ev_errs)

            if per_match_errors:
                # show the best (shortest) mismatch list
                best = min(per_match_errors, key=len)
                errors.extend(best)

    if errors:
        print("ABI event schema check: FAILED")
        for e in errors:
            print("-", e)
        print("\nFix guidance:")
        print("- Update the Solidity event declaration/emission to match the canonical spec.")
        print("- Regenerate ABIs via: python3 scripts/export_abis.py --network base_mainnet --outdir abis/base_mainnet")
        return 1

    print("ABI event schema check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
