#!/usr/bin/env python3
"""Validate subgraph manifest event handler signatures against ABI JSON.

Why this exists
- A single wrong `indexed` marker (or wrong arg type ordering) in a subgraph manifest
  causes The Graph Node to miss events or fail the deployment.
- ClaimRush v1.0.0 event schemas are locked, so we can deterministically validate
  the manifest against the pinned ABIs in-repo.

What it checks
- Every `eventHandlers[].event` signature in:
  - dataSources[].mapping
  - templates[].mapping

It compares the declared arg types + `indexed` flags against the ABI event inputs for
that data source's `source.abi`.

Usage
  # Default (repo_root/subgraph/subgraph.yaml)
  python3 scripts/check_subgraph_manifest_events_vs_abi.py

  # Explicit manifests
  python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.prod.yaml
  python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.staging.yaml
  python3 scripts/check_subgraph_manifest_events_vs_abi.py subgraph/subgraph.local.yaml

Exit code
  0 on success
  1 on any mismatch
  2 on invalid input (missing files, invalid YAML, etc.)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    import yaml  # type: ignore
except ModuleNotFoundError:
    print(
        "ERROR: PyYAML not installed. Install pinned deps: python3 -m pip install -r requirements-ci.txt",
        file=sys.stderr,
    )
    sys.exit(2)


RE_EVENT = re.compile(r"^(?P<name>[A-Za-z0-9_]+)\((?P<args>.*)\)$")
MAX_MANIFEST_YAML_BYTES = 2 * 1024 * 1024
MAX_ABI_JSON_BYTES = 2 * 1024 * 1024


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


def parse_event_signature(sig: str) -> Tuple[str, List[Tuple[str, bool]]]:
    """Return (name, [(type, indexed), ...])."""
    m = RE_EVENT.match(sig.strip())
    if not m:
        raise ValueError(f"Invalid event signature format: {sig}")

    name = m.group("name")
    args_str = m.group("args").strip()
    if not args_str:
        return name, []

    parts = [p.strip() for p in args_str.split(",")]
    args: List[Tuple[str, bool]] = []
    for p in parts:
        if not p:
            continue
        tokens = p.split()
        if len(tokens) == 1:
            indexed = False
            typ = tokens[0]
        elif len(tokens) == 2 and tokens[0] == "indexed":
            indexed = True
            typ = tokens[1]
        else:
            raise ValueError(f"Invalid argument fragment: `{p}` in `{sig}`")
        args.append((typ, indexed))

    return name, args


def load_abi_events(abi_path: Path, *, max_bytes: int = MAX_ABI_JSON_BYTES) -> Dict[str, List[List[Tuple[str, bool]]]]:
    """Return map: eventName -> list of possible [(type, indexed), ...] signatures."""
    abi = json.loads(_read_text_file_safe(abi_path, label="ABI JSON", max_bytes=max_bytes))
    if not isinstance(abi, list):
        raise SystemExit(f"ERROR: expected ABI array in {abi_path}")
    out: Dict[str, List[List[Tuple[str, bool]]]] = {}
    for item in abi:
        if item.get("type") != "event":
            continue
        name = item.get("name")
        if not name:
            continue
        sig = [(inp["type"], bool(inp.get("indexed"))) for inp in item.get("inputs", [])]
        out.setdefault(name, []).append(sig)
    return out


def mapping_abi_path(mapping: Dict[str, Any], abi_name: str, base_dir: Path) -> Optional[Path]:
    for abi in mapping.get("abis", []) or []:
        if abi.get("name") == abi_name:
            file_path = abi.get("file")
            if not file_path:
                return None
            return (base_dir / file_path).resolve()
    return None


def check_mapping(name: str, source_abi: str, mapping: Dict[str, Any], base_dir: Path) -> List[str]:
    errs: List[str] = []

    abi_path = mapping_abi_path(mapping, source_abi, base_dir)
    if abi_path is None or not abi_path.exists():
        errs.append(f"[{name}] ABI `{source_abi}` not found in mapping abis[]")
        return errs

    abi_events = load_abi_events(abi_path)

    for eh in mapping.get("eventHandlers", []) or []:
        sig_str = eh.get("event")
        if not sig_str:
            continue
        try:
            ev_name, ev_args = parse_event_signature(sig_str)
        except ValueError as e:
            errs.append(f"[{name}] {e}")
            continue

        candidates = abi_events.get(ev_name)
        if not candidates:
            errs.append(f"[{name}] Event `{ev_name}` not found in ABI {abi_path.name}")
            continue

        if list(ev_args) not in candidates:
            # Render helpful diff
            want = ", ".join([f"{'indexed ' if ix else ''}{t}" for t, ix in ev_args])
            have = [", ".join([f"{'indexed ' if ix else ''}{t}" for t, ix in cand]) for cand in candidates]
            errs.append(
                f"[{name}] Signature mismatch for `{ev_name}`\n"
                f"  manifest: {ev_name}({want})\n"
                f"  abi:      " + " OR ".join([f"{ev_name}({h})" for h in have])
            )

    return errs


def _resolve_manifest_path(arg: str, repo_root: Path) -> Path:
    """Resolve a manifest path.

    - If `arg` exists as-given, use it.
    - Otherwise try repo_root / arg.
    """

    p = Path(arg)
    if p.exists():
        return p.resolve()

    p2 = (repo_root / arg)
    if p2.exists():
        return p2.resolve()

    raise FileNotFoundError(arg)


def check_manifest(manifest_path: Path) -> List[str]:
    data = yaml.safe_load(_read_text_file_safe(manifest_path, label="manifest YAML", max_bytes=MAX_MANIFEST_YAML_BYTES))
    if not isinstance(data, dict):
        raise SystemExit(f"ERROR: expected top-level mapping in {manifest_path}")
    base_dir = manifest_path.parent

    errors: List[str] = []

    for ds in data.get("dataSources", []) or []:
        ds_name = ds.get("name", "<unknown>")
        source_abi = (ds.get("source") or {}).get("abi")
        mapping = ds.get("mapping") or {}
        if source_abi:
            errors.extend(check_mapping(f"dataSource:{ds_name}", source_abi, mapping, base_dir))

    for tmpl in data.get("templates", []) or []:
        t_name = tmpl.get("name", "<unknown>")
        source_abi = (tmpl.get("source") or {}).get("abi")
        mapping = tmpl.get("mapping") or {}
        if source_abi:
            errors.extend(check_mapping(f"template:{t_name}", source_abi, mapping, base_dir))

    return errors


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    default_manifest = repo_root / "subgraph" / "subgraph.yaml"

    ap = argparse.ArgumentParser(
        description="Validate subgraph manifest event handler signatures (including indexed flags) vs ABI JSON"
    )
    ap.add_argument(
        "manifests",
        nargs="*",
        help=f"Subgraph manifest YAML files to validate (default: {default_manifest.relative_to(repo_root)})",
    )
    args = ap.parse_args()

    manifest_args: List[str] = list(args.manifests or [])
    if not manifest_args:
        manifest_paths = [default_manifest]
    else:
        try:
            manifest_paths = [_resolve_manifest_path(a, repo_root) for a in manifest_args]
        except FileNotFoundError as e:
            print(f"ERROR: manifest not found: {e}", file=sys.stderr)
            return 2

    any_errors = False
    for mp in manifest_paths:
        if not mp.exists():
            print(f"ERROR: manifest not found: {mp}", file=sys.stderr)
            return 2

        try:
            errors = check_manifest(mp)
        except Exception as e:  # noqa: BLE001
            print(f"ERROR: failed to check manifest {mp}: {e}", file=sys.stderr)
            return 2

        if errors:
            any_errors = True
            print(f"Subgraph manifest event signature mismatches found in: {mp}\n")
            for err in errors:
                print(err)
                print()
        else:
            # Keep output stable / grep-friendly
            print(f"OK: {mp.name} event handler signatures match ABI definitions")

    return 1 if any_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
