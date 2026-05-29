#!/usr/bin/env python3
"""Verify Furnace bonus rollups source delivered values from receipt events.

`BonusPaid.userBonusClaim` carries the raw AMM user split before Furnace
refunds sub-MIN_TOPUP user dust to reserve. Public headline totals therefore
sum the delivered bonus from the receipt events: `FurnaceEnter`,
`FurnaceMergeWithBonus`, and `AutoMaxBonusClaimed`.
"""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAPPING = ROOT / "subgraph/src/mappings/furnace.ts"
MANIFESTS = [
    ROOT / "subgraph/subgraph.yaml",
    ROOT / "subgraph/subgraph.prod.yaml",
    ROOT / "subgraph/subgraph.staging.yaml",
    ROOT / "subgraph/subgraph.local.yaml",
]


def function_body(src: str, name: str) -> str:
    marker = f"export function {name}"
    start = src.find(marker)
    if start < 0:
        raise AssertionError(f"missing {name} in {MAPPING}")

    brace = src.find("{", start)
    if brace < 0:
        raise AssertionError(f"missing body for {name}")

    depth = 0
    for i in range(brace, len(src)):
        ch = src[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[brace + 1 : i]

    raise AssertionError(f"unterminated body for {name}")


def main() -> int:
    src = MAPPING.read_text(encoding="utf-8")

    bonus_paid = function_body(src, "handleBonusPaid")
    if "totalUserBonus" in bonus_paid:
        raise AssertionError(
            "handleBonusPaid must not increment DailyFurnaceAgg.totalUserBonus; "
            "use delivered receipt events instead"
        )
    if "recordPendingBonusPaid(event)" not in bonus_paid:
        raise AssertionError("handleBonusPaid must record pending raw AMM bonus data")

    if "PendingBonusPaidQueue" not in src or "pendingBonusPaidQueueId" not in src:
        raise AssertionError("pending BonusPaid matching must use a per-(tx,user) FIFO queue")

    for handler in ("handleFurnaceEnter", "handleFurnaceMergeWithBonus", "handleAutoMaxBonusClaimed"):
        body = function_body(src, handler)
        if "settleDeliveredUserBonus(" not in body:
            raise AssertionError(f"{handler} must settle delivered user bonus")

    schema = (ROOT / "subgraph/schema.graphql").read_text(encoding="utf-8")
    if "type PendingBonusPaidQueue" not in schema:
        raise AssertionError("schema must include PendingBonusPaidQueue helper entity")
    if "type PendingBonusPaid" not in schema:
        raise AssertionError("schema must include PendingBonusPaid helper entity")

    for manifest in MANIFESTS:
        text = manifest.read_text(encoding="utf-8")
        if "FurnaceMergeWithBonusEvent" not in text:
            raise AssertionError(f"{manifest}: missing FurnaceMergeWithBonusEvent entity")
        if "PendingBonusPaidQueue" not in text:
            raise AssertionError(f"{manifest}: missing PendingBonusPaidQueue entity")
        if "PendingBonusPaid" not in text:
            raise AssertionError(f"{manifest}: missing PendingBonusPaid entity")
        if not re.search(r"event:\s*FurnaceMergeWithBonus\(indexed address,indexed uint256,indexed uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256\)", text):
            raise AssertionError(f"{manifest}: missing FurnaceMergeWithBonus handler")

    print("Subgraph bonus rollup semantics: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
