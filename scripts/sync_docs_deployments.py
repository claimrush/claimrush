#!/usr/bin/env python3
"""Sync docs/deployments/*.md from deployments/*.json.

Why:
- Contract addresses + start blocks are money-critical.
- The repo already has a machine-readable source of truth (deployments/*.json).
- docs/deployments/* must not be a second human-edited source of truth.

Usage:
  python3 scripts/sync_docs_deployments.py            # write/sync generated docs
  python3 scripts/sync_docs_deployments.py --write    # same as default
  python3 scripts/sync_docs_deployments.py --check    # CI mode; fails if drift exists
"""

from __future__ import annotations

import argparse
import difflib
import json
import sys
from dataclasses import dataclass
from pathlib import Path

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "deployments"
DOCS_DIR = ROOT / "docs" / "deployments"
RUNTIME_PROXY_CONTRACTS = {
    "MineCore",
    "ShareholderRoyalties",
    "Furnace",
    "MarketRouter",
}
GOVERNANCE_CONTRACT_KEYS = {
    "TimelockController",
}

def _write_text_lf(path: Path, content: str) -> None:
    # Deterministic newlines across platforms (avoids CRLF drift on Windows).
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(content)


@dataclass(frozen=True)
class ManifestInfo:
    deployment_name: str
    version: str
    chain_id: int
    doc_filename: str
    network_label: str
    classification_label: str


def _load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except json.JSONDecodeError as e:
        raise ValueError(f"{path}: invalid JSON: {e}")


def _network_label(deployment_name: str, chain_id: int) -> str:
    # Keep this mapping intentionally small and explicit.
    if deployment_name == "base_mainnet" or chain_id == 8453:
        return "Base mainnet"
    if deployment_name == "base_sepolia" or chain_id == 84532:
        return "Base Sepolia"

    # Fallback: humanize the name.
    return deployment_name.replace("_", " ")


def _classification_label(deployment_name: str) -> str:
    name = deployment_name.lower()
    if "mainnet" in name:
        return "Production"
    if "sepolia" in name or "testnet" in name or "staging" in name:
        return "Staging/testnet"
    return "Network"


def _explorer_line(deployment_name: str, chain_id: int) -> str:
    # Keep this conservative: only hardcode explorers we are sure about.
    if deployment_name == "base_mainnet" or chain_id == 8453:
        return "Explorer: BaseScan (`https://basescan.org`)"
    if deployment_name == "base_sepolia" or chain_id == 84532:
        return "Explorer: Base Sepolia explorer (use BaseScan Sepolia or official explorer as configured)"
    return "Explorer: (not specified)"


def _is_template_network(deployment_name: str) -> bool:
    name = deployment_name.lower()
    return "sepolia" in name or "testnet" in name or "staging" in name


def _requires_nonzero_start_blocks(deployment_name: str) -> bool:
    return deployment_name.lower() != "local"


def _fmt_addr(addr: str) -> str:
    return f"`{addr}`"


def _fmt_block(n: int) -> str:
    return f"`{n}`"


def _fmt_proxy_meta(addr: str) -> str:
    if not addr:
        return "—"
    return f"`{addr}`"


