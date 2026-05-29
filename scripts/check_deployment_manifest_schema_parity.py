#!/usr/bin/env python3
"""Guardrail: deployment manifest top-level JSON schemas must stay in sync.

Every deployment manifest (base_mainnet, base_sepolia, local) should share
the same set of top-level keys, except for a small allowlist of
environment-specific keys (e.g. localDex is only in local.json).

Catches:
- Keys added to one manifest but not propagated to others.
- Stale keys left behind after a refactor.

Run:
    python3 scripts/check_deployment_manifest_schema_parity.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENTS_DIR = ROOT / "deployments"

MANIFEST_FILES = sorted(DEPLOYMENTS_DIR.glob("*.json"))

# Keys that are allowed to appear in only a subset of manifests.
# Add entries here when a key is intentionally environment-specific.
ALLOWED_SUBSET_KEYS: set[str] = {
    "localDex",  # only relevant for local Anvil environment
    "safes",  # mainnet-only: real Admin/Guardian Safe multisigs. Sepolia/local do not use Safes.
}


def main() -> int:
    if len(MANIFEST_FILES) < 2:
        print("[manifest-schema-parity] SKIP: fewer than 2 manifest files found.")
        return 0

    all_keys: dict[str, set[str]] = {}
    for path in MANIFEST_FILES:
        data = json.loads(path.read_text(encoding="utf-8"))
        all_keys[path.name] = set(data.keys())

    union = set().union(*all_keys.values())
    errors = 0

    for key in sorted(union):
        if key in ALLOWED_SUBSET_KEYS:
            continue
        present_in = [name for name, keys in all_keys.items() if key in keys]
        missing_from = [name for name, keys in all_keys.items() if key not in keys]
        if missing_from:
            errors += 1
            print(
                f"[manifest-schema-parity] ERROR: key '{key}' present in "
                f"{', '.join(present_in)} but missing from {', '.join(missing_from)}",
                file=sys.stderr,
            )

    if errors:
        print(f"[manifest-schema-parity] FAIL: {errors} schema parity issue(s).", file=sys.stderr)
        return 1

    names = ", ".join(p.name for p in MANIFEST_FILES)
    print(f"[manifest-schema-parity] OK ({names}; {len(union)} keys)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
