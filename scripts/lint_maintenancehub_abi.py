#!/usr/bin/env python3
"""Lint the committed MaintenanceHub ABI against the v1.0.0 spec.

Why:
- docs/spec/maintenance-hub-spec-v1.0.0.md explicitly excludes any Baron/LP compounding.
- docs/analytics/dune-integration-pack-v1.0.0.md locks the Poked(...) event signature.

This script is intentionally narrow: it asserts the MaintenanceHub ABI contains ONLY the
v1.0.0 PokeArgs fields (no compounds/maxCompounds) and the v1.0.0 Poked event fields.

Usage:
  python3 scripts/lint_maintenancehub_abi.py
  python3 scripts/lint_maintenancehub_abi.py --abi abis/base_mainnet/MaintenanceHub.abi.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ABI = ROOT / "abis" / "base_mainnet" / "MaintenanceHub.abi.json"


EXPECTED_POKE_COMPONENTS = [
    ("offerIds", "uint256[]"),
    ("maxOffers", "uint256"),
]

EXPECTED_POKED_INPUTS = [
    ("caller", "address"),
    ("checkpointOk", "bool"),
    ("flushOk", "bool"),
    ("offersAttempted", "uint256"),
    ("offersSucceeded", "uint256"),
    ("furnaceTickSucceeded", "bool"),
    ("bountyWethForwarded", "uint256"),
]

FORBIDDEN_NAMES = {
    "compounds",
    "maxCompounds",
    "compoundsAttempted",
    "compoundsSucceeded",
}


def _err(msg: str) -> None:
    print(f"[abi-lint] ERROR: {msg}", file=sys.stderr)


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"Failed to parse JSON: {path}: {e}")


def _find_first(abi: list[dict[str, Any]], *, typ: str, name: str) -> dict[str, Any] | None:
    for item in abi:
        if item.get("type") == typ and item.get("name") == name:
            return item
    return None


def _names_types(items: list[dict[str, Any]]) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for i in items:
        out.append((str(i.get("name", "")), str(i.get("type", ""))))
    return out


def _scan_forbidden_names(obj: Any, found: set[str]) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "name" and isinstance(v, str) and v in FORBIDDEN_NAMES:
                found.add(v)
            _scan_forbidden_names(v, found)
    elif isinstance(obj, list):
        for v in obj:
            _scan_forbidden_names(v, found)


def lint(path: Path) -> int:
    abi_raw = _load_json(path)
    if not isinstance(abi_raw, list):
        _err(f"ABI root must be a JSON array, got: {type(abi_raw).__name__}")
        return 1

    abi: list[dict[str, Any]] = []
    for i, item in enumerate(abi_raw):
        if not isinstance(item, dict):
            _err(f"ABI item {i} must be an object, got: {type(item).__name__}")
            return 1
        abi.append(item)

    # Global scan for forbidden names.
    found: set[str] = set()
    _scan_forbidden_names(abi, found)
    if found:
        _err(
            "Forbidden MaintenanceHub fields present in ABI (scope violation): "
            + ", ".join(sorted(found))
        )
        return 1

    # poke(PokeArgs args)
    poke = _find_first(abi, typ="function", name="poke")
    if poke is None:
        _err("Missing function: poke")
        return 1

    inputs = poke.get("inputs")
    if not isinstance(inputs, list) or len(inputs) != 1:
        _err("poke must have exactly 1 input: (PokeArgs args)")
        return 1

    args0 = inputs[0]
    if not isinstance(args0, dict) or args0.get("name") != "args" or args0.get("type") != "tuple":
        _err("poke input must be named 'args' and have type 'tuple'")
        return 1

    comps = args0.get("components")
    if not isinstance(comps, list):
        _err("poke args tuple must include 'components'")
        return 1

    got_components = _names_types(comps)
    if got_components != EXPECTED_POKE_COMPONENTS:
        _err("poke(PokeArgs) struct fields do not match v1.0.0 spec")
        _err(f"Expected: {EXPECTED_POKE_COMPONENTS}")
        _err(f"Got:      {got_components}")
        return 1

    # Poked event
    poked = _find_first(abi, typ="event", name="Poked")
    if poked is None:
        _err("Missing event: Poked")
        return 1

    ev_inputs = poked.get("inputs")
    if not isinstance(ev_inputs, list):
        _err("Poked.inputs must be a list")
        return 1

    got_inputs = _names_types(ev_inputs)
    if got_inputs != EXPECTED_POKED_INPUTS:
        _err("Poked(...) signature does not match Dune pack / spec")
        _err(f"Expected: {EXPECTED_POKED_INPUTS}")
        _err(f"Got:      {got_inputs}")
        return 1

    print(f"[abi-lint] OK: {path}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--abi",
        default=str(DEFAULT_ABI),
        help=f"Path to MaintenanceHub ABI JSON array (default: {DEFAULT_ABI})",
    )
    args = ap.parse_args()

    path = Path(args.abi)
    return lint(path)


if __name__ == "__main__":
    raise SystemExit(main())
