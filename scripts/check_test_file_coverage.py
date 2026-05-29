#!/usr/bin/env python3
"""Guardrail: every top-level Solidity source (and lens/) must have a test file.

Scans:
  - src/*.sol (direct children)
  - src/lens/*.sol (agent/view helpers)

Verifies that test/ contains at least one .t.sol file whose name starts
with the contract name.  Coarse-grained safety net for new contracts.

Run:
    python3 scripts/check_test_file_coverage.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "src"
TEST_DIR = ROOT / "test"

# Contracts that are intentionally test-only or have non-standard test layouts.
# MineCoreQuoter is a view-only quoter with no state mutations.
KNOWN_EXCEPTIONS: set[str] = {
    "MineCoreQuoter",
    "FurnaceQuoter",
    "FurnaceGuardHelper",
    "MineCoreHelper",
}


def _stem(p: Path) -> str:
    return p.stem


def main() -> int:
    if not SRC_DIR.is_dir():
        print("[test-coverage] ERROR: src/ directory not found", file=sys.stderr)
        return 1
    if not TEST_DIR.is_dir():
        print("[test-coverage] ERROR: test/ directory not found", file=sys.stderr)
        return 1

    # Collect top-level source contracts
    src_contracts = sorted(
        _stem(f) for f in SRC_DIR.glob("*.sol") if f.is_file()
    )

    # Also scan src/lens/*.sol — agent/view helpers should have test files.
    lens_dir = SRC_DIR / "lens"
    if lens_dir.is_dir():
        src_contracts.extend(
            sorted(_stem(f) for f in lens_dir.glob("*.sol") if f.is_file())
        )
        src_contracts.sort()

    if not src_contracts:
        print("[test-coverage] ERROR: no .sol files found in src/", file=sys.stderr)
        return 1

    # Collect all test file stems (flattened, including subdirs)
    test_stems: set[str] = set()
    for t in TEST_DIR.rglob("*.t.sol"):
        # "Furnace.t" -> stem is "Furnace.t", extract "Furnace"
        name = t.stem.replace(".t", "")
        test_stems.add(name)
        # Also handle names like "Furnace_LpOverflowDrip.t" -> "Furnace"
        base = name.split("_")[0]
        test_stems.add(base)

    errors = 0
    for contract in src_contracts:
        if contract in KNOWN_EXCEPTIONS:
            continue

        has_test = any(
            ts == contract or ts.startswith(contract + "_")
            for ts in test_stems
        )
        if not has_test:
            errors += 1
            print(
                f"[test-coverage] ERROR: src/{contract}.sol has no matching test in test/",
                file=sys.stderr,
            )

    if errors:
        print(
            f"[test-coverage] FAIL: {errors} contract(s) without test coverage.",
            file=sys.stderr,
        )
        return 1

    print(f"[test-coverage] OK ({len(src_contracts)} contracts checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
