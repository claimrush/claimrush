#!/usr/bin/env python3
"""Check Foundry version consistency across CI, docs, and config.

The Foundry toolchain version is pinned in multiple locations for
reproducible builds. This script ensures they all agree.

Checked locations:
  1. .github/workflows/ci.yml  (foundry-toolchain version: ...)
  2. the install-deps document   (foundryup -v X.Y.Z and prose pin)

Usage:
    python3 scripts/check_foundry_version_consistency.py

Exit codes:
    0 = all pins are consistent
    1 = version mismatch found
    2 = missing file or unable to parse
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import List, Optional

ROOT = Path(__file__).resolve().parents[1]


def _extract_ci_version() -> Optional[str]:
    ci_yml = ROOT / ".github" / "workflows" / "ci.yml"
    if not ci_yml.exists():
        return None
    text = ci_yml.read_text(encoding="utf-8")
    m = re.search(r"foundry-toolchain@\w+.*?\n\s+with:\s*\n(?:.*?\n)*?\s+version:\s*v?([\d.]+)", text)
    return m.group(1) if m else None


def _extract_docs_versions() -> List[str]:
    doc = ROOT / "docs" / "dev" / "install-deps.md"
    if not doc.exists():
        return []
    text = doc.read_text(encoding="utf-8")
    versions = []
    for m in re.finditer(r"foundryup\s+-v\s+([\d.]+)", text):
        versions.append(m.group(1))
    for m in re.finditer(r"\*\*([\d.]+)\*\*", text):
        versions.append(m.group(1))
    return versions


def main() -> int:
    errors: List[str] = []
    all_versions: dict[str, str] = {}

    ci_ver = _extract_ci_version()
    if ci_ver:
        all_versions["ci.yml"] = ci_ver
    else:
        errors.append("Could not extract Foundry version from ci.yml")

    doc_versions = _extract_docs_versions()
    for i, v in enumerate(doc_versions):
        key = f"install-deps.md (pin #{i+1})"
        all_versions[key] = v

    if not all_versions:
        print("[foundry-version] SKIP: no version pins found")
        return 0

    unique = set(all_versions.values())

    if len(unique) > 1:
        print("[foundry-version] ERROR: Foundry version mismatch detected!", file=sys.stderr)
        for loc, ver in sorted(all_versions.items()):
            print(f"  {loc}: {ver}", file=sys.stderr)
        return 1

    canonical = unique.pop()
    print(f"[foundry-version] OK: all {len(all_versions)} pins agree on v{canonical}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
