#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMPOSE_FILE="$ROOT_DIR/ops/graph-node/docker-compose.local.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[graph-node] Missing compose file: $COMPOSE_FILE" >&2
  exit 1
fi

# Prefer native docker; fallback to Docker Desktop CLI in WSL.
DOCKER_BIN="${DOCKER_BIN:-}"
if [[ -z "$DOCKER_BIN" ]]; then
  for candidate in docker docker.exe; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi
    if "$candidate" version >/dev/null 2>&1; then
      DOCKER_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "$DOCKER_BIN" ]]; then
  echo "[graph-node] ERROR: docker CLI not usable (tried: docker, docker.exe)." >&2
  echo "[graph-node] Install Docker Desktop and enable WSL integration for this distro." >&2
  exit 127
fi

# In WSL2, host.docker.internal often can't route back to WSL where Anvil runs.
# Auto-detect the WSL2 IP so Docker containers can reach Anvil.
if grep -qi microsoft /proc/version 2>/dev/null; then
  WSL_IP=$(hostname -I | awk '{print $1}')
  export ANVIL_HOST="${ANVIL_HOST:-$WSL_IP}"
  echo "[graph-node] WSL2 detected — using ANVIL_HOST=$ANVIL_HOST for Anvil RPC"
fi

echo "[graph-node] Starting local graph-node stack (ipfs + postgres + graph-node)"
echo "  - compose: $COMPOSE_FILE"
"$DOCKER_BIN" compose -f "$COMPOSE_FILE" up -d

echo "[graph-node] Ports:"
echo "  - GraphQL queries (HTTP):   http://127.0.0.1:8000/"
echo "  - GraphQL subscriptions:    ws://127.0.0.1:8001/  (websocket; not a browser page)"
echo "  - Deploy/admin (JSON-RPC):  http://127.0.0.1:8020/"
echo "  - Index node:               http://127.0.0.1:8030/"
echo "  - Metrics:                  http://127.0.0.1:8040/metrics"
echo "  - IPFS:   http://127.0.0.1:5001/"

