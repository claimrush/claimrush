#!/usr/bin/env python3
"""Validate that package.public.json does not leak private-surface references.

The public seed script (scripts/seed-public-repo.sh) replaces the internal
root package.json with package.public.json before publishing. This gate keeps
package.public.json honest: no private-surface path references, no scripts
that target internal infrastructure, and every `node ./scripts/*` entry
points at a script listed in .public-allowlist.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PRIVATE_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_./-])(?:"
    r"frontend/|workers/|services/|infra/|"
    r"docs-site/|developers-site/|ops/private/|\.private/"
    r")"
)
SCRIPT_REF_RE = re.compile(r"(?:node|bash|sh|python3?)\s+\.?/?(scripts/[A-Za-z0-9_./-]+)")


def _load_allowlisted_scripts(repo_root: Path) -> set[str]:
    # Prefer .public-allowlist when present (pre-seed source tree). In the
    # seeded tree the allowlist is not shipped; fall back to enumerating
    # scripts/* that physically exist, which is the post-seed equivalent.
    allowlist = repo_root / ".public-allowlist"
    if allowlist.is_file():
        scripts: set[str] = set()
        for raw in allowlist.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("scripts/") and not line.endswith("/"):
                scripts.add(line)
        return scripts

    scripts_dir = repo_root / "scripts"
    if not scripts_dir.is_dir():
        return set()
    return {
        f"scripts/{p.relative_to(scripts_dir).as_posix()}"
        for p in scripts_dir.rglob("*")
        if p.is_file()
    }


def check(repo_root: Path) -> int:
    # The check targets the slim public root manifest. In the pre-seed source
    # tree this lives at package.public.json; the seed script renames it to
    # package.json inside the exported public tree. Look at both so the same
    # gate works when invoked against either layout.
    manifest_path = repo_root / "package.public.json"
    if not manifest_path.is_file():
        manifest_path = repo_root / "package.json"
    if not manifest_path.is_file():
        print(
            "[public-package-manifest] ERROR: package.public.json (or seeded package.json) not found",
            file=sys.stderr,
        )
        return 1

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(
            f"[public-package-manifest] ERROR: package.public.json is not valid JSON: {e}",
            file=sys.stderr,
        )
        return 1

    errors = 0
    scripts = manifest.get("scripts") or {}
    allowlisted_scripts = _load_allowlisted_scripts(repo_root)

    for name, cmd in sorted(scripts.items()):
        if not isinstance(cmd, str):
            print(
                f"[public-package-manifest] ERROR: scripts.{name} is not a string",
                file=sys.stderr,
            )
            errors += 1
            continue

        for m in PRIVATE_PATH_RE.finditer(cmd):
            print(
                f"[public-package-manifest] ERROR: scripts.{name} references private surface: {m.group(0)!r} in {cmd!r}",
                file=sys.stderr,
            )
            errors += 1

        for m in SCRIPT_REF_RE.finditer(cmd):
            rel = m.group(1)
            if rel not in allowlisted_scripts:
                print(
                    f"[public-package-manifest] ERROR: scripts.{name} invokes non-public script: {rel} (not in .public-allowlist)",
                    file=sys.stderr,
                )
                errors += 1

    for key in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        block = manifest.get(key) or {}
        if not isinstance(block, dict):
            continue
        for dep, _ in block.items():
            # Defensive: disallow relative file: links that would point at
            # private workspaces (file:../workers/chat).
            if isinstance(block.get(dep), str) and block[dep].startswith("file:"):
                target = block[dep][len("file:") :]
                if PRIVATE_PATH_RE.search(target):
                    print(
                        f"[public-package-manifest] ERROR: {key}.{dep} -> {block[dep]} references private surface",
                        file=sys.stderr,
                    )
                    errors += 1

    if errors:
        print(
            f"[public-package-manifest] FAIL: {errors} issue(s) found.",
            file=sys.stderr,
        )
        return 1

    print(
        f"[public-package-manifest] OK ({len(scripts)} script(s) in {manifest_path.name})"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repo root (defaults to CWD).",
    )
    args = parser.parse_args()
    return check(Path(args.repo_root).resolve())


if __name__ == "__main__":
    raise SystemExit(main())
