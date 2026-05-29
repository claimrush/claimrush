#!/usr/bin/env python3
"""Validate the docs event checklist against shipped ABIs and subgraph manifests.

Why this exists
- The analytics schema doc contains a human-maintained "required" event checklist.
- A docs typo or stale bullet can silently claim an event is indexed even when it is not emitted,
  not exported in ABI, or not wired into manifests.

What it checks
- Every checklist event exists in the canonical exported ABI for the named contract.
- Every checklist event is wired into at least one committed subgraph manifest handler.
- A tiny normalization layer covers standard-library wording like "ERC721 Transfer".

Usage
  python3 scripts/check_subgraph_doc_event_checklist.py

Exit codes
  0 = docs checklist matches current ABI + manifest coverage
  1 = drift found
  2 = invalid repo layout / missing dependency
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Set

try:
    import yaml  # type: ignore
except ModuleNotFoundError:
    print(
        "ERROR: PyYAML not installed. Install pinned deps: python3 -m pip install -r requirements-ci.txt",
        file=sys.stderr,
    )
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / 'docs/analytics/subgraph-schema-v1.0.0.md'
ABI_DIR = ROOT / 'abis/base_mainnet'
MANIFESTS = (
    ROOT / 'subgraph/subgraph.yaml',
    ROOT / 'subgraph/subgraph.local.yaml',
    ROOT / 'subgraph/subgraph.prod.yaml',
    ROOT / 'subgraph/subgraph.staging.yaml',
)
SECTION_RE = re.compile(
    r"## E\) Event-to-entity mapping checklist \(required\)\n(?P<body>.*?)(?:\n## [A-Z]|\Z)",
    re.S,
)
EVENT_RE = re.compile(r"^(?P<name>[A-Za-z0-9_]+)\((?P<args>.*)\)$")

DOC_EVENT_NAME_OVERRIDES = {
    ('VeClaimNFT', 'ERC721 `Transfer`'): 'Transfer',
    ('VeClaimNFT', 'ERC721 Transfer'): 'Transfer',
}


def load_yaml(path: Path):
    return yaml.safe_load(path.read_text(encoding='utf-8'))


def load_abi_event_names(path: Path) -> Set[str]:
    raw = json.loads(path.read_text(encoding='utf-8'))
    names: Set[str] = set()
    for item in raw:
        if item.get('type') != 'event':
            continue
        name = item.get('name')
        if isinstance(name, str) and name:
            names.add(name)
    return names


def parse_manifest_event_name(sig: str) -> str:
    m = EVENT_RE.match(sig.strip())
    if not m:
        raise ValueError(f'invalid event signature: {sig}')
    return m.group('name')


def collect_manifest_events() -> Dict[str, Set[str]]:
    out: Dict[str, Set[str]] = {}
    for manifest in MANIFESTS:
        data = load_yaml(manifest)
        for group_key in ('dataSources', 'templates'):
            for ds in data.get(group_key, []) or []:
                source = ds.get('source') or {}
                abi_name = source.get('abi')
                mapping = ds.get('mapping') or {}
                if not isinstance(abi_name, str) or not abi_name:
                    continue
                dest = out.setdefault(abi_name, set())
                for eh in mapping.get('eventHandlers', []) or []:
                    sig = eh.get('event')
                    if not isinstance(sig, str) or not sig:
                        continue
                    dest.add(parse_manifest_event_name(sig))
    return out


def parse_doc_checklist() -> Dict[str, List[str]]:
    text = DOC.read_text(encoding='utf-8')
    m = SECTION_RE.search(text)
    if not m:
        raise ValueError('could not find required checklist section in docs/analytics/subgraph-schema-v1.0.0.md')

    body = m.group('body')
    result: Dict[str, List[str]] = {}
    current_contract: str | None = None

    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.endswith(':') and not line.startswith('- '):
            label = line[:-1].strip()
            if label.lower().startswith('index these events'):
                current_contract = None
                continue
            current_contract = re.sub(r"\s+\(.*\)$", '', label)
            result.setdefault(current_contract, [])
            continue
        if not line.startswith('- ') or current_contract is None:
            continue

        value = line[2:].strip()
        value = re.sub(r"\s*\(.*$", '', value).strip()
        value = DOC_EVENT_NAME_OVERRIDES.get((current_contract, value), value)
        if value.startswith('`') and value.endswith('`'):
            value = value[1:-1]
        result[current_contract].append(value)

    return result


def main() -> int:
    if not DOC.exists():
        print(f'ERROR: missing doc: {DOC}', file=sys.stderr)
        return 2
    if not ABI_DIR.exists():
        print(f'ERROR: missing ABI dir: {ABI_DIR}', file=sys.stderr)
        return 2

    abi_events: Dict[str, Set[str]] = {}
    for path in ABI_DIR.glob('*.abi.json'):
        abi_events[path.stem.replace('.abi', '')] = load_abi_event_names(path)

    try:
        doc_checklist = parse_doc_checklist()
    except ValueError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2

    manifest_events = collect_manifest_events()
    errors: List[str] = []

    for contract, events in doc_checklist.items():
        abi_names = abi_events.get(contract)
        if abi_names is None:
            errors.append(f'doc checklist references unknown ABI contract `{contract}`')
            continue

        handled = manifest_events.get(contract, set())
        for event_name in events:
            if event_name not in abi_names:
                errors.append(
                    f'docs checklist drift: `{contract}.{event_name}` is listed as required but is absent from {ABI_DIR / (contract + ".abi.json")}'
                )
                continue
            if event_name not in handled:
                errors.append(
                    f'docs checklist drift: `{contract}.{event_name}` is listed as required but no committed subgraph manifest wires a handler for it'
                )

    if errors:
        print('Subgraph docs event-checklist drift detected:', file=sys.stderr)
        for err in errors:
            print(f'  - {err}', file=sys.stderr)
        return 1

    print('OK: docs required event checklist matches shipped ABIs + committed manifests')
    return 0


if __name__ == '__main__':
    sys.exit(main())
