#!/usr/bin/env python3
"""Validate documented command references in public markdown."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
FENCED_CODE_RE = re.compile(r"```[^\n]*\n(.*?)```", re.DOTALL)
MAKE_TARGET_RE = re.compile(r"(?<![A-Za-z0-9_.-])make\s+([A-Za-z0-9_.-]+)")
SCRIPT_CMD_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])(?:python3?|node|bash|sh)\s+([A-Za-z0-9_./-]+\.(?:py|mjs|js|sh))(?![A-Za-z0-9_./-])"
)
LOCAL_SCRIPT_RE = re.compile(r"(?<![A-Za-z0-9_.-])\./([A-Za-z0-9_./-]+\.(?:py|mjs|js|sh))(?![A-Za-z0-9_./-])")
NPM_C_RE = re.compile(r"npm\s+-C\s+([^\s`]+)\s+run\s+([^\s`]+)")
NPM_CD_RE = re.compile(r"cd\s+([^\s`]+)\s*&&\s*npm\s+run\s+([^\s`]+)")
TARGET_DEF_RE = re.compile(r"^([A-Za-z0-9_.-]+):(?:\s|$)", re.MULTILINE)
REPO_SCRIPT_PREFIXES = (
    "scripts/",
    "analytics/scripts/",
    "agents/",
    "keeper/",
    "packages/",
    "subgraph/",
    "test/",
    "script/",
    "skills/",
)
EXCLUDED_DIR_NAMES = frozenset(
    {
        "node_modules",
        ".git",
        ".next",
        "dist",
        "build",
        "out",
        "cache",
        "broadcast",
        ".open-next",
        # Foundry vendored dependencies (forge-std, openzeppelin-contracts).
        # These are installed at build time by `forge install` and ship their
        # own README/Makefile that should never be linted as if it were
        # public-shipping source.
        "lib",
    }
)


def _is_excluded(path: Path, repo_root: Path) -> bool:
    try:
        rel = path.relative_to(repo_root)
    except ValueError:
        return False
    return any(part in EXCLUDED_DIR_NAMES for part in rel.parts)


def _load_public_allowlist(repo_root: Path) -> tuple[set[str], set[str]] | None:
    allowlist_path = repo_root / ".public-allowlist"
    if not allowlist_path.is_file():
        return None
    file_prefixes: set[str] = set()
    dir_prefixes: set[str] = set()
    for raw in allowlist_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.endswith("/"):
            dir_prefixes.add(line)
        else:
            file_prefixes.add(line)
    return file_prefixes, dir_prefixes


def _is_public_surface(
    rel_posix: str,
    file_prefixes: set[str],
    dir_prefixes: set[str],
) -> bool:
    if rel_posix in file_prefixes:
        return True
    return any(rel_posix.startswith(prefix) for prefix in dir_prefixes)


def _load_make_targets(makefile: Path) -> set[str]:
    text = makefile.read_text(encoding="utf-8")
    return {name for name in TARGET_DEF_RE.findall(text) if not name.startswith(".")}


def _load_package_scripts(package_dir: Path) -> set[str] | None:
    package_json = package_dir / "package.json"
    if not package_json.exists():
        return None
    data = json.loads(package_json.read_text(encoding="utf-8"))
    return set((data.get("scripts") or {}).keys())


def iter_markdown_files(repo_root: Path, *, public_only: bool) -> list[Path]:
    # NOTE: implemented with os.walk + in-place directory pruning instead of
    # Path.rglob. In this monorepo rglob traverses node_modules / .next /
    # build / dist (tens of thousands of entries each) before the downstream
    # excluded-dir filter drops them, which takes >60s wall-time per run and
    # used to hang `make gates-docs`. Pruning the dir list in os.walk avoids
    # descent entirely and keeps this script well under 2s.
    import os

    allowlist: tuple[set[str], set[str]] | None = None
    if public_only:
        allowlist = _load_public_allowlist(repo_root)

    # Public-only mode can prune any top-level directory that is not a prefix
    # of any allowlist entry. This is the early-exit that makes a full scan
    # of a large monorepo practical.
    allowed_top_level: set[str] | None = None
    if public_only and allowlist is not None:
        file_prefixes, dir_prefixes = allowlist
        allowed_top_level = set()
        for raw in file_prefixes | dir_prefixes:
            head = raw.split("/", 1)[0]
            if head:
                allowed_top_level.add(head)

    results: list[Path] = []
    repo_root_str = str(repo_root)
    for dirpath, dirnames, filenames in os.walk(repo_root):
        # In-place mutate dirnames to prune descent into excluded directories.
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIR_NAMES]

        # Public-only: prune any top-level dir that isn't a prefix of an
        # allowlist entry. We only apply this at the repo root so subdirs of
        # an allowed top-level dir are all traversed.
        if allowed_top_level is not None and dirpath == repo_root_str:
            dirnames[:] = [d for d in dirnames if d in allowed_top_level]

        for name in filenames:
            if not name.endswith(".md"):
                continue
            full = Path(dirpath) / name
            if _is_excluded(full, repo_root):
                continue
            results.append(full)

    if not public_only or allowlist is None:
        return sorted(results)

    file_prefixes, dir_prefixes = allowlist
    filtered = [
        p
        for p in results
        if _is_public_surface(
            p.relative_to(repo_root).as_posix(),
            file_prefixes,
            dir_prefixes,
        )
    ]
    return sorted(filtered)


def _command_text(markdown: str) -> str:
    parts = [*INLINE_CODE_RE.findall(markdown), *FENCED_CODE_RE.findall(markdown)]
    return "\n".join(parts)


def _normalize_repo_script(raw: str) -> str | None:
    script = raw.rstrip(".,)")
    if script.startswith("./"):
        script = script[2:]
    if not script.startswith(REPO_SCRIPT_PREFIXES):
        return None
    # Build outputs (e.g., `keeper/dist/run.js`) are documented entry points
    # that exist only after the relevant `npm run build`. We cannot verify
    # their presence on disk without building everything, so we trust that
    # their source counterparts are covered by the build gate and skip the
    # existence check here.
    segments = script.split("/")
    if any(seg in {"dist", "build", "out", ".next", ".open-next"} for seg in segments):
        return None
    return script


def check_repo_root(repo_root: Path, *, public_only: bool = True) -> int:
    makefile = repo_root / "Makefile"
    if not makefile.exists():
        print("[public-markdown-commands] ERROR: Makefile not found", file=sys.stderr)
        return 1

    make_targets = _load_make_targets(makefile)
    package_cache: dict[Path, set[str] | None] = {}
    errors = 0

    for path in iter_markdown_files(repo_root, public_only=public_only):
        text = _command_text(path.read_text(encoding="utf-8", errors="replace"))
        rel = path.relative_to(repo_root).as_posix()

        for target in sorted(set(MAKE_TARGET_RE.findall(text))):
            if target not in make_targets:
                print(
                    f"[public-markdown-commands] ERROR: {rel} references missing Make target: make {target}",
                    file=sys.stderr,
                )
                errors += 1

        for raw in sorted(set(SCRIPT_CMD_RE.findall(text)) | set(LOCAL_SCRIPT_RE.findall(text))):
            script = _normalize_repo_script(raw)
            if script is None:
                continue
            if not (repo_root / script).exists():
                print(
                    f"[public-markdown-commands] ERROR: {rel} references missing script: {script}",
                    file=sys.stderr,
                )
                errors += 1

        for pkg_rel, script_name in sorted(set(NPM_C_RE.findall(text)) | set(NPM_CD_RE.findall(text))):
            package_dir = (repo_root / pkg_rel.rstrip("/")).resolve()
            if package_dir not in package_cache:
                package_cache[package_dir] = _load_package_scripts(package_dir)
            scripts = package_cache[package_dir]
            if scripts is None:
                print(
                    f"[public-markdown-commands] ERROR: {rel} references missing package dir: {pkg_rel}",
                    file=sys.stderr,
                )
                errors += 1
                continue
            script = script_name.rstrip(".,)")
            if script not in scripts:
                print(
                    f"[public-markdown-commands] ERROR: {rel} references missing npm script: {pkg_rel} -> {script}",
                    file=sys.stderr,
                )
                errors += 1

    if errors:
        print(f"[public-markdown-commands] FAIL: {errors} issue(s) found.", file=sys.stderr)
        return 1

    print("[public-markdown-commands] OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate documented command references in public markdown.")
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repo root to scan. Defaults to the current working directory.",
    )
    parser.add_argument(
        "--all",
        dest="public_only",
        action="store_false",
        help=(
            "Scan every markdown file instead of limiting to the public "
            ".public-allowlist surface. Default is public-only."
        ),
    )
    parser.set_defaults(public_only=True)
    args = parser.parse_args()
    return check_repo_root(Path(args.repo_root).resolve(), public_only=args.public_only)


if __name__ == "__main__":
    raise SystemExit(main())
