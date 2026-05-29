#!/usr/bin/env python3
"""Guardrails for docs indexes and manuals truthiness.

Checks kept intentionally narrow and high leverage:
- docs indexes/READMEs/SUMMARY files must not link to missing local files.
- repo-local commands documented in the top-level docs indexes must reference
  real Make targets and script files.
- manuals SUMMARY files must cover every shipped manual page so pages do not
  silently drift out of navigation.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = ROOT / "Makefile"

DOC_INDEX_FILES = [
    ROOT / "docs" / "README.md",
    ROOT / "docs" / "v1.0.0-index.md",
]
MANUAL_INDEX_FILES = [
    ROOT / "docs" / "manuals" / "developer" / "README.md",
    ROOT / "docs" / "manuals" / "developer" / "SUMMARY.md",
    ROOT / "docs" / "manuals" / "user" / "README.md",
    ROOT / "docs" / "manuals" / "user" / "SUMMARY.md",
]
CHECKED_DOCS = DOC_INDEX_FILES + MANUAL_INDEX_FILES
MANUAL_ROOTS = [ROOT / "docs" / "manuals" / "developer", ROOT / "docs" / "manuals" / "user"]

MARKDOWN_LINK_RE = re.compile(r"\[[^\]]+\]\(([^)#]+)")
INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
MAKE_TARGET_RE = re.compile(r"(?<![A-Za-z0-9_.-])make\s+([A-Za-z0-9_.-]+)")
SCRIPT_CMD_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])(?:python3?|node|bash|sh)\s+([A-Za-z0-9_./-]+\.(?:py|mjs|js|sh))(?![A-Za-z0-9_./-])"
)
PY_LAUNCHER_RE = re.compile(r"(?<![A-Za-z0-9_.-])py\s+-3\s+([A-Za-z0-9_./-]+\.py)(?![A-Za-z0-9_./-])")
PATH_LIKE_RE = re.compile(
    r"^(?:\./|\.\./)?[A-Za-z0-9_./-]+\.(?:md|json|jsonc|toml|yaml|yml|py|mjs|js|sh|ts|tsx)$"
)
TARGET_DEF_RE = re.compile(r"^([A-Za-z0-9_.-]+):(?:\s|$)", re.MULTILINE)

PLACEHOLDER_CHARS = {"*", "<", ">", "{", "}"}
IGNORED_PREFIXES = ("http://", "https://", "mailto:")


def configure(repo_root: Path) -> None:
    global ROOT, MAKEFILE, DOC_INDEX_FILES, MANUAL_INDEX_FILES, CHECKED_DOCS, MANUAL_ROOTS

    ROOT = repo_root.resolve()
    MAKEFILE = ROOT / "Makefile"
    DOC_INDEX_FILES = [
        ROOT / "docs" / "README.md",
        ROOT / "docs" / "v1.0.0-index.md",
    ]
    MANUAL_INDEX_FILES = [
        ROOT / "docs" / "manuals" / "developer" / "README.md",
        ROOT / "docs" / "manuals" / "developer" / "SUMMARY.md",
        ROOT / "docs" / "manuals" / "user" / "README.md",
        ROOT / "docs" / "manuals" / "user" / "SUMMARY.md",
    ]
    CHECKED_DOCS = DOC_INDEX_FILES + MANUAL_INDEX_FILES
    MANUAL_ROOTS = [ROOT / "docs" / "manuals" / "developer", ROOT / "docs" / "manuals" / "user"]


def _rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def _err(message: str) -> None:
    print(f"[docs-index-truthiness] ERROR: {message}", file=sys.stderr)


def _looks_like_template(value: str) -> bool:
    if any(ch in value for ch in PLACEHOLDER_CHARS):
        return True
    return "..." in value or value.startswith("#")


def _resolve_repo_path(raw: str, *, doc: Path, markdown_relative: bool) -> Path:
    candidate = raw.strip()
    if markdown_relative:
        base = doc.parent
    else:
        base = doc.parent if candidate.startswith(("./", "../")) else ROOT
    return (base / candidate).resolve()


def _existing_local_markdown_targets(doc: Path) -> list[str]:
    text = doc.read_text(encoding="utf-8")
    refs: list[str] = []
    for raw in MARKDOWN_LINK_RE.findall(text):
        value = raw.strip()
        if not value or value.startswith(IGNORED_PREFIXES) or _looks_like_template(value):
            continue
        refs.append(value)
    return refs


def _existing_inline_path_refs(doc: Path) -> list[str]:
    text = doc.read_text(encoding="utf-8")
    refs: list[str] = []
    for raw in INLINE_CODE_RE.findall(text):
        value = raw.strip()
        if not value or _looks_like_template(value):
            continue
        if " " in value or "," in value:
            continue
        if value.startswith(IGNORED_PREFIXES):
            continue
        if PATH_LIKE_RE.fullmatch(value):
            refs.append(value)
    return refs


def _make_targets() -> set[str]:
    text = MAKEFILE.read_text(encoding="utf-8")
    targets = {name for name in TARGET_DEF_RE.findall(text) if not name.startswith(".")}
    return targets


def _check_local_links_and_paths() -> int:
    errors = 0
    for doc in CHECKED_DOCS:
        # Skip index files that don't ship in this tree (e.g. the user manual
        # lives in the private repo and is published to docs.claimru.sh; the
        # public repo only has the developer manual).
        if not doc.exists():
            continue
        for raw in _existing_local_markdown_targets(doc):
            target = _resolve_repo_path(raw, doc=doc, markdown_relative=True)
            if not target.exists():
                errors += 1
                _err(f"{_rel(doc)} links to missing file via markdown link: {raw}")
        for raw in _existing_inline_path_refs(doc):
            target = _resolve_repo_path(raw, doc=doc, markdown_relative=False)
            if not target.exists():
                errors += 1
                _err(f"{_rel(doc)} references missing repo path: {raw}")
    return errors


def _check_documented_commands() -> int:
    errors = 0
    make_targets = _make_targets()

    for doc in DOC_INDEX_FILES:
        if not doc.exists():
            continue
        text = doc.read_text(encoding="utf-8")

        for target in sorted(set(MAKE_TARGET_RE.findall(text))):
            if target not in make_targets:
                errors += 1
                _err(f"{_rel(doc)} references missing Make target: make {target}")

        for raw in sorted(set(SCRIPT_CMD_RE.findall(text)) | set(PY_LAUNCHER_RE.findall(text))):
            if _looks_like_template(raw):
                continue
            path = _resolve_repo_path(raw, doc=doc, markdown_relative=False)
            if not path.exists():
                errors += 1
                _err(f"{_rel(doc)} references missing script in documented command: {raw}")

    return errors


def _summary_links(summary: Path) -> set[Path]:
    linked: set[Path] = set()
    for raw in _existing_local_markdown_targets(summary):
        target = _resolve_repo_path(raw, doc=summary, markdown_relative=True)
        if target.suffix == ".md":
            linked.add(target)
    return linked


def _check_manual_summary_coverage() -> int:
    errors = 0
    for manual_root in MANUAL_ROOTS:
        if not manual_root.is_dir():
            continue
        summary = manual_root / "SUMMARY.md"
        if not summary.exists():
            continue
        linked = _summary_links(summary)
        shipped = {
            path.resolve()
            for path in manual_root.rglob("*.md")
            if path.name not in {"README.md", "SUMMARY.md"}
        }
        missing = sorted(_rel(path) for path in shipped - linked)
        if missing:
            errors += len(missing)
            _err(f"{_rel(summary)} is missing manual pages: {', '.join(missing)}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Guardrails for docs indexes and manuals truthiness.")
    parser.add_argument(
        "--repo-root",
        default=str(ROOT),
        help="Repo root to scan. Defaults to the repo containing this script.",
    )
    args = parser.parse_args()
    configure(Path(args.repo_root))

    errors = 0
    errors += _check_local_links_and_paths()
    errors += _check_documented_commands()
    errors += _check_manual_summary_coverage()

    if errors:
        print(f"[docs-index-truthiness] FAIL: {errors} issue(s) found.", file=sys.stderr)
        return 1

    print("[docs-index-truthiness] OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
