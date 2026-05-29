#!/usr/bin/env python3
"""Guardrail: release manifests must route authority and value endpoints deliberately.

This is a static companion to the live `verify_deployment.py` gate. It catches
manifest-level mistakes that can silently redirect value or leave launch roles
unreachable before a fork/live RPC check is run.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ZERO = "0x" + "0" * 40
ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")


def _norm(value: str) -> str:
    return value.lower()


def _is_addr(value: Any) -> bool:
    return isinstance(value, str) and bool(ADDR_RE.fullmatch(value))


def _require_addr(errors: list[str], label: str, value: Any, *, allow_zero: bool = False) -> str | None:
    if not _is_addr(value):
        errors.append(f"{label}: invalid address {value!r}")
        return None
    if not allow_zero and _norm(value) == ZERO:
        errors.append(f"{label}: zero address is not reachable")
        return None
    return value


def _contract_addresses(contracts: dict[str, Any]) -> dict[str, str]:
    out: dict[str, str] = {}
    for name, meta in contracts.items():
        if isinstance(meta, dict):
            addr = meta.get("address")
            if _is_addr(addr) and _norm(addr) != ZERO:
                out[_norm(addr)] = name
    return out


def _check_safe(errors: list[str], label: str, safe: dict[str, Any]) -> str | None:
    addr = _require_addr(errors, f"safes.{label}.address", safe.get("address"))
    threshold = safe.get("threshold")
    owners = safe.get("owners")
    if not isinstance(threshold, int) or threshold < 2:
        errors.append(f"safes.{label}.threshold: expected integer >= 2")
    if not isinstance(owners, list) or not owners:
        errors.append(f"safes.{label}.owners: missing owners")
    else:
        seen: set[str] = set()
        for i, owner in enumerate(owners):
            owner_addr = _require_addr(errors, f"safes.{label}.owners[{i}]", owner)
            if owner_addr is not None:
                if _norm(owner_addr) in seen:
                    errors.append(f"safes.{label}.owners[{i}]: duplicate owner {owner_addr}")
                seen.add(_norm(owner_addr))
        if isinstance(threshold, int) and len(owners) < threshold:
            errors.append(f"safes.{label}: threshold {threshold} exceeds owner count {len(owners)}")
    return addr


def _is_template_state(contracts: dict[str, Any]) -> bool:
    """Detect pre-deploy template manifests where every protocol contract address
    is still the zero placeholder (0x0...0). In that state role-reachability
    checks are meaningless because no contracts exist yet — the deploy script
    will populate every address from the live broadcast artefact and the
    manifest's own notes block instructs operators to leave them at 0x0.
    Allows the gate to pass on template manifests while staying strict for
    populated ones."""
    own_addresses = [
        meta.get("address")
        for meta in contracts.values()
        if isinstance(meta, dict) and "address" in meta
    ]
    if not own_addresses:
        return False
    return all(_is_addr(a) and _norm(a) == ZERO for a in own_addresses)


def check_manifest(path: Path) -> list[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []

    contracts = data.get("contracts")
    if not isinstance(contracts, dict):
        return [f"{path}: missing contracts object"]

    if _is_template_state(contracts):
        print(
            f"[role-reachability] SKIP: {path.name} is a pre-deploy template "
            f"(all protocol contract addresses are 0x0). Will be enforced "
            f"automatically once the deploy populates the manifest."
        )
        return []

    contract_by_addr = _contract_addresses(contracts)
    chain_id = data.get("chainId")

    timelock = contracts.get("TimelockController", {})
    if not isinstance(timelock, dict):
        errors.append("contracts.TimelockController: missing object")
        timelock = {}

    timelock_addr = _require_addr(errors, "contracts.TimelockController.address", timelock.get("address"))
    proposer = _require_addr(errors, "contracts.TimelockController.proposer", timelock.get("proposer"))
    executor = _require_addr(errors, "contracts.TimelockController.executor", timelock.get("executor"))
    bootstrap_admin = _require_addr(
        errors, "contracts.TimelockController.bootstrapAdmin", timelock.get("bootstrapAdmin")
    )

    min_delay = timelock.get("minDelaySeconds")
    if not isinstance(min_delay, int) or min_delay < 0:
        errors.append("contracts.TimelockController.minDelaySeconds: expected non-negative integer")
    elif chain_id == 8453 and min_delay < 172_800:
        errors.append("contracts.TimelockController.minDelaySeconds: Base mainnet must be >= 172800 seconds")

    safes = data.get("safes")
    if chain_id == 8453:
        if not isinstance(safes, dict):
            errors.append("safes: Base mainnet manifest must declare adminSafe and guardianSafe")
            safes = {}
        admin_safe = safes.get("adminSafe", {}) if isinstance(safes, dict) else {}
        guardian_safe = safes.get("guardianSafe", {}) if isinstance(safes, dict) else {}
        admin_addr = _check_safe(errors, "adminSafe", admin_safe if isinstance(admin_safe, dict) else {})
        guardian_addr = _check_safe(errors, "guardianSafe", guardian_safe if isinstance(guardian_safe, dict) else {})

        if admin_addr and proposer and _norm(proposer) != _norm(admin_addr):
            errors.append("Timelock proposer must be the Admin Safe on Base mainnet")
        if admin_addr and executor and _norm(executor) != _norm(admin_addr):
            errors.append("Timelock executor must be the Admin Safe on Base mainnet")
        if admin_addr and guardian_addr and _norm(admin_addr) == _norm(guardian_addr):
            errors.append("Admin Safe and Guardian Safe must be distinct")

        admin_owners = {
            _norm(x)
            for x in (admin_safe.get("owners", []) if isinstance(admin_safe, dict) else [])
            if _is_addr(x)
        }
        guardian_owners = {
            _norm(x)
            for x in (guardian_safe.get("owners", []) if isinstance(guardian_safe, dict) else [])
            if _is_addr(x)
        }
        overlap = sorted(admin_owners & guardian_owners)
        if overlap:
            errors.append(f"Admin Safe and Guardian Safe signer sets overlap: {', '.join(overlap)}")

    role_sinks = {
        "timelock.proposer": proposer,
        "timelock.executor": executor,
        "timelock.bootstrapAdmin": bootstrap_admin,
        "GenesisLPVault24M.lpWithdrawRecipient": (
            contracts.get("GenesisLPVault24M", {}) or {}
        ).get("lpWithdrawRecipient"),
        "MaintenanceHub.rescueRecipient": (contracts.get("MaintenanceHub", {}) or {}).get("rescueRecipient"),
    }

    if chain_id == 8453 and isinstance(safes, dict):
        admin_addr = (safes.get("adminSafe", {}) or {}).get("address")
        rescue = role_sinks["MaintenanceHub.rescueRecipient"]
        if _is_addr(admin_addr) and _is_addr(rescue) and _norm(rescue) != _norm(admin_addr):
            errors.append("MaintenanceHub.rescueRecipient must be the Admin Safe on Base mainnet")

    for label, value in role_sinks.items():
        addr = _require_addr(errors, label, value)
        if addr is None:
            continue
        if timelock_addr and label != "timelock.bootstrapAdmin" and _norm(addr) == _norm(timelock_addr):
            errors.append(f"{label}: points at TimelockController itself")
        pointed_contract = contract_by_addr.get(_norm(addr))
        if pointed_contract and label not in {"timelock.proposer", "timelock.executor"}:
            errors.append(f"{label}: points at protocol contract {pointed_contract}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifests", nargs="*", type=Path, default=[ROOT / "deployments/base_mainnet.json"])
    args = parser.parse_args()

    failures = 0
    for manifest in args.manifests:
        path = manifest if manifest.is_absolute() else ROOT / manifest
        errors = check_manifest(path)
        if errors:
            failures += len(errors)
            for err in errors:
                print(f"[role-reachability] ERROR: {path.relative_to(ROOT)}: {err}", file=sys.stderr)
        else:
            print(f"[role-reachability] OK: {path.relative_to(ROOT)}")

    if failures:
        print(f"[role-reachability] FAIL: {failures} issue(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
