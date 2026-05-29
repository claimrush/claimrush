#!/usr/bin/env python3
"""Fail-fast guard for EVM contract size limits.

Why this exists
- Local Anvil can be started with --disable-code-size-limit.
- Foundry tests can stay green even if runtime bytecode exceeds EIP-170 (24,576 bytes).
- That makes the artifact undeployable on Base mainnet.

This script reads Foundry build artifacts in ./out/** and checks:
- Runtime (deployedBytecode) size against EIP-170.
- Initcode (bytecode) size against EIP-3860.

Notes
- Initcode size limit is checked against the compiler-produced creation bytecode only.
  The actual initcode at deployment time appends constructor args, so keep some headroom.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


EIP170_RUNTIME_LIMIT_BYTES = 24_576
EIP3860_INITCODE_LIMIT_BYTES = 49_152

# Contracts we expect to be deployable to Base/Mainnet for v1.
# (Intentionally excludes src/mocks/** and local dex helpers.)
DEFAULT_CONTRACTS = [
    "ClaimToken",
    "VeClaimNFT",
    "MineCore",
    "MineCoreHelper",
    "MineCoreQuoter",
    "ShareholderRoyalties",
    "Furnace",
    "FurnaceQuoter",
    "FurnaceGuardHelper",
    "MarketRouter",
    "ClaimAllHelper",
    "EntryTokenRegistry",
    "DexAdapter",
    "MaintenanceHub",
    "LpStakingVault7D",
    "LaunchController",
    "GenesisLPVault24M",
    "DelegationHub",
    "AgentLens",
]


@dataclass(frozen=True)
class SizeResult:
    name: str
    artifact_path: Optional[Path]
    runtime_bytes: Optional[int]
    initcode_bytes: Optional[int]


def _hex_to_bytes_len(hexstr: Optional[str]) -> Optional[int]:
    if hexstr is None:
        return None
    if not isinstance(hexstr, str):
        return None

    h = hexstr.strip()
    if h.startswith("0x"):
        h = h[2:]
    if h == "":
        return 0
    if len(h) % 2 != 0:
        raise ValueError(f"Odd-length hex string ({len(h)} chars)")
    return len(h) // 2


def _extract_bytecode_object(field: Any) -> Optional[str]:
    """Foundry artifacts typically encode bytecode as {'object': '0x...'}.

    Some tools also provide a plain string. Handle both.
    """

    if field is None:
        return None
    if isinstance(field, str):
        return field
    if isinstance(field, dict):
        obj = field.get("object")
        if isinstance(obj, str):
            return obj
    return None


def locate_artifact(out_dir: Path, contract_name: str) -> Optional[Path]:
    # Common Foundry path: out/<File>.sol/<Contract>.json, where <File> usually == <Contract>.
    direct = out_dir / f"{contract_name}.sol" / f"{contract_name}.json"
    if direct.exists():
        return direct

    # Fallback: search by filename.
    matches = list(out_dir.rglob(f"{contract_name}.json"))
    if not matches:
        return None

    # Prefer the canonical folder name if present.
    preferred = [p for p in matches if p.parent.name == f"{contract_name}.sol"]
    if preferred:
        # If multiple, prefer the shortest path (heuristic).
        preferred.sort(key=lambda p: len(str(p)))
        return preferred[0]

    matches.sort(key=lambda p: len(str(p)))
    return matches[0]


def read_sizes(artifact_path: Path, contract_name: str) -> SizeResult:
    data = json.loads(artifact_path.read_text())

    deployed_bc = _extract_bytecode_object(data.get("deployedBytecode"))
    create_bc = _extract_bytecode_object(data.get("bytecode"))

    runtime_bytes = _hex_to_bytes_len(deployed_bc)
    initcode_bytes = _hex_to_bytes_len(create_bc)

    return SizeResult(
        name=contract_name,
        artifact_path=artifact_path,
        runtime_bytes=runtime_bytes,
        initcode_bytes=initcode_bytes,
    )


def main() -> int:
    p = argparse.ArgumentParser(description="Check Foundry artifacts for EVM contract size limits")
    p.add_argument(
        "--out",
        default="out",
        help="Foundry output directory (default: ./out)",
    )
    p.add_argument(
        "--contracts",
        nargs="*",
        default=DEFAULT_CONTRACTS,
        help="Contract names to check (default: core deployable contracts)",
    )
    p.add_argument(
        "--max-runtime-bytes",
        type=int,
        default=EIP170_RUNTIME_LIMIT_BYTES,
        help=f"Runtime code size limit (default: {EIP170_RUNTIME_LIMIT_BYTES})",
    )
    p.add_argument(
        "--max-initcode-bytes",
        type=int,
        default=EIP3860_INITCODE_LIMIT_BYTES,
        help=f"Initcode size limit (default: {EIP3860_INITCODE_LIMIT_BYTES})",
    )
    p.add_argument(
        "--no-initcode-check",
        action="store_true",
        help="Skip the initcode (EIP-3860) size check",
    )
    p.add_argument(
        "--fail",
        action="store_true",
        help="Exit non-zero when limits are exceeded (default: warn-only). "
        "You can also set CODESIZE_ENFORCE=1.",
    )

    args = p.parse_args()
    enforce = args.fail or os.environ.get("CODESIZE_ENFORCE", "").strip() == "1"

    out_dir = Path(args.out)
    if not out_dir.exists():
        print(f"ERROR: {out_dir} does not exist. Run 'forge build' first.", file=sys.stderr)
        return 2

    results: list[SizeResult] = []
    missing: list[str] = []

    for name in args.contracts:
        ap = locate_artifact(out_dir, name)
        if ap is None:
            missing.append(name)
            continue
        try:
            results.append(read_sizes(ap, name))
        except Exception as e:
            print(f"ERROR: failed to parse {ap} for {name}: {e}", file=sys.stderr)
            return 2

    if missing:
        level = "ERROR" if enforce else "WARN"
        print(f"{level}: missing artifacts for:")
        for name in missing:
            print(f"  - {name}")
        print("(If these contracts are intentionally not built, update scripts/check_contract_sizes.py.)")
        print("")
        if enforce:
            print(
                "ERROR: refusing to pass code-size preflight with missing artifacts. Run 'forge build' or fix the contract allowlist.",
                file=sys.stderr,
            )
            return 1

    max_runtime = int(args.max_runtime_bytes)
    max_init = int(args.max_initcode_bytes)

    # Pretty print.
    print("== Contract size check ==")
    print(f"Runtime limit (EIP-170): {max_runtime} bytes")
    if args.no_initcode_check:
        print("Initcode limit (EIP-3860): SKIPPED")
    else:
        print(f"Initcode limit (EIP-3860): {max_init} bytes")
    print("")

    any_fail = False

    # Header
    print(f"{'Contract':24} {'Runtime':>10} {'Initcode':>10} Status")
    print(f"{'-'*24} {'-'*10} {'-'*10} {'-'*16}")

    for r in results:
        runtime = r.runtime_bytes if r.runtime_bytes is not None else 0
        initcode = r.initcode_bytes if r.initcode_bytes is not None else 0

        status_parts = []
        if r.runtime_bytes is None:
            status_parts.append("NO_RUNTIME")
        elif runtime > max_runtime:
            status_parts.append("RUNTIME_TOO_LARGE")

        if not args.no_initcode_check:
            if r.initcode_bytes is None:
                status_parts.append("NO_INIT")
            elif initcode > max_init:
                status_parts.append("INIT_TOO_LARGE")

        status = "OK" if not status_parts else ",".join(status_parts)

        if status != "OK":
            any_fail = True

        print(f"{r.name:24} {runtime:10} {initcode:10} {status}")

    print("")

    if any_fail:
        msg = (
            "WARN: One or more deployable contracts exceed EVM size limits. "
            "This will block Base/Mainnet deployment."
        )
        if enforce:
            print(msg.replace("WARN:", "ERROR:"), file=sys.stderr)
            return 1
        print(msg, file=sys.stderr)
        return 0

    print("OK: All checked contracts are within size limits.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