def _render_core_contracts_table(contracts: dict, optional: dict) -> str:
    # Canonical ordering for v1.0.0 docs.
    core_order = [
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
        "GameRouter",
        "ClaimAllHelper",
    ]

    lines: list[str] = []
    lines.append("| Component | Status | Address | Implementation | Proxy admin | Proxy admin owner | Start block |")
    lines.append("|---|---|---:|---:|---:|---:|---:|")

    # Build lookup of all entries.
    def _get_entry(name: str) -> tuple[str, int]:
        if name in contracts:
            entry = contracts[name] or {}
            return str(entry.get("address", "")), int(entry.get("startBlock", 0))
        if name in optional:
            entry = optional[name] or {}
            return str(entry.get("address", "")), int(entry.get("startBlock", 0))
        return "", 0

    # Build status.
    def _status(name: str) -> str:
        if name in optional:
            deployed = bool((optional.get(name) or {}).get("deployed"))
            return "OPTIONAL" if deployed else "NOT DEPLOYED IN V1.0.0 (MUST remain unset)"
        return "REQUIRED"

    # Track unknown keys so generator doesn't silently drop new addresses.
    known_contracts = set(core_order) | {
        "LaunchController",
        "GenesisLPVault24M",
        "MaintenanceHub",
        "DelegationHub",
        "TimelockController",
        "AgentLens",
        "FurnaceQuoter",
        "MineCoreQuoter",
    }

    unknown_contracts = set(contracts.keys()) - known_contracts
    unknown_optional = set(optional.keys()) - set(core_order)

    if unknown_contracts:
        raise ValueError(
            "deployments manifest contains contracts not covered by docs generator: "
            + ", ".join(sorted(unknown_contracts))
        )
    if unknown_optional:
        raise ValueError(
            "deployments manifest contains optional contracts not covered by docs generator: "
            + ", ".join(sorted(unknown_optional))
        )

    for name in core_order:
        addr, start_block = _get_entry(name)
        if not addr:
            # Render a visible zero-address row when the contract key is absent.
            addr = "0x0000000000000000000000000000000000000000"
        if name in contracts:
            entry = contracts.get(name) or {}
        else:
            entry = optional.get(name) or {}
        impl = _fmt_proxy_meta(str(entry.get("implementation", "")) if name in RUNTIME_PROXY_CONTRACTS else "")
        proxy_admin = _fmt_proxy_meta(str(entry.get("proxyAdmin", "")) if name in RUNTIME_PROXY_CONTRACTS else "")
        proxy_admin_owner = _fmt_proxy_meta(
            str(entry.get("proxyAdminOwner", "")) if name in RUNTIME_PROXY_CONTRACTS else ""
        )
        lines.append(
            f"| {name} | {_status(name)} | {_fmt_addr(addr)} | {impl} | {proxy_admin} | {proxy_admin_owner} | {_fmt_block(start_block)} |"
        )

    return "\n".join(lines)


def _render_governance_table(contracts: dict) -> str:
    entry = contracts.get("TimelockController") or {}
    addr = str(entry.get("address", "0x0000000000000000000000000000000000000000"))
    start_block = int(entry.get("startBlock", 0))
    delay = entry.get("minDelaySeconds")
    bootstrap_admin = str(entry.get("bootstrapAdmin", "") or "").strip()
    proposer = str(entry.get("proposer", "") or "").strip()
    executor = str(entry.get("executor", "") or "").strip()
    note_parts = ["governance timelock"]
    if delay is not None:
        note_parts = [f"governance timelock (`minDelaySeconds = {delay}`)"]
    if bootstrap_admin and bootstrap_admin.lower() != ZERO_ADDRESS:
        note_parts.append(f"bootstrap admin = `{bootstrap_admin}`")
    if proposer and proposer.lower() != ZERO_ADDRESS:
        note_parts.append(f"proposer = `{proposer}`")
    if executor and executor.lower() != ZERO_ADDRESS:
        note_parts.append(f"executor = `{executor}`")
    note = "; ".join(note_parts)

    return "\n".join(
        [
            "| Component | Address | Start block | Notes |",
            "|---|---:|---:|---|",
            f"| TimelockController | {_fmt_addr(addr)} | {_fmt_block(start_block)} | {note} |",
        ]
    )


def _render_genesis_table(contracts: dict) -> str:
    order = ["LaunchController", "GenesisLPVault24M"]
    lines: list[str] = []
    lines.append("| Component | Address | Start block | Notes |")
    lines.append("|---|---:|---:|---|")

    notes = {
        "LaunchController": "one-shot genesis controller (`finalizeGenesis`)",
        "GenesisLPVault24M": "locks genesis LP 24 months",
    }

    for name in order:
        entry = contracts.get(name) or {}
        addr = str(entry.get("address", "0x0000000000000000000000000000000000000000"))
        start_block = int(entry.get("startBlock", 0))
        note = notes.get(name, "")
        if name == "GenesisLPVault24M":
            lp_withdraw_recipient = str(entry.get("lpWithdrawRecipient", "") or "").strip()
            if lp_withdraw_recipient and lp_withdraw_recipient.lower() != ZERO_ADDRESS:
                note = f"{note}; `lpWithdrawRecipient = {lp_withdraw_recipient}`"
        lines.append(
            f"| {name} | {_fmt_addr(addr)} | {_fmt_block(start_block)} | {note} |"
        )

    return "\n".join(lines)


