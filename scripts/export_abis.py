#!/usr/bin/env python3
"""Export ABI arrays from Foundry build artifacts.

Usage:
  forge build
  python3 scripts/export_abis.py --network base_mainnet --outdir abis/base_mainnet

This script extracts the `abi` field from Foundry's `out/**/<Contract>.json` artifacts and writes
`<Contract>.abi.json` files containing the ABI array only.

This is designed for Dune / indexer consumption.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import List, Optional

FORGE_INSPECT_TIMEOUT_SEC = 60


DEFAULT_CONTRACTS: List[str] = [
    "ClaimToken",
    "VeClaimNFT",
    "MineCore",
    "ShareholderRoyalties",
    "Furnace",
    "FurnaceQuoter",
    "MineCoreQuoter",
    "LpStakingVault7D",
    "MarketRouter",
    "EntryTokenRegistry",
    "DexAdapter",
    "ClaimAllHelper",
    "DelegationHub",
    "GenesisLPVault24M",
    "LaunchController",
    "MaintenanceHub",
    "AgentLens",
]


def find_foundry_artifact(out_dir: Path, contract: str) -> Optional[Path]:
    # Prefer the common Foundry layout when the contract lives in a file named
    # `<Contract>.sol` (which is the convention in this repo).
    #
    # This avoids non-deterministic selection when multiple artifacts exist with
    # the same contract name (e.g. older builds, duplicates under test/fixtures).
    preferred = out_dir / f"{contract}.sol" / f"{contract}.json"
    if preferred.exists():
        return preferred

    # Common Foundry layout: out/<File>.sol/<Contract>.json
    matches = sorted(out_dir.glob(f"**/{contract}.json"), key=lambda path: path.as_posix())
    # Prefer exact match in a folder named *.sol
    for m in matches:
        if m.parent.name.endswith(".sol"):
            return m
    return matches[0] if matches else None


def forge_inspect_abi(contract: str) -> Optional[list]:
    """Return ABI array via `forge inspect <contract> abi`.

    This is the most reliable way to avoid ambiguity when multiple Foundry artifacts
    exist for the same contract name.
    """
    try:
        completed = subprocess.run(
            ["forge", "inspect", contract, "abi"],
            check=False,
            text=True,
            stderr=subprocess.STDOUT,
            stdout=subprocess.PIPE,
            timeout=FORGE_INSPECT_TIMEOUT_SEC,
        )
    except Exception:
        return None
    if completed.returncode != 0:
        return None
    out = completed.stdout or ""

    # `forge inspect` is usually pure JSON, but to be robust (warnings, etc),
    # extract the first JSON array from the output.
    start = out.find("[")
    end = out.rfind("]")
    if start == -1 or end == -1 or end < start:
        return None
    blob = out[start : end + 1]
    try:
        return json.loads(blob)
    except Exception:
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--network", required=True, help="Network label (informational only)")
    ap.add_argument("--outdir", required=True, help="Output directory for ABI JSON arrays")
    ap.add_argument("--foundry-out", default="out", help="Foundry output directory (default: out)")
    ap.add_argument("--contracts", nargs="*", default=DEFAULT_CONTRACTS, help="Contracts to export")
    args = ap.parse_args()

    out_dir = Path(args.foundry_out)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    missing: List[str] = []

    for contract in args.contracts:
        abi = forge_inspect_abi(contract)
        # Treat an empty ABI as a failure and fall back to artifacts. This can happen when
        # `forge inspect` resolves the wrong target or prints a stub/empty interface.
        if abi is None or len(abi) == 0:
            artifact = find_foundry_artifact(out_dir, contract)
            if artifact is None:
                missing.append(contract)
                continue

            with artifact.open("r", encoding="utf-8") as f:
                data = json.load(f)

            abi = data.get("abi")
            if abi is None:
                raise RuntimeError(f"No 'abi' field in artifact: {artifact}")

        out_path = outdir / f"{contract}.abi.json"
        with out_path.open("w", encoding="utf-8") as f:
            json.dump(abi, f, indent=2)
            f.write("\n")

        print(f"Exported {contract} ABI -> {out_path}")

    if missing:
        print("\nWARNING: Missing artifacts for:")
        for c in missing:
            print(f"- {c}")
        print("\nThis is expected if the contract is not compiled yet or not in the repo.")

    print("\nDone.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
