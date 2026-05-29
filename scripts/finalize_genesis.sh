#!/usr/bin/env bash
#
# Finalize genesis on local Anvil (warps time + calls LaunchController.finalizeGenesis)
#
# Usage:
#   ./scripts/finalize_genesis.sh
#
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPC_URL="${LOCAL_RPC_URL:-http://127.0.0.1:8545}"
PRIVATE_KEY="${LOCAL_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# Safety: this script uses a well-known public Anvil account and is intended
# only for local development. Refuse to run against any RPC whose chainId is
# not a local Anvil chain (31337 or 1337). This prevents an accidental
# `LOCAL_RPC_URL=https://...` from broadcasting signed transactions from a
# shared test key on a real network.
if command -v cast >/dev/null 2>&1; then
  CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
  if [ "$CHAIN_ID" != "31337" ] && [ "$CHAIN_ID" != "1337" ]; then
    echo "Error: finalize_genesis.sh is dev-only and refuses non-local chains (got chainId '$CHAIN_ID')." >&2
    echo "Set LOCAL_RPC_URL to a local Anvil endpoint (chainId 31337 or 1337)." >&2
    exit 1
  fi
else
  echo "Error: 'cast' not found in PATH. finalize_genesis.sh requires foundry to verify the target chainId before broadcasting." >&2
  exit 1
fi

read_json_address() {
  local dotted_path="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -r --arg path "$dotted_path" '
      ($path | split(".")) as $parts
      | getpath($parts)
      | if . == null then "" else . end
    ' "$ROOT_DIR/deployments/local.json"
    return
  fi

  python3 - "$ROOT_DIR/deployments/local.json" "$dotted_path" <<'PY'
import json
import sys

manifest_path, dotted_path = sys.argv[1], sys.argv[2]
with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
cur = data
for part in dotted_path.split("."):
    if not isinstance(cur, dict) or part not in cur:
        print("")
        raise SystemExit(0)
    cur = cur[part]
print(cur if isinstance(cur, str) else "")
PY
}

decode_uint() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    echo ""
    return
  fi
  if [[ "$raw" == 0x* ]]; then
    cast to-dec "$raw" 2>/dev/null || echo "$raw"
    return
  fi
  echo "$raw"
}

