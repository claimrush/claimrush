#!/usr/bin/env bash
set -euo pipefail

# ClaimRush v1.0.0 policy lint.
#
# Purpose:
# - Enforce the naming-map policy around where custom errors and constants are declared.
# - Keep additions explicit via small allowlists.
#
# Run:
#   bash scripts/solidity_policy_lint.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# -----------------------------------------------------------------------------
# Allowlist (v1.0.0)
# -----------------------------------------------------------------------------

# Files allowed to declare custom errors (`error Foo();`).
#
# Notes:
# - Shared/common errors belong in src/lib/Errors.sol.
# - Contract-local errors are allowed in a small set of contracts with pinned specs.
ALLOWED_ERROR_FILES=(
  "src/lib/Errors.sol"
  "src/EntryTokenRegistry.sol"
  "src/vault/GenesisLPVault24M.sol"
  "src/vault/LpStakingVault7D.sol"
  "src/genesis/LaunchController.sol"
  "src/lens/AgentLens.sol"
  # Upgradeable base contract (OZ-compatible reimplementation)
  "src/lib/UpgradeableProtocolBase.sol"
  # Named runtime proxy wrappers — host the shared DelegatedEOAGuard library
  # used by every transparent proxy to reject EIP-7702 delegation designators
  # on the proxy initialOwner / admin slot. Contract-local custom error.
  "src/lib/RuntimeProxyWrappers.sol"
  # Local-only test mocks (Path B)
  "src/mocks/localdex/LocalAerodromePool.sol"
  "src/mocks/localdex/LocalAerodromeRouter.sol"
)

# Files allowed to declare `constant` state variables.
#
# Notes:
# - Shared/global numeric constants belong in src/lib/Constants.sol.
# - Contract-local constants are allowed only where the spec defines them.
ALLOWED_CONSTANT_FILES=(
  "src/lib/Constants.sol"
  "src/lib/DelegationActionTypes.sol"
  "src/lib/DelegationPermissions.sol"
  "src/Furnace.sol"
  "src/FurnaceGuardHelper.sol"
  "src/MineCore.sol"
  "src/MineCoreHelper.sol"
  "src/MarketRouter.sol"
  "src/MaintenanceHub.sol"
  "src/ClaimToken.sol"
  "src/ClaimAllHelper.sol"
  "src/ShareholderRoyalties.sol"
  "src/VeClaimNFT.sol"
  "src/DelegationHub.sol"
  "src/vault/GenesisLPVault24M.sol"
  "src/vault/LpStakingVault7D.sol"
  "src/lens/AgentLens.sol"
  "src/genesis/LaunchController.sol"
  "src/EntryTokenRegistry.sol"
  "src/lib/SafeERC20View.sol"
  # Upgradeable base contract (OZ-compatible reimplementation)
  "src/lib/UpgradeableProtocolBase.sol"
  # Local-only test mocks (Path B)
  "src/mocks/localdex/LocalPools.sol"
)

declare -A _ALLOWED_ERR
for f in "${ALLOWED_ERROR_FILES[@]}"; do
  _ALLOWED_ERR["$f"]=1
done

declare -A _ALLOWED_CONST
for f in "${ALLOWED_CONSTANT_FILES[@]}"; do
  _ALLOWED_CONST["$f"]=1
done

fail=0

echo "[policy-lint] Checking custom error declarations..."
# Match Solidity custom error declarations.
# Example: error ZeroAddress();
while IFS= read -r match; do
  [[ -z "$match" ]] && continue
  file="${match%%:*}"

  if [[ -z "${_ALLOWED_ERR[$file]+x}" ]]; then
    echo "[policy-lint] ERROR: custom error declaration outside allowlist: $match" >&2
    fail=1
  fi

done < <(
  grep -RIn --include '*.sol' -E '^[[:space:]]*error[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' src || true
)


echo "[policy-lint] Checking constant declarations..."
# Match Solidity constant declarations. We keep this intentionally lightweight:
# - grep for the keyword `constant`
# - exclude comment-only lines
while IFS= read -r match; do
  [[ -z "$match" ]] && continue
  file="${match%%:*}"

  if [[ -z "${_ALLOWED_CONST[$file]+x}" ]]; then
    echo "[policy-lint] ERROR: constant declaration outside allowlist: $match" >&2
    fail=1
  fi

done < <(
  grep -RIn --include '*.sol' -E '\bconstant\b' src \
    | grep -vE ':[[:space:]]*//' \
    | grep -vE ':[[:space:]]*/\*' \
    | grep -vE ':[[:space:]]*\*' \
    || true
)

if [[ "$fail" -ne 0 ]]; then
  echo "[policy-lint] FAILED" >&2
  echo "[policy-lint] See the naming map for the policy." >&2
  echo "[policy-lint] If this change is intentional, update allowlists in scripts/solidity_policy_lint.sh." >&2
  exit 1
fi

echo "[policy-lint] OK"
