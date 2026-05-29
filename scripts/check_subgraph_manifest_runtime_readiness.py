#!/usr/bin/env python3
"""Validate that subgraph manifests are deployable on a live network.

Why this exists
----------------
Manifest/schema parity checks can all pass while a runtime manifest is still
non-deployable because one or more data sources point at the zero address or use
startBlock = 0. Local/dev manifests may intentionally use those values, but
staging/prod manifests must fail loudly when they do.

What it checks
--------------
- Every ethereum dataSource has a non-zero `source.address`.
- Every ethereum dataSource has `source.startBlock > 0`.
- Optional `--allow-network <name>` exemptions let local/dev manifests opt out.

Usage
-----
  python3 scripts/check_subgraph_manifest_runtime_readiness.py subgraph/subgraph.prod.yaml
  python3 scripts/check_subgraph_manifest_runtime_readiness.py     subgraph/subgraph.local.yaml --allow-network local

Exit codes
----------
  0 = all manifests passed
  1 = one or more runtime-readiness violations found
  2 = invalid input / missing dependencies
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple

try:
    import yaml  # type: ignore
except ModuleNotFoundError:
    print(
        "ERROR: PyYAML not installed. Install pinned deps: python3 -m pip install -r requirements-ci.txt",
        file=sys.stderr,
    )
    sys.exit(2)

ZERO_ADDR = "0x0000000000000000000000000000000000000000"
HEX_ADDR_RE = re.compile(r"^0x[a-fA-F0-9]{40}$")
MAX_MANIFEST_YAML_BYTES = 2 * 1024 * 1024


def _read_text_file_safe(path: Path, *, label: str, max_bytes: int) -> str:
    if not path.is_file():
        raise SystemExit(f"ERROR: {label} is not a regular file: {path}")
    try:
        size = path.stat().st_size
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"ERROR: failed to stat {label} {path}: {exc}")
    if size > max_bytes:
        raise SystemExit(f"ERROR: {label} too large: {path} ({size} bytes > {max_bytes})")
    return path.read_text(encoding="utf-8")


def parse_yaml(path: Path, *, max_bytes: int = MAX_MANIFEST_YAML_BYTES) -> Dict[str, Any]:
    try:
        data = yaml.safe_load(_read_text_file_safe(path, label="manifest YAML", max_bytes=max_bytes))
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"ERROR: failed to parse YAML {path}: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"ERROR: expected top-level mapping in {path}")
    return data


def iter_ethereum_data_sources(doc: Dict[str, Any]) -> Iterable[Tuple[str, Dict[str, Any]]]:
    data_sources = doc.get("dataSources") or []
    if not isinstance(data_sources, list):
        return
    for ds in data_sources:
        if not isinstance(ds, dict):
            continue
        if ds.get("kind") != "ethereum":
            continue
        name = str(ds.get("name") or "<unnamed>")
        yield name, ds


def normalize_addr(addr: Any) -> str:
    return str(addr or "").strip()


def is_zero_addr(addr: str) -> bool:
    return addr.lower() == ZERO_ADDR


def validate_manifest(path: Path, allow_networks: set[str]) -> Tuple[List[str], int]:
    doc = parse_yaml(path)
    issues: List[str] = []
    checked = 0

    for name, ds in iter_ethereum_data_sources(doc):
        checked += 1
        network = str(ds.get("network") or "")
        if network in allow_networks:
            continue

        source = ds.get("source")
        if not isinstance(source, dict):
            issues.append(f"[{name}] missing source block")
            continue

        addr = normalize_addr(source.get("address"))
        if not HEX_ADDR_RE.match(addr):
            issues.append(f"[{name}] invalid source.address: {addr or '<missing>'}")
        elif is_zero_addr(addr):
            issues.append(f"[{name}] source.address is the zero address")

        start_block = source.get("startBlock")
        if not isinstance(start_block, int):
            issues.append(f"[{name}] invalid source.startBlock: {start_block!r}")
        elif start_block <= 0:
            issues.append(f"[{name}] source.startBlock must be > 0 (found {start_block})")

    return issues, checked


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate that subgraph manifests are runtime-ready (non-zero addresses/start blocks).")
    ap.add_argument("manifests", nargs="+", help="One or more subgraph manifest YAML files")
    ap.add_argument(
        "--allow-network",
        action="append",
        default=[],
        help="Datasource network name to exempt from strict readiness checks (repeatable, e.g. --allow-network local)",
    )
    args = ap.parse_args()

    allow_networks = {str(v) for v in args.allow_network}
    all_ok = True

    for raw_path in args.manifests:
        path = Path(raw_path)
        if not path.exists():
            print(f"ERROR: manifest not found: {path}", file=sys.stderr)
            return 2

        issues, checked = validate_manifest(path, allow_networks)
        if issues:
            all_ok = False
            print(f"FAIL {path} ({checked} ethereum data source(s) checked)")
            for issue in issues:
                print(f"  - {issue}")
        else:
            print(f"OK   {path} ({checked} ethereum data source(s) checked)")

    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
