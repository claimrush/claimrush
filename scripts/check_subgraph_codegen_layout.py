#!/usr/bin/env python3
"""Validate subgraph codegen/build layout hygiene.

Why this exists
- Mappings import generated bindings from `subgraph/src/generated/...`.
- Stale checked-in artifacts under `subgraph/generated/...` do not satisfy those imports and can
  mask drift after ABI or manifest changes.
- `npm run build` should regenerate bindings before compiling so a fresh checkout cannot build
  against stale or missing generated output.

What it checks
- `subgraph/package.json` has a `codegen` script targeting `src/generated`.
- The `build` path runs `codegen` before `graph build` (directly or via `prebuild`).
- `subgraph/generated/` is absent or empty of files.

Usage
  python3 scripts/check_subgraph_codegen_layout.py

Exit codes
  0 = all checks passed
  1 = layout/build hygiene issue found
  2 = invalid repo layout
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUBGRAPH_DIR = ROOT / "subgraph"
PKG = SUBGRAPH_DIR / "package.json"
STALE_GENERATED_DIR = SUBGRAPH_DIR / "generated"


def main() -> int:
    if not PKG.exists():
        print(f"ERROR: missing {PKG}", file=sys.stderr)
        return 2

    pkg = json.loads(PKG.read_text(encoding="utf-8"))
    scripts = pkg.get("scripts") or {}

    errors: list[str] = []

    codegen = str(scripts.get("codegen") or "")
    build = str(scripts.get("build") or "")
    prebuild = str(scripts.get("prebuild") or "")

    if not codegen:
        errors.append("subgraph/package.json is missing scripts.codegen")
    elif "src/generated" not in codegen:
        errors.append(
            "scripts.codegen must target src/generated (mappings import ../generated/... from subgraph/src/*)"
        )

    build_runs_codegen = "codegen" in build or "codegen" in prebuild
    if not build_runs_codegen:
        errors.append(
            "build path must run codegen before graph build (either in scripts.build or scripts.prebuild)"
        )

    if STALE_GENERATED_DIR.exists():
        stale_files = sorted(p for p in STALE_GENERATED_DIR.rglob("*") if p.is_file())
        if stale_files:
            errors.append(
                "stale checked-in files found under subgraph/generated; remove them and rely on subgraph/src/generated"
            )
            for path in stale_files[:10]:
                errors.append(f"  stale file: {path.relative_to(ROOT)}")
            if len(stale_files) > 10:
                errors.append(f"  ... and {len(stale_files) - 10} more")

    if errors:
        print("Subgraph codegen layout check failed:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("OK: subgraph codegen/build layout looks correct")
    return 0


if __name__ == "__main__":
    sys.exit(main())
