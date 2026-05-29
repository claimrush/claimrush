#!/usr/bin/env python3
"""Sanity-check exported ABI JSON files under abis/**.

Why this exists
- ABI files are consumed by indexers (subgraph/Dune) and downstream client decoders.
- A single malformed entry can break tooling (ex: missing function name).
- Duplicate event signatures can confuse decoders and should never ship.

Checks
- ABI JSON parses and is a list.
- `type=function|error` entries have a non-empty `name`.
- Function/error inputs MUST NOT include `indexed` (illegal in ABI).
- Duplicate signatures are rejected:
  - functions/errors: name + input types
  - events: name + input types (+ indexed pattern)
  - additionally, we reject multiple events sharing the same topic signature
    (name + input types) even if indexed flags differ.

Usage:
  python3 scripts/check_abi_sanity.py --abi-dir abis/base_mainnet
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"Invalid JSON: {e}")


def _types_from_inputs(inputs: List[Dict[str, Any]], *, where: str, errors: List[str]) -> List[str]:
    types: List[str] = []
    for j, inp in enumerate(inputs):
        if not isinstance(inp, dict):
            errors.append(f"{where}: inputs[{j}] is not an object")
            continue
        t = inp.get("type")
        if not t or not isinstance(t, str):
            errors.append(f"{where}: inputs[{j}] missing/invalid 'type'")
            continue
        types.append(t)
    return types


def _check_one_abi_file(path: Path) -> List[str]:
    errors: List[str] = []

    try:
        abi = _load_json(path)
    except ValueError as e:
        return [f"{path}: {e}"]

    if not isinstance(abi, list):
        return [f"{path}: ABI root must be a list, got {type(abi).__name__}"]

    seen_fn: Set[str] = set()
    seen_err: Set[str] = set()
    seen_event_full: Set[str] = set()
    seen_event_topic: Set[str] = set()

    for i, item in enumerate(abi):
        if not isinstance(item, dict):
            errors.append(f"{path}: item[{i}] is not an object")
            continue

        typ = item.get("type")
        name = item.get("name")

        if not typ or not isinstance(typ, str):
            errors.append(f"{path}: item[{i}] missing/invalid 'type'")
            continue

        # Functions and errors must be named.
        if typ in ("function", "error"):
            if not name or not isinstance(name, str):
                errors.append(f"{path}: {typ} item[{i}] missing/invalid 'name'")
                continue

            inputs = item.get("inputs", [])
            if not isinstance(inputs, list):
                errors.append(f"{path}: {typ} {name} item[{i}] has non-list 'inputs'")
                continue

            # ABI rule: only event inputs can be indexed.
            for j, inp in enumerate(inputs):
                if isinstance(inp, dict) and "indexed" in inp:
                    errors.append(
                        f"{path}: {typ} {name} item[{i}] inputs[{j}] has illegal 'indexed' field"
                    )

            in_types = _types_from_inputs(inputs, where=f"{path}:{typ}:{name}:item[{i}]", errors=errors)
            sig = f"{name}({','.join(in_types)})"
            if typ == "function":
                if sig in seen_fn:
                    errors.append(f"{path}: duplicate function signature: {sig}")
                seen_fn.add(sig)
            else:
                if sig in seen_err:
                    errors.append(f"{path}: duplicate error signature: {sig}")
                seen_err.add(sig)

        elif typ == "event":
            if not name or not isinstance(name, str):
                errors.append(f"{path}: event item[{i}] missing/invalid 'name'")
                continue

            inputs = item.get("inputs", [])
            if not isinstance(inputs, list):
                errors.append(f"{path}: event {name} item[{i}] has non-list 'inputs'")
                continue

            in_types = _types_from_inputs(inputs, where=f"{path}:event:{name}:item[{i}]", errors=errors)
            indexed_flags: List[str] = []
            for inp in inputs:
                if isinstance(inp, dict):
                    indexed_flags.append("1" if bool(inp.get("indexed", False)) else "0")
                else:
                    indexed_flags.append("0")

            topic_sig = f"{name}({','.join(in_types)})"
            full_sig = f"{topic_sig}|{''.join(indexed_flags)}"

            if topic_sig in seen_event_topic:
                errors.append(f"{path}: duplicate event topic signature: {topic_sig}")
            else:
                seen_event_topic.add(topic_sig)

            if full_sig in seen_event_full:
                errors.append(f"{path}: duplicate event signature: {full_sig}")
            else:
                seen_event_full.add(full_sig)

        else:
            # constructor / fallback / receive are fine; ignore.
            continue

    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description="Sanity-check ABI JSON files")
    ap.add_argument("--abi-dir", required=True, help="Directory containing *.abi.json files")
    args = ap.parse_args()

    abi_dir = Path(args.abi_dir)
    if not abi_dir.exists() or not abi_dir.is_dir():
        print(f"ABI sanity: FAILED (not a directory): {abi_dir}")
        return 2

    files = sorted(abi_dir.glob("*.abi.json"))
    if not files:
        print(f"ABI sanity: FAILED (no *.abi.json files found): {abi_dir}")
        return 2

    all_errors: List[str] = []
    for f in files:
        all_errors.extend(_check_one_abi_file(f))

    if all_errors:
        print("ABI sanity: FAILED")
        for e in sorted(all_errors):
            print("-", e)
        print("\nFix guidance:")
        print("- Regenerate ABIs via: make abis-export")
        print("- Or edit the offending ABI JSON entry so it is valid and deterministic")
        return 1

    print(f"ABI sanity: OK ({abi_dir})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
