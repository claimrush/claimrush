#!/usr/bin/env python3
"""Verify structural parity between the four shipped subgraph manifests.

Files compared:
  - subgraph/subgraph.yaml         (default / committed active)
  - subgraph/subgraph.local.yaml   (graph-node-local workflow)
  - subgraph/subgraph.staging.yaml (base-sepolia)
  - subgraph/subgraph.prod.yaml    (base mainnet)

We REQUIRE that all four manifests declare identical:
  - dataSources list order
  - per-source: kind, name, mapping.kind, mapping.apiVersion, mapping.language,
    mapping.file, mapping.entities, mapping.abis[*].name,
    mapping.eventHandlers (event + handler pairs), mapping.blockHandlers
  - templates block (if present, must match structurally)

Network-specific fields are INTENTIONALLY allowed to differ:
  - network
  - source.address, source.abi, source.startBlock
  - abis[*].file (per-network ABI directory is OK; names must still match)

The gate catches two real drift classes caught in the v1.0.0 audit:
  1. A mapping handler added to one manifest but not the others (e.g. the
     Furnace block handler that used to be missing from subgraph.local.yaml).
  2. ABI pathing conventions becoming inconsistent across environments.

Exit status:
  0 - all manifests structurally match.
  1 - at least one divergence found; a unified diff is printed to stderr.
"""
from __future__ import annotations

import json
import pathlib
import sys
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - CI image has PyYAML
    sys.stderr.write("PyYAML required. Add 'pyyaml' to requirements-ci.txt.\n")
    raise SystemExit(2)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SUBGRAPH_DIR = REPO_ROOT / "subgraph"
MANIFESTS = [
    SUBGRAPH_DIR / "subgraph.yaml",
    SUBGRAPH_DIR / "subgraph.local.yaml",
    SUBGRAPH_DIR / "subgraph.staging.yaml",
    SUBGRAPH_DIR / "subgraph.prod.yaml",
]


def _load(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def _normalise(manifest: dict[str, Any]) -> dict[str, Any]:
    """Project the manifest down to the fields we require identical across networks."""
    out: dict[str, Any] = {
        "specVersion": manifest.get("specVersion"),
        "schema": manifest.get("schema"),
        "dataSources": [],
    }
    for ds in manifest.get("dataSources", []) or []:
        mapping = ds.get("mapping", {}) or {}
        out["dataSources"].append(
            {
                "kind": ds.get("kind"),
                "name": ds.get("name"),
                # intentionally skip `source` (address/startBlock/network)
                "mapping": {
                    "kind": mapping.get("kind"),
                    "apiVersion": mapping.get("apiVersion"),
                    "language": mapping.get("language"),
                    "file": mapping.get("file"),
                    "entities": mapping.get("entities"),
                    "abiNames": [a.get("name") for a in (mapping.get("abis") or [])],
                    "eventHandlers": [
                        {"event": h.get("event"), "handler": h.get("handler")}
                        for h in (mapping.get("eventHandlers") or [])
                    ],
                    "blockHandlers": [
                        {"handler": h.get("handler"), "filter": h.get("filter")}
                        for h in (mapping.get("blockHandlers") or [])
                    ],
                    "callHandlers": [
                        {"function": h.get("function"), "handler": h.get("handler")}
                        for h in (mapping.get("callHandlers") or [])
                    ],
                },
            }
        )
    templates = manifest.get("templates")
    if templates:
        out["templates"] = []
        for tpl in templates:
            mapping = tpl.get("mapping", {}) or {}
            out["templates"].append(
                {
                    "kind": tpl.get("kind"),
                    "name": tpl.get("name"),
                    "mapping": {
                        "kind": mapping.get("kind"),
                        "apiVersion": mapping.get("apiVersion"),
                        "language": mapping.get("language"),
                        "file": mapping.get("file"),
                        "entities": mapping.get("entities"),
                        "abiNames": [a.get("name") for a in (mapping.get("abis") or [])],
                        "eventHandlers": [
                            {"event": h.get("event"), "handler": h.get("handler")}
                            for h in (mapping.get("eventHandlers") or [])
                        ],
                        "blockHandlers": [
                            {"handler": h.get("handler"), "filter": h.get("filter")}
                            for h in (mapping.get("blockHandlers") or [])
                        ],
                        # Mirror the dataSources projection: templates can also
                        # declare callHandlers. Omitting this key would allow
                        # one manifest to add a callHandler under a template
                        # without the parity check failing, silently drifting
                        # the indexers off the canonical behaviour.
                        "callHandlers": [
                            {"function": h.get("function"), "handler": h.get("handler")}
                            for h in (mapping.get("callHandlers") or [])
                        ],
                    },
                }
            )
    return out


def main() -> int:
    missing = [p for p in MANIFESTS if not p.exists()]
    if missing:
        for p in missing:
            sys.stderr.write(f"[subgraph-parity] missing manifest: {p.relative_to(REPO_ROOT)}\n")
        return 1

    loaded = {p.name: _normalise(_load(p)) for p in MANIFESTS}
    baseline_name = MANIFESTS[0].name
    baseline = loaded[baseline_name]
    baseline_json = json.dumps(baseline, indent=2, sort_keys=False)

    failures = 0
    for p in MANIFESTS[1:]:
        other = loaded[p.name]
        other_json = json.dumps(other, indent=2, sort_keys=False)
        if other_json != baseline_json:
            failures += 1
            import difflib

            diff = difflib.unified_diff(
                baseline_json.splitlines(keepends=True),
                other_json.splitlines(keepends=True),
                fromfile=f"subgraph/{baseline_name} (normalised)",
                tofile=f"subgraph/{p.name} (normalised)",
            )
            sys.stderr.write(
                f"[subgraph-parity] drift detected between {baseline_name} and {p.name}:\n"
            )
            sys.stderr.writelines(diff)
            sys.stderr.write("\n")

    if failures:
        sys.stderr.write(
            f"[subgraph-parity] FAIL: {failures} manifest(s) diverge from {baseline_name}. "
            f"Keep dataSources/mapping/handlers identical; only network, addresses, "
            f"startBlock and ABI file paths may differ per environment.\n"
        )
        return 1

    print("[subgraph-parity] OK — all manifests agree on dataSources/handlers/templates.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
