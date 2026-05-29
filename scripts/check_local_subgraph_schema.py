#!/usr/bin/env python3
"""Check that the locally deployed subgraph serves every Query root used by repo GraphQL callers.

This catches schema drift where the subgraph code/schema changed but the local graph-node deployment
was not redeployed. The required root-field set is derived from actual GraphQL queries in
repo caller source instead of a stale hand-maintained allowlist.

Run: python3 scripts/check_local_subgraph_schema.py

Exit codes:
  0 = OK (schema matches or subgraph not running - skip in CI)
  1 = Schema mismatch (needs redeploy)
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

SUBGRAPH_URL = "http://127.0.0.1:8000/subgraphs/name/claimrush/local"
MAX_SUBGRAPH_RESPONSE_BYTES = 1_000_000
REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE_EXTS = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}
VIRTUAL_QUERY_ROOTS = {
    "leaderboardTopKingClaimMined",
    "leaderboardLongestReign",
    "leaderboardMostTakeovers",
    "leaderboardTopEthSpentOnTakeovers",
    "leaderboardTopBaronsByEthClaimed",
    "leaderboardTopBaronsByVe",
    "leaderboardTopFurnaceClaimIn",
    "leaderboardTopFurnaceEthIn",
}
GRAPHQL_TEMPLATE_RE = re.compile(r"(?:/\*\s*GraphQL\s*\*/\s*|gql\s*)`([\s\S]*?)`")
ALL_TEMPLATE_RE = re.compile(r"`([\s\S]*?)`")
GRAPHQL_OPERATION_RE = re.compile(r"\b(query|mutation|subscription)\s+([A-Za-z0-9_]+)\s*(\(|\{)")
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

INTROSPECTION_QUERY = """
query IntrospectQueryType {
  __schema {
    queryType {
      fields {
        name
      }
    }
  }
}
"""


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        raise urllib.error.HTTPError(req.full_url, code, f"redirects not allowed: {newurl}", headers, fp)


def _decode_json_response_bytes(raw: bytes) -> Tuple[Optional[dict], Optional[str]]:
    if len(raw) > MAX_SUBGRAPH_RESPONSE_BYTES:
        return None, f"response_too_large>{MAX_SUBGRAPH_RESPONSE_BYTES}"
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None, "response_not_utf8"
    try:
        body = json.loads(decoded)
    except Exception:
        return None, "response_not_json"
    if not isinstance(body, dict):
        return None, "response_not_object"
    return body, None


def make_request(query: str) -> Tuple[Optional[dict], Optional[str]]:
    try:
        data = json.dumps({"query": query}).encode("utf-8")
        req = urllib.request.Request(
            SUBGRAPH_URL,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        opener = urllib.request.build_opener(_NoRedirectHandler)
        with opener.open(req, timeout=5) as resp:
            return _decode_json_response_bytes(resp.read(MAX_SUBGRAPH_RESPONSE_BYTES + 1))
    except urllib.error.HTTPError as exc:
        if 300 <= exc.code < 400:
            return None, f"redirect:{exc.code}"
        return None, f"http_error:{exc.code}"
    except urllib.error.URLError:
        return None, "not_reachable"
    except Exception:
        return None, "request_failed"


def fetch_schema_fields() -> Tuple[Optional[List[str]], Optional[str]]:
    body, request_error = make_request(INTROSPECTION_QUERY)
    if request_error is not None:
        return None, request_error

    errors = body.get("errors", [])
    if errors:
        msg = errors[0].get("message", "")
        if "has not started syncing yet" in msg:
            return None, "not_syncing"
        return None, f"error: {msg}"

    fields = body.get("data", {}).get("__schema", {}).get("queryType", {}).get("fields", [])
    return [f["name"] for f in fields], None


def extract_graphql_templates(source: str) -> List[str]:
    out: Set[str] = set()
    for match in GRAPHQL_TEMPLATE_RE.finditer(source):
        out.add(match.group(1) or "")
    for match in ALL_TEMPLATE_RE.finditer(source):
        tpl = match.group(1) or ""
        if GRAPHQL_OPERATION_RE.search(tpl):
            out.add(tpl)
    return list(out)


def default_source_dirs() -> List[Path]:
    env_raw = os.environ.get("LOCAL_SUBGRAPH_CALLER_DIRS", "").strip()
    if env_raw:
        out: List[Path] = []
        for raw in env_raw.split(os.pathsep):
            raw = raw.strip()
            if not raw:
                continue
            out.append((REPO_ROOT / raw).resolve() if not Path(raw).is_absolute() else Path(raw))
        return out

    excluded_top_level = {
        ".git",
        ".github",
        "abis",
        "analytics",
        "brand",
        "deployments",
        "docs",
        "lib",
        "node_modules",
        "out",
        "script",
        "signatures",
        "src",
        "subgraph",
        "test",
    }
    discovered: List[Path] = []
    seen: Set[Path] = set()
    for path in REPO_ROOT.rglob("src"):
        if not path.is_dir():
            continue
        try:
            rel = path.relative_to(REPO_ROOT)
        except ValueError:
            continue
        if not rel.parts:
            continue
        if rel.parts[0] in excluded_top_level or rel.parts[0].endswith("-site"):
            continue
        if "node_modules" in rel.parts:
            continue
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        discovered.append(resolved)
    return discovered


def iter_source_files() -> Iterable[Path]:
    for base in default_source_dirs():
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.is_file() and path.suffix.lower() in SOURCE_EXTS:
                yield path


def strip_js_interpolations(template: str) -> str:
    out: List[str] = []
    i = 0
    n = len(template)
    while i < n:
        if template[i] == "$" and i + 1 < n and template[i + 1] == "{":
            out.append("__INTERP__")
            i += 2
            depth = 1
            while i < n and depth > 0:
                ch = template[i]
                if ch in {'"', "'", "`"}:
                    quote = ch
                    i += 1
                    while i < n:
                        ch = template[i]
                        if ch == "\\":
                            i += 2
                            continue
                        if ch == quote:
                            i += 1
                            break
                        i += 1
                    continue
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                i += 1
            continue
        out.append(template[i])
        i += 1
    return "".join(out)


def skip_comment(src: str, i: int) -> int:
    while i < len(src) and src[i] != "\n":
        i += 1
    return i


def skip_string(src: str, i: int) -> int:
    if src.startswith('"""', i):
        end = src.find('"""', i + 3)
        return len(src) if end == -1 else end + 3

    quote = src[i]
    i += 1
    while i < len(src):
        ch = src[i]
        if ch == "\\":
            i += 2
            continue
        if ch == quote:
            return i + 1
        i += 1
    return len(src)


