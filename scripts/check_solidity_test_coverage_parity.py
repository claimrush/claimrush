#!/usr/bin/env python3
"""Guardrail: every deployable src/*.sol and src/vault/*.sol contract must have a test.

This is a structural check, not a coverage check.  It ensures that when a new
contract is added to src/ (excluding interfaces/, lib/, lens/, genesis/) or to
src/vault/ it has at least one corresponding test file that imports it.

Run:
    python3 scripts/check_solidity_test_coverage_parity.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "src"
TEST_DIR = ROOT / "test"

# Directories under src/ that are not deployable contracts.
EXCLUDE_DIRS = {"interfaces", "lib", "lens", "genesis", "mocks"}

# Files that are intentionally test-free (document reasons here).
ALLOWLIST: set[str] = {
    # View-only quoter contracts: read-only helpers whose logic is exercised
    # transitively by the contracts that delegate to them.
    # If quoters gain mutating functions, remove from this allowlist.
    "FurnaceQuoter.sol",
    "MineCoreQuoter.sol",
    # Guard/helper contracts auto-deployed by their parent; logic is exercised
    # transitively through Furnace and MineCore test suites.
    "FurnaceGuardHelper.sol",
    "MineCoreHelper.sol",
}


def _deployable_sources() -> list[Path]:
    """Return all top-level src/*.sol files that represent deployable contracts."""
    sources: list[Path] = []
    for sol in SRC_DIR.glob("*.sol"):
        if sol.name in ALLOWLIST:
            continue
        sources.append(sol)
    # Also scan src/vault/*.sol — vault contracts are deployable.
    vault_dir = SRC_DIR / "vault"
    if vault_dir.is_dir():
        for sol in vault_dir.glob("*.sol"):
            if sol.name not in ALLOWLIST:
                sources.append(sol)
    return sorted(sources)


def _test_imports() -> dict[str, set[str]]:
    """Build a map from imported contract name to set of test files that import it."""
    import_re = re.compile(r'import\s+\{[^}]*\}\s+from\s+"src/([^"]+)"')
    import_plain_re = re.compile(r'import\s+"src/([^"]+)"')
    result: dict[str, set[str]] = {}
    for test_file in TEST_DIR.rglob("*.sol"):
        text = test_file.read_text(encoding="utf-8", errors="replace")
        for m in import_re.finditer(text):
            imported = m.group(1).split("/")[-1]
            result.setdefault(imported, set()).add(str(test_file.relative_to(ROOT)))
        for m in import_plain_re.finditer(text):
            imported = m.group(1).split("/")[-1]
            result.setdefault(imported, set()).add(str(test_file.relative_to(ROOT)))
    return result


def main() -> int:
    sources = _deployable_sources()
    test_map = _test_imports()
    errors = 0
    checked = 0

    for src in sources:
        checked += 1
        name = src.name
        if name not in test_map or not test_map[name]:
            errors += 1
            print(
                f"[sol-test-parity] ERROR: {name} has no test file that imports it. "
                f"Add a test file or add {name} to ALLOWLIST in this script.",
                file=sys.stderr,
            )

    if errors:
        print(
            f"[sol-test-parity] FAIL: {errors}/{checked} contract(s) missing test coverage.",
            file=sys.stderr,
        )
        return 1

    print(f"[sol-test-parity] OK ({checked} contracts checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