def _render_maintenance_table(contracts: dict) -> str:
    entry = contracts.get("MaintenanceHub") or {}
    addr = str(entry.get("address", "0x0000000000000000000000000000000000000000"))
    start_block = int(entry.get("startBlock", 0))
    rescue_recipient = str(entry.get("rescueRecipient", "") or "").strip()
    note = f"`rescueRecipient = {rescue_recipient}`" if rescue_recipient and rescue_recipient.lower() != ZERO_ADDRESS else ""

    return "\n".join(
        [
            "| Component | Address | Start block | Notes |",
            "|---|---:|---:|---|",
            f"| MaintenanceHub | {_fmt_addr(addr)} | {_fmt_block(start_block)} | {note} |",
        ]
    )


def _render_delegation_table(contracts: dict) -> str:
    entry = contracts.get("DelegationHub") or {}
    addr = str(entry.get("address", "0x0000000000000000000000000000000000000000"))
    start_block = int(entry.get("startBlock", 0))

    return "\n".join(
        [
            "| Component | Address | Start block |",
            "|---|---:|---:|",
            f"| DelegationHub | {_fmt_addr(addr)} | {_fmt_block(start_block)} |",
        ]
    )


def _render_auxiliary_table(contracts: dict) -> str:
    order = ["AgentLens", "FurnaceQuoter", "MineCoreQuoter"]
    lines: list[str] = []
    lines.append("| Component | Address | Start block |")
    lines.append("|---|---:|---:|")

    for name in order:
        entry = contracts.get(name) or {}
        if not entry:
            continue
        addr = str(entry.get("address", "0x0000000000000000000000000000000000000000"))
        start_block = int(entry.get("startBlock", 0))
        lines.append(f"| {name} | {_fmt_addr(addr)} | {_fmt_block(start_block)} |")

    if len(lines) == 2:
        return ""
    return "\n".join(lines)

def _render_aerodrome_table(aero: dict) -> str:
    wrapped = aero.get("wrappedNative") or {}
    router = aero.get("router") or {}
    pool = aero.get("claimWethPool") or {}
    lp = aero.get("lpToken") or {}

    pool_type = str(pool.get("poolType", "")).strip()
    pool_notes = pool_type if pool_type else ""

    wrapped_symbol = wrapped.get("symbol") or "WETH"

    return "\n".join(
        [
            "| Component | Address | Start block | Notes |",
            "|---|---:|---:|---|",
            f"| Wrapped native ({wrapped_symbol}) | {_fmt_addr(str(wrapped.get('address', '0x0000000000000000000000000000000000000000')))} | {_fmt_block(int(wrapped.get('startBlock', 0)))} | token used for the ETH swap path |",
            f"| Aerodrome router | {_fmt_addr(str(router.get('address', '0x0000000000000000000000000000000000000000')))} | {_fmt_block(int(router.get('startBlock', 0)))} | used internally by DexAdapter (swap routing) |",
            f"| CLAIM/WETH pool | {_fmt_addr(str(pool.get('address', '0x0000000000000000000000000000000000000000')))} | {_fmt_block(int(pool.get('startBlock', 0)))} | {pool_notes} |",
            f"| LP token | {_fmt_addr(str(lp.get('address', '0x0000000000000000000000000000000000000000')))} | {_fmt_block(int(lp.get('startBlock', 0)))} | same as pool in many cases |",
        ]
    )


def _render_chainlink_table(chainlink: dict) -> str:
    feed = (chainlink.get("ethUsdFeed") or {}).get(
        "address", "0x0000000000000000000000000000000000000000"
    )
    return "\n".join(
        [
            "| Feed | Address | Notes |",
            "|---|---:|---|",
            f"| ETH/USD price feed | {_fmt_addr(str(feed))} | used for USD-denominated displays (UI/indexer only) |",
        ]
    )


def _render_protocol_params_table(protocol_params: dict) -> str:
    furnace = protocol_params.get("furnace") or {}

    # Canonical ordering for Furnace params.
    rows = [
        ("maxUserBonusBps", "basis points (100%)"),
        ("lpTopupRateMinBps", "basis points (7.5%)"),
        ("lpTopupRateMaxBps", "basis points (15%)"),
        ("lockTargetClaim", "compatibility field; bonus uses lock% targets"),
        ("lockPctTargetBps", "basis points (7.0%)"),
        ("lockPctMinForBoostCapBps", "basis points (5%)"),
        ("lockPctFullBoostCapBps", "basis points (20%)"),
        ("reserveTargetFinalClaim", "CLAIM (whole tokens) target reserve at end of run"),
        ("reserveMultMaxBpsLowLock", "basis points (1.5x)"),
        ("reserveMultMaxBps", "basis points (2.0x)"),
        ("swingTimeSeconds", "seconds (60 days)"),
        ("bonusDecayWindowSeconds", "seconds (3 hours)"),
        ("sellSpreadFloor7dBps", "basis points (1.2% at 7d)"),
    ]

    lines: list[str] = []
    lines.append("| Param | Value | Units / notes |")
    lines.append("|---|---:|---|")

    for key, notes in rows:
        val = furnace.get(key)
        if val is None:
            val = ""
        lines.append(f"| `{key}` | `{val}` | {notes} |")

    return "\n".join(lines)


