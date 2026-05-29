#!/usr/bin/env python3
"""Validate repo-local path references in public markdown.

This guardrail scans markdown files in a public repo tree and fails when
backticked repo paths or local markdown links point at files that do not exist.
It is intentionally narrow: it only checks explicit repo-path references, not
arbitrary prose.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_PREFIXES = (
    "docs/",
    "scripts/",
    # Foundry deploy / smoke scripts live under `script/` (singular), which is
    # the canonical Foundry convention. Without this prefix, any broken doc
    # reference like `script/Deploy.s.sol` silently passes the gate because
    # `_normalize_repo_ref` returns None and the file is never existence-checked.
    "script/",
    "src/",
    "test/",
    # NOTE: `lib/` is intentionally NOT listed here. Foundry vendored deps
    # (forge-std, openzeppelin-contracts) live under lib/ in the in-place
    # source tree but are NOT shipped in the public export (contributors
    # install them via scripts at build time). A reference to `lib/` in a
    # README is expected to not resolve against the exported tree, so we
    # leave it outside the existence-checked prefix set.
    "deployments/",
    "abis/",
    "analytics/",
    "agents/",
    "subgraph/",
    "brand/",
    "keeper/",
    "packages/",
    "skills/",
    ".github/",
    "README.md",
    "LICENSE",
    "TRADEMARKS.md",
    "CLA.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CHANGELOG.md",
    "PUBLIC_RELEASE_POLICY.md",
    "Makefile",
    ".public-allowlist",
)

BACKTICK_RE = re.compile(r"`([^`\n]+)`")
MARKDOWN_LINK_RE = re.compile(r"\]\(([^)#]+)\)")

# Per-file negative-reference allowlist: paths that a document legitimately
# names only to forbid or contrast them ("do NOT create `subgraph/abis/`").
# These paths intentionally must not exist on disk, so we skip existence
# checks for them in the named file.
NEGATIVE_REFERENCE_ALLOWLIST: dict[str, set[str]] = {
    "abis/README.md": {
        # The rules section forbids maintaining shadow ABI copies here.
        "subgraph/abis/",
    },
    "docs/manuals/LINKING.md": {
        # The "Note for contributors editing manuals" section explains the
        # two-tree layout. `docs/manuals/user/` is intentionally NOT in
        # `.public-allowlist` (private-only) and so does not resolve against
        # the public export tree; the reference is descriptive prose, not a
        # link target.
        "docs/manuals/user/",
    },
}


def _normalize_repo_ref(raw: str) -> str | None:
    value = raw.strip().rstrip(".,):;")
    if not value:
        return None
    if value.startswith(("http://", "https://", "mailto:", "#")):
        return None
    if any(ch in value for ch in "*<>|"):
        return None
    if " " in value:
        return None
    if value.startswith("docs/") and "/<network>" in value:
        return None
    if value.startswith(("deployments/<network>", "abis/<network>")):
        return None
    # Foundry's `path:Contract` notation (e.g. `script/Wire.s.sol:Wire`) is a
    # valid command-line artifact identifier. The path before the colon is
    # what exists on disk; strip the contract suffix before existence checks.
    if ".sol:" in value:
        value = value.split(":", 1)[0]
    if any(value.startswith(prefix) for prefix in REPO_PREFIXES):
        return value
    return None


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
        # Installed at build time by `forge install`; not part of source.
        "lib",
    }
)


# Path components that, when present anywhere in a referenced repo path, indicate
# build or runtime output. Such paths are intentionally not checked into the
# repo, so docs that mention them must not fail the existence check (e.g.
# ``agents/sdk/out/`` or ``skills/<name>/dist/``).
BUILD_OUTPUT_COMPONENTS = frozenset(
    {
        "node_modules",
        ".next",
        "dist",
        "build",
        "out",
        "cache",
        "broadcast",
        ".open-next",
    }
)


def _is_build_output_ref(ref: str) -> bool:
    parts = [p for p in ref.split("/") if p]
    return any(part in BUILD_OUTPUT_COMPONENTS for part in parts)


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


def iter_markdown_files(repo_root: Path, *, public_only: bool) -> list[Path]:
    """Collect markdown files, pruning excluded directories DURING traversal.

    Previous implementation used ``repo_root.rglob("*.md")`` which walks every
    file in the private monorepo (including ``frontend/node_modules``,
    ``docs-site/.next``, etc.) before filtering. On real trees that walk can
    take >60s and made ``make gates-docs`` effectively hang. We use
    ``os.walk`` here so that excluded / non-public directories can be pruned
    before we descend into them.
    """
    import os

    allowlist = _load_public_allowlist(repo_root)
    if public_only and allowlist is not None:
        file_prefixes, dir_prefixes = allowlist
    else:
        file_prefixes, dir_prefixes = None, None

    results: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(repo_root):
        # Prune excluded directories in-place so os.walk does not descend
        # into them. This is where the 100x speedup comes from on a big
        # monorepo: node_modules / .next / out / build are pruned up-front.
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIR_NAMES]

        # In public-only mode we can also prune subtrees that aren't part of
        # any allowlisted prefix. We only do this for the top-level children
        # of repo_root to stay conservative (a lower-level dir that is
        # allowlisted must still be traversable even if its parent isn't
        # explicitly listed — but that shape isn't currently used by the
        # allowlist). For the current allowlist all public surfaces have
        # either a top-level file or a ``prefix/`` entry rooted at the repo,
        # so this optimization is safe.
        if public_only and dir_prefixes is not None and Path(dirpath) == repo_root:
            top_prefixes = {p.split("/", 1)[0] for p in dir_prefixes}
            top_files = {p.split("/", 1)[0] for p in (file_prefixes or set())}
            keep = top_prefixes | top_files | {".github"}
            dirnames[:] = [d for d in dirnames if d in keep]

        for name in filenames:
            if not name.endswith(".md"):
                continue
            full = Path(dirpath) / name
            if _is_excluded(full, repo_root):
                continue
            results.append(full)

    if not public_only or allowlist is None:
        return sorted(results)

    assert file_prefixes is not None and dir_prefixes is not None
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


def _repo_ref_exists(repo_root: Path, doc: Path, ref: str) -> bool:
    candidates = []
    if ref.startswith(("./", "../")):
        candidates.append((doc.parent / ref).resolve())
    else:
        candidates.append((repo_root / ref).resolve())
        candidates.append((doc.parent / ref).resolve())

    for candidate in candidates:
        if candidate.exists():
            return True
    return False


def check_repo_root(repo_root: Path, *, public_only: bool = True) -> int:
    errors = 0
    for path in iter_markdown_files(repo_root, public_only=public_only):
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = path.relative_to(repo_root).as_posix()

        refs = {
            ref
            for raw in BACKTICK_RE.findall(text)
            if (ref := _normalize_repo_ref(raw)) is not None
        }
        refs.update(
            ref
            for raw in MARKDOWN_LINK_RE.findall(text)
            if (ref := _normalize_repo_ref(raw)) is not None
        )

        negative_allowed = NEGATIVE_REFERENCE_ALLOWLIST.get(rel, set())
        for ref in sorted(refs):
            if ref in negative_allowed:
                continue
            if _is_build_output_ref(ref):
                continue
            if not _repo_ref_exists(repo_root, path, ref):
                print(
                    f"[public-markdown-paths] ERROR: {rel} references missing repo path: {ref}",
                    file=sys.stderr,
                )
                errors += 1

    if errors:
        print(f"[public-markdown-paths] FAIL: {errors} issue(s) found.", file=sys.stderr)
        return 1

    print("[public-markdown-paths] OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate repo-local path references in public markdown.")
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