def skip_ws_and_commas(src: str, i: int) -> int:
    while i < len(src):
        ch = src[i]
        if ch == '#':
            i = skip_comment(src, i)
            continue
        if ch == ',' or ch.isspace():
            i += 1
            continue
        break
    return i


def read_name(src: str, i: int) -> Optional[Tuple[str, int]]:
    m = NAME_RE.match(src, i)
    if not m:
        return None
    return m.group(0), m.end()


def skip_balanced(src: str, i: int, open_char: str, close_char: str) -> int:
    depth = 0
    while i < len(src):
        ch = src[i]
        if ch == '#':
            i = skip_comment(src, i)
            continue
        if ch in {'"', "'"}:
            i = skip_string(src, i)
            continue
        if ch == open_char:
            depth += 1
            i += 1
            continue
        if ch == close_char:
            depth -= 1
            i += 1
            if depth == 0:
                return i
            continue
        i += 1
    return len(src)


def skip_directives_and_args(src: str, i: int) -> int:
    while i < len(src):
        i = skip_ws_and_commas(src, i)
        if i < len(src) and src[i] == '(':
            i = skip_balanced(src, i, '(', ')')
            continue
        if i < len(src) and src[i] == '@':
            i += 1
            name = read_name(src, i)
            if name is not None:
                _, i = name
            i = skip_ws_and_commas(src, i)
            if i < len(src) and src[i] == '(':
                i = skip_balanced(src, i, '(', ')')
            continue
        break
    return i


