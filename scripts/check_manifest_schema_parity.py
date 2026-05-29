#!/usr/bin/env python3
"""Verify deployment-manifest schema parity across networks.

Why this exists
- deployments/<network>.json is treated as the canonical configuration surface.
- Derived artifacts (docs + downstream mirrors) assume stable key structure.
- If network manifests drift (missing keys), tooling breaks and deployments become ambiguous.
- When comparing against `deployments/local.json`, known local-only supplements
  (`contracts.AgentLens`, `localDex`) are ignored so parity focuses on the shared runtime surface.
- When comparing against `deployments/base_mainnet.json`, known mainnet-only supplements
  (`safes`: real Admin/Guardian Safe multisigs) are ignored for the same reason — Sepolia and
  local environments do not use real Safe multisigs.

This check enforces that two manifests have the same nested key paths.
It is intentionally strict: values may differ, but the shape must not.

Usage:
  python3 scripts/check_manifest_schema_parity.py \
    --a deployments/base_mainnet.json \
    --b deployments/base_sepolia.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, List, Set


KNOWN_LOCAL_ONLY_PREFIXES = (
    "contracts.AgentLens",
    "localDex",
)

KNOWN_MAINNET_ONLY_PREFIXES = (
    "safes",
)


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"{path}: invalid JSON: {e}")


def _flatten_keys(obj: Any, prefix: str, out: Set[str]) -> None:
    """Collect nested key paths.

    Rules:
    - Dict keys become path segments.
    - Lists are treated as leaf values (we do not enforce element schema).
    """

    if isinstance(obj, dict):
        for k, v in obj.items():
            if not isinstance(k, str):
                # JSON object keys should always be strings.
                continue
            p = f"{prefix}.{k}" if prefix else k
            out.add(p)
            _flatten_keys(v, p, out)
        return

    if isinstance(obj, list):
        out.add(f"{prefix}[]" if prefix else "[]")
        return

    # Primitive leaf: nothing else to add.
    return


def _looks_local(path: Path, data: Any) -> bool:
    if path.stem == "local":
        return True
    if isinstance(data, dict) and data.get("chain") == "local":
        return True
    return False


def _looks_mainnet(path: Path, data: Any) -> bool:
    if path.stem == "base_mainnet":
        return True
    if isinstance(data, dict) and data.get("chain") == "base_mainnet":
        return True
    if isinstance(data, dict) and data.get("chainId") == 8453:
        return True
    return False


def _drop_prefixes(keys: Set[str], prefixes: tuple[str, ...]) -> Set[str]:
    out: Set[str] = set()
    for key in keys:
        if any(key == prefix or key.startswith(f"{prefix}.") for prefix in prefixes):
            continue
        out.add(key)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Check deployments JSON schema parity")
    ap.add_argument("--a", required=True, help="First deployments manifest JSON")
    ap.add_argument("--b", required=True, help="Second deployments manifest JSON")
    args = ap.parse_args()

    pa = Path(args.a)
    pb = Path(args.b)

    try:
        a = _load_json(pa)
        b = _load_json(pb)
    except ValueError as e:
        print(f"Manifest schema parity: FAILED\n- {e}")
        return 2

    keys_a: Set[str] = set()
    keys_b: Set[str] = set()
    _flatten_keys(a, "", keys_a)
    _flatten_keys(b, "", keys_b)

    local_a = _looks_local(pa, a)
    local_b = _looks_local(pb, b)
    if local_a ^ local_b:
        keys_a = _drop_prefixes(keys_a, KNOWN_LOCAL_ONLY_PREFIXES)
        keys_b = _drop_prefixes(keys_b, KNOWN_LOCAL_ONLY_PREFIXES)

    mainnet_a = _looks_mainnet(pa, a)
    mainnet_b = _looks_mainnet(pb, b)
    if mainnet_a ^ mainnet_b:
        keys_a = _drop_prefixes(keys_a, KNOWN_MAINNET_ONLY_PREFIXES)
        keys_b = _drop_prefixes(keys_b, KNOWN_MAINNET_ONLY_PREFIXES)

    only_a = sorted(keys_a - keys_b)
    only_b = sorted(keys_b - keys_a)

    if only_a or only_b:
        print("Manifest schema parity: FAILED")
        if only_a:
            print(f"- Present only in {pa}:")
            for k in only_a:
                print(f"  - {k}")
        if only_b:
            print(f"- Present only in {pb}:")
            for k in only_b:
                print(f"  - {k}")
        print("\nFix guidance:")
        print("- Align deployments/*.json key structure across networks (add missing keys with 0/empty placeholders).")
        print("- For local comparisons, keep shared runtime keys aligned; local-only AgentLens/localDex keys are ignored.")
        print("- Then run: bash scripts/sync_deployments_all.sh --write")
        return 1

    print("Manifest schema parity: OK")
    if local_a ^ local_b:
        print("- Ignored known local-only supplements: contracts.AgentLens, localDex")
    if mainnet_a ^ mainnet_b:
        print("- Ignored known mainnet-only supplements: safes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
