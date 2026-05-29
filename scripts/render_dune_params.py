#!/usr/bin/env python3
"""Render suggested Dune parameter values from a deployments/*.json manifest.

This repo ships Dune SQL templates under `analytics/dune/` that rely on start-block
filters for performance.

Source of truth:
  - deployments/<network>.json (ex: deployments/base_mainnet.json)

This script prints copy/paste-friendly parameter defaults for Dune.

Usage:
  python3 scripts/render_dune_params.py deployments/base_mainnet.json

Formats:
  --format md   (default)  Markdown table
  --format env            KEY=VALUE lines
  --format json           JSON object

Exit codes:
  0 = success
  2 = invalid input (missing/invalid manifest)
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


ZERO_ADDR = "0x0000000000000000000000000000000000000000"


@dataclass(frozen=True)
class Param:
    name: str
    value: Optional[Any]
    note: str
    dune_type: str  # display only ("integer", "varbinary", "timestamp", ...)


def _norm_addr(addr: str) -> str:
    return (addr or "").strip().lower()


def _is_zero_addr(addr: str) -> bool:
    return _norm_addr(addr) == ZERO_ADDR


def _load_manifest(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f"ERROR: failed to read manifest JSON: {path}: {e}")


def _contract_meta(manifest: Dict[str, Any], contract_name: str) -> Dict[str, Any]:
    contracts = manifest.get("contracts")
    if not isinstance(contracts, dict):
        return {}
    meta = contracts.get(contract_name)
    return meta if isinstance(meta, dict) else {}


def _contract_addr(manifest: Dict[str, Any], contract_name: str) -> Optional[str]:
    addr = _contract_meta(manifest, contract_name).get("address")
    if not isinstance(addr, str) or not addr.strip():
        return None
    if _is_zero_addr(addr):
        return None
    return addr


def _contract_start_block(manifest: Dict[str, Any], contract_name: str) -> Optional[int]:
    meta = _contract_meta(manifest, contract_name)
    # Canonical key: startBlock
    sb = meta.get("startBlock")
    # Some local manifests use blockNumber for non-indexed helper objects.
    if sb is None:
        sb = meta.get("blockNumber")
    if isinstance(sb, int) and sb > 0:
        return sb
    # Accept numeric strings defensively.
    if isinstance(sb, str):
        try:
            v = int(sb)
            return v if v > 0 else None
        except Exception:  # noqa: BLE001
            return None
    return None


def _min_nonzero(values: List[Optional[int]]) -> Optional[int]:
    xs = [v for v in values if isinstance(v, int) and v > 0]
    return min(xs) if xs else None


def _protocol_param(manifest: Dict[str, Any], dotted: str) -> Optional[Any]:
    cur: Any = manifest
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def build_params(manifest: Dict[str, Any]) -> List[Param]:
    # Required leaderboards + UI list templates
    params: List[Param] = []

    params.append(
        Param(
            name="MINECORE_START_BLOCK",
            value=_contract_start_block(manifest, "MineCore"),
            note="deployments.<network>.json contracts.MineCore.startBlock",
            dune_type="integer",
        )
    )
    params.append(
        Param(
            name="FURNACE_START_BLOCK",
            value=_contract_start_block(manifest, "Furnace"),
            note="deployments.<network>.json contracts.Furnace.startBlock",
            dune_type="integer",
        )
    )
    params.append(
        Param(
            name="SHAREHOLDER_ROYALTIES_START_BLOCK",
            value=_contract_start_block(manifest, "ShareholderRoyalties"),
            note="deployments.<network>.json contracts.ShareholderRoyalties.startBlock",
            dune_type="integer",
        )
    )
    params.append(
        Param(
            name="VECLAIMNFT_START_BLOCK",
            value=_contract_start_block(manifest, "VeClaimNFT"),
            note="deployments.<network>.json contracts.VeClaimNFT.startBlock",
            dune_type="integer",
        )
    )
    params.append(
        Param(
            name="MARKETROUTER_START_BLOCK",
            value=_contract_start_block(manifest, "MarketRouter"),
            note="deployments.<network>.json contracts.MarketRouter.startBlock",
            dune_type="integer",
        )
    )

    # Two-registry model (v1.0.0): choose the minimum non-zero start block.
    # This is safe as a performance filter, and avoids missing events if one
    # registry was deployed earlier.
    reg_start = _min_nonzero(
        [
            _contract_start_block(manifest, "MineCoreEntryTokenRegistry"),
            _contract_start_block(manifest, "FurnaceEntryTokenRegistry"),
        ]
    )
    params.append(
        Param(
            name="ENTRY_TOKEN_REGISTRY_START_BLOCK",
            value=reg_start,
            note="min(MineCoreEntryTokenRegistry.startBlock, FurnaceEntryTokenRegistry.startBlock)",
            dune_type="integer",
        )
    )

    params.append(
        Param(
            name="MAINTENANCEHUB_START_BLOCK",
            value=_contract_start_block(manifest, "MaintenanceHub"),
            note="deployments.<network>.json contracts.MaintenanceHub.startBlock (optional; used by keeper panels)",
            dune_type="integer",
        )
    )

    # Optional panels
    params.append(
        Param(
            name="LP_STAKING_VAULT_ADDRESS",
            value=_contract_addr(manifest, "LpStakingVault7D"),
            note="deployments.<network>.json contracts.LpStakingVault7D.address",
            dune_type="varbinary",
        )
    )
    params.append(
        Param(
            name="RESERVE_TARGET_FINAL_CLAIM",
            value=_protocol_param(manifest, "protocolParams.furnace.reserveTargetFinalClaim"),
            note="protocolParams.furnace.reserveTargetFinalClaim (whole CLAIM)",
            dune_type="integer",
        )
    )
    # Not stored in the deployment manifest; must be supplied manually.
    params.append(
        Param(
            name="FURNACE_LAUNCH_TIME",
            value=None,
            note="timestamp (set to the Furnace launch time; often the block timestamp at Furnace.startBlock)",
            dune_type="timestamp",
        )
    )

    return params


def _render_md(params: List[Param]) -> str:
    lines = ["| Parameter | Value | Type | Notes |", "|---|---:|---|---|"]
    for p in params:
        v = "(missing)" if p.value is None else str(p.value)
        lines.append(f"| `{p.name}` | `{v}` | {p.dune_type} | {p.note} |")
    return "\n".join(lines)


def _render_env(params: List[Param]) -> str:
    out: List[str] = []
    for p in params:
        if p.value is None:
            out.append(f"# {p.name}=  # {p.note}")
        else:
            out.append(f"{p.name}={p.value}")
    return "\n".join(out)


def _render_json(params: List[Param]) -> str:
    obj: Dict[str, Any] = {p.name: p.value for p in params}
    return json.dumps(obj, indent=2, sort_keys=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Render Dune parameter defaults from deployments/*.json")
    ap.add_argument("manifest", help="Path to deployments/<network>.json")
    ap.add_argument(
        "--format",
        choices=["md", "env", "json"],
        default="md",
        help="Output format (default: md)",
    )
    args = ap.parse_args()

    path = Path(args.manifest)
    if not path.exists():
        print(f"ERROR: manifest not found: {path}")
        return 2

    manifest = _load_manifest(path)
    params = build_params(manifest)

    if args.format == "md":
        print(_render_md(params))
    elif args.format == "env":
        print(_render_env(params))
    else:
        print(_render_json(params))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