def render_docs_manifest(data: dict, deployment_name: str) -> str:
    version = str(data.get("version", "")).strip()
    if not version:
        raise ValueError(f"deployments/{deployment_name}.json: missing `version`")

    chain_id = int(data.get("chainId", 0))

    contracts = data.get("contracts") or {}
    optional = data.get("optional") or {}
    aerodrome = data.get("aerodrome") or {}
    chainlink = data.get("chainlink") or {}
    protocol_params = data.get("protocolParams") or {}

    network = _network_label(deployment_name, chain_id)

    # The docs file has a slightly different subtitle for testnets.
    if _is_template_network(deployment_name):
        network_subtitle = f"{network} (staging/testnet)"
    else:
        network_subtitle = network

    title = f"# ClaimRush {version} deployment manifest ({network})"

    lines: list[str] = []

    lines.append(title)
    lines.append("")
    lines.append("<!--")
    lines.append("AUTO-GENERATED FILE. DO NOT EDIT DIRECTLY.")
    lines.append(f"Source of truth: deployments/{deployment_name}.json")
    lines.append("Run: python3 scripts/sync_docs_deployments.py --write")
    lines.append("-->")
    lines.append("")

    lines.append(
        f"This file is the **docs-only canonical deployment manifest** for ClaimRush {version} on {network_subtitle}."
    )
    lines.append("")

    lines.append("Identity:")
    lines.append(f"- Deployment name (manifest selector): `{deployment_name}`")
    lines.append(f"- Chain ID: `{chain_id}`")
    lines.append(f"- {_explorer_line(deployment_name, chain_id)}")
    lines.append("")

    lines.append("Constraints (required):")
    lines.append(
        f"- The runtime source of truth is `deployments/{deployment_name}.json` (repo root), which the app loads at runtime."
    )
    lines.append("- This doc MUST match the repo-root deployment manifests for all shared fields:")
    lines.append(f"  - `deployments/{deployment_name}.json`")
    lines.append(f"  - `deployments/{deployment_name}.md`")
    lines.append("")

    if _is_template_network(deployment_name):
        lines.append(
            "This manifest is a template and is NOT production-ready until all REQUIRED addresses and REQUIRED start blocks are filled with non-zero values."
        )
        lines.append("")

    lines.append("Manifest validity requires:")
    lines.append("- Every REQUIRED address is non-zero.")
    if _requires_nonzero_start_blocks(deployment_name):
        lines.append("- Every REQUIRED start block is non-zero.")
    else:
        lines.append("- For local manifests, startBlock MAY be `0` on ephemeral chains, but generated mirrors should be refreshed from the latest deployment output.")
    lines.append("- Every component not deployed in v1.0.0 remains unset (`0x00…` / `0`).")
    lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## Core contracts")
    lines.append("")
    lines.append(_render_core_contracts_table(contracts, optional))
    lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## Governance infrastructure")
    lines.append("")
    lines.append(_render_governance_table(contracts))
    lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## Aerodrome")
    lines.append("")
    lines.append(_render_aerodrome_table(aerodrome))
    lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## Chainlink")
    lines.append("")
    lines.append(_render_chainlink_table(chainlink))
    lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## Genesis infrastructure (required)")
    lines.append("")
    lines.append(_render_genesis_table(contracts))
    lines.append("")

    # Keep wiring/config notes verbatim.
    lines.append("Wiring / config:")
    lines.append(
        "- `GenesisLPVault24M.lpWithdrawRecipient` MUST match the manifest-declared LP withdrawal recipient."
    )
    lines.append(
        "- LP lock starts at genesis (`LaunchController.finalizeGenesis()`). `GenesisLPVault24M.extendLock(newUnlockTime)` exists but is not part of the v1.0.0 manifest requirements."
    )
    lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## MaintenanceHub (required)")
    lines.append("")
    lines.append("This manifest MUST include `MaintenanceHub` under `contracts`.")
    lines.append("")
    lines.append(_render_maintenance_table(contracts))
    lines.append("")
    lines.append("Wiring / config:")
    lines.append("- `MaintenanceHub.rescueRecipient` MUST match the manifest-declared rescue recipient.")
    lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## DelegationHub (required)")
    lines.append("")
    lines.append("This manifest MUST include `DelegationHub` under `contracts`.")
    lines.append("")
    lines.append(_render_delegation_table(contracts))
    lines.append("")

    auxiliary_table = _render_auxiliary_table(contracts)
    if auxiliary_table:
        lines.append("---")
        lines.append("")
        lines.append("## Auxiliary read helpers")
        lines.append("")
        lines.append(auxiliary_table)
        lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## Protocol params (Furnace)")
    lines.append("")
    lines.append(_render_protocol_params_table(protocol_params))
    lines.append("")

    lines.append("---")
    lines.append("")

    lines.append("## Analytics config")
    lines.append("")
    lines.append("- No address exclusions are applied in v1.0.0 leaderboards.")

    # Ensure a trailing newline for clean diffs.
    return "\n".join(lines).rstrip() + "\n"