verify_post_final_state() {
  local launch_controller="$1"

  local minecore
  minecore=$(read_json_address "contracts.MineCore.address")
  if [[ -z "$minecore" || "$minecore" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "ERROR: MineCore not found in deployments/local.json"
    return 1
  fi

  local genesis_lp_vault
  genesis_lp_vault=$(read_json_address "contracts.GenesisLPVault24M.address")
  if [[ -z "$genesis_lp_vault" || "$genesis_lp_vault" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "ERROR: GenesisLPVault24M not found in deployments/local.json"
    return 1
  fi

  local paused guardian lock_start_raw lp_locked_raw lock_start lp_locked
  paused=$(cast call "$minecore" "takeoversPaused()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "unknown")
  guardian=$(cast call "$minecore" "guardian()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "unknown")
  lock_start_raw=$(cast call "$genesis_lp_vault" "lockStartTime()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  lp_locked_raw=$(cast call "$genesis_lp_vault" "lpLockedAmount()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  lock_start=$(decode_uint "$lock_start_raw")
  lp_locked=$(decode_uint "$lp_locked_raw")

  echo "  takeoversPaused: $paused"
  echo "  MineCore.guardian: $guardian"
  echo "  GenesisLPVault24M.lockStartTime: ${lock_start:-unknown}"
  echo "  GenesisLPVault24M.lpLockedAmount: ${lp_locked:-unknown}"

  if [[ "$paused" != "false" ]]; then
    echo "ERROR: MineCore.takeoversPaused() must be false after genesis finalization"
    return 1
  fi

  if [[ "${guardian,,}" == "${launch_controller,,}" ]]; then
    echo "ERROR: MineCore.guardian is still LaunchController; rotate it away before treating genesis as finalized"
    return 1
  fi

  if [[ -z "$lock_start" || "$lock_start" == "0" ]]; then
    echo "ERROR: GenesisLPVault24M.lockStartTime() is still 0"
    return 1
  fi

  if [[ -z "$lp_locked" || "$lp_locked" == "0" ]]; then
    echo "ERROR: GenesisLPVault24M.lpLockedAmount() is still 0"
    return 1
  fi

  return 0
}

echo "============================================"
echo "  Finalizing Genesis (Local)"
echo "============================================"
echo ""
echo "RPC: $RPC_URL"
echo ""

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [[ "$CHAIN_ID" != "31337" && "$CHAIN_ID" != "1337" ]]; then
  echo "ERROR: scripts/finalize_genesis.sh is local-only and refuses chainId '$CHAIN_ID'."
  echo "Use script/FinalizeGenesis.s.sol directly for Base Sepolia or Base mainnet."
  exit 1
fi
echo "Chain ID: $CHAIN_ID"
echo ""

LOCAL_DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || echo "")
if [[ -z "$LOCAL_DEPLOYER" ]]; then
  echo "ERROR: failed to derive local deployer address from LOCAL_PRIVATE_KEY"
  exit 1
fi

echo "Local deployer / guardian pin: $LOCAL_DEPLOYER"
echo ""

# Check if deployments/local.json exists
if [[ ! -f "$ROOT_DIR/deployments/local.json" ]]; then
  echo "ERROR: deployments/local.json not found. Populate it with a local deployment first."
  exit 1
fi

# Check if LaunchController is deployed
LAUNCH_CONTROLLER=$(read_json_address "contracts.LaunchController.address")
if [[ -z "$LAUNCH_CONTROLLER" || "$LAUNCH_CONTROLLER" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "ERROR: LaunchController not found in deployments/local.json"
  exit 1
fi

echo "LaunchController: $LAUNCH_CONTROLLER"

# Check if genesis is already finalized
ALREADY_FINALIZED=$(cast call "$LAUNCH_CONTROLLER" "genesisFinalized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "false")
if [[ "$ALREADY_FINALIZED" == "true" ]]; then
  echo ""
  echo "✓ Genesis already finalized. Verifying guardian rotation + LP lock state..."
  if verify_post_final_state "$LAUNCH_CONTROLLER"; then
    exit 0
  fi
  exit 1
fi

# Must match the local deployment flow's GENESIS_TIME_WARP_SEC.
# The canonical local deployment flow starts Anvil with --timestamp this many seconds in the past,
# so after this warp the chain arrives at approximately wall-clock time.
# Genesis accrual window is chain-gated: 1 day on local/testnet (10 days on mainnet).
GENESIS_TIME_WARP_SEC=86500

echo ""
echo "[1/3] Warping time forward $GENESIS_TIME_WARP_SEC seconds (sync with the local deployment flow offset)..."
cast rpc evm_increaseTime $GENESIS_TIME_WARP_SEC --rpc-url "$RPC_URL" > /dev/null 2>&1 && echo "  ✓ Time warped"
cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null 2>&1 && echo "  ✓ Block mined"

echo ""
echo "[2/3] Running FinalizeLocalGenesis script..."
cd "$ROOT_DIR"
LOCAL_PRIVATE_KEY="$PRIVATE_KEY" \
GUARDIAN="$LOCAL_DEPLOYER" \
forge script script/FinalizeLocalGenesis.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --non-interactive \
  -vvv

echo ""
echo "[3/3] Verifying genesis finalization..."
FINALIZED=$(cast call "$LAUNCH_CONTROLLER" "genesisFinalized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "false")
if [[ "$FINALIZED" == "true" ]]; then
  echo "  ✓ Genesis finalized successfully!"

  if ! verify_post_final_state "$LAUNCH_CONTROLLER"; then
    exit 1
  fi
else
  echo "  ⚠ Genesis finalization may have failed. Check the output above."
  exit 1
fi

echo ""
echo "============================================"
echo "  Genesis finalized! Guardian rotation and LP lock are now confirmed."
echo "============================================"
echo ""
