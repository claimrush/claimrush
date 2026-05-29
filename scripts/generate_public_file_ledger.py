#!/usr/bin/env python3
"""Generate a classified file ledger for a public repo tree."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath

LEGAL_PATHS = {
    "LICENSE",
    "CLA.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "TRADEMARKS.md",
}

GENERATED_SUFFIXES = (
    ".abi.json",
    ".tsbuildinfo",
)

GENERATED_PATHS = {
    ".secrets.baseline",
}

GENERATED_PREFIXES = (
    "docs/deployments/",
)

GENERATED_GLOBS = (
    "**/package-lock.json",
    "deployments/*.md",
)

BINARY_EXTENSIONS = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".ico",
    ".bmp",
    ".woff",
    ".woff2",
    ".ttf",
    ".otf",
    ".eot",
    ".pdf",
    ".mp4",
    ".mov",
    ".zip",
    ".gz",
    ".tgz",
    ".tar",
}


def is_binary(path: Path) -> bool:
    if path.suffix.lower() in BINARY_EXTENSIONS:
        return True
    with path.open("rb") as fh:
        chunk = fh.read(8192)
    return b"\x00" in chunk


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def classify(path: Path, repo_root: Path) -> tuple[str, str]:
    rel = path.relative_to(repo_root).as_posix()
    if rel in LEGAL_PATHS:
        return "legal", "license or public legal/community document"
    if is_binary(path):
        return "binary", "binary asset shipped as-is"
    if rel in GENERATED_PATHS:
        return "generated", "generated or tool-owned artifact"
    if rel.startswith(GENERATED_PREFIXES):
        return "generated", "generated documentation mirror"
    if any(rel.endswith(suffix) for suffix in GENERATED_SUFFIXES):
        return "generated", "generated artifact"
    rel_path = PurePosixPath(rel)
    for pattern in GENERATED_GLOBS:
        if rel_path.match(pattern):
            return "generated", "generated artifact"
    return "reviewed", "human-reviewed shipped file"


def build_ledger(repo_root: Path) -> dict[str, object]:
    files = sorted(path for path in repo_root.rglob("*") if path.is_file())
    entries: list[dict[str, object]] = []
    counts = {"reviewed": 0, "generated": 0, "binary": 0, "legal": 0}

    for path in files:
        category, reason = classify(path, repo_root)
        counts[category] += 1
        entries.append(
            {
                "path": path.relative_to(repo_root).as_posix(),
                "category": category,
                "reason": reason,
                "size_bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )

    return {
        "repo_root": str(repo_root),
        "file_count": len(entries),
        "counts": counts,
        "files": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a classified file ledger for a public repo tree.")
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repo root to scan. Defaults to the current working directory.",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output JSON path.",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    ledger = build_ledger(repo_root)
    output.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    counts = ledger["counts"]
    print(
        "[public-file-ledger] OK: "
        f"{ledger['file_count']} files "
        f"(reviewed={counts['reviewed']}, generated={counts['generated']}, "
        f"binary={counts['binary']}, legal={counts['legal']})"
    )
    print(f"[public-file-ledger] Wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
