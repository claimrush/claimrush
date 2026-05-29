#!/usr/bin/env python3
"""Verify the exported ABI set is identical across networks.

Why this exists
- `abis/README.md` declares: "For v1.0.0, the Base Sepolia contract ABIs are
  expected to be identical to Base mainnet."
- Existing gates (abi-sanity, abi-strict-mode, subgraph-abi-parity) validate
  each file individually. None of them flag a missing file in one network
  folder, which is exactly how TimelockController drifted to sepolia-only.
- This gate enforces that `abis/base_mainnet/*.abi.json` and
  `abis/base_sepolia/*.abi.json` contain the same set of contract names.

Exit codes:
  0 = OK
  1 = drift detected
  2 = invalid input
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Set


def _abi_names(folder: Path) -> Set[str]:
    if not folder.is_dir():
        raise SystemExit(f"ERROR: not a directory: {folder}")
    return {p.name for p in folder.glob("*.abi.json") if p.is_file()}


def main() -> int:
    ap = argparse.ArgumentParser(description="Check ABI-set parity between two abis/<network>/ folders")
    ap.add_argument("--a", default="abis/base_mainnet", help="Reference ABI folder (default: abis/base_mainnet)")
    ap.add_argument("--b", default="abis/base_sepolia", help="Compared ABI folder (default: abis/base_sepolia)")
    args = ap.parse_args()

    folder_a = Path(args.a)
    folder_b = Path(args.b)

    set_a = _abi_names(folder_a)
    set_b = _abi_names(folder_b)

    only_a = sorted(set_a - set_b)
    only_b = sorted(set_b - set_a)

    if only_a or only_b:
        print(f"ABI set parity: FAILED ({folder_a} vs {folder_b})")
        if only_a:
            print(f"- Present in {folder_a} but missing in {folder_b}:")
            for name in only_a:
                print(f"    {name}")
        if only_b:
            print(f"- Present in {folder_b} but missing in {folder_a}:")
            for name in only_b:
                print(f"    {name}")
        print("\nFix guidance:")
        print("- If the contract ships in v1.0.0, export its ABI for both networks.")
        print("- If it is not part of v1.0.0, remove it from both folders.")
        print("- Update abis/README.md 'Required' lists to reflect the final set.")
        return 1

    print(f"ABI set parity: OK ({len(set_a)} files in both {folder_a} and {folder_b})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