def find_first_selection_set(query: str) -> int:
    i = 0
    while i < len(query):
        ch = query[i]
        if ch == '#':
            i = skip_comment(query, i)
            continue
        if ch in {'"', "'"}:
            i = skip_string(query, i)
            continue
        if ch == '{':
            return i
        i += 1
    return -1


def extract_top_level_fields(query: str) -> List[str]:
    fields: List[str] = []
    start = find_first_selection_set(query)
    if start < 0:
        return fields

    i = start + 1
    depth = 1
    while i < len(query) and depth > 0:
        i = skip_ws_and_commas(query, i)
        if i >= len(query):
            break

        if query.startswith('...', i):
            i += 3
            i = skip_ws_and_commas(query, i)
            name = read_name(query, i)
            if name is not None:
                _, i = name
            i = skip_directives_and_args(query, i)
            i = skip_ws_and_commas(query, i)
            if i < len(query) and query[i] == '{':
                i = skip_balanced(query, i, '{', '}')
            continue

        if query[i] == '}':
            depth -= 1
            i += 1
            continue

        if depth != 1:
            if query[i] == '{':
                depth += 1
            i += 1
            continue

        first = read_name(query, i)
        if first is None:
            if query[i] == '{':
                depth += 1
            i += 1
            continue
        field_name, j = first
        j = skip_ws_and_commas(query, j)
        if j < len(query) and query[j] == ':':
            second = read_name(query, skip_ws_and_commas(query, j + 1))
            if second is None:
                i = j + 1
                continue
            field_name, j = second

        if field_name != '__INTERP__':
            fields.append(field_name)
        j = skip_directives_and_args(query, j)
        j = skip_ws_and_commas(query, j)
        if j < len(query) and query[j] == '{':
            j = skip_balanced(query, j, '{', '}')
        i = j

    return fields


def collect_required_query_roots() -> Dict[str, Set[str]]:
    roots_to_locations: Dict[str, Set[str]] = {"_meta": {"built-in metadata"}}
    for file_path in iter_source_files():
        source = file_path.read_text(encoding="utf-8", errors="ignore")
        rel = file_path.relative_to(REPO_ROOT).as_posix()
        for tpl in extract_graphql_templates(source):
            op_match = GRAPHQL_OPERATION_RE.search(tpl)
            if not op_match:
                continue
            op_name = op_match.group(2)
            sanitized = strip_js_interpolations(tpl)
            for root in extract_top_level_fields(sanitized):
                if root in VIRTUAL_QUERY_ROOTS:
                    continue
                roots_to_locations.setdefault(root, set()).add(f"{rel}::{op_name}")
    return roots_to_locations


def main() -> int:
    fields, error = fetch_schema_fields()

    if error == "not_reachable":
        print("SKIP: Local subgraph not reachable at", SUBGRAPH_URL)
        print("      Run 'bash scripts/graphnode_local_up.sh && bash scripts/subgraph_deploy_local.sh' to start it.")
        return 0

    if error == "not_syncing":
        print("SKIP: Local subgraph deployed but not syncing yet.")
        print("      This is normal - the subgraph needs the chain to produce blocks.")
        print("      Run some transactions on Anvil to trigger block production.")
        return 0

    if error:
        print(f"SKIP: Could not check subgraph schema: {error}")
        return 0

    if fields is None or len(fields) == 0:
        print("SKIP: Subgraph returned empty schema (may still be initializing)")
        return 0

    required_roots = collect_required_query_roots()
    if not required_roots:
        print("SKIP: No GraphQL caller roots found in shipped source dirs.")
        return 0
    missing = sorted(root for root in required_roots if root not in fields)

    if missing:
        print("FAIL: Local subgraph schema is outdated!")
        print()
        print("Missing Query roots used by repo callers:")
        for root in missing:
            locations = sorted(required_roots[root])
            suffix = f" (used by: {', '.join(locations[:3])}"
            if len(locations) > 3:
                suffix += f", +{len(locations) - 3} more"
            suffix += ")"
            print(f"- {root}{suffix}")
        print()
        print("Fix: Redeploy the subgraph with:")
        print("  bash scripts/subgraph_deploy_local.sh")
        print()
        return 1

    print(f"OK: Local subgraph schema exposes all {len(required_roots)} query roots used by repo callers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
