#!/usr/bin/env python3
"""Guardrail: developer manuals must not reference contracts, events, or
functions that no longer exist in the Solidity source.

Checks:
- Contract names mentioned in backtick-fenced code in manuals exist in src/.
- Event names mentioned as ``EventName(...)`` in manuals exist in src/lib/Events.sol.
- ABI filenames mentioned in manuals exist in abis/.
- Manual H1 titles do not embed protocol version numbers (see
  docs/manuals/VERSIONING.md).

Run:
    python3 scripts/check_manuals_truthiness.py
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANUAL_DIRS = [ROOT / "docs" / "manuals" / "developer", ROOT / "docs" / "manuals" / "user"]
SRC_DIR = ROOT / "src"
EVENTS_SOL = ROOT / "src" / "lib" / "Events.sol"
ABI_DIRS = [ROOT / "abis" / "base_mainnet", ROOT / "abis" / "base_sepolia"]

# Contract names from src/
CONTRACT_RE = re.compile(
    r"`((?:ClaimToken|MineCore|Furnace|MarketRouter|VeClaimNFT|DelegationHub"
    r"|ShareholderRoyalties|EntryTokenRegistry|DexAdapter|LpStakingVault7D"
    r"|GenesisLPVault24M|MaintenanceHub|ClaimAllHelper|FurnaceQuoter"
    r"|MineCoreQuoter|LaunchController))`"
)

# Event references: ``EventName(...)`` or `Events.EventName`
EVENT_REF_RE = re.compile(r"`(?:Events\.)?([A-Z][a-zA-Z]+)\([^)]*\)`")

# ABI file references
ABI_REF_RE = re.compile(r"`([A-Za-z0-9_]+\.abi\.json)`")

# H1 titles that embed a protocol version (e.g. "# Foo (v1.0.0)"). These drift
# silently as the repo evolves; use Category 3 scoped claims or section headers
# instead. See docs/manuals/VERSIONING.md.
H1_VERSION_RE = re.compile(r"^#\s+.*\bv\d+\.\d+\.\d+\b", re.MULTILINE)


def configure(repo_root: Path) -> None:
    global ROOT, MANUAL_DIRS, SRC_DIR, EVENTS_SOL, ABI_DIRS

    ROOT = repo_root.resolve()
    MANUAL_DIRS = [ROOT / "docs" / "manuals" / "developer", ROOT / "docs" / "manuals" / "user"]
    SRC_DIR = ROOT / "src"
    EVENTS_SOL = ROOT / "src" / "lib" / "Events.sol"
    ABI_DIRS = [ROOT / "abis" / "base_mainnet", ROOT / "abis" / "base_sepolia"]


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def _source_contract_names() -> set[str]:
    names: set[str] = set()
    for sol in SRC_DIR.rglob("*.sol"):
        text = _read(sol)
        for m in re.finditer(r"contract\s+(\w+)", text):
            names.add(m.group(1))
    return names


def _all_event_names() -> set[str]:
    """Collect event names from ALL Solidity source files, not only Events.sol."""
    names: set[str] = set()
    for sol in SRC_DIR.rglob("*.sol"):
        text = _read(sol)
        for m in re.finditer(r"event\s+(\w+)\s*\(", text):
            names.add(m.group(1))
    # Also collect custom error names (which share the FooBar(...) syntax in docs).
    for sol in SRC_DIR.rglob("*.sol"):
        text = _read(sol)
        for m in re.finditer(r"error\s+(\w+)\s*\(", text):
            names.add(m.group(1))
    return names


def _event_names() -> set[str]:
    if not EVENTS_SOL.exists():
        return set()
    text = _read(EVENTS_SOL)
    return set(re.findall(r"event\s+(\w+)\s*\(", text))


def _abi_filenames() -> set[str]:
    names: set[str] = set()
    for d in ABI_DIRS:
        if d.is_dir():
            for f in d.iterdir():
                if f.suffix == ".json":
                    names.add(f.name)
    return names


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Guardrail: developer manuals must not reference missing contracts, events, or ABI files."
    )
    parser.add_argument(
        "--repo-root",
        default=str(ROOT),
        help="Repo root to scan. Defaults to the repo containing this script.",
    )
    args = parser.parse_args()
    configure(Path(args.repo_root))

    contract_names = _source_contract_names()
    # Use the expanded set that covers events AND errors across all source files.
    event_names = _all_event_names()
    abi_names = _abi_filenames()
    errors = 0

    for manual_dir in MANUAL_DIRS:
        if not manual_dir.is_dir():
            continue
        for md in manual_dir.rglob("*.md"):
            text = _read(md)
            rel = md.relative_to(ROOT)

            for m in CONTRACT_RE.finditer(text):
                name = m.group(1)
                if name not in contract_names:
                    errors += 1
                    print(
                        f"[manuals-truth] ERROR: {rel} references contract "
                        f"`{name}` not found in src/",
                        file=sys.stderr,
                    )

            for m in EVENT_REF_RE.finditer(text):
                name = m.group(1)
                if not (event_names and name not in event_names):
                    continue
                # Skip EIP-712 typehash strings, which are syntactically
                # identical to event signatures (`Name(type field, ...)`)
                # but do not represent on-chain events. The line introduces
                # them with `Typehash:` (or similar) preceding the backtick
                # block.
                line_start = text.rfind("\n", 0, m.start()) + 1
                line_end = text.find("\n", m.end())
                if line_end == -1:
                    line_end = len(text)
                line = text[line_start:line_end]
                if re.search(r"\b[Tt]ypehash\b", line):
                    continue
                errors += 1
                print(
                    f"[manuals-truth] ERROR: {rel} references event "
                    f"`{name}(...)` not in Events.sol",
                    file=sys.stderr,
                )

            for m in ABI_REF_RE.finditer(text):
                name = m.group(1)
                if abi_names and name not in abi_names:
                    errors += 1
                    print(
                        f"[manuals-truth] ERROR: {rel} references ABI "
                        f"`{name}` not in abis/",
                        file=sys.stderr,
                    )

            for m in H1_VERSION_RE.finditer(text):
                line = m.group(0).rstrip()
                errors += 1
                print(
                    f"[manuals-truth] ERROR: {rel} has a versioned H1 "
                    f"({line!r}); see docs/manuals/VERSIONING.md",
                    file=sys.stderr,
                )

    if errors:
        print(f"[manuals-truth] FAIL: {errors} issue(s)", file=sys.stderr)
        return 1

    print("[manuals-truth] OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
