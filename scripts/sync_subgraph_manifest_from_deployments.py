#!/usr/bin/env python3
"""Sync subgraph manifest addresses + start blocks from deployments/<network>.json.

Why this exists
----------------
The canonical source of truth for addresses and start blocks in this repo is:

  deployments/<network>.json

The Graph subgraph manifests (`subgraph/subgraph.*.yaml`) MUST match those values
exactly before deployment (per v1.0.0 docs).

This script patches a manifest YAML in-place (or writes to --out) by replacing:
  - dataSources[*].source.address
  - dataSources[*].source.startBlock

for known ClaimRush v1.0.0 data sources.

Safety
------
By default this script FAILS if it encounters a zero address or startBlock=0 in
the deployment manifest, because real deployments require those values.

Local manifests can be synced with zero values when explicitly allowed:
  --allow-zero-addresses
  --allow-start-block-zero

Usage
-----
  python3 scripts/sync_subgraph_manifest_from_deployments.py \
    --manifest subgraph/subgraph.yaml \
    --deployments deployments/base_mainnet.json

  python3 scripts/sync_subgraph_manifest_from_deployments.py \
    --manifest subgraph/subgraph.local.yaml \
    --deployments deployments/local.json \
    --allow-zero-addresses \
    --allow-start-block-zero \
    --check

Exit codes:
  0 = success / no drift in --check mode
  1 = drift detected in --check mode
  2 = invalid input / sync failure
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


ZERO_ADDR = "0x0000000000000000000000000000000000000000"


# Graph-node network name for each supported chainId. Keep this table in sync
# with `subgraph/subgraph.*.yaml` and the v1.0.0 deployments matrix.
CHAIN_ID_TO_NETWORK: Dict[int, str] = {
    31337: "local",
    84532: "base-sepolia",
    8453: "base",
}


@dataclass(frozen=True)
class ContractMeta:
    address: str
    start_block: int


@dataclass(frozen=True)
class Drift:
    data_source: str
    field: str
    current: str
    expected: str


NAME_MAP: Dict[str, str] = {
    # dataSource name -> deployments.contracts key
    "MineCore": "MineCore",
    "Furnace": "Furnace",
    "ShareholderRoyalties": "ShareholderRoyalties",
    "VeClaimNFT": "VeClaimNFT",
    # DelegationHub + bot helper contracts (indexed in v1.0.0)
    "DelegationHub": "DelegationHub",
    "ClaimAllHelper": "ClaimAllHelper",
    "MarketRouter": "MarketRouter",
    "LpStakingVault7D": "LpStakingVault7D",
    "LaunchController": "LaunchController",
    "GenesisLPVault24M": "GenesisLPVault24M",
    "MaintenanceHub": "MaintenanceHub",
}


def _read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f"ERROR: failed to read JSON: {path}: {e}")


def _norm_addr(addr: str) -> str:
    return (addr or "").strip().lower()


def _is_zero_addr(addr: str) -> bool:
    return _norm_addr(addr) == ZERO_ADDR


def _parse_start_block(meta: dict) -> Optional[int]:
    # Canonical key
    sb = meta.get("startBlock")
    if isinstance(sb, int):
        return sb
    if isinstance(sb, str):
        try:
            return int(sb)
        except Exception:  # noqa: BLE001
            return None
    return None


def _load_expected_network(deployments_path: Path) -> Optional[str]:
    """Return the graph-node network name implied by the deployments manifest.

    Uses the manifest's `chainId` (canonical source of truth for network
    identity). Returns None for manifests whose chainId is not in the
    v1.0.0 supported table, in which case network validation is skipped.
    """
    data = _read_json(deployments_path)
    chain_id = data.get("chainId")
    if isinstance(chain_id, str):
        try:
            chain_id = int(chain_id)
        except Exception:  # noqa: BLE001
            chain_id = None
    if isinstance(chain_id, int) and chain_id in CHAIN_ID_TO_NETWORK:
        return CHAIN_ID_TO_NETWORK[chain_id]
    return None


def _load_contracts(deployments_path: Path) -> Dict[str, ContractMeta]:
    data = _read_json(deployments_path)
    contracts = data.get("contracts")
    if not isinstance(contracts, dict):
        raise SystemExit(f"ERROR: deployments manifest missing 'contracts': {deployments_path}")

    out: Dict[str, ContractMeta] = {}
    for k, v in contracts.items():
        if not isinstance(v, dict):
            continue
        addr = v.get("address")
        if not isinstance(addr, str):
            continue
        sb = _parse_start_block(v)
        if sb is None:
            continue
        out[k] = ContractMeta(address=addr, start_block=sb)
    return out


def _validate_meta(
    name: str,
    meta: ContractMeta,
    *,
    allow_zero_addresses: bool,
    allow_start_block_zero: bool,
) -> Optional[str]:
    if not allow_zero_addresses and _is_zero_addr(meta.address):
        return f"{name}: zero address in deployments manifest"
    if not allow_start_block_zero and meta.start_block == 0:
        return f"{name}: startBlock=0 in deployments manifest"
    return None


def sync_manifest_text(
    text: str,
    contracts: Dict[str, ContractMeta],
    *,
    allow_zero_addresses: bool,
    allow_start_block_zero: bool,
    expected_network: Optional[str] = None,
) -> Tuple[str, List[str], List[Drift]]:
    """Return (new_text, errors, drifts)."""

    lines = text.splitlines(keepends=True)
    out: List[str] = []
    errors: List[str] = []
    drifts: List[Drift] = []

    current_ds: Optional[str] = None
    patched_addr: Dict[str, bool] = {}
    patched_sb: Dict[str, bool] = {}
    seen_ds: Dict[str, bool] = {}
    validated_ds: Dict[str, bool] = {}

    # Match only top-level dataSource/template `name:` lines (4-space indent).
    # Deeper `name:` keys inside `mapping.abis[]` or other nested blocks must NOT
    # reset the active data source.
    name_re = re.compile(r"^\s{4}name:\s*([A-Za-z0-9_]+)\s*$")
    addr_re = re.compile(r"^(\s*)address:\s*\"?([^\"\n]+)\"?\s*$")
    sb_re = re.compile(r"^(\s*)startBlock:\s*([0-9]+)\s*$")
    network_re = re.compile(r"^(\s*)network:\s*([A-Za-z0-9._-]+)\s*$")

    for line in lines:
        m_name = name_re.match(line.rstrip("\n"))
        if m_name:
            current_ds = m_name.group(1)
            if current_ds in NAME_MAP:
                seen_ds[current_ds] = True
            out.append(line)
            continue

        if current_ds in NAME_MAP:
            contract_key = NAME_MAP[current_ds]
            meta = contracts.get(contract_key)
            if meta is None:
                errors.append(f"Missing deployments.contracts.{contract_key} for data source {current_ds}")
                out.append(line)
                continue

            if not validated_ds.get(current_ds, False):
                err = _validate_meta(
                    contract_key,
                    meta,
                    allow_zero_addresses=allow_zero_addresses,
                    allow_start_block_zero=allow_start_block_zero,
                )
                if err:
                    errors.append(err)
                validated_ds[current_ds] = True

            m_addr = addr_re.match(line.rstrip("\n"))
            if m_addr:
                indent = m_addr.group(1)
                current_addr = m_addr.group(2)
                # Subgraph manifests follow the Graph Protocol convention of
                # lowercase hex addresses (no EIP-55 mixed case). Deployment
                # manifests under deployments/*.json are EIP-55 checksummed for
                # human review, so we must normalize to lowercase when we
                # materialize the address into the subgraph manifest.
                target_addr = _norm_addr(meta.address)
                if _norm_addr(current_addr) != target_addr:
                    drifts.append(
                        Drift(
                            data_source=current_ds,
                            field="source.address",
                            current=current_addr,
                            expected=target_addr,
                        )
                    )
                out.append(f'{indent}address: "{target_addr}"\n')
                patched_addr[current_ds] = True
                continue

            m_sb = sb_re.match(line.rstrip("\n"))
            if m_sb:
                indent = m_sb.group(1)
                current_sb = m_sb.group(2)
                if current_sb != str(meta.start_block):
                    drifts.append(
                        Drift(
                            data_source=current_ds,
                            field="source.startBlock",
                            current=current_sb,
                            expected=str(meta.start_block),
                        )
                    )
                out.append(f"{indent}startBlock: {meta.start_block}\n")
                patched_sb[current_ds] = True
                continue

            if expected_network is not None:
                m_net = network_re.match(line.rstrip("\n"))
                if m_net:
                    indent = m_net.group(1)
                    current_net = m_net.group(2)
                    if current_net != expected_network:
                        drifts.append(
                            Drift(
                                data_source=current_ds,
                                field="network",
                                current=current_net,
                                expected=expected_network,
                            )
                        )
                    out.append(f"{indent}network: {expected_network}\n")
                    continue

        out.append(line)

    # Ensure we actually patched all dataSources we saw in this manifest.
    for ds in seen_ds.keys():
        if not patched_addr.get(ds, False):
            errors.append(f"{ds}: did not find/patch source.address in manifest")
        if not patched_sb.get(ds, False):
            errors.append(f"{ds}: did not find/patch source.startBlock in manifest")

    return ("".join(out), errors, drifts)


def main() -> int:
    ap = argparse.ArgumentParser(description="Sync subgraph manifest addresses/start blocks from deployments/*.json")
    ap.add_argument("--manifest", required=True, help="Path to subgraph manifest YAML to patch")
    ap.add_argument("--deployments", required=True, help="Path to deployments/<network>.json")
    ap.add_argument("--out", help="Optional output path (default: in-place)")
    ap.add_argument(
        "--check",
        action="store_true",
        help="Validate manifest values against deployments/<network>.json without rewriting files",
    )
    ap.add_argument(
        "--allow-zero-addresses",
        action="store_true",
        help="Allow zero addresses (useful for local dev / partial deployments)",
    )
    ap.add_argument(
        "--allow-start-block-zero",
        action="store_true",
        help="Allow startBlock=0 (useful for local dev)",
    )

    args = ap.parse_args()

    manifest_path = Path(args.manifest)
    deployments_path = Path(args.deployments)

    if not manifest_path.exists():
        print(f"ERROR: manifest not found: {manifest_path}")
        return 2
    if not deployments_path.exists():
        print(f"ERROR: deployments not found: {deployments_path}")
        return 2
    if args.check and args.out:
        print("ERROR: --check cannot be combined with --out")
        return 2

    contracts = _load_contracts(deployments_path)
    expected_network = _load_expected_network(deployments_path)
    src = manifest_path.read_text(encoding="utf-8")
    dst, errors, drifts = sync_manifest_text(
        src,
        contracts,
        allow_zero_addresses=args.allow_zero_addresses,
        allow_start_block_zero=args.allow_start_block_zero,
        expected_network=expected_network,
    )

    if errors:
        print("ERROR: subgraph manifest sync failed:")
        for e in errors:
            print(f"  - {e}")
        return 2

    if args.check:
        if drifts or src != dst:
            print("Subgraph manifest sync: FAILED")
            for drift in drifts:
                print(
                    f"- {drift.data_source}.{drift.field}: manifest={drift.current} deployments={drift.expected}"
                )
            print("\nFix guidance:")
            print("- Re-run without --check to rewrite the manifest in place.")
            print("- Commit the synced manifest so docs/tooling cannot drift silently.")
            return 1

        print("Subgraph manifest sync: OK")
        return 0

    out_path = Path(args.out) if args.out else manifest_path
    out_path.write_text(dst, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
