#!/usr/bin/env python3
"""Check subgraph/schema.graphql matches the pinned v1.0.0 schema doc.

Why this exists
- The UI contract is pinned in docs/analytics/subgraph-schema-v1.0.0.md.
- The deployed subgraph schema.graphql must be a *superset* of that contract:
  - Required types/enums must exist.
  - Required fields must exist with the same GraphQL types (including nullability).
  - Extra types/fields are allowed.

Usage
  python3 scripts/check_subgraph_schema_vs_doc.py \
    --doc docs/analytics/subgraph-schema-v1.0.0.md \
    --schema subgraph/schema.graphql

Exit code
- 0 if schema satisfies the pinned contract
- 1 if any missing/mismatched type/field/enum is found
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Set, Tuple


@dataclass(frozen=True)
class Field:
    name: str
    gql_type: str


def _extract_graphql_blocks(md: str) -> List[str]:
    blocks: List[str] = []
    for m in re.finditer(r"```graphql\n(.*?)\n```", md, flags=re.S):
        blocks.append(m.group(1))
    return blocks


def _strip_comments(s: str) -> str:
    # Remove whole-line and trailing # comments.
    out_lines: List[str] = []
    for line in s.splitlines():
        if "#" in line:
            line = line.split("#", 1)[0]
        out_lines.append(line)
    return "\n".join(out_lines)


def _normalize_ws(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def _parse_types_and_enums(sdl: str) -> Tuple[Dict[str, Dict[str, Field]], Dict[str, List[str]]]:
    """Parse GraphQL SDL for `type` and `enum` blocks.

    Notes
    - This is a small permissive parser (no external deps).
    - It ignores directives like `@entity`.
    - It ignores interfaces/inputs/unions (not used in the pinned schema doc).
    """

    sdl = _strip_comments(sdl)

    # Enums
    enums: Dict[str, List[str]] = {}
    for m in re.finditer(r"\benum\s+([A-Za-z0-9_]+)\s*{(.*?)}", sdl, flags=re.S):
        name = m.group(1)
        body = m.group(2)
        values = [v.strip() for v in body.splitlines() if v.strip()]
        enums[name] = values

    # Types
    types: Dict[str, Dict[str, Field]] = {}

    # Match `type Name ... { ... }`
    # Allow optional directives between name and `{`.
    for m in re.finditer(
        r"\btype\s+([A-Za-z0-9_]+)(?:\s+@[^\n{]+)*\s*{(.*?)}",
        sdl,
        flags=re.S,
    ):
        name = m.group(1)
        body = m.group(2)

        fields: Dict[str, Field] = {}
        for raw in body.splitlines():
            line = raw.strip()
            if not line:
                continue

            # Skip block comments and anything that isn't `name: Type`.
            if ":" not in line:
                continue

            # Remove any directives on the field itself.
            # Example: `foo: BigInt! @derivedFrom(field: "..." )`
            line = line.split("@", 1)[0].strip()

            m_field = re.match(r"^([A-Za-z0-9_]+)\s*:\s*(.+)$", line)
            if not m_field:
                continue

            fname = m_field.group(1)
            ftype = _normalize_ws(m_field.group(2))
            fields[fname] = Field(name=fname, gql_type=ftype)

        types[name] = fields

    return types, enums


def main() -> int:
    ap = argparse.ArgumentParser(description="Check subgraph schema matches pinned v1.0.0 doc")
    ap.add_argument(
        "--doc",
        default="docs/analytics/subgraph-schema-v1.0.0.md",
        help="Pinned schema doc (default: docs/analytics/subgraph-schema-v1.0.0.md)",
    )
    ap.add_argument(
        "--schema",
        default="subgraph/schema.graphql",
        help="Subgraph schema file (default: subgraph/schema.graphql)",
    )
    args = ap.parse_args()

    doc_path = Path(args.doc)
    schema_path = Path(args.schema)

    if not doc_path.exists():
        print(f"Subgraph schema vs doc: FAILED\n- missing doc file: {doc_path}")
        return 2

    if not schema_path.exists():
        print(f"Subgraph schema vs doc: FAILED\n- missing schema file: {schema_path}")
        return 2

    doc = doc_path.read_text(encoding="utf-8")
    schema = schema_path.read_text(encoding="utf-8")

    doc_blocks = _extract_graphql_blocks(doc)
    doc_sdl = "\n\n".join(doc_blocks)

    doc_types, doc_enums = _parse_types_and_enums(doc_sdl)
    schema_types, schema_enums = _parse_types_and_enums(schema)

    errors: List[str] = []

    # Types: schema must be a superset
    for tname, tfields in doc_types.items():
        if tname not in schema_types:
            errors.append(f"Missing type in schema: {tname}")
            continue

        sfields = schema_types[tname]
        for fname, f in tfields.items():
            if fname not in sfields:
                errors.append(f"{tname}.{fname}: missing field in schema")
                continue

            got = sfields[fname].gql_type
            exp = f.gql_type
            if got != exp:
                errors.append(f"{tname}.{fname}: type mismatch (expected {exp}, got {got})")

    # Enums: should match exactly (values)
    for ename, evals in doc_enums.items():
        if ename not in schema_enums:
            errors.append(f"Missing enum in schema: {ename}")
            continue

        got = schema_enums[ename]
        if got != evals:
            errors.append(f"Enum {ename}: value mismatch (expected {evals}, got {got})")

    if errors:
        print("Subgraph schema vs doc: FAILED")
        for e in errors:
            print(f"- {e}")
        print("\nFix guidance:")
        print("- Update subgraph/schema.graphql to satisfy docs/analytics/subgraph-schema-v1.0.0.md")
        print("- Re-run this check and re-deploy the subgraph")
        return 1

    print("Subgraph schema vs doc: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