def render_docs_index(manifests: list[ManifestInfo]) -> str:
    # Group by version while keeping stable ordering.
    by_version: dict[str, list[ManifestInfo]] = {}
    for m in manifests:
        by_version.setdefault(m.version, []).append(m)

    # Deterministic ordering.
    versions = sorted(by_version.keys())
    for v in versions:
        by_version[v] = sorted(by_version[v], key=lambda x: (x.classification_label, x.deployment_name))

    lines: list[str] = []
    lines.append("# docs/deployments/README.md")
    lines.append("")
    lines.append("This folder contains the **docs-only canonical deployment manifests** for ClaimRush.")
    lines.append("")
    lines.append("This folder is **generated** from the repo-root deployment manifests:")
    lines.append("- `deployments/*.json` (machine-readable source of truth)")
    lines.append("")
    lines.append("Why this exists:")
    lines.append("- Many specs reference the deployment manifest as the source of truth for **contract addresses** and **start blocks**.")
    lines.append("- When viewing documentation in isolation (only `docs/`), the repo-root `deployments/` folder may not be available.")
    lines.append("- A canonical \"here are the addresses\" page is a core anti-phishing and user verification rail.")
    lines.append("")
    lines.append("Hard rule:")
    lines.append("- The network docs in this folder MUST match `deployments/<deploymentName>.json` for all shared fields:")
    lines.append("  - `chainId`")
    lines.append("  - contract addresses")
    lines.append("  - runtime proxy metadata for `MineCore`, `Furnace`, `MarketRouter`, and `ShareholderRoyalties` (`address`, `implementation`, `proxyAdmin`)")
    lines.append("  - `startBlock` values")
    lines.append("  - third-party pins (Aerodrome, Chainlink)")
    lines.append("  - protocol params consumed by offchain components")
    lines.append("")

    for v in versions:
        lines.append(f"## Canonical manifests ({v})")
        lines.append("")

        items = by_version[v]
        prod = [m for m in items if m.classification_label == "Production"]
        stage = [m for m in items if m.classification_label == "Staging/testnet"]
        other = [m for m in items if m.classification_label not in {"Production", "Staging/testnet"}]

        def _emit_group(group_label: str, group_items: list[ManifestInfo]) -> None:
            for m in group_items:
                lines.append(f"- **{group_label} ({m.network_label})**")
                lines.append(f"  - Deployment name: `{m.deployment_name}`")
                lines.append(f"  - Chain ID: `{m.chain_id}`")
                lines.append(f"  - Canonical docs manifest: [{m.doc_filename}](./{m.doc_filename})")
                lines.append("")

        if prod:
            _emit_group("Production", prod)
        if stage:
            _emit_group("Staging/testnet", stage)
        if other:
            _emit_group("Network", other)

    lines.append("## How to use this for verification (anti-phishing)")
    lines.append("")
    lines.append("- Verify you are on the intended chain (chainId).")
    lines.append("- Compare the in-app **About / Security** contract list to the relevant page in this folder.")
    lines.append("- For the runtime quartet, treat `.contracts.<Name>.address` as the live proxy address users and integrations should call. `implementation` and `proxyAdmin` are governance metadata.")
    lines.append("- If any address is `0x0000000000000000000000000000000000000000`, treat it as **not set**.")

    return "\n".join(lines).rstrip() + "\n"


