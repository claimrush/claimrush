#!/usr/bin/env python3
"""Validate exported workflow workdirs and script references."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except ModuleNotFoundError:
    print(
        "[public-workflow-resolution] ERROR: PyYAML not installed. Install pinned deps with requirements-ci.txt.",
        file=sys.stderr,
    )
    raise SystemExit(2)


SCRIPT_RE = re.compile(
    r"(?:(?:python3?|node|bash|sh)\s+|\./)([A-Za-z0-9_./-]+\.(?:py|mjs|js|sh))(?![A-Za-z0-9_./-])"
)


def iter_workflow_files(repo_root: Path) -> list[Path]:
    workflows = repo_root / ".github" / "workflows"
    if not workflows.exists():
        return []
    return sorted(
        [*workflows.rglob("*.yml"), *workflows.rglob("*.yaml")]
    )


def _check_workdir(repo_root: Path, workflow: Path, job_name: str, workdir: str, *, errors: list[str]) -> None:
    if workdir and not (repo_root / workdir).exists():
        errors.append(
            f"{workflow.relative_to(repo_root).as_posix()}::{job_name} references missing working-directory: {workdir}"
        )


def check_repo_root(repo_root: Path) -> int:
    errors: list[str] = []

    for workflow in iter_workflow_files(repo_root):
        doc = yaml.safe_load(workflow.read_text(encoding="utf-8", errors="replace"))
        jobs = doc.get("jobs") if isinstance(doc, dict) else {}
        if not isinstance(jobs, dict):
            continue

        for job_name, job in jobs.items():
            if not isinstance(job, dict):
                continue

            defaults = job.get("defaults") if isinstance(job.get("defaults"), dict) else {}
            run_defaults = defaults.get("run") if isinstance(defaults.get("run"), dict) else {}
            workdir = run_defaults.get("working-directory")
            if isinstance(workdir, str):
                _check_workdir(repo_root, workflow, str(job_name), workdir, errors=errors)

            for step in job.get("steps") or []:
                if not isinstance(step, dict):
                    continue

                step_workdir = step.get("working-directory")
                if isinstance(step_workdir, str):
                    _check_workdir(repo_root, workflow, str(job_name), step_workdir, errors=errors)

                run = step.get("run")
                if not isinstance(run, str):
                    continue
                for match in SCRIPT_RE.findall(run):
                    script = match.rstrip(".,)")
                    if not (repo_root / script).exists():
                        errors.append(
                            f"{workflow.relative_to(repo_root).as_posix()}::{job_name} references missing script: {script}"
                        )

    if errors:
        for error in errors:
            print(f"[public-workflow-resolution] ERROR: {error}", file=sys.stderr)
        print(f"[public-workflow-resolution] FAIL: {len(errors)} issue(s) found.", file=sys.stderr)
        return 1

    print("[public-workflow-resolution] OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate exported workflow workdirs and script references.")
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repo root to scan. Defaults to the current working directory.",
    )
    args = parser.parse_args()
    return check_repo_root(Path(args.repo_root).resolve())


if __name__ == "__main__":
    raise SystemExit(main())
