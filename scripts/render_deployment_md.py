#!/usr/bin/env python3
"""Render ClaimRush deployment manifests to markdown.

Single source of truth:
  - deployments/<network>.json

Generated outputs:
  - deployments/<network>.md
  - docs/deployments/<version>-<network>.md

This script is intentionally dependency-free and deterministic.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Mapping

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


NETWORK_TITLES: dict[str, str] = {
    "base_mainnet": "Base mainnet",
    "base_sepolia": "Base Sepolia",
    "local": "Local",
}

# These explorer strings are rendered into markdown verbatim.
EXPLORER_LABELS: dict[str, str] = {
    "base_mainnet": "BaseScan (`https://basescan.org`)",
    "base_sepolia": "BaseScan Sepolia (`https://sepolia.basescan.org`)",
}

# Ordering + grouping (v1.0.0). Unknown/new contracts fall back to the Core table.
CORE_ORDER = [
    "ClaimToken",
    "VeClaimNFT",
    "MineCore",
    "ShareholderRoyalties",
    "Furnace",
    "LpStakingVault7D",
    "MarketRouter",
    "FurnaceEntryTokenRegistry",
    "MineCoreEntryTokenRegistry",
    "DexAdapter",
    "GameRouter",  # optional contract (unset in v1.0.0)
    "DelegationHub",
    "ClaimAllHelper",
]

GOVERNANCE_ORDER = [
    "TimelockController",
]

GENESIS_ORDER = [
    "LaunchController",
    "GenesisLPVault24M",
]

MAINTENANCE_ORDER = [
    "MaintenanceHub",
]

AUXILIARY_ORDER = [
    "AgentLens",
    "FurnaceQuoter",
    "MineCoreQuoter",
]

GENESIS_NOTES: dict[str, str] = {
    "LaunchController": "one-shot genesis controller (`finalizeGenesis`)",
    "GenesisLPVault24M": "locks genesis LP 24 months",
}

PROTOCOL_PARAM_ORDER = [
    "maxUserBonusBps",
    "lpTopupRateMinBps",
    "lpTopupRateMaxBps",
    "lockTargetClaim",  # compatibility field for the prior base-cap anchor
    "lockPctTargetBps",
    "lockPctMinForBoostCapBps",
    "lockPctFullBoostCapBps",
    "reserveTargetFinalClaim",
    "reserveMultMaxBpsLowLock",
    "reserveMultMaxBps",
    "swingTimeSeconds",
    "bonusDecayWindowSeconds",
    "sellSpreadFloor7dBps",
]

PROTOCOL_PARAM_NOTES: dict[str, str] = {
    "maxUserBonusBps": "basis points (100%)",
    "lpTopupRateMinBps": "basis points (7.5%)",
    "lpTopupRateMaxBps": "basis points (15%)",
    "lockTargetClaim": "compatibility field; bonus uses lock% targets",
    "lockPctTargetBps": "basis points (7.0%)",
    "lockPctMinForBoostCapBps": "basis points (5%)",
    "lockPctFullBoostCapBps": "basis points (20%)",
    "reserveTargetFinalClaim": "CLAIM (whole tokens) target reserve at end of run",
    "reserveMultMaxBpsLowLock": "basis points (1.5x)",
    "reserveMultMaxBps": "basis points (2.0x)",
    "swingTimeSeconds": "seconds (60 days)",
    "bonusDecayWindowSeconds": "seconds (3 hours)",
    "sellSpreadFloor7dBps": "basis points (1.2% at 7d)",
}

RUNTIME_PROXY_CONTRACTS = {
    "MineCore",
    "ShareholderRoyalties",
    "Furnace",
    "MarketRouter",
}


def _load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8", errors="replace"))


def _human_network(network: str, data: Mapping[str, Any]) -> str:
    if network in NETWORK_TITLES:
        return NETWORK_TITLES[network]

    chain = str(data.get("chain") or "").strip().lower()
    if chain == "base":
        return "Base mainnet"
    if chain == "base_sepolia":
        return "Base Sepolia"

    return network.replace("_", " ").title()


def _is_testnet(network: str, data: Mapping[str, Any]) -> bool:
    chain = str(data.get("chain") or "").lower()
    s = f"{network} {chain}".lower()
    return "sepolia" in s or "testnet" in s


def _requires_nonzero_start_blocks(network: str, data: Mapping[str, Any]) -> bool:
    title = _human_network(network, data).lower()
    chain = str(data.get("chain") or "").lower()
    return network != "local" and title != "local" and chain != "local"


def _fmt_addr(addr: Any) -> str:
    return f"`{str(addr)}`"


def _fmt_block(block: Any) -> str:
    try:
        return f"`{int(block)}`"
    except Exception:
        return f"`{str(block)}`"


def _fmt_proxy_meta(value: Any) -> str:
    s = str(value or "").strip()
    if not s:
        return "—"
    return f"`{s}`"


def _banner(network: str) -> list[str]:
    return [
        "<!--",
        "  AUTO-GENERATED FILE. DO NOT EDIT.",
        f"  Source of truth: deployments/{network}.json",
        "  Regenerate: bash scripts/sync_deployments_all.sh",
        "-->",
        "",
        f"> ⚠️ Auto-generated from `deployments/{network}.json`. Do not edit by hand.",
        "> Regenerate with `bash scripts/sync_deployments_all.sh`.",
        "",
    ]


def _core_row_names(required: Mapping[str, Any], optional: Mapping[str, Any]) -> list[str]:
    required_keys = set(required.keys())
    optional_keys = set(optional.keys())

    excluded_required = set(GOVERNANCE_ORDER) | set(GENESIS_ORDER) | set(MAINTENANCE_ORDER) | set(AUXILIARY_ORDER)

    out: list[str] = []

    for name in CORE_ORDER:
        if name in required_keys or name in optional_keys:
            out.append(name)

    # Any new/unknown required contracts (not in known groupings) should still show up.
    remaining_required = sorted(required_keys - excluded_required - set(out))
    out.extend(remaining_required)

    # Optional contracts must appear in Core table (docs lint requirement).
    remaining_optional = sorted(optional_keys - set(out))
    out.extend(remaining_optional)

    return out


def _render_core_contracts(required: Mapping[str, Any], optional: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    lines.append("## Core contracts")
    lines.append("")
    lines.append("| Component | Status | Address | Implementation | Proxy admin | Proxy admin owner | Start block |")
    lines.append("|---|---|---:|---:|---:|---:|---:|")

    for name in _core_row_names(required, optional):
        if name in optional:
            o = optional.get(name) or {}
            deployed = bool(o.get("deployed"))
            status = "OPTIONAL" if deployed else "NOT DEPLOYED IN V1.0.0 (MUST remain unset)"
            addr = _fmt_addr(o.get("address"))
            impl = _fmt_proxy_meta(o.get("implementation") if name in RUNTIME_PROXY_CONTRACTS else None)
            proxy_admin = _fmt_proxy_meta(o.get("proxyAdmin") if name in RUNTIME_PROXY_CONTRACTS else None)
            proxy_admin_owner = _fmt_proxy_meta(o.get("proxyAdminOwner") if name in RUNTIME_PROXY_CONTRACTS else None)
            start = _fmt_block(o.get("startBlock"))
        else:
            c = required.get(name) or {}
            status = "REQUIRED"
            addr = _fmt_addr(c.get("address"))
            impl = _fmt_proxy_meta(c.get("implementation") if name in RUNTIME_PROXY_CONTRACTS else None)
            proxy_admin = _fmt_proxy_meta(c.get("proxyAdmin") if name in RUNTIME_PROXY_CONTRACTS else None)
            proxy_admin_owner = _fmt_proxy_meta(c.get("proxyAdminOwner") if name in RUNTIME_PROXY_CONTRACTS else None)
            start = _fmt_block(c.get("startBlock"))

        lines.append(f"| {name} | {status} | {addr} | {impl} | {proxy_admin} | {proxy_admin_owner} | {start} |")

    return lines


def _render_governance(required: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    entries = [(n, required.get(n) or {}) for n in GOVERNANCE_ORDER if required.get(n)]
    if not entries:
        return lines

    lines.append("## Governance infrastructure")
    lines.append("")
    lines.append("| Component | Address | Start block | Notes |")
    lines.append("|---|---:|---:|---|")
    for name, c in entries:
        note = ""
        if name == "TimelockController":
            delay = c.get("minDelaySeconds")
            bootstrap_admin = str(c.get("bootstrapAdmin") or "").strip()
            proposer = str(c.get("proposer") or "").strip()
            executor = str(c.get("executor") or "").strip()
            note_parts: list[str] = []
            if delay is None:
                note_parts.append("governance timelock")
            else:
                note_parts.append(f"governance timelock (`minDelaySeconds = {delay}`)")
            if bootstrap_admin and bootstrap_admin.lower() != ZERO_ADDRESS:
                note_parts.append(f"bootstrap admin = `{bootstrap_admin}`")
            if proposer and proposer.lower() != ZERO_ADDRESS:
                note_parts.append(f"proposer = `{proposer}`")
            if executor and executor.lower() != ZERO_ADDRESS:
                note_parts.append(f"executor = `{executor}`")
            note = "; ".join(note_parts)
        lines.append(f"| {name} | {_fmt_addr(c.get('address'))} | {_fmt_block(c.get('startBlock'))} | {note} |")
    return lines


def _render_aerodrome(data: Mapping[str, Any], symbol_fallback: str = "WETH") -> list[str]:
    aero = data.get("aerodrome") or {}

    wrapped = aero.get("wrappedNative") or {}
    router = aero.get("router") or {}
    pool = aero.get("claimWethPool") or {}
    lp = aero.get("lpToken") or {}

    symbol = str(wrapped.get("symbol") or symbol_fallback)

    lines: list[str] = []
    lines.append("## Aerodrome")
    lines.append("")
    lines.append("| Component | Address | Start block | Notes |")
    lines.append("|---|---:|---:|---|")
    lines.append(
        f"| Wrapped native ({symbol}) | {_fmt_addr(wrapped.get('address'))} | {_fmt_block(wrapped.get('startBlock'))} | token used for the ETH swap path |"
    )
    lines.append(
        f"| Aerodrome router | {_fmt_addr(router.get('address'))} | {_fmt_block(router.get('startBlock'))} | used internally by DexAdapter (swap routing) |"
    )

    pool_notes = str(pool.get("poolType") or "")
    if not pool_notes:
        pool_notes = "pool"

    lines.append(
        f"| CLAIM/{symbol} pool | {_fmt_addr(pool.get('address'))} | {_fmt_block(pool.get('startBlock'))} | {pool_notes} |"
    )
    lines.append(
        f"| LP token | {_fmt_addr(lp.get('address'))} | {_fmt_block(lp.get('startBlock'))} | same as pool in many cases |"
    )

    return lines


def _render_chainlink(data: Mapping[str, Any]) -> list[str]:
    cl = data.get("chainlink") or {}
    feed = cl.get("ethUsdFeed") or {}

    lines: list[str] = []
    lines.append("## Chainlink")
    lines.append("")
    lines.append("| Feed | Address | Notes |")
    lines.append("|---|---:|---|")
    lines.append(
        f"| ETH/USD price feed | {_fmt_addr(feed.get('address'))} | used for USD-denominated displays (UI/indexer only) |"
    )
    return lines


def _render_genesis(required: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    lines.append("## Genesis infrastructure (required)")
    lines.append("")
    lines.append("| Component | Address | Start block | Notes |")
    lines.append("|---|---:|---:|---|")

    for name in GENESIS_ORDER:
        if name not in required:
            continue
        c = required.get(name) or {}
        note = GENESIS_NOTES.get(name, "")
        if name == "GenesisLPVault24M":
            lp_withdraw_recipient = str(c.get("lpWithdrawRecipient") or "").strip()
            if lp_withdraw_recipient and lp_withdraw_recipient.lower() != ZERO_ADDRESS:
                note = f"{note}; `lpWithdrawRecipient = {lp_withdraw_recipient}`"
        lines.append(
            f"| {name} | {_fmt_addr(c.get('address'))} | {_fmt_block(c.get('startBlock'))} | {note} |"
        )

    lines.append("")
    lines.append("Wiring / config:")
    lines.append("- `GenesisLPVault24M.lpWithdrawRecipient` MUST match the manifest-declared LP withdrawal recipient.")
    lines.append(
        "- LP lock starts at genesis (`LaunchController.finalizeGenesis()`). `GenesisLPVault24M.extendLock(newUnlockTime)` exists but is not part of the v1.0.0 manifest requirements."
    )

    return lines


def _render_maintenance_repo(network: str, required: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    lines.append("## MaintenanceHub (required)")
    lines.append(f"`deployments/{network}.json` MUST include `MaintenanceHub` under `contracts`.")
    lines.append("| Component | Address | Start block | Notes |")
    lines.append("|---|---:|---:|---|")

    name = "MaintenanceHub"
    c = required.get(name) or {}
    rescue_recipient = str(c.get("rescueRecipient") or "").strip()
    note = f"`rescueRecipient = {rescue_recipient}`" if rescue_recipient and rescue_recipient.lower() != ZERO_ADDRESS else ""
    lines.append(f"| {name} | {_fmt_addr(c.get('address'))} | {_fmt_block(c.get('startBlock'))} | {note} |")
    lines.append("")
    lines.append("Wiring / config:")
    lines.append("- `MaintenanceHub.rescueRecipient` MUST match the manifest-declared rescue recipient.")

    return lines


def _render_auxiliary(required: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    entries = [(n, required.get(n) or {}) for n in AUXILIARY_ORDER if required.get(n)]
    if not entries:
        return lines
    lines.append("## Auxiliary read helpers")
    lines.append("")
    lines.append("| Component | Address | Start block |")
    lines.append("|---|---:|---:|")
    for name, c in entries:
        lines.append(f"| {name} | {_fmt_addr(c.get('address'))} | {_fmt_block(c.get('startBlock'))} |")
    return lines


def _render_maintenance_docs(required: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    lines.append("## MaintenanceHub (required)")
    lines.append("")
    lines.append("This manifest MUST include `MaintenanceHub` under `contracts`.")
    lines.append("")
    lines.append("| Component | Address | Start block | Notes |")
    lines.append("|---|---:|---:|---|")

    name = "MaintenanceHub"
    c = required.get(name) or {}
    rescue_recipient = str(c.get("rescueRecipient") or "").strip()
    note = f"`rescueRecipient = {rescue_recipient}`" if rescue_recipient and rescue_recipient.lower() != ZERO_ADDRESS else ""
    lines.append(f"| {name} | {_fmt_addr(c.get('address'))} | {_fmt_block(c.get('startBlock'))} | {note} |")
    lines.append("")
    lines.append("Wiring / config:")
    lines.append("- `MaintenanceHub.rescueRecipient` MUST match the manifest-declared rescue recipient.")

    return lines


def _render_protocol_params(data: Mapping[str, Any]) -> list[str]:
    furnace = ((data.get("protocolParams") or {}).get("furnace") or {})

    lines: list[str] = []
    lines.append("## Protocol params (Furnace)")
    lines.append("")
    lines.append("| Param | Value | Units / notes |")
    lines.append("|---|---:|---|")

    for key in PROTOCOL_PARAM_ORDER:
        val = furnace.get(key)
        if val is None:
            val = 0
        note = PROTOCOL_PARAM_NOTES.get(key, "")
        lines.append(f"| `{key}` | `{val}` | {note} |")

    return lines


def _render_analytics_config(data: Mapping[str, Any]) -> list[str]:
    analytics = data.get("analytics") or {}
    excl = analytics.get("addressExclusions")

    lines: list[str] = []
    lines.append("## Analytics config")
    lines.append("")

    if not excl:
        version = str(data.get("version") or "")
        if version:
            lines.append(f"- No address exclusions are applied in {version} leaderboards.")
        else:
            lines.append("- No address exclusions are applied.")
        return lines

    # Render explicit exclusions.
    lines.append(f"- Address exclusions ({len(excl)}):")
    for addr in excl:
        lines.append(f"  - `{addr}`")
    return lines


def _render_repo_markdown(network: str, data: Mapping[str, Any]) -> str:
    version = str(data.get("version") or "")
    title_net = _human_network(network, data)
    is_testnet = _is_testnet(network, data)

    lines: list[str] = []
    lines.append(f"# ClaimRush {version} deployment manifest ({title_net})".strip())
    lines.append("")
    lines.extend(_banner(network))

    suffix = "" if not is_testnet else " (staging/testnet)"
    lines.append(
        f"This file is the human-readable deployment manifest for ClaimRush {version} on {title_net}{suffix}.".strip()
    )
    lines.append("")

    if is_testnet:
        lines.append(
            "This manifest is a template and is NOT production-ready until all REQUIRED addresses and REQUIRED start blocks are filled with non-zero values."
        )
        lines.append("")

    lines.append(f"`deployments/{network}.json` is canonical. This markdown file is generated from it.")
    lines.append("")

    lines.append(f"Manifest validity on {title_net} requires:")
    lines.append("- Every REQUIRED address is non-zero.")
    if _requires_nonzero_start_blocks(network, data):
        lines.append("- Every REQUIRED start block is non-zero.")
    else:
        lines.append("- For local manifests, startBlock MAY be `0` on ephemeral chains, but persisted mirrors should be refreshed from the latest deployment output.")
    lines.append("- Every component not deployed in v1.0.0 remains unset (`0x00…` / `0`).")
    lines.append("")

    required = data.get("contracts") or {}
    optional = data.get("optional") or {}

    sections: list[list[str]] = [
        _render_core_contracts(required, optional),
        _render_governance(required),
        _render_aerodrome(data),
        _render_chainlink(data),
        _render_genesis(required),
        _render_maintenance_repo(network, required),
        _render_auxiliary(required),
        _render_protocol_params(data),
        _render_analytics_config(data),
    ]

    # Join sections with a single blank line between them.
    for i, sec in enumerate(sections):
        if i != 0:
            lines.append("")
        lines.extend(sec)

    return "\n".join(lines).rstrip() + "\n"


def _render_docs_markdown(network: str, data: Mapping[str, Any]) -> str:
    version = str(data.get("version") or "")
    title_net = _human_network(network, data)
    is_testnet = _is_testnet(network, data)

    chain_id = data.get("chainId")
    explorer = EXPLORER_LABELS.get(network)

    lines: list[str] = []
    lines.append(f"# ClaimRush {version} deployment manifest ({title_net})".strip())
    lines.append("")
    lines.extend(_banner(network))

    suffix = "" if not is_testnet else " (staging/testnet)"
    lines.append(
        f"This file is the docs-only deployment manifest mirror for ClaimRush {version} on {title_net}{suffix}.".strip()
    )
    lines.append("")

    lines.append("Identity:")
    lines.append(f"- Deployment name (manifest selector): `{network}`")
    if chain_id is not None:
        lines.append(f"- Chain ID: `{chain_id}`")
    if explorer:
        lines.append(f"- Explorer: {explorer}")
    lines.append("")

    lines.append("Notes:")
    lines.append(f"- Canonical source of truth: `deployments/{network}.json` (repo root)")
    lines.append(
        f"- This file (`deployments/{network}.md`) is auto-generated from the JSON manifest."
    )
    lines.append("- Regenerate: `bash scripts/sync_deployments_all.sh`")
    lines.append("")

    if is_testnet:
        lines.append(
            "This manifest is a template and is NOT production-ready until all REQUIRED addresses and REQUIRED start blocks are filled with non-zero values."
        )
        lines.append("")

    lines.append(f"Manifest validity on {title_net} requires:")
    lines.append("- Every REQUIRED address is non-zero.")
    if _requires_nonzero_start_blocks(network, data):
        lines.append("- Every REQUIRED start block is non-zero.")
    else:
        lines.append("- For local manifests, startBlock MAY be `0` on ephemeral chains, but persisted mirrors should be refreshed from the latest deployment output.")
    lines.append("- Every component not deployed in v1.0.0 remains unset (`0x00…` / `0`).")
    lines.append("")

    required = data.get("contracts") or {}
    optional = data.get("optional") or {}

    sections: list[list[str]] = [
        _render_core_contracts(required, optional),
        _render_governance(required),
        _render_aerodrome(data),
        _render_chainlink(data),
        _render_genesis(required),
        _render_maintenance_docs(required),
        _render_auxiliary(required),
        _render_protocol_params(data),
        _render_analytics_config(data),
    ]

    # Docs format uses horizontal rules between sections for readability.
    lines.append("---")
    lines.append("")

    for i, sec in enumerate(sections):
        if i != 0:
            lines.append("")
            lines.append("---")
            lines.append("")
        lines.extend(sec)

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="Render deployment manifest markdown from a canonical JSON file")
    ap.add_argument("--json", required=True, help="Path to deployments/<network>.json")
    ap.add_argument("--network", required=True, help="Deployment name (file stem), e.g. base_mainnet")
    ap.add_argument("--format", required=True, choices=["repo", "docs"], help="Output markdown format")
    args = ap.parse_args()

    path = Path(args.json)
    data = _load_json(path)

    if args.format == "repo":
        out = _render_repo_markdown(args.network, data)
    else:
        out = _render_docs_markdown(args.network, data)

    print(out, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
