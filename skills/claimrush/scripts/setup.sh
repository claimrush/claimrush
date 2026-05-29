#!/usr/bin/env bash
# One-shot setup: build the SDK, install + build the skill, run an offline smoke check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
SDK_DIR="$REPO_ROOT/agents/sdk"

echo "[claimrush-skill] repo root:  $REPO_ROOT"
echo "[claimrush-skill] sdk dir:    $SDK_DIR"
echo "[claimrush-skill] skill dir:  $SKILL_DIR"

if [[ ! -d "$SDK_DIR" ]]; then
  echo "[claimrush-skill] ERROR: agents/sdk not found at $SDK_DIR" >&2
  exit 1
fi

if [[ ! -d "$SDK_DIR/node_modules" ]]; then
  echo "[claimrush-skill] installing SDK dependencies (one-shot)..."
  npm -C "$SDK_DIR" install
fi

if [[ ! -d "$SDK_DIR/dist" ]]; then
  echo "[claimrush-skill] building SDK..."
  npm -C "$SDK_DIR" run build
fi

if [[ ! -d "$SKILL_DIR/node_modules" ]]; then
  echo "[claimrush-skill] installing skill dependencies..."
  npm -C "$SKILL_DIR" install
fi

echo "[claimrush-skill] building skill..."
npm -C "$SKILL_DIR" run build

echo "[claimrush-skill] smoke check: action coverage..."
npm -C "$SDK_DIR" run example:action-coverage -- --pretty | head -40 || true

echo "[claimrush-skill] DONE. Try:"
echo "  bash $SKILL_DIR/scripts/cr.sh --help"
echo "  bash $SKILL_DIR/scripts/cr.sh status --chain local"
