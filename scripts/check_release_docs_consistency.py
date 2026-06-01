#!/usr/bin/env python3
"""Check release documentation consistency across versioned docs.

This guardrail ensures that:
1. Every versioned doc referenced by the master index (docs/v1.0.0-index.md) exists.
2. The SECURITY.md documentation index entries all point to existing files.
3. Cross-references between versioned docs (e.g., "see docs/spec/...") resolve to
   files that actually exist in the repo.
4. No orphaned versioned docs exist that are not referenced by the master index.
5. Relative links inside docs/manuals/{developer,user}/ stay within their
   manual tree (per docs/manuals/LINKING.md). Cross-manual or out-of-tree
   references must use an absolute URL.

Usage:
    python3 scripts/check_release_docs_consistency.py

Exit codes:
    0 = all checks passed
    1 = consistency violation found
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import List, Optional, Set

ROOT = Path(__file__).resolve().parents[1]
VERSION = "v1.0.0"
INDEX_FILE = ROOT / "docs" / f"{VERSION}-index.md"
DOCS_README_FILE = ROOT / "docs" / "README.md"
SECURITY_FILE = ROOT / "SECURITY.md"

# This checker validates the markdown graph that survives the public export.
# These roots mirror the public-scope markdown surface shipped by
# scripts/seed-public-repo.sh.
PUBLIC_MARKDOWN_DIRS = (
    ROOT / "docs" / "manuals" / "developer",
    ROOT / "docs" / "manuals" / "user",
    ROOT / "docs" / "spec",
    ROOT / "docs" / "deployments",
    ROOT / "docs" / "analytics",
    ROOT / "docs" / "architecture",
    ROOT / "analytics",
    ROOT / "deployments",
    ROOT / "agents",
    ROOT / "keeper",
    ROOT / "skills",
    ROOT / "subgraph",
    ROOT / "packages" / "node-utils",
    ROOT / "plugins",
    ROOT / "brand",
)
PUBLIC_MARKDOWN_FILES = (
    ROOT / "docs" / "README.md",
    ROOT / "docs" / f"{VERSION}-index.md",
    ROOT / "docs" / "manuals" / "LINKING.md",
    ROOT / "docs" / "manuals" / "VERSIONING.md",
    ROOT / "docs" / "security" / "README.md",
    ROOT / "README.md",
    ROOT / "PUBLIC_RELEASE_POLICY.md",
    ROOT / "SECURITY.md",
    ROOT / "CLA.md",
    ROOT / "CONTRIBUTING.md",
    ROOT / "TRADEMARKS.md",
    ROOT / "CHANGELOG.md",
)
PUBLIC_MARKDOWN_EXCLUDES = {
    "docs/analytics/posthog-cloud-and-ai-setup-v1.0.0.md",
    "docs/analytics/ui-kpis-and-instrumentation-v1.0.0.md",
    "docs/spec/env-config-and-constants-v1.0.0.md",
    "docs/spec/real-time-layer-spec-v1.0.0.md",
    "docs/architecture/real-time-layer-v1.0.0.md",
}


def load_public_markdown_paths() -> Set[str]:
    """Return repo-relative markdown paths that ship in the public repo."""
    paths: Set[str] = set()

    for root in PUBLIC_MARKDOWN_DIRS:
        if not root.exists():
            continue
        for md in root.rglob("*.md"):
            rel = str(md.relative_to(ROOT))
            if rel not in PUBLIC_MARKDOWN_EXCLUDES:
                paths.add(rel)

    for md in PUBLIC_MARKDOWN_FILES:
        if not md.exists():
            continue
        rel = str(md.relative_to(ROOT))
        if rel not in PUBLIC_MARKDOWN_EXCLUDES:
            paths.add(rel)

    return paths


PUBLIC_MARKDOWN_PATHS = load_public_markdown_paths()
PUBLIC_DOC_PATHS = {path for path in PUBLIC_MARKDOWN_PATHS if path.startswith("docs/")}


def configure(repo_root: Path) -> None:
    global ROOT, INDEX_FILE, DOCS_README_FILE, SECURITY_FILE
    global PUBLIC_MARKDOWN_DIRS, PUBLIC_MARKDOWN_FILES, PUBLIC_MARKDOWN_PATHS, PUBLIC_DOC_PATHS

    ROOT = repo_root.resolve()
    INDEX_FILE = ROOT / "docs" / f"{VERSION}-index.md"
    DOCS_README_FILE = ROOT / "docs" / "README.md"
    SECURITY_FILE = ROOT / "SECURITY.md"
    PUBLIC_MARKDOWN_DIRS = (
        ROOT / "docs" / "manuals" / "developer",
        ROOT / "docs" / "manuals" / "user",
        ROOT / "docs" / "spec",
        ROOT / "docs" / "deployments",
        ROOT / "docs" / "analytics",
        ROOT / "docs" / "architecture",
        ROOT / "analytics",
        ROOT / "deployments",
        ROOT / "agents",
        ROOT / "keeper",
        ROOT / "skills",
        ROOT / "subgraph",
        ROOT / "packages" / "node-utils",
        ROOT / "plugins",
        ROOT / "brand",
    )
    PUBLIC_MARKDOWN_FILES = (
        ROOT / "docs" / "README.md",
        ROOT / "docs" / f"{VERSION}-index.md",
        ROOT / "docs" / "manuals" / "LINKING.md",
        ROOT / "docs" / "manuals" / "VERSIONING.md",
        ROOT / "docs" / "security" / "README.md",
        ROOT / "README.md",
        ROOT / "PUBLIC_RELEASE_POLICY.md",
        ROOT / "SECURITY.md",
        ROOT / "CLA.md",
        ROOT / "CONTRIBUTING.md",
        ROOT / "TRADEMARKS.md",
        ROOT / "CHANGELOG.md",
    )
    PUBLIC_MARKDOWN_PATHS = load_public_markdown_paths()
    PUBLIC_DOC_PATHS = {path for path in PUBLIC_MARKDOWN_PATHS if path.startswith("docs/")}


def _normalize_md_ref(ref: str, base_dir: Optional[Path]) -> Optional[str]:
    ref = ref.strip()
    if not ref or ref.startswith("#") or re.match(r"^[a-z]+://", ref):
        return None
    if any(ch in ref for ch in "<>*"):
        return None

    candidates = []
    if ref.startswith("docs/"):
        candidates.append(ROOT / ref)
    else:
        if base_dir is not None:
            candidates.append((base_dir / ref).resolve())
        candidates.append((ROOT / ref).resolve())

    normalized_candidates = []
    for full in candidates:
        try:
            rel = full.relative_to(ROOT)
        except ValueError:
            continue
        if rel.suffix != ".md":
            continue
        normalized = str(rel)
        normalized_candidates.append(normalized)
        if full.exists():
            return normalized

    if normalized_candidates:
        return normalized_candidates[0]
    return None


def _strip_fenced_code(text: str) -> str:
    """Remove triple-backtick fenced code blocks.

    Markdown links inside fenced blocks render as verbatim text, not as live
    links, so they should not be subjected to repo-link reachability checks.
    Example link demonstrations in convention pages (e.g. LINKING.md) live
    here and would otherwise produce spurious "missing file" errors.
    """
    return re.sub(r"```.*?```", "", text, flags=re.DOTALL)


def extract_md_paths(text: str, base_dir: Optional[Path] = None) -> Set[str]:
    """Extract repo-local markdown paths from backtick references and links."""
    paths: Set[str] = set()
    text = _strip_fenced_code(text)
    for m in re.finditer(r"`([^`\s][^`]*?\.md)`", text):
        normalized = _normalize_md_ref(m.group(1), base_dir)
        if normalized:
            paths.add(normalized)
    for m in re.finditer(r"\]\(([^)#]+\.md)\)", text):
        normalized = _normalize_md_ref(m.group(1), base_dir)
        if normalized:
            paths.add(normalized)
    return paths


def check_index_references() -> List[str]:
    """Verify every path in the master index exists."""
    errors: List[str] = []
    if not INDEX_FILE.exists():
        return [f"Master index not found: {INDEX_FILE.relative_to(ROOT)}"]

    text = INDEX_FILE.read_text(encoding="utf-8")
    refs = extract_md_paths(text, INDEX_FILE.parent)
    for ref in sorted(refs):
        full = ROOT / ref
        if not full.exists():
            errors.append(
                f"Index references missing file: {ref}"
            )
        elif ref not in PUBLIC_MARKDOWN_PATHS:
            errors.append(
                f"Index references non-public file: {ref}"
            )
    return errors


def check_security_references() -> List[str]:
    """Verify SECURITY.md documentation index entries exist."""
    errors: List[str] = []
    if not SECURITY_FILE.exists():
        return [f"SECURITY.md not found"]

    text = SECURITY_FILE.read_text(encoding="utf-8")
    in_index = False
    for line in text.splitlines():
        if "Security documentation index" in line:
            in_index = True
            continue
        if in_index and line.startswith("##"):
            break
        if in_index:
            for ref in extract_md_paths(line, SECURITY_FILE.parent):
                full = ROOT / ref
                if not full.exists():
                    errors.append(
                        f"SECURITY.md references missing file: {ref}"
                    )
                elif ref not in PUBLIC_MARKDOWN_PATHS:
                    errors.append(
                        f"SECURITY.md references non-public file: {ref}"
                    )
    return errors


def check_cross_references() -> List[str]:
    """Verify public docs only link to markdown that ships publicly."""
    errors: List[str] = []
    for rel in sorted(PUBLIC_DOC_PATHS):
        doc = ROOT / rel
        text = doc.read_text(encoding="utf-8")
        refs = extract_md_paths(text, doc.parent)
        for ref in sorted(refs):
            full = ROOT / ref
            if not full.exists():
                errors.append(
                    f"{rel} references missing: {ref}"
                )
            elif ref not in PUBLIC_MARKDOWN_PATHS:
                errors.append(
                    f"{rel} references non-public file: {ref}"
                )
    return errors


_MANUAL_LINK_RE = re.compile(r"\]\(([^)]+)\)")


def check_manual_link_locality() -> List[str]:
    """Reject relative links in manual pages that escape their manual tree.

    Per docs/manuals/LINKING.md, relative Markdown links inside
    docs/manuals/{developer,user}/ MUST resolve to a target inside the same
    manual tree. Cross-manual links and out-of-tree references must use an
    absolute URL (deployed site, GitHub permalink, or asset URL), so they
    render correctly on the deployed Nextra mirrors that only contain the
    manual subtree.

    Two narrow exceptions:
    - Shared umbrella files that live directly in docs/manuals/ (e.g.
      LINKING.md, VERSIONING.md) are allowed targets from any manual.
    - Anchors and absolute URLs are not inspected.
    """
    errors: List[str] = []
    manuals_umbrella = (ROOT / "docs" / "manuals").resolve()
    manual_roots = (
        ROOT / "docs" / "manuals" / "developer",
        ROOT / "docs" / "manuals" / "user",
    )
    resolved_roots = [r.resolve() for r in manual_roots if r.exists()]

    for manual_root in manual_roots:
        if not manual_root.exists():
            continue
        own_root_resolved = manual_root.resolve()
        for md in sorted(manual_root.rglob("*.md")):
            text = _strip_fenced_code(md.read_text(encoding="utf-8"))
            for m in _MANUAL_LINK_RE.finditer(text):
                target = m.group(1).strip()
                if not target:
                    continue
                if target.startswith(("http://", "https://", "mailto:", "tel:", "#")):
                    continue
                if any(ch in target for ch in "<>*"):
                    continue
                path_part = target.split("#", 1)[0].split("?", 1)[0]
                if not path_part:
                    continue
                resolved = (md.parent / path_part).resolve()

                # Same manual tree: allowed.
                try:
                    resolved.relative_to(own_root_resolved)
                    continue
                except ValueError:
                    pass

                # Shared umbrella file directly in docs/manuals/: allowed.
                # (e.g. docs/manuals/LINKING.md, docs/manuals/VERSIONING.md)
                if resolved.parent == manuals_umbrella and resolved.is_file():
                    continue

                # Other manual's subtree, or fully out-of-tree: rejected.
                rel_src = md.relative_to(ROOT)
                cross_manual = any(
                    _is_subpath(resolved, other)
                    for other in resolved_roots
                    if other != own_root_resolved
                )
                kind = "cross-manual" if cross_manual else "out-of-tree"
                errors.append(
                    f"{rel_src}: relative link escapes manual tree ({kind}): {target} "
                    f"(use deployed URL, GitHub permalink, or asset URL — "
                    f"see docs/manuals/LINKING.md)"
                )
    return errors


def _is_subpath(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def collect_reachable_public_docs() -> Set[str]:
    """Traverse repo-local markdown links starting from the public docs entrypoints."""
    seeds = [
        str(INDEX_FILE.relative_to(ROOT)),
        str(DOCS_README_FILE.relative_to(ROOT)),
    ]
    reachable: Set[str] = set()
    stack = [seed for seed in seeds if seed in PUBLIC_DOC_PATHS]

    while stack:
        rel = stack.pop()
        if rel in reachable:
            continue
        reachable.add(rel)
        full = ROOT / rel
        text = full.read_text(encoding="utf-8")
        for ref in extract_md_paths(text, full.parent):
            if ref in PUBLIC_DOC_PATHS and ref not in reachable:
                stack.append(ref)

    return reachable


def check_orphaned_docs() -> List[str]:
    """Warn about versioned docs not in the master index (non-blocking)."""
    warnings: List[str] = []
    if not INDEX_FILE.exists():
        return warnings

    reachable_docs = collect_reachable_public_docs()
    for rel in sorted(PUBLIC_DOC_PATHS):
        if VERSION not in Path(rel).name:
            continue
        if rel not in reachable_docs:
            warnings.append(f"Possibly orphaned (not in index): {rel}")

    return warnings


def main() -> int:
    parser = argparse.ArgumentParser(description="Check release documentation consistency across versioned docs.")
    parser.add_argument(
        "--repo-root",
        default=str(ROOT),
        help="Repo root to scan. Defaults to the repo containing this script.",
    )
    args = parser.parse_args()
    configure(Path(args.repo_root))

    errors: List[str] = []
    warnings: List[str] = []

    errors.extend(check_index_references())
    errors.extend(check_security_references())
    errors.extend(check_cross_references())
    errors.extend(check_manual_link_locality())
    warnings.extend(check_orphaned_docs())

    for w in warnings:
        print(f"[release-docs] WARN: {w}")

    if errors:
        for e in errors:
            print(f"[release-docs] ERROR: {e}", file=sys.stderr)
        print(
            f"\n[release-docs] FAIL: {len(errors)} consistency issue(s) found.",
            file=sys.stderr,
        )
        return 1

    print(f"[release-docs] OK ({len(warnings)} warnings)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
