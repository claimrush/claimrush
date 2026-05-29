#!/usr/bin/env python3
"""Validate that every entity directly constructed by a mapping is declared in manifest mapping.entities.

Why this exists
- The subgraph can silently drift when a mapping starts writing a new entity but the manifest's
  `entities:` allowlist is not updated.
- Missing declarations are easy to miss in review because builds often keep working until a
  downstream tool or deployment path depends on the manifest metadata.

What it checks
- For every datasource/template mapping file, find direct `new EntityName(` constructions where
  `EntityName` was imported from `../generated/schema` (including aliased imports).
- Fail if any constructed entity is absent from the mapping's declared `entities:` list.

Usage
  python3 scripts/check_subgraph_manifest_entities.py subgraph/subgraph.yaml
  python3 scripts/check_subgraph_manifest_entities.py subgraph/subgraph.yaml subgraph/subgraph.prod.yaml

Exit codes
  0 = all manifests passed
  1 = manifest entity completeness violation found
  2 = invalid input / missing dependencies
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Set, Tuple

try:
    import yaml  # type: ignore
except ModuleNotFoundError:
    print(
        "ERROR: PyYAML not installed. Install pinned deps: python3 -m pip install -r requirements-ci.txt",
        file=sys.stderr,
    )
    sys.exit(2)

ENTITY_TYPE_RE = re.compile(r"\btype\s+([A-Za-z0-9_]+)\s+@entity(?:\([^)]*\))?")
SCHEMA_IMPORT_RE = re.compile(
    r"import\s*{(?P<body>[\s\S]*?)}\s*from\s*[\"']\.\./generated/schema[\"'];",
    re.MULTILINE,
)
IMPORT_PART_RE = re.compile(r"^([A-Za-z0-9_]+)(?:\s+as\s+([A-Za-z0-9_]+))?$")
NEW_ENTITY_RE = re.compile(r"\bnew\s+([A-Za-z0-9_]+)\s*\(")


def parse_yaml(path: Path) -> Dict[str, Any]:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def load_schema_entities(schema_path: Path) -> Set[str]:
    return {m.group(1) for m in ENTITY_TYPE_RE.finditer(schema_path.read_text(encoding="utf-8"))}


def parse_schema_import_aliases(mapping_src: str) -> Dict[str, str]:
    aliases: Dict[str, str] = {}
    for match in SCHEMA_IMPORT_RE.finditer(mapping_src):
        body = match.group("body") or ""
        for raw_part in body.split(','):
            part = raw_part.strip()
            if not part:
                continue
            m = IMPORT_PART_RE.match(part)
            if not m:
                continue
            original = m.group(1)
            alias = m.group(2) or original
            aliases[alias] = original
    return aliases


def constructed_entities(mapping_path: Path, schema_entities: Set[str]) -> Set[str]:
    src = mapping_path.read_text(encoding="utf-8")
    aliases = parse_schema_import_aliases(src)
    constructed: Set[str] = set()
    for match in NEW_ENTITY_RE.finditer(src):
        alias = match.group(1)
        entity = aliases.get(alias)
        if entity is None:
            continue
        if entity not in schema_entities:
            continue
        constructed.add(entity)
    return constructed


def iter_mappings(doc: Dict[str, Any]) -> Iterable[Tuple[str, str, Dict[str, Any]]]:
    for kind in ("dataSources", "templates"):
        for item in doc.get(kind, []) or []:
            mapping = item.get("mapping") or {}
            name = item.get("name", "<unnamed>")
            yield kind, name, mapping


def check_manifest(manifest_path: Path, schema_entities: Set[str]) -> List[str]:
    doc = parse_yaml(manifest_path)
    errors: List[str] = []
    base_dir = manifest_path.parent
    for kind, name, mapping in iter_mappings(doc):
        mapping_file = mapping.get("file")
        if not mapping_file:
            continue
        mapping_path = (base_dir / mapping_file).resolve()
        if not mapping_path.exists():
            errors.append(f"[{kind}:{name}] mapping file not found: {mapping_file}")
            continue
        declared = set(mapping.get("entities", []) or [])
        required = constructed_entities(mapping_path, schema_entities)
        missing = sorted(required - declared)
        if missing:
            errors.append(
                f"[{kind}:{name}] mapping constructs entities missing from manifest entities[]: {', '.join(missing)}"
            )
    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description="Check subgraph manifest entity completeness")
    ap.add_argument("manifests", nargs="+", help="One or more subgraph manifest YAML files")
    args = ap.parse_args()

    schema_entities = load_schema_entities(Path("subgraph/schema.graphql"))
    failures = 0
    for manifest in args.manifests:
        path = Path(manifest)
        if not path.exists():
            print(f"ERROR: manifest not found: {manifest}", file=sys.stderr)
            return 2
        errors = check_manifest(path, schema_entities)
        if errors:
            failures += 1
            print(f"Manifest entity completeness: FAILED [{manifest}]")
            for err in errors:
                print(f"- {err}")
        else:
            print(f"Manifest entity completeness: OK [{manifest}]")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
