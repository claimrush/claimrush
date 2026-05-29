#!/usr/bin/env python3
"""Check critical derived subgraph event-kind parity across mappings, schema, and docs.

Why this exists
- Some subgraph entities are not one-to-one onchain events; they are derived history surfaces.
- Their `kind` values are consumed by downstream applications and documented in:
  - subgraph/schema.graphql
  - docs/analytics/subgraph-schema-v1.0.0.md
- A mapping regression can silently stop emitting a critical kind while ABI coverage checks still pass.

This guardrail validates the highest-risk derived event surfaces:
- BonusTargetEscrowEvent
  - mapping emit set
  - schema/doc advertised kind set
  - canonical FILLED history row from handleBonusTargetEscrowExecuted
- MarketTradeEvent
  - mapping emit set
  - schema/doc advertised kind set

Usage:
  python3 scripts/check_subgraph_derived_event_kinds.py
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterable, List, Set

ROOT = Path(__file__).resolve().parents[1]

SCHEMA_PATH = ROOT / "subgraph" / "schema.graphql"
DOC_PATH = ROOT / "docs" / "analytics" / "subgraph-schema-v1.0.0.md"
MARKET_ROUTER_MAPPING = ROOT / "subgraph" / "src" / "mappings" / "marketRouter.ts"
FURNACE_MAPPING = ROOT / "subgraph" / "src" / "mappings" / "furnace.ts"

EXPECTED_BONUS_TARGET_ESCROW_EVENT_KINDS = {
    "CREATED",
    "CANCELLED",
    "EXPIRED",
    "EXPIRY_EXTENDED",
    "FILLED",
    "BONUS_CONFIGURED",
    "AUTO_FURNACE_EXECUTED",
}
EXPECTED_MARKET_TRADE_EVENT_KINDS = {"BUY"}


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _extract_type_block(text: str, type_name: str) -> str:
    m = re.search(
        rf"\btype\s+{re.escape(type_name)}(?:\s+@[^\n{{]+)?\s*{{(.*?)}}",
        text,
        flags=re.S,
    )
    if not m:
        raise ValueError(f"missing type block: {type_name}")
    return m.group(1)


def _extract_kind_comment_values(text: str, type_name: str) -> Set[str]:
    block = _extract_type_block(text, type_name)
    m = re.search(r"^\s*kind\s*:\s*String!\s*#\s*(.+)$", block, flags=re.M)
    if not m:
        raise ValueError(f"missing kind comment for type: {type_name}")
    return set(re.findall(r'"([A-Z_]+)"', m.group(1)))


def _mapping_kinds(path: Path, pattern: str) -> Set[str]:
    return set(re.findall(pattern, _read(path)))


def _extract_function_body(text: str, fn_name: str) -> str:
    start = text.find(f"export function {fn_name}")
    if start == -1:
        raise ValueError(f"missing function: {fn_name}")

    brace = text.find("{", start)
    if brace == -1:
        raise ValueError(f"missing function body: {fn_name}")

    depth = 0
    i = brace
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : i]
        i += 1

    raise ValueError(f"unterminated function body: {fn_name}")


def _fmt(values: Iterable[str]) -> str:
    return ", ".join(sorted(values)) or "<none>"


def main() -> int:
    errors: List[str] = []

    schema = _read(SCHEMA_PATH)
    doc = _read(DOC_PATH)
    market_router = _read(MARKET_ROUTER_MAPPING)

    try:
        schema_bonus_target_kinds = _extract_kind_comment_values(schema, "BonusTargetEscrowEvent")
    except ValueError as exc:
        errors.append(f"{SCHEMA_PATH}: {exc}")
        schema_bonus_target_kinds = set()

    try:
        doc_bonus_target_kinds = _extract_kind_comment_values(doc, "BonusTargetEscrowEvent")
    except ValueError as exc:
        errors.append(f"{DOC_PATH}: {exc}")
        doc_bonus_target_kinds = set()

    bonus_target_mapping_kinds = _mapping_kinds(
        MARKET_ROUTER_MAPPING,
        r"createBonusTargetEscrowEvent\([^\n]+?['\"]([A-Z_]+)['\"]",
    )

    if schema_bonus_target_kinds != EXPECTED_BONUS_TARGET_ESCROW_EVENT_KINDS:
        errors.append(
            "BonusTargetEscrowEvent schema kind set mismatch: "
            f"expected [{_fmt(EXPECTED_BONUS_TARGET_ESCROW_EVENT_KINDS)}], "
            f"got [{_fmt(schema_bonus_target_kinds)}]"
        )

    if doc_bonus_target_kinds != EXPECTED_BONUS_TARGET_ESCROW_EVENT_KINDS:
        errors.append(
            "BonusTargetEscrowEvent doc kind set mismatch: "
            f"expected [{_fmt(EXPECTED_BONUS_TARGET_ESCROW_EVENT_KINDS)}], "
            f"got [{_fmt(doc_bonus_target_kinds)}]"
        )

    if bonus_target_mapping_kinds != EXPECTED_BONUS_TARGET_ESCROW_EVENT_KINDS:
        errors.append(
            "BonusTargetEscrowEvent mapping kind set mismatch: "
            f"expected [{_fmt(EXPECTED_BONUS_TARGET_ESCROW_EVENT_KINDS)}], "
            f"got [{_fmt(bonus_target_mapping_kinds)}]"
        )

    try:
        exec_body = _extract_function_body(market_router, "handleBonusTargetEscrowExecuted")
        if not re.search(r"createBonusTargetEscrowEvent\([^\n]+?['\"]FILLED['\"]", exec_body):
            errors.append(
                "handleBonusTargetEscrowExecuted must create the canonical "
                'BonusTargetEscrowEvent(kind="FILLED") history row'
            )
    except ValueError as exc:
        errors.append(f"{MARKET_ROUTER_MAPPING}: {exc}")

    try:
        schema_market_trade_kinds = _extract_kind_comment_values(schema, "MarketTradeEvent")
    except ValueError as exc:
        errors.append(f"{SCHEMA_PATH}: {exc}")
        schema_market_trade_kinds = set()

    try:
        doc_market_trade_kinds = _extract_kind_comment_values(doc, "MarketTradeEvent")
    except ValueError as exc:
        errors.append(f"{DOC_PATH}: {exc}")
        doc_market_trade_kinds = set()

    market_trade_mapping_kinds = _mapping_kinds(FURNACE_MAPPING, r"trade\.kind\s*=\s*['\"]([A-Z_]+)['\"]")

    if schema_market_trade_kinds != EXPECTED_MARKET_TRADE_EVENT_KINDS:
        errors.append(
            "MarketTradeEvent schema kind set mismatch: "
            f"expected [{_fmt(EXPECTED_MARKET_TRADE_EVENT_KINDS)}], "
            f"got [{_fmt(schema_market_trade_kinds)}]"
        )

    if doc_market_trade_kinds != EXPECTED_MARKET_TRADE_EVENT_KINDS:
        errors.append(
            "MarketTradeEvent doc kind set mismatch: "
            f"expected [{_fmt(EXPECTED_MARKET_TRADE_EVENT_KINDS)}], "
            f"got [{_fmt(doc_market_trade_kinds)}]"
        )

    if market_trade_mapping_kinds != EXPECTED_MARKET_TRADE_EVENT_KINDS:
        errors.append(
            "MarketTradeEvent mapping kind set mismatch: "
            f"expected [{_fmt(EXPECTED_MARKET_TRADE_EVENT_KINDS)}], "
            f"got [{_fmt(market_trade_mapping_kinds)}]"
        )

    if errors:
        print("Subgraph derived event-kind parity: FAILED")
        for err in errors:
            print(f"- {err}")
        print("\nFix guidance:")
        print("- Keep subgraph/schema.graphql and docs/analytics/subgraph-schema-v1.0.0.md aligned with emitted derived kinds.")
        print("- Ensure handleBonusTargetEscrowExecuted writes the canonical FILLED history row.")
        print("- Do not advertise unsupported MarketTradeEvent kinds in strict mode.")
        return 1

    print("Subgraph derived event-kind parity: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
