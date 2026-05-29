#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require_cmd node
require_cmd npm
require_cmd python3

SUBGRAPH_DIR="$ROOT_DIR/subgraph"
MANIFEST_ACTIVE="$SUBGRAPH_DIR/subgraph.yaml"
DEPLOYMENTS_MANIFEST="$ROOT_DIR/deployments/base_sepolia.json"
SYNC_SCRIPT="$ROOT_DIR/scripts/sync_subgraph_manifest_from_deployments.py"

if [[ ! -d "$SUBGRAPH_DIR" ]]; then
  echo "Missing subgraph/ folder at repo root." >&2
  exit 1
fi
if [[ ! -f "$MANIFEST_ACTIVE" ]]; then
  echo "Missing active manifest: $MANIFEST_ACTIVE" >&2
  exit 1
fi
if [[ ! -f "$DEPLOYMENTS_MANIFEST" ]]; then
  echo "Missing deployments manifest: $DEPLOYMENTS_MANIFEST" >&2
  exit 1
fi
if [[ ! -f "$SYNC_SCRIPT" ]]; then
  echo "Missing sync script: $SYNC_SCRIPT" >&2
  exit 1
fi

# Restore original manifest on exit (even if deploy fails)
TMP_MANIFEST="$(mktemp -t claimrush-subgraph-manifest.XXXXXX.yaml)"
chmod 600 "$TMP_MANIFEST"
cp "$MANIFEST_ACTIVE" "$TMP_MANIFEST"
cleanup() {
  cp "$TMP_MANIFEST" "$MANIFEST_ACTIVE" || true
  rm -f "$TMP_MANIFEST" || true
}
trap cleanup EXIT

build_subgraph() {

  echo "==> Checking subgraph layout + mutable wiring semantics"
  python3 "$ROOT_DIR/scripts/check_subgraph_codegen_layout.py"
  python3 "$ROOT_DIR/scripts/check_subgraph_protocol_wiring_semantics.py"

  cd "$SUBGRAPH_DIR"

  # Deterministic install
  npm ci

  # Build (includes codegen into src/generated)
  npm run build

  test -d build || { echo "Missing subgraph/build after build." >&2; exit 1; }
}

echo "==> Activating STAGING manifest"
cp "$SUBGRAPH_DIR/subgraph.staging.yaml" "$MANIFEST_ACTIVE"
echo "==> Syncing addresses + start blocks from deployments/base_sepolia.json"
python3 "$SYNC_SCRIPT" \
  --manifest "$MANIFEST_ACTIVE" \
  --deployments "$DEPLOYMENTS_MANIFEST"

python3 "$ROOT_DIR/scripts/check_subgraph_manifest_runtime_readiness.py" "$MANIFEST_ACTIVE"

echo "==> Building subgraph"
build_subgraph

# Provider enable flags (1 = deploy, 0 = skip). Default: both on.
DEPLOY_STUDIO="${DEPLOY_STUDIO:-1}"
DEPLOY_GOLDSKY="${DEPLOY_GOLDSKY:-1}"

if [[ "$DEPLOY_STUDIO" != "1" && "$DEPLOY_GOLDSKY" != "1" ]]; then
  echo "ERROR: Both DEPLOY_STUDIO and DEPLOY_GOLDSKY are 0; nothing to deploy." >&2
  exit 1
fi

cd "$SUBGRAPH_DIR"

# Reused semver pattern for version labels across providers.
# Suffix character class includes '-' so labels like v1.0.7-may6-redeploy and
# v1.0.8-may7-genesis (operator's hyphen-separated <date>-<purpose> convention)
# validate. Suffix must still start with [a-z0-9] to keep ill-formed labels out.
VERSION_LABEL_RE='^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9][a-z0-9.-]*)?$'
SLUG_RE='^[a-z0-9][a-z0-9_/-]{0,63}$'

