#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMPOSE_FILE="$ROOT_DIR/ops/graph-node/docker-compose.local.yml"

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

echo "[graph-node] Stopping local graph-node stack"
"$DOCKER_BIN" compose -f "$COMPOSE_FILE" down

