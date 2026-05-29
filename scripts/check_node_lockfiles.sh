#!/usr/bin/env bash
set -euo pipefail

# Check that Node lockfiles are present and consistent.
#
# Policy:
# - Every directory containing a package.json MUST also contain a lockfile,
#   UNLESS the directory is explicitly listed in IGNORE_DIRS below.
# - This prevents reproducibility drift and supply-chain surprises.
# - Directories are discovered automatically so new packages are enforced
#   without updating this script.
#
# Lockfiles accepted:
# - pnpm-lock.yaml
# - package-lock.json
# - yarn.lock

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Directories that are intentionally lockfile-free ─────────────────────────
# Internal shared packages with zero external dependencies don't produce a
# meaningful lockfile.  Add paths relative to ROOT_DIR.
IGNORE_DIRS=(
  "packages/node-utils"
  "packages/worker-utils"
  "services/monitoring"
)

# ── Helpers ──────────────────────────────────────────────────────────────────

has_lockfile() {
  local d="$1"
  [[ -f "$d/pnpm-lock.yaml" || -f "$d/package-lock.json" || -f "$d/yarn.lock" ]]
}

is_ignored() {
  local d="$1"
  for ign in "${IGNORE_DIRS[@]}"; do
    if [[ "$d" == "$ROOT_DIR/$ign" ]]; then
      return 0
    fi
  done
  return 1
}

# A package.json with no dependencies/devDependencies/peerDependencies/
# optionalDependencies cannot produce a meaningful lockfile. Treat such
# manifests as lockfile-free even if not in IGNORE_DIRS. This mirrors the
# real-world public root manifest (package.public.json) which exposes only
# a `deploy:protocol` script and declares no third-party deps.
has_any_dependencies() {
  local d="$1"
  python3 - "$d/package.json" <<'PY' || return 1
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        m = json.load(f)
except Exception:
    sys.exit(0)
keys = ('dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies')
for k in keys:
    v = m.get(k) or {}
    if isinstance(v, dict) and len(v) > 0:
        sys.exit(0)
sys.exit(1)
PY
}

# ── Discover every directory containing a package.json ───────────────────────
# Excludes node_modules, hidden directories (e.g. .git), the lib/ tree
# (Foundry/Forge git submodules for Solidity contracts), and the gitignored
# build/ tree (e.g. build/public-selftest/ contains a clone-like repo
# snapshot used for public-release self-tests, not a real workspace).

mapfile -t DIRS < <(
  find "$ROOT_DIR" \
    -name node_modules -prune -o \
    -name '.*' -prune -o \
    -path "$ROOT_DIR/lib" -prune -o \
    -path "$ROOT_DIR/build" -prune -o \
    -name package.json -print \
  | sed 's|/package.json$||' \
  | sort
)

# ── Enforce ──────────────────────────────────────────────────────────────────

missing=0
for d in "${DIRS[@]}"; do
  if is_ignored "$d"; then
    continue
  fi
  if ! has_any_dependencies "$d"; then
    continue
  fi
  if ! has_lockfile "$d"; then
    echo "ERROR: ${d} contains package.json but no lockfile (pnpm-lock.yaml, package-lock.json, or yarn.lock) detected." >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "" >&2
  echo "Lockfiles must be committed per project directory to ensure reproducible builds." >&2
  echo "To fix:" >&2
  echo "  - Generate a lockfile in the directory missing one:" >&2
  echo "      npm:  (cd <dir> && npm install --package-lock-only --ignore-scripts)" >&2
  echo "      pnpm: (cd <dir> && pnpm install --lockfile-only)" >&2
  echo "      yarn: (cd <dir> && yarn install)" >&2
  echo "  - Commit the generated lockfile" >&2
  echo "  - Or add the directory to IGNORE_DIRS in this script if it intentionally has no dependencies" >&2
  exit 1
fi

echo "✓ Lockfile check passed"
exit 0