def _unified_diff(a: str, b: str, fromfile: str, tofile: str) -> str:
    return "".join(
        difflib.unified_diff(
            a.splitlines(keepends=True),
            b.splitlines(keepends=True),
            fromfile=fromfile,
            tofile=tofile,
        )
    )

def _normalize_newlines(s: str) -> str:
    # Treat CRLF and LF as equivalent for drift checks.
    # The generator emits LF; some environments may checkout/write CRLF.
    return s.replace("\r\n", "\n")


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--write", action="store_true", help="Write/sync generated docs files (default)")
    parser.add_argument("--check", action="store_true", help="CI mode; fail if generated output differs")

    args = parser.parse_args()

    mode = "write"
    if args.check:
        mode = "check"
    if args.write:
        mode = "write"

    if not SRC_DIR.exists():
        print(f"[sync-docs-deployments] Missing deployments dir: {SRC_DIR}", file=sys.stderr)
        return 1

    src_files = sorted(p for p in SRC_DIR.glob("*.json") if p.is_file())
    if not src_files:
        print(f"[sync-docs-deployments] No deployment manifests found in {SRC_DIR}", file=sys.stderr)
        return 1

    expected: dict[Path, str] = {}
    infos: list[ManifestInfo] = []

    for src in src_files:
        deployment_name = src.stem
        data = _load_json(src)

        version = str(data.get("version", "")).strip()
        if not version:
            print(f"[sync-docs-deployments] {src}: missing `version`", file=sys.stderr)
            return 1

        chain_id = int(data.get("chainId", 0))
        if chain_id <= 0:
            print(f"[sync-docs-deployments] {src}: missing/invalid `chainId`", file=sys.stderr)
            return 1

        doc_filename = f"{version}-{deployment_name}.md"
        out_path = DOCS_DIR / doc_filename

        try:
            md = render_docs_manifest(data, deployment_name)
        except ValueError as e:
            print(f"[sync-docs-deployments] ERROR: {e}", file=sys.stderr)
            return 1

        expected[out_path] = md

        infos.append(
            ManifestInfo(
                deployment_name=deployment_name,
                version=version,
                chain_id=chain_id,
                doc_filename=doc_filename,
                network_label=_network_label(deployment_name, chain_id),
                classification_label=_classification_label(deployment_name),
            )
        )

    # README index
    expected[DOCS_DIR / "README.md"] = render_docs_index(infos)

    if mode == "write":
        DOCS_DIR.mkdir(parents=True, exist_ok=True)
        for path, content in expected.items():
            _write_text_lf(path, content)

        rels = [str(p.relative_to(ROOT)) for p in sorted(expected.keys())]
        print(f"[sync-docs-deployments] Wrote {len(rels)} file(s):")
        for r in rels:
            print(f"  - {r}")
        return 0

    # mode == check
    exit_code = 0

    # Fail on missing or drifted generated outputs.
    for path, exp in sorted(expected.items(), key=lambda kv: str(kv[0])):
        rel = path.relative_to(ROOT)
        if not path.exists():
            print(f"[sync-docs-deployments] Missing generated file: {rel}", file=sys.stderr)
            exit_code = 1
            continue

        got = path.read_text(encoding="utf-8", errors="replace")
        got_norm = _normalize_newlines(got)
        exp_norm = _normalize_newlines(exp)
        if got_norm != exp_norm:
            print(f"[sync-docs-deployments] Drift detected: {rel}", file=sys.stderr)
            diff = _unified_diff(got_norm, exp_norm, fromfile=str(rel), tofile=str(rel) + " (expected)")
            sys.stderr.write(diff)
            if not diff.endswith("\n"):
                sys.stderr.write("\n")
            exit_code = 1

    # Fail on extra manifests not backed by deployments/*.json.
    if DOCS_DIR.exists():
        expected_paths = set(expected.keys())
        extra: list[Path] = []

        for p in DOCS_DIR.glob("*.md"):
            if p.name == "README.md":
                continue
            if p not in expected_paths:
                extra.append(p)

        if extra:
            exit_code = 1
            for p in sorted(extra):
                rel = p.relative_to(ROOT)
                print(
                    f"[sync-docs-deployments] Unexpected docs manifest not generated from deployments/*.json: {rel}",
                    file=sys.stderr,
                )

    if exit_code != 0:
        print("", file=sys.stderr)
        print(
            "Fix: run 'python3 scripts/sync_docs_deployments.py --write' and commit the updated docs/deployments/*.md",
            file=sys.stderr,
        )

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
