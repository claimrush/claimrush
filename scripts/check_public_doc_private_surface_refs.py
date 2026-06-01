#!/usr/bin/env python3
"""Fail when public-shipping files leak excluded/private surface paths.

Scans both Markdown prose and Solidity NatSpec/comments. Solidity coverage is
required because contract-level NatSpec ships verbatim into the public
repo, and a `frontend/...` or `docs/dev/internal/...` reference inside a
`/// @dev` block leaks the same private-surface information that the
markdown gate guards against."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


CHECKS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("frontend path", re.compile(r"(?<![A-Za-z0-9_.-])frontend/")),
    ("docs-site path", re.compile(r"(?<![A-Za-z0-9_.-])docs-site/")),
    ("developers-site path", re.compile(r"(?<![A-Za-z0-9_.-])developers-site/")),
    ("workers path", re.compile(r"(?<![A-Za-z0-9_.-])workers/")),
    ("services path", re.compile(r"(?<![A-Za-z0-9_.-])services/")),
    ("private repo name", re.compile(r"\bclaimrush-private\b")),
    ("private repo phrase", re.compile(r"\bprivate repo\b", re.IGNORECASE)),
    ("sync-from-public marker", re.compile(r"\bsync-from-public\b")),
    ("private PAT marker", re.compile(r"\bPRIVATE_REPO_PAT\b")),
    # Internal audit IDs: each prefix is a private-audit scenario label that
    # leaks the existence of an audit pass to public readers.
    (
        "audit id",
        re.compile(r"\b(?:M-0\d|F-[A-Z]-\d+|IF-[A-Z]-\d+|I-0\d|MWB-\d+)\b"),
    ),
    # Audit / remediation phrasing. Targets the explicit nouns and noun
    # phrases that frame the codebase as a remediation artifact, while
    # avoiding plain English uses ("auditable replay" in agents/sdk,
    # "audit log" as a generic term, "the bug" in a bug-report template).
    (
        "audit phrase",
        re.compile(
            r"\b(?:"
            r"audit\s+(?:report|finding|patch|response|run|note|trail\s+of)"
            r"|remediation\b"
            r"|hotfix\b"
            r"|gas\s+trap\b"
            r"|known\s+bug\b"
            r"|regression\s+test\s+for\b"
            r")",
            re.IGNORECASE,
        ),
    ),
    # Change-history phrasing. Tuned to catch explicit "added in vX /
    # removed in vX / before this fix / the legacy <thing>" wording without
    # flagging legitimate runtime semantics ("no longer eligible", "lock is
    # no longer ownable"), EIP terminology ("legacy bytecode" in EIP-3541
    # NatSpec), or hypotheticals ("if X were removed").
    (
        "history phrase",
        re.compile(
            r"\b(?:"
            r"prior\s+to\s+v\d"
            r"|(?:removed|added|introduced)\s+in\s+v\d"
            r"|before\s+(?:this|the)\s+(?:change|fix|patch|version|release)\b"
            r"|the\s+legacy\s+\w+"
            r"|the\s+previous\s+(?:impl|implementation|version|release)\b"
            r"|previously\s+(?:returned|named|known\s+as|approved|credited)\b"
            r"|formerly\s+\w+"
            r")",
            re.IGNORECASE,
        ),
    ),
)

ALLOWLIST: dict[str, set[str]] = {
    # The public release policy catalogs the full repo split and legitimately
    # names every private surface it is about to split off.
    "PUBLIC_RELEASE_POLICY.md": {
        "frontend path",
        "docs-site path",
        "developers-site path",
        "workers path",
        "services path",
        "private repo phrase",
        # The policy itself names the categories of content public docs MUST
        # NOT contain (decision logs, remediation history, etc.). The
        # policy's own enumeration of those forbidden categories is exempt.
        "audit phrase",
        "history phrase",
    },
    # Public security index. The whole purpose of this file is to explain
    # the public-vs-private split of the security documentation tree and
    # to forward-reference the eventual external-audit report that will
    # land here at Phase 8 (Freeze-and-Burn). Phrasing like "audit report"
    # is therefore intentional and required for the document to do its
    # job; the gate's purpose (preventing leaks of internal audit-pass /
    # remediation-cycle framing into the public surface) is not in scope
    # for this file.
    "docs/security/README.md": {
        "audit phrase",
    },
    # Cross-cutting specs/architecture docs that describe systems spanning
    # public (contracts/analytics/manuals) and private (frontend/workers/
    # services) surfaces. The path references here are intentional pointers
    # for implementers, not leaks of private source. Allowlisted on a per-
    # file, per-label basis so new private surfaces cannot silently bleed
    # into these documents.
    "docs/spec/env-config-and-constants-v1.0.0.md": {
        "frontend path",
        "workers path",
        "services path",
        "private repo phrase",
    },
    "docs/spec/real-time-layer-spec-v1.0.0.md": {
        "services path",
    },
    "docs/architecture/real-time-layer-v1.0.0.md": {
        "frontend path",
        "workers path",
        "services path",
    },
    "docs/analytics/posthog-cloud-and-ai-setup-v1.0.0.md": {
        "frontend path",
    },
}


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


def _is_excluded(path: Path, repo_root: Path) -> bool:
    try:
        rel = path.relative_to(repo_root)
    except ValueError:
        return False
    return any(part in EXCLUDED_DIR_NAMES for part in rel.parts)


def _load_public_allowlist(repo_root: Path) -> tuple[set[str], set[str]] | None:
    """Read .public-allowlist, returning (file_prefixes, dir_prefixes).

    Returns None if the allowlist is missing, in which case the caller falls
    back to scanning every markdown file. This preserves backward compatibility
    with repos that don't yet ship a public allowlist.
    """
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


SCANNED_SUFFIXES: tuple[str, ...] = (".md", ".sol")


def iter_target_files(repo_root: Path, *, public_only: bool) -> list[Path]:
    # NOTE: implemented with os.walk + in-place directory pruning instead of
    # Path.rglob. rglob traverses node_modules / .next / build / dist (tens
    # of thousands of entries each in this monorepo) before the downstream
    # excluded-dir filter drops them; on real hardware that used to take
    # >60s and hung `make gates-docs`. Early-pruning the dir list in
    # os.walk keeps this script under 2s.
    import os

    allowlist: tuple[set[str], set[str]] | None = None
    if public_only:
        allowlist = _load_public_allowlist(repo_root)

    # Public-only mode can prune any top-level directory that is not a prefix
    # of any allowlist entry. We only apply this at the repo root so that
    # subdirs of an allowed top-level dir are all traversed normally.
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
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIR_NAMES]

        if allowed_top_level is not None and dirpath == repo_root_str:
            dirnames[:] = [d for d in dirnames if d in allowed_top_level]

        for name in filenames:
            if not name.endswith(SCANNED_SUFFIXES):
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


def check_repo_root(repo_root: Path, *, public_only: bool = True) -> int:
    errors = 0
    for path in iter_target_files(repo_root, public_only=public_only):
        rel = path.relative_to(repo_root).as_posix()
        allowed = ALLOWLIST.get(rel, set())
        text = path.read_text(encoding="utf-8", errors="replace")

        for label, pattern in CHECKS:
            if label in allowed:
                continue
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                print(
                    f"[public-doc-private-refs] ERROR: {rel}:{line} contains excluded surface reference ({label})",
                    file=sys.stderr,
                )
                errors += 1

    if errors:
        print(f"[public-doc-private-refs] FAIL: {errors} issue(s) found.", file=sys.stderr)
        return 1

    print("[public-doc-private-refs] OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when public-shipping files (Markdown prose or Solidity "
            "NatSpec/comments) leak excluded/private surface paths."
        ),
    )
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
            "Scan every Markdown and Solidity file instead of limiting to "
            "the public .public-allowlist surface. The default matches the "
            "gate's intent (public-only) and avoids noise from out-of-scope "
            "files."
        ),
    )
    parser.set_defaults(public_only=True)
    args = parser.parse_args()
    return check_repo_root(Path(args.repo_root).resolve(), public_only=args.public_only)


if __name__ == "__main__":
    raise SystemExit(main())
