#!/usr/bin/env python3
"""Validate mutable Protocol wiring semantics in subgraph mappings.

Why this exists
- Several core protocol addresses are mutable during the pre-freeze wiring phase.
- The subgraph `Protocol` singleton is intended to expose the latest observed current wiring,
  not just the first non-zero seed.
- A handler can exist in the manifest yet still be semantically wrong if it keeps using
  write-once helpers like `setBytesIfZero(...)` for mutable peer addresses.

What it checks
- Required mutable-wiring handlers exist in the expected mapping files.
- Each handler writes the latest configured peer address directly to the correct `Protocol` field.
- The handler does not use `setBytesIfZero(...)` for the mutable target field.

Usage
  python3 scripts/check_subgraph_protocol_wiring_semantics.py

Exit codes
  0 = all checks passed
  1 = semantic drift found
  2 = invalid repo layout / parse failure
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class HandlerExpectation:
    path: Path
    function_name: str
    required: tuple[str, ...]
    forbidden: tuple[str, ...] = ()
    signature_required: tuple[str, ...] = ()


def extract_function_body(text: str, function_name: str) -> str:
    marker = f"export function {function_name}("
    start = text.find(marker)
    if start == -1:
        raise ValueError(f"missing function `{function_name}`")

    brace_start = text.find("{", start)
    if brace_start == -1:
        raise ValueError(f"missing opening brace for `{function_name}`")

    depth = 0
    for idx in range(brace_start, len(text)):
        ch = text[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace_start + 1:idx]

    raise ValueError(f"unterminated function `{function_name}`")


def format_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


EXPECTATIONS: tuple[HandlerExpectation, ...] = (
    HandlerExpectation(
        path=ROOT / "subgraph/src/mappings/veClaimNFT.ts",
        function_name="handleFurnaceChanged",
        required=("protocol.furnace = event.params.newFurnace;",),
        forbidden=("setBytesIfZero(protocol.furnace",),
    ),
    HandlerExpectation(
        path=ROOT / "subgraph/src/mappings/veClaimNFT.ts",
        function_name="handleMineMarketChanged",
        required=("protocol.marketRouter = event.params.newMineMarket;",),
        forbidden=("setBytesIfZero(protocol.marketRouter",),
    ),
    HandlerExpectation(
        path=ROOT / "subgraph/src/mappings/minecore.ts",
        function_name="handleFurnaceChanged",
        required=("protocol.furnace = event.params.newFurnace;",),
        forbidden=("setBytesIfZero(protocol.furnace",),
    ),
    HandlerExpectation(
        path=ROOT / "subgraph/src/mappings/furnace.ts",
        function_name="handleMineCoreChanged",
        required=("protocol.mineCore = event.params.newMineCore;",),
        forbidden=("setBytesIfZero(protocol.mineCore",),
    ),
    HandlerExpectation(
        path=ROOT / "subgraph/src/mappings/furnace.ts",
        function_name="handleMineMarketChanged",
        required=("protocol.marketRouter = event.params.newMineMarket;",),
        forbidden=("setBytesIfZero(protocol.marketRouter",),
    ),
    HandlerExpectation(
        path=ROOT / "subgraph/src/mappings/furnace.ts",
        function_name="handleShareholderRoyaltiesChanged",
        required=("protocol.shareholderRoyalties = event.params.newSR;",),
        forbidden=("setBytesIfZero(protocol.shareholderRoyalties",),
    ),
    HandlerExpectation(
        path=ROOT / "subgraph/src/mappings/shareholderRoyalties.ts",
        function_name="handleShareholderWiringSet",
        required=(
            "protocol.shareholderRoyalties = event.address;",
            "protocol.mineCore = event.params.mineCore;",
            "protocol.marketRouter = event.params.mineMarket;",
            "protocol.furnace = event.params.furnace;",
        ),
        forbidden=(
            "setBytesIfZero(protocol.shareholderRoyalties",
            "setBytesIfZero(protocol.mineCore",
            "setBytesIfZero(protocol.marketRouter",
            "setBytesIfZero(protocol.furnace",
        ),
        signature_required=(
            "export function handleShareholderWiringSet(event: ShareholderWiringSet): void",
        ),
    ),
)


def main() -> int:
    errors: List[str] = []

    for exp in EXPECTATIONS:
        if not exp.path.exists():
            errors.append(f"missing mapping file: {format_path(exp.path)}")
            continue

        text = exp.path.read_text(encoding="utf-8")
        for needle in exp.signature_required:
            if needle not in text:
                errors.append(
                    f"{format_path(exp.path)}::{exp.function_name} missing required signature snippet: {needle}"
                )

        try:
            body = extract_function_body(text, exp.function_name)
        except ValueError as exc:
            errors.append(f"{format_path(exp.path)}: {exc}")
            continue

        for needle in exp.required:
            if needle not in body:
                errors.append(
                    f"{format_path(exp.path)}::{exp.function_name} missing required snippet: {needle}"
                )

        for needle in exp.forbidden:
            if needle in body:
                errors.append(
                    f"{format_path(exp.path)}::{exp.function_name} contains forbidden write-once snippet: {needle}"
                )

    if errors:
        print("Protocol wiring semantic drift detected:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("OK: subgraph mutable Protocol wiring semantics look correct")
    return 0


if __name__ == "__main__":
    sys.exit(main())
