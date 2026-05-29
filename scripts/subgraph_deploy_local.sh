#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require_cmd node
require_cmd npm
require_cmd python3

MANIFEST_SRC="$ROOT_DIR/subgraph/subgraph.local.yaml"
MANIFEST_DST="$ROOT_DIR/subgraph/subgraph.yaml"
DEPLOYMENTS_MANIFEST="$ROOT_DIR/deployments/local.json"
SYNC_SCRIPT="$ROOT_DIR/scripts/sync_subgraph_manifest_from_deployments.py"

SUBGRAPH_NAME="${SUBGRAPH_NAME:-claimrush/local}"
GRAPH_NODE="${GRAPH_NODE:-http://127.0.0.1:8020}"
IPFS="${IPFS:-http://127.0.0.1:5001}"
VERSION_LABEL="${VERSION_LABEL:-v0.0.1}"

if [[ ! -f "$MANIFEST_SRC" ]]; then
  echo "[subgraph] Missing manifest: $MANIFEST_SRC" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST_DST" ]]; then
  echo "[subgraph] Missing active manifest: $MANIFEST_DST" >&2
  exit 1
fi
if [[ ! -f "$DEPLOYMENTS_MANIFEST" ]]; then
  echo "[subgraph] Missing deployments manifest: $DEPLOYMENTS_MANIFEST" >&2
  exit 1
fi
if [[ ! -f "$SYNC_SCRIPT" ]]; then
  echo "[subgraph] Missing sync script: $SYNC_SCRIPT" >&2
  exit 1
fi

BACKUP_FILE=""
cleanup() {
  if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    cp "$BACKUP_FILE" "$MANIFEST_DST"
    rm -f "$BACKUP_FILE"
  fi
}
trap cleanup EXIT

# Save current active manifest and restore on exit.
BACKUP_FILE="$(mktemp -t claimrush_subgraph_yaml_backup.XXXXXX)"
chmod 600 "$BACKUP_FILE"
cp "$MANIFEST_DST" "$BACKUP_FILE"

echo "[subgraph] Copying local manifest -> subgraph.yaml"
cp "$MANIFEST_SRC" "$MANIFEST_DST"

echo "[subgraph] Syncing addresses + start blocks from deployments/local.json"
python3 "$SYNC_SCRIPT" \
  --manifest "$MANIFEST_DST" \
  --deployments "$DEPLOYMENTS_MANIFEST" \
  --allow-zero-addresses \
  --allow-start-block-zero

echo "[subgraph] Checking subgraph layout + mutable wiring semantics"
python3 "$ROOT_DIR/scripts/check_subgraph_codegen_layout.py"
python3 "$ROOT_DIR/scripts/check_subgraph_protocol_wiring_semantics.py"

echo "[subgraph] Installing deps + building"
cd "$ROOT_DIR/subgraph"
npm ci
npm run build

# Use the repo-pinned Graph CLI from node_modules (avoid npm exec auto-download).
GRAPH_BIN="$ROOT_DIR/subgraph/node_modules/.bin/graph"
if [ ! -x "$GRAPH_BIN" ]; then
  echo "ERROR: graph CLI not found at $GRAPH_BIN. Run 'npm ci' in subgraph/ to install devDependencies." >&2
  exit 1
fi

echo "[subgraph] Deploying to local graph-node"
echo "  - subgraph: $SUBGRAPH_NAME"
echo "  - node:     $GRAPH_NODE"
echo "  - ipfs:     $IPFS"

# Create is idempotent; ignore "already exists" failures.
"$GRAPH_BIN" create --node "$GRAPH_NODE" "$SUBGRAPH_NAME" || true
"$GRAPH_BIN" deploy --node "$GRAPH_NODE" --ipfs "$IPFS" --version-label "$VERSION_LABEL" "$SUBGRAPH_NAME"

echo "[subgraph] Done. Endpoint (default): http://127.0.0.1:8000/subgraphs/name/$SUBGRAPH_NAME"
