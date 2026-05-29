#!/usr/bin/env bash
set -euo pipefail

# Slither/crytic-compile reads every JSON file in out/build-info. Recent
# Foundry versions can emit metadata-only build-info stubs for skipped test or
# script compilations; those files have no `output` key and make Slither abort
# before analysis. Keep the normal Foundry build, then remove only those stubs.
forge clean
forge build --build-info --force --skip './test/**' './script/**'

python3 - <<'PY'
import json
from pathlib import Path

build_info_dir = Path("out/build-info")
removed = 0
kept = 0

for path in build_info_dir.glob("*.json"):
    data = json.loads(path.read_text(encoding="utf-8"))
    if "output" not in data:
        path.unlink()
        removed += 1
    else:
        kept += 1

if kept == 0:
    raise SystemExit("slither build wrapper: no complete build-info files remain")

print(f"slither build wrapper: kept {kept} complete build-info file(s), pruned {removed} metadata stub(s)")
PY
