#!/usr/bin/env bash
# Thin wrapper used by SKILL.md examples. Resolves the skill dir relative to
# the repo so it works whether invoked from the repo root or any subfolder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$SKILL_DIR/dist/cli.js"

if [[ ! -f "$CLI" ]]; then
  echo "[claimrush] CLI not built. Running 'npm -C $SKILL_DIR run build' first..." >&2
  npm -C "$SKILL_DIR" run build >&2
fi

exec node "$CLI" "$@"
