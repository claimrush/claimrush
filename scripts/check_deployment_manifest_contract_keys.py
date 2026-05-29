#!/usr/bin/env python3
"""Guardrail: deployment manifests must have a consistent set of required contract keys.

Every network manifest (base_mainnet, base_sepolia, local) must include
all contracts in the REQUIRED set.  Optional contracts (AgentLens, FurnaceQuoter)
are allowed to appear in any subset.

Run:
    python3 scripts/check_deployment_manifest_contract_keys.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENTS_DIR = ROOT / "deployments"

# Every shipped manifest MUST have these contract keys.
# If a new contract is added to the protocol, add it here.
REQUIRED_CONTRACT_KEYS = {
    "ClaimToken",
    "VeClaimNFT",
    "MineCore",
    "MineCoreQuoter",
    "ShareholderRoyalties",
    "Furnace",
    "LpStakingVault7D",
    "FurnaceEntryTokenRegistry",
    "MineCoreEntryTokenRegistry",
    "ClaimAllHelper",
    "DelegationHub",
    "TimelockController",
    "MarketRouter",
    "DexAdapter",
    "LaunchController",
    "GenesisLPVault24M",
    "MaintenanceHub",
}

# Contracts that may appear only in some manifests.
OPTIONAL_CONTRACT_KEYS = {
    "AgentLens",
    "FurnaceQuoter",
}


def main() -> int:
    errors = 0
    manifests = sorted(DEPLOYMENTS_DIR.glob("*.json"))

    if not manifests:
        print("[manifest-keys] ERROR: no deployment manifests found", file=sys.stderr)
        return 1

    for mpath in manifests:
        data = json.loads(mpath.read_text(encoding="utf-8"))
        contracts = set(data.get("contracts", {}).keys())

        # Check required keys present.
        missing = REQUIRED_CONTRACT_KEYS - contracts
        if missing:
            errors += len(missing)
            for key in sorted(missing):
                print(
                    f"[manifest-keys] ERROR: {mpath.name} missing required contract: {key}",
                    file=sys.stderr,
                )

        # Check no unexpected keys.
        unexpected = contracts - REQUIRED_CONTRACT_KEYS - OPTIONAL_CONTRACT_KEYS
        if unexpected:
            errors += len(unexpected)
            for key in sorted(unexpected):
                print(
                    f"[manifest-keys] ERROR: {mpath.name} has unknown contract key: {key} "
                    f"(add to REQUIRED or OPTIONAL set in this script)",
                    file=sys.stderr,
                )

    if errors:
        print(f"[manifest-keys] FAIL: {errors} issue(s)", file=sys.stderr)
        return 1

    print(f"[manifest-keys] OK ({len(manifests)} manifests checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