# ---- Subgraph Studio (The Graph) ----
if [[ "$DEPLOY_STUDIO" == "1" ]]; then
  echo "==> Deploying to Subgraph Studio (staging)"
  if [[ -z "${SUBGRAPH_STUDIO_DEPLOY_KEY:-}" ]]; then
    echo "Missing required env var: SUBGRAPH_STUDIO_DEPLOY_KEY (or set DEPLOY_STUDIO=0 to skip)" >&2
    exit 1
  fi

  SUBGRAPH_STUDIO_SLUG="${SUBGRAPH_STUDIO_SLUG:-claimrush-v1-0-0-staging}"
  SUBGRAPH_VERSION_LABEL="${SUBGRAPH_VERSION_LABEL:-v1.0.0-staging}"

  if [[ ! "$SUBGRAPH_STUDIO_SLUG" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    echo "ERROR: Invalid SUBGRAPH_STUDIO_SLUG format" >&2
    exit 1
  fi
  if [[ ! "$SUBGRAPH_VERSION_LABEL" =~ $VERSION_LABEL_RE ]]; then
    echo "ERROR: Invalid SUBGRAPH_VERSION_LABEL format" >&2
    exit 1
  fi
  if [[ ! "$SUBGRAPH_STUDIO_DEPLOY_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: SUBGRAPH_STUDIO_DEPLOY_KEY contains unexpected characters" >&2
    exit 1
  fi

  # Use the repo-pinned Graph CLI from node_modules (avoid npm exec auto-download).
  GRAPH_BIN="$SUBGRAPH_DIR/node_modules/.bin/graph"
  if [ ! -x "$GRAPH_BIN" ]; then
    echo "ERROR: graph CLI not found at $GRAPH_BIN. Run 'npm ci' in subgraph/ to install devDependencies." >&2
    exit 1
  fi

  echo "==> Authenticating Graph CLI for Subgraph Studio"
  "$GRAPH_BIN" auth "$SUBGRAPH_STUDIO_DEPLOY_KEY"

  echo "==> Deploying to Subgraph Studio (slug: $SUBGRAPH_STUDIO_SLUG, version: $SUBGRAPH_VERSION_LABEL)"
  "$GRAPH_BIN" deploy "$SUBGRAPH_STUDIO_SLUG" --version-label "$SUBGRAPH_VERSION_LABEL" --deploy-key "$SUBGRAPH_STUDIO_DEPLOY_KEY"
else
  echo "==> Skipping Subgraph Studio deploy (DEPLOY_STUDIO=$DEPLOY_STUDIO)"
fi

# ---- Goldsky (primary upstream for /api/subgraph) ----
if [[ "$DEPLOY_GOLDSKY" == "1" ]]; then
  echo "==> Deploying to Goldsky (staging)"
  require_cmd goldsky

  if [[ -z "${GOLDSKY_DEPLOY_KEY:-}" ]]; then
    echo "Missing required env var: GOLDSKY_DEPLOY_KEY (or set DEPLOY_GOLDSKY=0 to skip)" >&2
    exit 1
  fi
  if [[ ! "$GOLDSKY_DEPLOY_KEY" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: GOLDSKY_DEPLOY_KEY contains unexpected characters" >&2
    exit 1
  fi

  GOLDSKY_SUBGRAPH_SLUG="${GOLDSKY_SUBGRAPH_SLUG:-claimrush-staging}"
  if [[ -z "${GOLDSKY_VERSION_LABEL:-}" ]]; then
    echo "Missing required env var: GOLDSKY_VERSION_LABEL (e.g. v1.0.6; Goldsky versions diverge from Studio)." >&2
    exit 1
  fi

  if [[ ! "$GOLDSKY_SUBGRAPH_SLUG" =~ $SLUG_RE ]]; then
    echo "ERROR: Invalid GOLDSKY_SUBGRAPH_SLUG format" >&2
    exit 1
  fi
  if [[ ! "$GOLDSKY_VERSION_LABEL" =~ $VERSION_LABEL_RE ]]; then
    echo "ERROR: Invalid GOLDSKY_VERSION_LABEL format" >&2
    exit 1
  fi

  echo "==> Authenticating Goldsky CLI"
  goldsky login --token "$GOLDSKY_DEPLOY_KEY"

  echo "==> Deploying to Goldsky ($GOLDSKY_SUBGRAPH_SLUG/$GOLDSKY_VERSION_LABEL)"
  goldsky subgraph deploy "$GOLDSKY_SUBGRAPH_SLUG/$GOLDSKY_VERSION_LABEL" --path "$SUBGRAPH_DIR/build"
else
  echo "==> Skipping Goldsky deploy (DEPLOY_GOLDSKY=$DEPLOY_GOLDSKY)"
fi

echo "==> Done"
echo "Next:"
if [[ "$DEPLOY_STUDIO" == "1" ]]; then
  echo "- In Subgraph Studio, copy the query endpoint for '$SUBGRAPH_STUDIO_SLUG' into SUBGRAPH_FALLBACK_DIRECT_URL / SUBGRAPH_FALLBACK_URL"
fi
if [[ "$DEPLOY_GOLDSKY" == "1" ]]; then
  echo "- Goldsky endpoint: https://api.goldsky.com/api/public/<project_id>/subgraphs/$GOLDSKY_SUBGRAPH_SLUG/$GOLDSKY_VERSION_LABEL/gn"
  echo "  Update SUBGRAPH_DIRECT_URL in frontend/wrangler.json (env.staging) + SUBGRAPH_URL on worker/chat + worker/chat/jobs."
fi
