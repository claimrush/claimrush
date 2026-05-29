#!/usr/bin/env python3
"""Verify an on-chain deployment matches a deployments/*.json manifest.

This is a *post-deploy* preflight tool.

What it checks (best-effort)
- chainId matches the manifest
- code exists at each contract address in `contracts`
- timelock governance metadata matches the manifest:
  - TimelockController exists and `getMinDelay()` matches `minDelaySeconds`
  - manifest `proposer` / `executor` addresses (when pinned) have the expected timelock roles
  - manifest `proposer` also retains `CANCELLER_ROLE` (OpenZeppelin grants cancellers from the proposer set)
  - TimelockController retains self-admin and the manifest `bootstrapAdmin` no longer has `DEFAULT_ADMIN_ROLE`
  - runtime quartet EIP-1967 admin slots match manifest `proxyAdmin`
  - runtime quartet EIP-1967 implementation slots match manifest `implementation`
  - runtime quartet `ProxyAdmin.owner()` matches manifest `proxyAdminOwner`
- `configFrozen()` state is reported for all 5 core contracts
  (ClaimToken, Furnace, MineCore, VeClaimNFT, ShareholderRoyalties);
  enforce with --require-frozen
- composite finality check via --require-finalized: asserts all of
  configFrozen()==true on 5 contracts, ProxyAdmin.owner()==address(0) on
  4 proxies, ClaimToken.owner()==address(0), bootstrap admin renounced
- contract-level owner() can be checked via --expected-owner <address>;
  asserts owner() on the 9 transferable-ownership contracts (VeClaimNFT,
  MineCore, Furnace, ShareholderRoyalties, MarketRouter,
  FurnaceEntryTokenRegistry, MineCoreEntryTokenRegistry, DexAdapter,
  LpStakingVault7D)
- core wiring matches the manifest:
  - ClaimToken.mineCore == MineCore
  - MineCore.furnace == Furnace
  - MineCore.claim == ClaimToken (immutable)
  - MineCore.ve == VeClaimNFT (immutable)
  - MineCore.royalties == ShareholderRoyalties (immutable)
  - MineCore.entryTokenRegistry == MineCoreEntryTokenRegistry
  - Furnace.entryTokenRegistry == FurnaceEntryTokenRegistry
  - Furnace.shareholderRoyalties == ShareholderRoyalties
  - Furnace.claim == ClaimToken (immutable)
  - Furnace.ve == VeClaimNFT (immutable)
  - Furnace.mineCore == MineCore
  - Furnace.mineMarket == MarketRouter
  - VeClaimNFT.claimToken == ClaimToken (immutable)
  - VeClaimNFT.furnace == Furnace
  - VeClaimNFT.mineMarket == MarketRouter
  - ShareholderRoyalties.ve == VeClaimNFT (immutable)
  - ShareholderRoyalties.mineCore == MineCore
  - ShareholderRoyalties.mineMarket == MarketRouter
  - MarketRouter.claim == ClaimToken (immutable)
  - MarketRouter.ve == VeClaimNFT (immutable)
  - MarketRouter.royalties == ShareholderRoyalties (immutable)
  - MineCore.claimAllHelper == ClaimAllHelper (required)
  - ShareholderRoyalties.claimAllHelper == ClaimAllHelper (required)
  - ClaimAllHelper.mineCore == MineCore (immutable)
  - ClaimAllHelper.royalties == ShareholderRoyalties (immutable)
- registry invariants:
  - FurnaceEntryTokenRegistry != MineCoreEntryTokenRegistry
  - getRouterConfig() matches pinned Aerodrome + CLAIM addresses
  - FurnaceEntryTokenRegistry WETH/CLAIM hop matches the manifest after genesis; pre-genesis it may be deferred until the canonical pool exists onchain
  - (if used) DexAdapter.aerodromeRouter matches manifest aerodrome.router
- FurnaceQuoter wiring:
  - FurnaceQuoter.furnace == Furnace
  - FurnaceQuoter.claim == ClaimToken
  - FurnaceQuoter.ve == VeClaimNFT
  - Furnace.furnaceQuoter == FurnaceQuoter

Extended "full deployment" coverage (v1.0.0)
- Genesis LP vault wiring
  - GenesisLPVault24M.pool matches manifest aerodrome.claimWethPool.address (or aerodrome.lpToken.address)
  - GenesisLPVault24M.pool == LpStakingVault7D.lpToken (cross-check)
  - GenesisLPVault24M.lpWithdrawRecipient matches the manifest on canonical deployments; local fallback only requires non-zero
- Furnace LP rewards pointer
  - Furnace.lpRewardsVault == LpStakingVault7D
- LaunchController wiring
  - LaunchController.{claim,mineCore,genesisLpVault,aerodromeRouter} match manifest
  - LaunchController.{weth,factory} match the pinned Aerodrome roots from the manifest
  - LaunchController.expectedPool matches manifest aerodrome.claimWethPool.address (if provided)
  - once genesis is finalized, manifest aerodrome.claimWethPool / aerodrome.lpToken addresses and startBlocks must be backfilled
- MineCoreQuoter wiring
  - MineCoreQuoter.mineCore == MineCore
- AgentLens wiring
  - AgentLens constructor immutables match the manifest exactly; optional fields omitted or zeroed in the manifest must also read back as 0x0 on the lens
- MaintenanceHub wiring
  - MaintenanceHub.rescueRecipient matches the manifest exactly
  - Best-effort scan of runtime bytecode for the remaining expected immutable addresses

The script uses `cast` for onchain reads.

Usage:
  python3 scripts/verify_deployment.py --network local --rpc-url http://127.0.0.1:8545
  python3 scripts/verify_deployment.py --manifest deployments/base_mainnet.json --rpc-url $RPC
  python3 scripts/verify_deployment.py --network base_mainnet --rpc-url $RPC --expected-guardian $GUARDIAN
  python3 scripts/verify_deployment.py --network base_mainnet --rpc-url $RPC --require-frozen
  python3 scripts/verify_deployment.py --network base_mainnet --rpc-url $RPC --require-finalized
  python3 scripts/verify_deployment.py --network base_mainnet --rpc-url $RPC --expected-owner 0xTIMELOCK
  python3 scripts/verify_deployment.py --network base_mainnet --rpc-url $RPC --expected-secondary-guardian $GUARDIAN_SAFE

Exit code:
  0 = all checks passed
  1 = one or more checks failed
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


ZERO_ADDR = "0x0000000000000000000000000000000000000000"
ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000"
IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
OPTIONAL_ZERO_CONTRACTS = {
    "AgentLens",
}
CAST_TIMEOUT_SEC = 30
MAX_CAST_STDOUT_CHARS = 2_000_000
MAX_CAST_STDERR_CHARS = 500_000
MAX_MANIFEST_JSON_BYTES = 2 * 1024 * 1024
RUN_RETRY_ATTEMPTS = 3
RUN_RETRY_BACKOFF_SEC = 1.5


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    detail: str


def _norm_addr(addr: str) -> str:
    a = (addr or "").strip()
    return a.lower()


def _is_zero(addr: str) -> bool:
    return _norm_addr(addr) == ZERO_ADDR


def _addr_hex40(addr: str) -> str:
    """Normalize address to 40 hex chars (no 0x), zero-padded."""
    a = _norm_addr(addr)
    if a.startswith("0x"):
        a = a[2:]
    return a.zfill(40)


def _run(
    cmd: Sequence[str],
    *,
    timeout_sec: int = CAST_TIMEOUT_SEC,
    max_stdout_chars: int = MAX_CAST_STDOUT_CHARS,
    max_stderr_chars: int = MAX_CAST_STDERR_CHARS,
) -> Tuple[int, str, str]:
    """Run a command and return (rc, stdout, stderr)."""
    last_rc = 1
    last_stdout = ""
    last_stderr = ""
    joined = " ".join(cmd)

    for attempt in range(1, RUN_RETRY_ATTEMPTS + 1):
        try:
            p = subprocess.run(
                list(cmd),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                timeout=timeout_sec,
            )
        except subprocess.TimeoutExpired:
            last_rc = 1
            last_stdout = ""
            last_stderr = f"command timed out after {timeout_sec}s: {joined}"
        else:
            stdout = (p.stdout or "").strip()
            stderr = (p.stderr or "").strip()
            if len(stdout) > max_stdout_chars:
                return 1, "", f"stdout too large ({len(stdout)} chars > {max_stdout_chars})"
            if len(stderr) > max_stderr_chars:
                return 1, "", f"stderr too large ({len(stderr)} chars > {max_stderr_chars})"

            last_rc = p.returncode
            last_stdout = stdout
            last_stderr = stderr

            if p.returncode == 0:
                return 0, stdout, stderr

            lowered = f"{stdout}\n{stderr}".lower()
            if "429" not in lowered and "over rate limit" not in lowered:
                return p.returncode, stdout, stderr

        if attempt < RUN_RETRY_ATTEMPTS:
            time.sleep(RUN_RETRY_BACKOFF_SEC * attempt)

    return last_rc, last_stdout, last_stderr


def _split_cast_output(raw: str) -> List[str]:
    """Split `cast call` output into a list of return values.

    `cast` output differs slightly across versions:
    - single return: 0x... / true / 123
    - multiple returns: each value on its own line
    - sometimes: a single tuple line: (0x..., 0x...)
    """

    s = (raw or "").strip()
    if not s:
        return []

    if s.startswith("(") and s.endswith(")"):
        inner = s[1:-1].strip()
        if not inner:
            return []
        return [p.strip() for p in inner.split(",") if p.strip()]

    # Common case: one value per line.
    out: List[str] = []
    for line in s.splitlines():
        line = line.strip()
        if line:
            out.append(line)
    return out


def _parse_cast_uint(raw: str) -> int:
    """Parse a uint emitted by `cast`, tolerating human-friendly annotations.

    Some `cast` versions print values like `172800 [1.728e5]` for large
    decimals. The first token remains the canonical integer literal.
    """

    s = (raw or "").strip()
    if not s:
        raise ValueError("empty cast integer output")
    token = s.split()[0]
    return int(token, 0)


class Cast:
    def __init__(self, rpc_url: str):
        self.rpc_url = rpc_url

    def call(self, addr: str, sig: str, args: Optional[List[str]] = None) -> Tuple[bool, List[str], str]:
        """Return (ok, outputs, err)."""
        argv = ["cast", "call", addr, sig]
        if args:
            argv.extend(args)
        argv.extend(["--rpc-url", self.rpc_url])
        rc, out, err = _run(argv)
        if rc != 0:
            # `cast` tends to put the useful revert/decode info in stderr.
            return False, [], (err or out or "cast call failed")
        return True, _split_cast_output(out), ""

    def code(self, addr: str) -> Tuple[bool, str, str]:
        rc, out, err = _run(["cast", "code", addr, "--rpc-url", self.rpc_url])
        if rc != 0:
            return False, "", (err or out or "cast code failed")
        return True, out.strip(), ""

    def storage(self, addr: str, slot: str) -> Tuple[bool, str, str]:
        rc, out, err = _run(["cast", "storage", addr, slot, "--rpc-url", self.rpc_url])
        if rc != 0:
            return False, "", (err or out or "cast storage failed")
        return True, out.strip(), ""

    def chain_id(self) -> Tuple[bool, Optional[int], str]:
        rc, out, err = _run(["cast", "chain-id", "--rpc-url", self.rpc_url])
        if rc != 0:
            return False, None, (err or out or "cast chain-id failed")
        try:
            return True, int(out.strip()), ""
        except Exception as e:  # noqa: BLE001
            return False, None, f"failed to parse chain-id '{out}': {e}"


def _load_manifest(path: Path, *, max_bytes: int = MAX_MANIFEST_JSON_BYTES) -> Dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"ERROR: manifest path is not a regular file: {path}")
    try:
        size = path.stat().st_size
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f"ERROR: failed to stat manifest: {path}: {e}")
    if size > max_bytes:
        raise SystemExit(f"ERROR: manifest too large: {path} ({size} bytes > {max_bytes})")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f"ERROR: failed to read manifest JSON: {path}: {e}")


def _get_addr(manifest: Dict[str, Any], dotted: str) -> str:
    """Get a nested 'a.b.c' value as a string (empty if missing)."""
    cur: Any = manifest
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return ""
        cur = cur[part]
    if isinstance(cur, str):
        return cur
    return ""


def _get_int(manifest: Dict[str, Any], dotted: str) -> Optional[int]:
    """Get a nested 'a.b.c' value as an int (None if missing or unparsable)."""
    cur: Any = manifest
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    if isinstance(cur, int):
        return cur
    if isinstance(cur, str):
        try:
            return int(cur, 0)
        except Exception:  # noqa: BLE001
            return None
    return None


def _contract_addr(manifest: Dict[str, Any], name: str) -> str:
    contracts = manifest.get("contracts")
    if not isinstance(contracts, dict):
        return ""
    item = contracts.get(name)
    if not isinstance(item, dict):
        return ""
    addr = item.get("address")
    return addr if isinstance(addr, str) else ""


def _check_eq_addr(label: str, got: str, want: str) -> Check:
    g = _norm_addr(got)
    w = _norm_addr(want)
    ok = bool(g) and bool(w) and g == w
    if ok:
        return Check(label, True, f"OK ({got})")
    return Check(label, False, f"expected {want}, got {got}")


def _check_true(label: str, got: str) -> Check:
    ok = got.strip().lower() == "true"
    if ok:
        return Check(label, True, "OK (true)")
    return Check(label, False, f"expected true, got {got}")


def _check_false(label: str, got: str) -> Check:
    ok = got.strip().lower() == "false"
    if ok:
        return Check(label, True, "OK (false)")
    return Check(label, False, f"expected false, got {got}")


def _check_nonzero(label: str, addr: str) -> Check:
    if _is_zero(addr) or not addr:
        return Check(label, False, f"missing/zero address: {addr or '(missing)'}")
    return Check(label, True, f"OK ({addr})")


def _prefer_nonzero_addr(*addrs: str) -> str:
    for addr in addrs:
        if addr and not _is_zero(addr):
            return addr
    return ""


def _should_defer_furnace_weth_claim_hop(
    launch_genesis_finalized: Optional[bool],
    expected_pool_live: bool,
) -> bool:
    return launch_genesis_finalized is False and not expected_pool_live


def _furnace_weth_claim_pool_status(
    name: str,
    actual_pool: str,
    expected_pool: str,
    launch_genesis_finalized: Optional[bool],
    expected_pool_live: bool,
) -> Tuple[Check, bool]:
    label = f"{name}.wethClaimPool"
    if _is_zero(actual_pool):
        if _should_defer_furnace_weth_claim_hop(launch_genesis_finalized, expected_pool_live):
            return (
                Check(
                    label,
                    True,
                    "deferred pre-genesis (rerun Wire.s.sol after LaunchController.finalizeGenesis() creates the canonical pool)",
                ),
                True,
            )
        return Check(label, False, "not set (pool=0x0)"), False

    if expected_pool and not _is_zero(expected_pool):
        return _check_eq_addr(label, actual_pool, expected_pool), False

    return Check(label, True, f"set to {actual_pool} (manifest and LaunchController missing claimWethPool)"), True


def _slot_addr(raw: str) -> str:
    value = (raw or "").strip().lower()
    if not value:
        return ""
    if value.startswith("0x"):
        value = value[2:]
    value = value.zfill(64)
    return f"0x{value[-40:]}"


def _fmt(checks: List[Check]) -> str:
    lines: List[str] = []
    for c in checks:
        status = "PASS" if c.ok else "FAIL"
        lines.append(f"[{status}] {c.name}: {c.detail}")
    return "\n".join(lines)


def _code_contains_any(code_hex: str, needles: Sequence[str]) -> bool:
    hay = (code_hex or "").lower()
    if hay.startswith("0x"):
        hay = hay[2:]
    for n in needles:
        if not n:
            continue
        if n.lower() in hay:
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument(
        "--network",
        choices=["local", "base_sepolia", "base_mainnet"],
        help="Shortcut for deployments/<network>.json",
    )
    ap.add_argument("--manifest", type=str, help="Path to deployments JSON manifest")
    ap.add_argument(
        "--rpc-url",
        type=str,
        default=os.getenv("RPC_URL") or os.getenv("ETH_RPC_URL") or "",
        help="RPC URL (or set RPC_URL / ETH_RPC_URL env var)",
    )
    ap.add_argument(
        "--allow-zero",
        action="store_true",
        help="Allow 0x000.. placeholders in the manifest (warn instead of fail)",
    )
    ap.add_argument(
        "--allow-raw-router",
        action="store_true",
        help="Allow registries to be configured with aerodrome.router instead of contracts.DexAdapter",
    )
    ap.add_argument(
        "--skip-maintenancehub-scan",
        action="store_true",
        help="Skip MaintenanceHub wiring scan (MaintenanceHub has no getters; scan checks runtime bytecode contains expected immutables)",
    )
    ap.add_argument(
        "--expect-maintenancehub-settlement-keeper",
        action="store_true",
        help="Require MarketRouter.isSettlementKeeper(MaintenanceHub)==true when MaintenanceHub is present. Omit by default because Wire.s.sol keeps a permissionless MaintenanceHub off the settlement-keeper allowlist unless operators explicitly opt in.",
    )
    ap.add_argument(
        "--require-frozen",
        action="store_true",
        help="Require configFrozen()==true on all 5 core contracts (ClaimToken, Furnace, MineCore, VeClaimNFT, ShareholderRoyalties). Omit this flag for pre-freeze verification.",
    )
    ap.add_argument(
        "--require-finalized",
        action="store_true",
        help="Composite finality gate: implies --require-frozen and additionally asserts ProxyAdmin.owner()==address(0) for all 4 runtime proxies, ClaimToken.owner()==address(0), and bootstrap admin has no DEFAULT_ADMIN_ROLE. Use after FreezeAndBurn to verify the system is fully finalized.",
    )
    ap.add_argument(
        "--expected-owner",
        type=str,
        default="",
        help="Assert owner() on the 9 transferable-ownership contracts equals this address (e.g. the TimelockController address). Useful post-FinalizeOwnership.",
    )
    ap.add_argument(
        "--expected-guardian",
        type=str,
        default=os.getenv("GUARDIAN") or "",
        help="Expected long-term MineCore.guardian after genesis (defaults to GUARDIAN env when set).",
    )
    ap.add_argument(
        "--expected-secondary-guardian",
        type=str,
        default="",
        help=(
            "Expected guardian on the 3 secondary guardian-bearing contracts "
            "(MarketRouter, FurnaceEntryTokenRegistry, MineCoreEntryTokenRegistry). "
            "Wire.s.sol sets these from GUARDIAN env at deploy time. "
            "If omitted, defaults to --expected-guardian. "
            "Furnace.guardian is spec-locked to MineCore and is checked separately. "
            "Lessons-learned: Sepolia 2026-04-30 Cycle A post-B.12 sweep — see "
            "docs/dev/internal/APR_29_F1_MINECORE_DEAD_CODE_REMOVAL_RUNBOOK.md."
        ),
    )
    args = ap.parse_args()

    # --require-finalized implies --require-frozen
    if args.require_finalized:
        args.require_frozen = True

    if not args.rpc_url:
        raise SystemExit("ERROR: --rpc-url is required (or set RPC_URL / ETH_RPC_URL)")

    if args.network and args.manifest:
        raise SystemExit("ERROR: choose either --network or --manifest (not both)")

    manifest_path: Path
    if args.network:
        manifest_path = Path("deployments") / f"{args.network}.json"
    elif args.manifest:
        manifest_path = Path(args.manifest)
    else:
        raise SystemExit("ERROR: provide --network or --manifest")

    # Local manifests often include canonical contract keys as 0x0 placeholders so
    # downstream tooling can rely on stable JSON shape even when a contract is not
    # deployed on an ephemeral Anvil chain. Treat those placeholders as non-fatal
    # by default for local, while keeping strict behavior for real networks.
    if (args.network == "local" or manifest_path.name == "local.json") and not args.allow_zero:
        args.allow_zero = True

    if not manifest_path.exists():
        raise SystemExit(f"ERROR: manifest not found: {manifest_path}")

    manifest = _load_manifest(manifest_path)
    cast = Cast(args.rpc_url)

    checks: List[Check] = []
    warnings: List[Check] = []

    is_local = args.network == "local" or manifest_path.name == "local.json"

    # ------------------------------------------------------------
    # ChainId
    # ------------------------------------------------------------
    manifest_chain_id = manifest.get("chainId")
    if isinstance(manifest_chain_id, int):
        ok, cid, err = cast.chain_id()
        if not ok or cid is None:
            checks.append(Check("chainId", False, err))
        else:
            if cid == manifest_chain_id:
                checks.append(Check("chainId", True, f"OK ({cid})"))
            else:
                checks.append(Check("chainId", False, f"expected {manifest_chain_id}, got {cid}"))
    else:
        if is_local:
            warnings.append(Check("chainId", True, "manifest missing chainId (skipped, local)"))
        else:
            checks.append(Check("chainId", False, "manifest missing chainId (required for non-local)"))

    # ------------------------------------------------------------
    # Read manifest addresses
    # ------------------------------------------------------------
    addr_claim = _contract_addr(manifest, "ClaimToken")
    addr_ve = _contract_addr(manifest, "VeClaimNFT")
    addr_mine = _contract_addr(manifest, "MineCore")
    addr_roy = _contract_addr(manifest, "ShareholderRoyalties")
    addr_furn = _contract_addr(manifest, "Furnace")
    addr_market = _contract_addr(manifest, "MarketRouter")
    addr_helper = _contract_addr(manifest, "ClaimAllHelper")
    addr_dex = _contract_addr(manifest, "DexAdapter")
    addr_reg_furn = _contract_addr(manifest, "FurnaceEntryTokenRegistry")
    addr_reg_mine = _contract_addr(manifest, "MineCoreEntryTokenRegistry")

    # Full deployment components
    addr_lp_vault = _contract_addr(manifest, "LpStakingVault7D")
    addr_genesis_vault = _contract_addr(manifest, "GenesisLPVault24M")
    addr_maint = _contract_addr(manifest, "MaintenanceHub")
    addr_launch = _contract_addr(manifest, "LaunchController")
    addr_mine_quoter = _contract_addr(manifest, "MineCoreQuoter")
    addr_agent_lens = _contract_addr(manifest, "AgentLens")
    addr_furnace_quoter = _contract_addr(manifest, "FurnaceQuoter")
    addr_timelock = _contract_addr(manifest, "TimelockController")

    # ------------------------------------------------------------
    # Required contract validation (fail closed for non-local)
    # ------------------------------------------------------------
    _required_contracts = {
        "ClaimToken": addr_claim,
        "VeClaimNFT": addr_ve,
        "MineCore": addr_mine,
        "ShareholderRoyalties": addr_roy,
        "Furnace": addr_furn,
        "MarketRouter": addr_market,
        "ClaimAllHelper": addr_helper,
    }
    for name, addr in _required_contracts.items():
        if not addr or _is_zero(addr):
            msg = f"manifest missing or zero: {name} (required for canonical bundle)"
            if is_local:
                warnings.append(Check(f"required:{name}", True, msg))
            else:
                checks.append(Check(f"required:{name}", False, msg))

    # Routing infrastructure: required for non-local (entry token swap routing)
    _required_routing = {
        "FurnaceEntryTokenRegistry": addr_reg_furn,
        "MineCoreEntryTokenRegistry": addr_reg_mine,
    }
    for name, addr in _required_routing.items():
        if not addr or _is_zero(addr):
            msg = f"manifest missing or zero: {name} (required for entry-token routing)"
            if is_local:
                warnings.append(Check(f"required:{name}", True, msg))
            else:
                checks.append(Check(f"required:{name}", False, msg))

    # Full-deployment components: required for non-local canonical deployment
    _required_full_deploy = {
        "LpStakingVault7D": addr_lp_vault,
        "GenesisLPVault24M": addr_genesis_vault,
        "LaunchController": addr_launch,
        "MaintenanceHub": addr_maint,
        "MineCoreQuoter": addr_mine_quoter,
        "AgentLens": addr_agent_lens,
        "FurnaceQuoter": addr_furnace_quoter,
        "TimelockController": addr_timelock,
    }
    for name, addr in _required_full_deploy.items():
        if not addr or _is_zero(addr):
            msg = f"manifest missing or zero: {name} (required for full deployment)"
            if is_local:
                warnings.append(Check(f"required:{name}", True, msg))
            else:
                checks.append(Check(f"required:{name}", False, msg))

    aero_router = _get_addr(manifest, "aerodrome.router.address")
    aero_factory = _get_addr(manifest, "aerodrome.poolFactory.address")
    aero_weth = _get_addr(manifest, "aerodrome.wrappedNative.address")
    aero_claim_weth_pool = _get_addr(manifest, "aerodrome.claimWethPool.address")
    aero_claim_weth_pool_start = _get_int(manifest, "aerodrome.claimWethPool.startBlock")
    aero_lp_token = _get_addr(manifest, "aerodrome.lpToken.address")
    aero_lp_token_start = _get_int(manifest, "aerodrome.lpToken.startBlock")
    manifest_lp_withdraw_recipient = _get_addr(manifest, "contracts.GenesisLPVault24M.lpWithdrawRecipient")
    manifest_rescue_recipient = _get_addr(manifest, "contracts.MaintenanceHub.rescueRecipient")

    # ------------------------------------------------------------
    # Code existence for all contracts in `contracts`
    # ------------------------------------------------------------
    contracts_obj = manifest.get("contracts")
    if not isinstance(contracts_obj, dict):
        raise SystemExit("ERROR: manifest.contracts missing or not an object")

    for name, meta in sorted(contracts_obj.items()):
        if not isinstance(meta, dict):
            checks.append(Check(f"contracts.{name}", False, "invalid manifest entry (not object)"))
            continue
        addr = meta.get("address")
        if not isinstance(addr, str):
            checks.append(Check(f"contracts.{name}", False, "missing address"))
            continue
        addr = addr.strip()
        if _is_zero(addr):
            if name in OPTIONAL_ZERO_CONTRACTS:
                warnings.append(Check(f"code@{name}", True, "optional contract unset in manifest (skipped)"))
                continue
            if args.allow_zero:
                warnings.append(Check(f"code@{name}", True, "zero address in manifest (skipped)"))
                continue
            checks.append(Check(f"code@{name}", False, "zero address in manifest"))
            continue
        ok, code_hex, err = cast.code(addr)
        if not ok:
            checks.append(Check(f"code@{name}", False, err))
            continue
        if code_hex.strip() == "0x":
            checks.append(Check(f"code@{name}", False, "no code at address"))
        else:
            checks.append(Check(f"code@{name}", True, "OK"))
            if not is_local:
                try:
                    raw_sb = meta.get("startBlock", 0)
                    start_block = int(raw_sb, 0) if isinstance(raw_sb, str) else int(raw_sb)
                except (ValueError, TypeError) as exc:
                    checks.append(Check(f"startBlock@{name}", False, f"unparseable startBlock: {meta.get('startBlock')!r} ({exc})"))
                    continue
                if start_block <= 0:
                    checks.append(Check(f"startBlock@{name}", False, "missing/zero startBlock in manifest"))

    # ------------------------------------------------------------
    # Timelock + runtime proxy governance metadata
    # ------------------------------------------------------------
    if addr_timelock and not _is_zero(addr_timelock):
        ok, outs, err = cast.call(addr_timelock, "getMinDelay()(uint256)")
        manifest_delay = manifest.get("contracts", {}).get("TimelockController", {}).get("minDelaySeconds")
        manifest_proposer = _get_addr(manifest, "contracts.TimelockController.proposer")
        manifest_executor = _get_addr(manifest, "contracts.TimelockController.executor")
        bootstrap_admin = (
            manifest.get("contracts", {}).get("TimelockController", {}).get("bootstrapAdmin")
            if isinstance(manifest.get("contracts", {}).get("TimelockController", {}), dict)
            else ""
        )
        if not ok:
            checks.append(Check("TimelockController.getMinDelay", False, err))
        elif len(outs) != 1:
            checks.append(Check("TimelockController.getMinDelay", False, f"unexpected output: {outs}"))
        else:
            try:
                got_delay = _parse_cast_uint(outs[0])
            except Exception as e:  # noqa: BLE001
                checks.append(Check("TimelockController.getMinDelay", False, f"failed to parse delay '{outs[0]}': {e}"))
            else:
                if isinstance(manifest_delay, int):
                    if got_delay == manifest_delay:
                        checks.append(Check("TimelockController.getMinDelay", True, f"OK ({got_delay})"))
                    else:
                        checks.append(
                            Check(
                                "TimelockController.getMinDelay",
                                False,
                                f"expected {manifest_delay}, got {got_delay}",
                            )
                        )
                else:
                    warnings.append(
                        Check("TimelockController.getMinDelay", True, f"manifest missing minDelaySeconds; live value is {got_delay}")
                    )

        ok, outs, err = cast.call(
            addr_timelock,
            "hasRole(bytes32,address)(bool)",
            [ZERO_BYTES32, addr_timelock],
        )
        if not ok:
            checks.append(Check("TimelockController.selfAdmin", False, err))
        elif len(outs) != 1:
            checks.append(Check("TimelockController.selfAdmin", False, f"unexpected output: {outs}"))
        else:
            checks.append(_check_true("TimelockController.selfAdmin", outs[0]))

        if manifest_proposer and not _is_zero(manifest_proposer):
            ok, role_outs, err = cast.call(addr_timelock, "PROPOSER_ROLE()(bytes32)")
            if not ok:
                checks.append(Check("TimelockController.proposer", False, err))
            elif len(role_outs) != 1:
                checks.append(Check("TimelockController.proposer", False, f"unexpected output: {role_outs}"))
            else:
                ok, outs, err = cast.call(
                    addr_timelock,
                    "hasRole(bytes32,address)(bool)",
                    [role_outs[0], manifest_proposer],
                )
                if not ok:
                    checks.append(Check("TimelockController.proposer", False, err))
                elif len(outs) != 1:
                    checks.append(Check("TimelockController.proposer", False, f"unexpected output: {outs}"))
                else:
                    checks.append(_check_true("TimelockController.proposer", outs[0]))

            ok, role_outs, err = cast.call(addr_timelock, "CANCELLER_ROLE()(bytes32)")
            if not ok:
                checks.append(Check("TimelockController.canceller", False, err))
            elif len(role_outs) != 1:
                checks.append(Check("TimelockController.canceller", False, f"unexpected output: {role_outs}"))
            else:
                ok, outs, err = cast.call(
                    addr_timelock,
                    "hasRole(bytes32,address)(bool)",
                    [role_outs[0], manifest_proposer],
                )
                if not ok:
                    checks.append(Check("TimelockController.canceller", False, err))
                elif len(outs) != 1:
                    checks.append(Check("TimelockController.canceller", False, f"unexpected output: {outs}"))
                else:
                    checks.append(_check_true("TimelockController.canceller", outs[0]))
        elif manifest_path.name == "base_mainnet.json":
            checks.append(
                Check(
                    "TimelockController.proposer",
                    False,
                    "manifest missing proposer (required on base_mainnet)",
                )
            )

        if manifest_executor and not _is_zero(manifest_executor):
            ok, role_outs, err = cast.call(addr_timelock, "EXECUTOR_ROLE()(bytes32)")
            if not ok:
                checks.append(Check("TimelockController.executor", False, err))
            elif len(role_outs) != 1:
                checks.append(Check("TimelockController.executor", False, f"unexpected output: {role_outs}"))
            else:
                ok, outs, err = cast.call(
                    addr_timelock,
                    "hasRole(bytes32,address)(bool)",
                    [role_outs[0], manifest_executor],
                )
                if not ok:
                    checks.append(Check("TimelockController.executor", False, err))
                elif len(outs) != 1:
                    checks.append(Check("TimelockController.executor", False, f"unexpected output: {outs}"))
                else:
                    checks.append(_check_true("TimelockController.executor", outs[0]))

                ok, outs, err = cast.call(
                    addr_timelock,
                    "hasRole(bytes32,address)(bool)",
                    [role_outs[0], ZERO_ADDR],
                )
                if not ok:
                    checks.append(Check("TimelockController.executorOpenRole", False, err))
                elif len(outs) != 1:
                    checks.append(Check("TimelockController.executorOpenRole", False, f"unexpected output: {outs}"))
                else:
                    checks.append(_check_false("TimelockController.executorOpenRole", outs[0]))
        elif manifest_path.name == "base_mainnet.json":
            checks.append(
                Check(
                    "TimelockController.executor",
                    False,
                    "manifest missing executor (required on base_mainnet)",
                )
            )

        if isinstance(bootstrap_admin, str) and bootstrap_admin.strip() and not _is_zero(bootstrap_admin):
            if is_local or not args.require_finalized:
                checks.append(Check("TimelockController.bootstrapAdminRenounced", True, "skipped (pre-bootstrap-finalize; use --require-finalized to enforce)"))
            else:
                ok, outs, err = cast.call(
                    addr_timelock,
                    "hasRole(bytes32,address)(bool)",
                    [ZERO_BYTES32, bootstrap_admin],
                )
                if not ok:
                    checks.append(Check("TimelockController.bootstrapAdminRenounced", False, err))
                elif len(outs) != 1:
                    checks.append(Check("TimelockController.bootstrapAdminRenounced", False, f"unexpected output: {outs}"))
                else:
                    checks.append(_check_false("TimelockController.bootstrapAdminRenounced", outs[0]))
        elif not is_local:
            checks.append(
                Check(
                    "TimelockController.bootstrapAdmin",
                    False,
                    "manifest missing bootstrapAdmin (required to prove deployer admin renunciation)",
                )
            )

    runtime_quartet = ("MineCore", "Furnace", "MarketRouter", "ShareholderRoyalties")
    for name in runtime_quartet:
        meta = manifest.get("contracts", {}).get(name, {})
        if not isinstance(meta, dict):
            continue
        proxy = meta.get("address") if isinstance(meta.get("address"), str) else ""
        implementation = meta.get("implementation") if isinstance(meta.get("implementation"), str) else ""
        proxy_admin = meta.get("proxyAdmin") if isinstance(meta.get("proxyAdmin"), str) else ""
        proxy_admin_owner = meta.get("proxyAdminOwner") if isinstance(meta.get("proxyAdminOwner"), str) else ""

        if not proxy or _is_zero(proxy):
            continue

        if proxy_admin and not _is_zero(proxy_admin):
            ok, slot_val, err = cast.storage(proxy, ADMIN_SLOT)
            if not ok:
                checks.append(Check(f"{name}.proxyAdmin(slot)", False, err))
            else:
                checks.append(_check_eq_addr(f"{name}.proxyAdmin(slot)", _slot_addr(slot_val), proxy_admin))

            ok, outs, err = cast.call(proxy_admin, "owner()(address)")
            if not ok:
                checks.append(Check(f"{name}.proxyAdmin.owner", False, err))
            elif len(outs) != 1:
                checks.append(Check(f"{name}.proxyAdmin.owner", False, f"unexpected output: {outs}"))
            elif args.require_finalized:
                # Post-FreezeAndBurn the canonical proxyAdmin.owner is address(0).
                # The composite finality block below re-asserts this; we skip the
                # pre-finalize equality check here to avoid double-counting against
                # the manifest's pre-burn `proxyAdminOwner` snapshot.
                checks.append(
                    Check(
                        f"{name}.proxyAdmin.owner",
                        True,
                        "deferred to composite --require-finalized gate (expects address(0))",
                    )
                )
            elif proxy_admin_owner:
                checks.append(_check_eq_addr(f"{name}.proxyAdmin.owner", outs[0], proxy_admin_owner))
            else:
                checks.append(
                    Check(
                        f"{name}.proxyAdmin.owner",
                        False,
                        "manifest missing proxyAdminOwner (required for runtime finality attestation)",
                    )
                )
        elif not is_local:
            checks.append(
                Check(
                    f"{name}.proxyAdmin(slot)",
                    False,
                    "manifest proxyAdmin missing/zero (required for runtime finality attestation)",
                )
            )

        if implementation and not _is_zero(implementation):
            ok, slot_val, err = cast.storage(proxy, IMPLEMENTATION_SLOT)
            if not ok:
                checks.append(Check(f"{name}.implementation(slot)", False, err))
            else:
                checks.append(_check_eq_addr(f"{name}.implementation(slot)", _slot_addr(slot_val), implementation))
        elif not is_local:
            checks.append(
                Check(
                    f"{name}.implementation(slot)",
                    False,
                    "manifest implementation missing/zero (required for runtime finality attestation)",
                )
            )

    # ------------------------------------------------------------
    # configFrozen on all 5 core contracts (multi-contract freeze)
    # ------------------------------------------------------------
    _freeze_targets = [
        ("ClaimToken", addr_claim),
        ("Furnace", addr_furn),
        ("MineCore", addr_mine),
        ("VeClaimNFT", addr_ve),
        ("ShareholderRoyalties", addr_roy),
    ]
    for name, addr in _freeze_targets:
        if addr and not _is_zero(addr):
            ok, outs, err = cast.call(addr, "configFrozen()(bool)")
            if not ok:
                checks.append(Check(f"{name}.configFrozen", False, err))
            elif len(outs) != 1:
                checks.append(Check(f"{name}.configFrozen", False, f"unexpected output: {outs}"))
            else:
                frozen = outs[0].strip().lower() == "true"
                if args.require_frozen:
                    checks.append(_check_true(f"{name}.configFrozen", outs[0]))
                elif frozen:
                    checks.append(Check(f"{name}.configFrozen", True, "OK (true)"))
                else:
                    warnings.append(
                        Check(
                            f"{name}.configFrozen",
                            True,
                            f"false (pre-freeze; {name} wiring not yet locked)",
                        )
                    )

    # ------------------------------------------------------------
    # Composite finality gate (--require-finalized)
    # Asserts: ProxyAdmin.owner()==address(0) for all 4 runtime proxies,
    #          ClaimToken.owner()==address(0), bootstrap admin renounced.
    # configFrozen is already enforced above via the implied --require-frozen.
    # ------------------------------------------------------------
    if args.require_finalized:
        # ProxyAdmin.owner() must be address(0) (burned) for all 4 runtime proxies.
        for name in runtime_quartet:
            meta = manifest.get("contracts", {}).get(name, {})
            if not isinstance(meta, dict):
                continue
            proxy_admin = meta.get("proxyAdmin") if isinstance(meta.get("proxyAdmin"), str) else ""
            if not proxy_admin or _is_zero(proxy_admin):
                checks.append(
                    Check(f"finality:{name}.proxyAdmin.burned", False, "manifest proxyAdmin missing/zero (cannot verify burn)")
                )
                continue
            ok, outs, err = cast.call(proxy_admin, "owner()(address)")
            if not ok:
                checks.append(Check(f"finality:{name}.proxyAdmin.burned", False, err))
            elif len(outs) != 1:
                checks.append(Check(f"finality:{name}.proxyAdmin.burned", False, f"unexpected output: {outs}"))
            else:
                if _is_zero(outs[0]):
                    checks.append(Check(f"finality:{name}.proxyAdmin.burned", True, "OK (owner == address(0))"))
                else:
                    checks.append(
                        Check(f"finality:{name}.proxyAdmin.burned", False, f"owner is {outs[0]}, expected address(0)")
                    )

        # ClaimToken.owner() must be address(0) (renounced at wire time).
        if addr_claim and not _is_zero(addr_claim):
            ok, outs, err = cast.call(addr_claim, "owner()(address)")
            if not ok:
                checks.append(Check("finality:ClaimToken.owner.renounced", False, err))
            elif len(outs) != 1:
                checks.append(Check("finality:ClaimToken.owner.renounced", False, f"unexpected output: {outs}"))
            else:
                if _is_zero(outs[0]):
                    checks.append(Check("finality:ClaimToken.owner.renounced", True, "OK (owner == address(0))"))
                else:
                    checks.append(
                        Check("finality:ClaimToken.owner.renounced", False, f"owner is {outs[0]}, expected address(0)")
                    )

        # Bootstrap admin must not hold DEFAULT_ADMIN_ROLE (already checked above,
        # but re-asserted here as a hard failure when --require-finalized is set).
        bootstrap_admin_meta = manifest.get("contracts", {}).get("TimelockController", {})
        ba = bootstrap_admin_meta.get("bootstrapAdmin", "") if isinstance(bootstrap_admin_meta, dict) else ""
        if ba and not _is_zero(ba) and addr_timelock and not _is_zero(addr_timelock):
            ok, outs, err = cast.call(addr_timelock, "hasRole(bytes32,address)(bool)", [ZERO_BYTES32, ba])
            if not ok:
                checks.append(Check("finality:bootstrapAdmin.renounced", False, err))
            elif len(outs) != 1:
                checks.append(Check("finality:bootstrapAdmin.renounced", False, f"unexpected output: {outs}"))
            else:
                if outs[0].strip().lower() == "false":
                    checks.append(Check("finality:bootstrapAdmin.renounced", True, "OK (no DEFAULT_ADMIN_ROLE)"))
                else:
                    checks.append(
                        Check("finality:bootstrapAdmin.renounced", False, "bootstrap admin still holds DEFAULT_ADMIN_ROLE")
                    )

    # ------------------------------------------------------------
    # Contract-level owner() checks (--expected-owner)
    # Asserts owner() on 9 transferable-ownership contracts.
    # ------------------------------------------------------------
    if args.expected_owner:
        _owner_targets = [
            ("VeClaimNFT", addr_ve),
            ("MineCore", addr_mine),
            ("ShareholderRoyalties", addr_roy),
            ("Furnace", addr_furn),
            ("MarketRouter", addr_market),
            ("FurnaceEntryTokenRegistry", addr_reg_furn),
            ("MineCoreEntryTokenRegistry", addr_reg_mine),
            ("DexAdapter", addr_dex),
            ("LpStakingVault7D", addr_lp_vault),
        ]
        for name, addr in _owner_targets:
            if not addr or _is_zero(addr):
                warnings.append(Check(f"owner:{name}", True, "manifest address missing/zero (skipped)"))
                continue
            ok, outs, err = cast.call(addr, "owner()(address)")
            if not ok:
                checks.append(Check(f"owner:{name}", False, err))
            elif len(outs) != 1:
                checks.append(Check(f"owner:{name}", False, f"unexpected output: {outs}"))
            else:
                checks.append(_check_eq_addr(f"owner:{name}", outs[0], args.expected_owner))

    # ------------------------------------------------------------
    # Wiring: core relationships
    # ------------------------------------------------------------
    def _call_one(addr: str, sig: str) -> Tuple[bool, str]:
        ok, outs, err = cast.call(addr, sig)
        if not ok:
            return False, err
        if len(outs) != 1:
            return False, f"unexpected output: {outs}"
        return True, outs[0]

    def _call_one_arg(addr: str, sig: str, arg: str) -> Tuple[bool, str]:
        ok, outs, err = cast.call(addr, sig, [arg])
        if not ok:
            return False, err
        if len(outs) != 1:
            return False, f"unexpected output: {outs}"
        return True, outs[0]

    launch_genesis_finalized: Optional[bool] = None
    launch_expected_pool = ""
    if addr_launch and not _is_zero(addr_launch):
        ok, got = _call_one(addr_launch, "genesisFinalized()(bool)")
        if ok:
            launch_genesis_finalized = got.strip().lower() == "true"
        ok, got = _call_one(addr_launch, "expectedPool()(address)")
        if ok and got and not _is_zero(got):
            launch_expected_pool = got

    expected_claim_weth_pool = _prefer_nonzero_addr(aero_claim_weth_pool, launch_expected_pool, aero_lp_token)

    expected_pool_live = False
    if expected_claim_weth_pool:
        ok_code, code_hex, _ = cast.code(expected_claim_weth_pool)
        expected_pool_live = ok_code and code_hex.strip() != "0x"

    if not is_local:
        pool_addr_set = bool(aero_claim_weth_pool and not _is_zero(aero_claim_weth_pool))
        lp_addr_set = bool(aero_lp_token and not _is_zero(aero_lp_token))
        if pool_addr_set != lp_addr_set:
            checks.append(
                Check(
                    "manifest.aerodrome.claimWethPool/lpToken pairing",
                    False,
                    "claimWethPool.address and lpToken.address must either both be zero or both be populated",
                )
            )
        if pool_addr_set and (aero_claim_weth_pool_start is None or aero_claim_weth_pool_start <= 0):
            checks.append(
                Check(
                    "manifest.aerodrome.claimWethPool.startBlock",
                    False,
                    "missing/zero startBlock for populated claimWethPool address",
                )
            )
        if lp_addr_set and (aero_lp_token_start is None or aero_lp_token_start <= 0):
            checks.append(
                Check(
                    "manifest.aerodrome.lpToken.startBlock",
                    False,
                    "missing/zero startBlock for populated lpToken address",
                )
            )
        if pool_addr_set and lp_addr_set:
            checks.append(
                _check_eq_addr(
                    "manifest.aerodrome.lpToken == aerodrome.claimWethPool",
                    aero_lp_token,
                    aero_claim_weth_pool,
                )
            )

        if expected_pool_live:
            if not pool_addr_set:
                checks.append(
                    Check(
                        "manifest.aerodrome.claimWethPool.address (live pool)",
                        False,
                        "live canonical pool has code but claimWethPool.address is missing/zero in manifest",
                    )
                )
            if not lp_addr_set:
                checks.append(
                    Check(
                        "manifest.aerodrome.lpToken.address (live pool)",
                        False,
                        "live canonical pool has code but lpToken.address is missing/zero in manifest",
                    )
                )

    if launch_genesis_finalized is True:
        if aero_claim_weth_pool and not _is_zero(aero_claim_weth_pool):
            checks.append(Check("manifest.aerodrome.claimWethPool.address (post-genesis)", True, aero_claim_weth_pool))
        else:
            checks.append(
                Check(
                    "manifest.aerodrome.claimWethPool.address (post-genesis)",
                    False,
                    "missing/zero; backfill the canonical pool address after FinalizeGenesis",
                )
            )

        if aero_lp_token and not _is_zero(aero_lp_token):
            checks.append(Check("manifest.aerodrome.lpToken.address (post-genesis)", True, aero_lp_token))
        else:
            checks.append(
                Check(
                    "manifest.aerodrome.lpToken.address (post-genesis)",
                    False,
                    "missing/zero; backfill the canonical LP token address after FinalizeGenesis",
                )
            )

        if aero_claim_weth_pool_start is not None and aero_claim_weth_pool_start > 0:
            checks.append(
                Check(
                    "manifest.aerodrome.claimWethPool.startBlock (post-genesis)",
                    True,
                    str(aero_claim_weth_pool_start),
                )
            )
        else:
            checks.append(
                Check(
                    "manifest.aerodrome.claimWethPool.startBlock (post-genesis)",
                    False,
                    "missing/zero; record the FinalizeGenesis receipt block before proceeding",
                )
            )

        if aero_lp_token_start is not None and aero_lp_token_start > 0:
            checks.append(Check("manifest.aerodrome.lpToken.startBlock (post-genesis)", True, str(aero_lp_token_start)))
        else:
            checks.append(
                Check(
                    "manifest.aerodrome.lpToken.startBlock (post-genesis)",
                    False,
                    "missing/zero; record the FinalizeGenesis receipt block before proceeding",
                )
            )

        # Co-population invariant: address and startBlock must both be set or both missing.
        _pool_set = bool(aero_claim_weth_pool and not _is_zero(aero_claim_weth_pool))
        _pool_block_set = aero_claim_weth_pool_start is not None and aero_claim_weth_pool_start > 0
        if _pool_set != _pool_block_set:
            checks.append(Check(
                "manifest.aerodrome.claimWethPool.consistency",
                False,
                f"address={'set' if _pool_set else 'missing'} but startBlock={'set' if _pool_block_set else 'missing'}; both must be populated simultaneously",
            ))
        _lp_set = bool(aero_lp_token and not _is_zero(aero_lp_token))
        _lp_block_set = aero_lp_token_start is not None and aero_lp_token_start > 0
        if _lp_set != _lp_block_set:
            checks.append(Check(
                "manifest.aerodrome.lpToken.consistency",
                False,
                f"address={'set' if _lp_set else 'missing'} but startBlock={'set' if _lp_block_set else 'missing'}; both must be populated simultaneously",
            ))

        if (
            aero_claim_weth_pool
            and not _is_zero(aero_claim_weth_pool)
            and aero_lp_token
            and not _is_zero(aero_lp_token)
        ):
            checks.append(
                _check_eq_addr(
                    "manifest.aerodrome.lpToken == aerodrome.claimWethPool (post-genesis)",
                    aero_lp_token,
                    aero_claim_weth_pool,
                )
            )

    # ClaimToken.mineCore
    if addr_claim and not _is_zero(addr_claim) and addr_mine and not _is_zero(addr_mine):
        ok, got = _call_one(addr_claim, "mineCore()(address)")
        checks.append(_check_eq_addr("ClaimToken.mineCore", got, addr_mine) if ok else Check("ClaimToken.mineCore", False, got))

    # MineCore.furnace
    if addr_mine and not _is_zero(addr_mine) and addr_furn and not _is_zero(addr_furn):
        ok, got = _call_one(addr_mine, "furnace()(address)")
        checks.append(_check_eq_addr("MineCore.furnace", got, addr_furn) if ok else Check("MineCore.furnace", False, got))

    # MineCore immutable roots (claim, ve, royalties)
    if addr_mine and not _is_zero(addr_mine) and addr_claim and not _is_zero(addr_claim):
        ok, got = _call_one(addr_mine, "claim()(address)")
        checks.append(_check_eq_addr("MineCore.claim", got, addr_claim) if ok else Check("MineCore.claim", False, got))
    if addr_mine and not _is_zero(addr_mine) and addr_ve and not _is_zero(addr_ve):
        ok, got = _call_one(addr_mine, "ve()(address)")
        checks.append(_check_eq_addr("MineCore.ve", got, addr_ve) if ok else Check("MineCore.ve", False, got))
    if addr_mine and not _is_zero(addr_mine) and addr_roy and not _is_zero(addr_roy):
        ok, got = _call_one(addr_mine, "royalties()(address)")
        checks.append(_check_eq_addr("MineCore.royalties", got, addr_roy) if ok else Check("MineCore.royalties", False, got))

    # MineCore.entryTokenRegistry
    if addr_mine and not _is_zero(addr_mine) and addr_reg_mine and not _is_zero(addr_reg_mine):
        ok, got = _call_one(addr_mine, "entryTokenRegistry()(address)")
        checks.append(
            _check_eq_addr("MineCore.entryTokenRegistry", got, addr_reg_mine) if ok else Check("MineCore.entryTokenRegistry", False, got)
        )

    # Furnace.entryTokenRegistry
    if addr_furn and not _is_zero(addr_furn) and addr_reg_furn and not _is_zero(addr_reg_furn):
        ok, got = _call_one(addr_furn, "entryTokenRegistry()(address)")
        checks.append(
            _check_eq_addr("Furnace.entryTokenRegistry", got, addr_reg_furn) if ok else Check("Furnace.entryTokenRegistry", False, got)
        )

    # Furnace.shareholderRoyalties
    if addr_furn and not _is_zero(addr_furn) and addr_roy and not _is_zero(addr_roy):
        ok, got = _call_one(addr_furn, "shareholderRoyalties()(address)")
        checks.append(
            _check_eq_addr("Furnace.shareholderRoyalties", got, addr_roy) if ok else Check("Furnace.shareholderRoyalties", False, got)
        )

    # Furnace.mineCore
    if addr_furn and not _is_zero(addr_furn) and addr_mine and not _is_zero(addr_mine):
        ok, got = _call_one(addr_furn, "mineCore()(address)")
        checks.append(_check_eq_addr("Furnace.mineCore", got, addr_mine) if ok else Check("Furnace.mineCore", False, got))

    # Furnace immutable roots (claim, ve)
    if addr_furn and not _is_zero(addr_furn) and addr_claim and not _is_zero(addr_claim):
        ok, got = _call_one(addr_furn, "claim()(address)")
        checks.append(_check_eq_addr("Furnace.claim", got, addr_claim) if ok else Check("Furnace.claim", False, got))
    if addr_furn and not _is_zero(addr_furn) and addr_ve and not _is_zero(addr_ve):
        ok, got = _call_one(addr_furn, "ve()(address)")
        checks.append(_check_eq_addr("Furnace.ve", got, addr_ve) if ok else Check("Furnace.ve", False, got))

    # Furnace.guardian MUST be MineCore (single locking pause surface; SPEC §5.6.2)
    if addr_furn and not _is_zero(addr_furn) and addr_mine and not _is_zero(addr_mine):
        ok, got = _call_one(addr_furn, "guardian()(address)")
        checks.append(
            _check_eq_addr("Furnace.guardian", got, addr_mine) if ok else Check("Furnace.guardian", False, got)
        )

    # Furnace.mineMarket (required for canonical bundle)
    if addr_furn and not _is_zero(addr_furn) and addr_market and not _is_zero(addr_market):
        ok, got = _call_one(addr_furn, "mineMarket()(address)")
        checks.append(_check_eq_addr("Furnace.mineMarket", got, addr_market) if ok else Check("Furnace.mineMarket", False, got))

    # VeClaimNFT wiring
    if addr_ve and not _is_zero(addr_ve) and addr_furn and not _is_zero(addr_furn):
        ok, got = _call_one(addr_ve, "furnace()(address)")
        checks.append(_check_eq_addr("VeClaimNFT.furnace", got, addr_furn) if ok else Check("VeClaimNFT.furnace", False, got))
    if addr_ve and not _is_zero(addr_ve) and addr_market and not _is_zero(addr_market):
        ok, got = _call_one(addr_ve, "mineMarket()(address)")
        checks.append(_check_eq_addr("VeClaimNFT.mineMarket", got, addr_market) if ok else Check("VeClaimNFT.mineMarket", False, got))

    # VeClaimNFT immutable root (claimToken)
    if addr_ve and not _is_zero(addr_ve) and addr_claim and not _is_zero(addr_claim):
        ok, got = _call_one(addr_ve, "claimToken()(address)")
        checks.append(_check_eq_addr("VeClaimNFT.claimToken", got, addr_claim) if ok else Check("VeClaimNFT.claimToken", False, got))

    # ShareholderRoyalties wiring
    if addr_roy and not _is_zero(addr_roy) and addr_mine and not _is_zero(addr_mine):
        ok, got = _call_one(addr_roy, "mineCore()(address)")
        checks.append(_check_eq_addr("Royalties.mineCore", got, addr_mine) if ok else Check("Royalties.mineCore", False, got))
    if addr_roy and not _is_zero(addr_roy) and addr_market and not _is_zero(addr_market):
        ok, got = _call_one(addr_roy, "mineMarket()(address)")
        checks.append(_check_eq_addr("Royalties.mineMarket", got, addr_market) if ok else Check("Royalties.mineMarket", False, got))

    # ShareholderRoyalties immutable root (ve)
    if addr_roy and not _is_zero(addr_roy) and addr_ve and not _is_zero(addr_ve):
        ok, got = _call_one(addr_roy, "ve()(address)")
        checks.append(_check_eq_addr("Royalties.ve", got, addr_ve) if ok else Check("Royalties.ve", False, got))

    # MarketRouter immutable roots (claim, ve, royalties)
    if addr_market and not _is_zero(addr_market):
        if addr_claim and not _is_zero(addr_claim):
            ok, got = _call_one(addr_market, "claim()(address)")
            checks.append(
                _check_eq_addr("MarketRouter.claim", got, addr_claim) if ok else Check("MarketRouter.claim", False, got)
            )
        if addr_ve and not _is_zero(addr_ve):
            ok, got = _call_one(addr_market, "ve()(address)")
            checks.append(
                _check_eq_addr("MarketRouter.ve", got, addr_ve) if ok else Check("MarketRouter.ve", False, got)
            )
        if addr_roy and not _is_zero(addr_roy):
            ok, got = _call_one(addr_market, "royalties()(address)")
            checks.append(
                _check_eq_addr("MarketRouter.royalties", got, addr_roy) if ok else Check("MarketRouter.royalties", False, got)
            )

    # DelegationHub wiring (Furnace + MineCore) — operational peripheral, warning-only on local revert
    addr_delegation_hub = _contract_addr(manifest, "DelegationHub")
    if addr_furn and not _is_zero(addr_furn) and addr_delegation_hub and not _is_zero(addr_delegation_hub):
        ok, got = _call_one(addr_furn, "delegationHub()(address)")
        if ok:
            checks.append(_check_eq_addr("Furnace.delegationHub", got, addr_delegation_hub))
        elif is_local:
            warnings.append(Check("Furnace.delegationHub", True, f"skipped ({got})"))
        else:
            checks.append(Check("Furnace.delegationHub", False, f"manifest includes DelegationHub but read failed: {got}"))

    if addr_mine and not _is_zero(addr_mine) and addr_delegation_hub and not _is_zero(addr_delegation_hub):
        ok, got = _call_one(addr_mine, "delegationHub()(address)")
        if ok:
            checks.append(_check_eq_addr("MineCore.delegationHub", got, addr_delegation_hub))
        elif is_local:
            warnings.append(Check("MineCore.delegationHub", True, f"skipped ({got})"))
        else:
            checks.append(Check("MineCore.delegationHub", False, f"manifest includes DelegationHub but read failed: {got}"))

    # ClaimAllHelper wiring (required for canonical bundle; part of freeze surface)
    if addr_helper and not _is_zero(addr_helper):
        if addr_mine and not _is_zero(addr_mine):
            ok, got = _call_one(addr_mine, "claimAllHelper()(address)")
            checks.append(
                _check_eq_addr("MineCore.claimAllHelper", got, addr_helper) if ok else Check("MineCore.claimAllHelper", False, got)
            )

        if addr_roy and not _is_zero(addr_roy):
            ok, got = _call_one(addr_roy, "claimAllHelper()(address)")
            checks.append(
                _check_eq_addr("Royalties.claimAllHelper", got, addr_helper) if ok else Check("Royalties.claimAllHelper", False, got)
            )

        # ClaimAllHelper immutable roots (mineCore, royalties)
        if addr_mine and not _is_zero(addr_mine):
            ok, got = _call_one(addr_helper, "mineCore()(address)")
            checks.append(
                _check_eq_addr("ClaimAllHelper.mineCore", got, addr_mine) if ok else Check("ClaimAllHelper.mineCore", False, got)
            )
        if addr_roy and not _is_zero(addr_roy):
            ok, got = _call_one(addr_helper, "royalties()(address)")
            checks.append(
                _check_eq_addr("ClaimAllHelper.royalties", got, addr_roy) if ok else Check("ClaimAllHelper.royalties", False, got)
            )

    # MarketRouter settlement-keeper posture for MaintenanceHub.
    # This is optional because Wire.s.sol keeps the permissionless MaintenanceHub off the
    # settlement-keeper allowlist by default unless operators explicitly opt in.
    if addr_market and not _is_zero(addr_market) and addr_maint and not _is_zero(addr_maint):
        ok, got = _call_one_arg(addr_market, "isSettlementKeeper(address)(bool)", addr_maint)
        if args.expect_maintenancehub_settlement_keeper:
            checks.append(
                _check_true("MarketRouter.isSettlementKeeper(MaintenanceHub)", got)
                if ok
                else Check("MarketRouter.isSettlementKeeper(MaintenanceHub)", False, got)
            )
        elif ok:
            enabled = got.strip().lower() == "true"
            detail = (
                "optional; allowlisted (grace-window offer execution via poke enabled)"
                if enabled
                else "optional; not allowlisted (default-safe posture)"
            )
            warnings.append(Check("MarketRouter.isSettlementKeeper(MaintenanceHub)", True, detail))
        else:
            warnings.append(Check("MarketRouter.isSettlementKeeper(MaintenanceHub)", True, f"skipped ({got})"))

    # ------------------------------------------------------------
    # Full deployment: vault cross-wiring + LP rewards pointers
    # ------------------------------------------------------------

    # Furnace.lpRewardsVault -> LpStakingVault7D
    if addr_furn and not _is_zero(addr_furn) and addr_lp_vault and not _is_zero(addr_lp_vault):
        ok, got = _call_one(addr_furn, "lpRewardsVault()(address)")
        checks.append(
            _check_eq_addr("Furnace.lpRewardsVault", got, addr_lp_vault) if ok else Check("Furnace.lpRewardsVault", False, got)
        )

    # LpStakingVault7D wiring
    if addr_lp_vault and not _is_zero(addr_lp_vault):
        # LpStakingVault7D.furnace
        if addr_furn and not _is_zero(addr_furn):
            ok, got = _call_one(addr_lp_vault, "furnace()(address)")
            checks.append(
                _check_eq_addr("LpStakingVault7D.furnace", got, addr_furn)
                if ok
                else Check("LpStakingVault7D.furnace", False, got)
            )


        # Basic token wiring
        if addr_claim and not _is_zero(addr_claim):
            ok, got = _call_one(addr_lp_vault, "claim()(address)")
            checks.append(_check_eq_addr("LpStakingVault7D.claim", got, addr_claim) if ok else Check("LpStakingVault7D.claim", False, got))

        if addr_ve and not _is_zero(addr_ve):
            ok, got = _call_one(addr_lp_vault, "ve()(address)")
            checks.append(_check_eq_addr("LpStakingVault7D.ve", got, addr_ve) if ok else Check("LpStakingVault7D.ve", False, got))

        if aero_weth and not _is_zero(aero_weth):
            ok, got = _call_one(addr_lp_vault, "weth()(address)")
            checks.append(_check_eq_addr("LpStakingVault7D.weth", got, aero_weth) if ok else Check("LpStakingVault7D.weth", False, got))
        else:
            warnings.append(Check("LpStakingVault7D.weth", True, "manifest missing aerodrome.wrappedNative.address"))

        # Router/factory for fee harvest swaps (raw Aerodrome router)
        if aero_router and not _is_zero(aero_router):
            ok, got = _call_one(addr_lp_vault, "aerodromeRouter()(address)")
            checks.append(
                _check_eq_addr("LpStakingVault7D.aerodromeRouter", got, aero_router)
                if ok
                else Check("LpStakingVault7D.aerodromeRouter", False, got)
            )
        else:
            warnings.append(Check("LpStakingVault7D.aerodromeRouter", True, "manifest missing aerodrome.router.address"))

        if aero_factory and not _is_zero(aero_factory):
            ok, got = _call_one(addr_lp_vault, "aerodromeFactory()(address)")
            checks.append(
                _check_eq_addr("LpStakingVault7D.aerodromeFactory", got, aero_factory)
                if ok
                else Check("LpStakingVault7D.aerodromeFactory", False, got)
            )
        else:
            warnings.append(Check("LpStakingVault7D.aerodromeFactory", True, "manifest missing aerodrome.poolFactory.address"))

        # Volatile pool expected for v1.0.0
        ok, got = _call_one(addr_lp_vault, "wethClaimStable()(bool)")
        if ok:
            checks.append(_check_false("LpStakingVault7D.wethClaimStable", got))
        else:
            checks.append(Check("LpStakingVault7D.wethClaimStable", False, got))

        # LP token address
        expected_lp = aero_lp_token if aero_lp_token and not _is_zero(aero_lp_token) else aero_claim_weth_pool
        if expected_lp and not _is_zero(expected_lp):
            ok, got = _call_one(addr_lp_vault, "lpToken()(address)")
            checks.append(_check_eq_addr("LpStakingVault7D.lpToken", got, expected_lp) if ok else Check("LpStakingVault7D.lpToken", False, got))
        else:
            warnings.append(Check("LpStakingVault7D.lpToken", True, "manifest missing aerodrome.lpToken.address and aerodrome.claimWethPool.address"))

    # GenesisLPVault24M wiring
    if addr_genesis_vault and not _is_zero(addr_genesis_vault):
        manifest_lp_withdraw_recipient = _get_addr(manifest, "contracts.GenesisLPVault24M.lpWithdrawRecipient")
        ok, got = _call_one(addr_genesis_vault, "lpWithdrawRecipient()(address)")
        if ok:
            if manifest_lp_withdraw_recipient and not _is_zero(manifest_lp_withdraw_recipient):
                checks.append(
                    _check_eq_addr(
                        "GenesisLPVault24M.lpWithdrawRecipient",
                        got,
                        manifest_lp_withdraw_recipient,
                    )
                )
            elif not is_local:
                checks.append(
                    Check(
                        "GenesisLPVault24M.lpWithdrawRecipient",
                        False,
                        "manifest missing lpWithdrawRecipient (required for canonical deployment verification)",
                    )
                )
            else:
                checks.append(_check_nonzero("GenesisLPVault24M.lpWithdrawRecipient", got))
        else:
            checks.append(Check("GenesisLPVault24M.lpWithdrawRecipient", False, got))

        # Pool address should match manifest and/or staking vault lpToken
        expected_pool = aero_claim_weth_pool if aero_claim_weth_pool and not _is_zero(aero_claim_weth_pool) else aero_lp_token
        if expected_pool and not _is_zero(expected_pool):
            ok, got = _call_one(addr_genesis_vault, "pool()(address)")
            checks.append(
                _check_eq_addr("GenesisLPVault24M.pool", got, expected_pool)
                if ok
                else Check("GenesisLPVault24M.pool", False, got)
            )
        else:
            warnings.append(Check("GenesisLPVault24M.pool", True, "manifest missing aerodrome.claimWethPool.address and aerodrome.lpToken.address"))

        # Cross-check: vault pool == staking lpToken
        if addr_lp_vault and not _is_zero(addr_lp_vault):
            okp, pool_got = _call_one(addr_genesis_vault, "pool()(address)")
            okl, lp_got = _call_one(addr_lp_vault, "lpToken()(address)")
            if okp and okl:
                checks.append(_check_eq_addr("Vaults.pool == LpStakingVault7D.lpToken", pool_got, lp_got))
            else:
                warnings.append(Check("Vaults.pool == LpStakingVault7D.lpToken", True, f"skipped ({pool_got if not okp else ''}{lp_got if not okl else ''})"))

    # ------------------------------------------------------------
    # LaunchController (genesis wiring)
    # ------------------------------------------------------------

    if addr_launch and not _is_zero(addr_launch):
        if addr_claim and not _is_zero(addr_claim):
            ok, got = _call_one(addr_launch, "claim()(address)")
            checks.append(_check_eq_addr("LaunchController.claim", got, addr_claim) if ok else Check("LaunchController.claim", False, got))

        if addr_mine and not _is_zero(addr_mine):
            ok, got = _call_one(addr_launch, "mineCore()(address)")
            checks.append(_check_eq_addr("LaunchController.mineCore", got, addr_mine) if ok else Check("LaunchController.mineCore", False, got))

        if addr_genesis_vault and not _is_zero(addr_genesis_vault):
            ok, got = _call_one(addr_launch, "genesisLpVault()(address)")
            checks.append(
                _check_eq_addr("LaunchController.genesisLpVault", got, addr_genesis_vault)
                if ok
                else Check("LaunchController.genesisLpVault", False, got)
            )

        # LaunchController expects a DexAdapter-like router.
        if addr_dex and not _is_zero(addr_dex):
            ok, got = _call_one(addr_launch, "aerodromeRouter()(address)")
            checks.append(
                _check_eq_addr("LaunchController.aerodromeRouter", got, addr_dex)
                if ok
                else Check("LaunchController.aerodromeRouter", False, got)
            )
        else:
            warnings.append(Check("LaunchController.aerodromeRouter", True, "manifest missing contracts.DexAdapter.address"))

        if aero_weth and not _is_zero(aero_weth):
            ok, got = _call_one(addr_launch, "weth()(address)")
            checks.append(_check_eq_addr("LaunchController.weth", got, aero_weth) if ok else Check("LaunchController.weth", False, got))
        else:
            warnings.append(Check("LaunchController.weth", True, "manifest missing aerodrome.wrappedNative.address"))

        if aero_factory and not _is_zero(aero_factory):
            ok, got = _call_one(addr_launch, "factory()(address)")
            checks.append(_check_eq_addr("LaunchController.factory", got, aero_factory) if ok else Check("LaunchController.factory", False, got))
        else:
            warnings.append(Check("LaunchController.factory", True, "manifest missing aerodrome.poolFactory.address"))

        if aero_claim_weth_pool and not _is_zero(aero_claim_weth_pool):
            ok, got = _call_one(addr_launch, "expectedPool()(address)")
            checks.append(
                _check_eq_addr("LaunchController.expectedPool", got, aero_claim_weth_pool)
                if ok
                else Check("LaunchController.expectedPool", False, got)
            )
        else:
            warnings.append(Check("LaunchController.expectedPool", True, "manifest missing aerodrome.claimWethPool.address"))

        # Cross-check: expectedPool == GenesisLPVault24M.pool
        if addr_genesis_vault and not _is_zero(addr_genesis_vault):
            ok1, got1 = _call_one(addr_launch, "expectedPool()(address)")
            ok2, got2 = _call_one(addr_genesis_vault, "pool()(address)")
            if ok1 and ok2:
                checks.append(_check_eq_addr("LaunchController.expectedPool == GenesisLPVault24M.pool", got1, got2))
            else:
                warnings.append(Check("LaunchController.expectedPool == GenesisLPVault24M.pool", True, "skipped (call failed)"))

        # ------------------------------------------------------------
        # MineCore genesis authority + pause state (stage-aware)
        # ------------------------------------------------------------
        # v1.0.0 requirement (pre-genesis):
        # - MineCore.guardian MUST be LaunchController so it can:
        #     - collectGenesisKingClaim(...)
        #     - setTakeoversPaused(false) inside finalizeGenesis()
        # - MineCore.takeoversPaused MUST be true until genesis finalization.
        #
        # Post-genesis: takeoversPaused MUST be false and guardian MUST be rotated away from LaunchController
        # before the deployment is considered production-ready.
        if addr_mine and not _is_zero(addr_mine):
            okf, finalized = _call_one(addr_launch, "genesisFinalized()(bool)")
            if okf:
                is_finalized = finalized.strip().lower() == "true"

                if not is_finalized:
                    ok, got = _call_one(addr_mine, "guardian()(address)")
                    checks.append(
                        _check_eq_addr("MineCore.guardian (pre-genesis)", got, addr_launch)
                        if ok
                        else Check("MineCore.guardian (pre-genesis)", False, got)
                    )

                    ok, got = _call_one(addr_mine, "takeoversPaused()(bool)")
                    checks.append(
                        _check_true("MineCore.takeoversPaused (pre-genesis)", got)
                        if ok
                        else Check("MineCore.takeoversPaused (pre-genesis)", False, got)
                    )

                    ok_owner, owner = _call_one(addr_mine, "owner()(address)")
                    ok_guardian, lc_guardian = _call_one(addr_launch, "guardian()(address)")
                    if ok_owner and ok_guardian:
                        if _norm_addr(owner) == _norm_addr(lc_guardian):
                            checks.append(Check("MineCore.owner == LaunchController.guardian (pre-genesis)", True, owner))
                        else:
                            warnings.append(
                                Check(
                                    "MineCore.owner == LaunchController.guardian (pre-genesis)",
                                    True,
                                    f"warning: owner={owner}, launch guardian={lc_guardian}; FinalizeGenesis.s.sol requires one selected signer to control both addresses in the same run",
                                )
                            )
                    else:
                        warnings.append(
                            Check(
                                "MineCore.owner == LaunchController.guardian (pre-genesis)",
                                True,
                                "skipped (call failed)",
                            )
                        )

                else:
                    ok, got = _call_one(addr_mine, "takeoversPaused()(bool)")
                    checks.append(
                        _check_false("MineCore.takeoversPaused (post-genesis)", got)
                        if ok
                        else Check("MineCore.takeoversPaused (post-genesis)", False, got)
                    )

                    ok, got = _call_one(addr_mine, "guardian()(address)")
                    if ok:
                        if _norm_addr(got) == _norm_addr(addr_launch):
                            checks.append(
                                Check(
                                    "MineCore.guardian rotated (post-genesis)",
                                    False,
                                    f"still LaunchController ({got}); rotate to long-term GUARDIAN",
                                )
                            )
                        else:
                            checks.append(Check("MineCore.guardian rotated (post-genesis)", True, got))
                            if args.expected_guardian and not _is_zero(args.expected_guardian):
                                checks.append(
                                    _check_eq_addr(
                                        "MineCore.guardian == expected guardian (post-genesis)",
                                        got,
                                        args.expected_guardian,
                                    )
                                )
                    else:
                        checks.append(Check("MineCore.guardian rotated (post-genesis)", False, got))
            else:
                if is_local:
                    warnings.append(Check("LaunchController.genesisFinalized", True, f"skipped ({finalized})"))
                else:
                    checks.append(Check("LaunchController.genesisFinalized", False, f"could not read genesis state: {finalized}"))

    # ------------------------------------------------------------
    # Secondary-guardian sweep (--expected-secondary-guardian)
    # Wire.s.sol:461-463/532-534 sets the guardian on MarketRouter,
    # FurnaceEntryTokenRegistry, and MineCoreEntryTokenRegistry from the
    # GUARDIAN env var at deploy time. Furnace.guardian is spec-locked to
    # MineCore (Furnace.sol:517) — checked here separately.
    #
    # Lessons-learned: Sepolia 2026-04-30 Cycle A post-B.12 guardian sweep.
    # The Apr-28 Sepolia redeploy used GUARDIAN=NEW_DEPLOYER (Guardian Safe
    # was deployed mid-rehearsal), leaving MarketRouter/FETR/METR.guardian
    # pointing at the deployer EOA after the B.10/B.11 governance handoff.
    # This flag mechanically catches that gap.
    # ------------------------------------------------------------
    expected_secondary = args.expected_secondary_guardian or args.expected_guardian
    if expected_secondary and not _is_zero(expected_secondary):
        _secondary_targets = [
            ("MarketRouter", addr_market),
            ("FurnaceEntryTokenRegistry", addr_reg_furn),
            ("MineCoreEntryTokenRegistry", addr_reg_mine),
        ]
        for name, addr in _secondary_targets:
            if not addr or _is_zero(addr):
                warnings.append(Check(f"guardian:{name}", True, "manifest address missing/zero (skipped)"))
                continue
            ok, outs, err = cast.call(addr, "guardian()(address)")
            if not ok:
                checks.append(Check(f"guardian:{name}", False, err))
            elif len(outs) != 1:
                checks.append(Check(f"guardian:{name}", False, f"unexpected output: {outs}"))
            else:
                checks.append(_check_eq_addr(f"guardian:{name}", outs[0], expected_secondary))

    # Furnace.guardian must equal MineCore (spec-locked via Furnace.sol:517 WiringMismatch revert).
    if addr_furn and addr_mine and not _is_zero(addr_furn) and not _is_zero(addr_mine):
        ok, outs, err = cast.call(addr_furn, "guardian()(address)")
        if not ok:
            checks.append(Check("guardian:Furnace (spec-locked == MineCore)", False, err))
        elif len(outs) != 1:
            checks.append(Check("guardian:Furnace (spec-locked == MineCore)", False, f"unexpected output: {outs}"))
        else:
            checks.append(_check_eq_addr("guardian:Furnace (spec-locked == MineCore)", outs[0], addr_mine))

    # ------------------------------------------------------------
    # MineCoreQuoter wiring
    # ------------------------------------------------------------
    if addr_mine_quoter and not _is_zero(addr_mine_quoter):
        if addr_mine and not _is_zero(addr_mine):
            ok, got = _call_one(addr_mine_quoter, "mineCore()(address)")
            checks.append(
                _check_eq_addr("MineCoreQuoter.mineCore", got, addr_mine)
                if ok
                else Check("MineCoreQuoter.mineCore", False, got)
            )

    # ------------------------------------------------------------
    # Registry invariants
    # ------------------------------------------------------------
    if addr_reg_furn and addr_reg_mine and not _is_zero(addr_reg_furn) and not _is_zero(addr_reg_mine):
        if _norm_addr(addr_reg_furn) == _norm_addr(addr_reg_mine):
            checks.append(Check("EntryTokenRegistry split", False, "FurnaceEntryTokenRegistry == MineCoreEntryTokenRegistry"))
        else:
            checks.append(Check("EntryTokenRegistry split", True, "OK (registries differ)"))

    def _check_registry(name: str, reg_addr: str) -> None:
        if not reg_addr or _is_zero(reg_addr):
            return

        ok, outs, err = cast.call(reg_addr, "getRouterConfig()(address,address,address,address)")
        if not ok:
            checks.append(Check(f"{name}.getRouterConfig", False, err))
            return
        if len(outs) != 4:
            checks.append(Check(f"{name}.getRouterConfig", False, f"unexpected output: {outs}"))
            return

        reg_router, reg_factory, reg_wrapped, reg_claim = outs

        # Local deployments may intentionally omit Aerodrome wiring (router config + hop).
        # When the manifest pins aerodrome.router to 0x0, the Wire flow skips
        # configuring routerConfig and the WETH/CLAIM hop. Treat these as non-fatal on local.
        is_local_manifest = (args.network == "local") or (manifest_path.name == "local.json")
        aero_router_is_placeholder = (not aero_router) or _is_zero(aero_router)
        router_config_unset = _is_zero(reg_router) and _is_zero(reg_factory) and _is_zero(reg_wrapped) and _is_zero(reg_claim)
        if is_local_manifest and aero_router_is_placeholder and router_config_unset:
            warnings.append(Check(f"{name}.routerConfig", True, "skipped on local (aerodrome router not configured in manifest)"))

            ok_hop, outs_hop, err_hop = cast.call(reg_addr, "getWethClaimHop()(bool,address)")
            if ok_hop and len(outs_hop) == 2:
                stable, pool = outs_hop
                if name == "FurnaceEntryTokenRegistry":
                    warnings.append(Check(f"{name}.wethClaimPool", True, f"not set on local (pool={pool})"))
                    warnings.append(Check(f"{name}.wethClaimStable", True, f"stable={stable}"))
                else:
                    warnings.append(Check(f"{name}.wethClaimHop", True, f"stable={stable}, pool={pool}"))
            else:
                warnings.append(Check(f"{name}.getWethClaimHop", True, f"skipped ({err_hop or outs_hop})"))
            return

        # Factory / wrapped / claim are always required.
        if aero_factory:
            checks.append(_check_eq_addr(f"{name}.factory", reg_factory, aero_factory))
        else:
            warnings.append(Check(f"{name}.factory", True, "manifest missing aerodrome.poolFactory.address"))

        if aero_weth:
            checks.append(_check_eq_addr(f"{name}.wrappedNative", reg_wrapped, aero_weth))
        else:
            warnings.append(Check(f"{name}.wrappedNative", True, "manifest missing aerodrome.wrappedNative.address"))

        if addr_claim and not _is_zero(addr_claim):
            checks.append(_check_eq_addr(f"{name}.claimToken", reg_claim, addr_claim))
        else:
            warnings.append(Check(f"{name}.claimToken", True, "manifest missing ClaimToken address"))

        # Router path: prefer DexAdapter if present.
        if addr_dex and not _is_zero(addr_dex) and not args.allow_raw_router:
            checks.append(_check_eq_addr(f"{name}.router", reg_router, addr_dex))
        else:
            # If we don't have DexAdapter, or user allows raw router, check against aerodrome.router if present.
            if aero_router:
                if _norm_addr(reg_router) in (_norm_addr(aero_router), _norm_addr(addr_dex)):
                    checks.append(Check(f"{name}.router", True, f"OK ({reg_router})"))
                else:
                    checks.append(Check(f"{name}.router", False, f"expected {aero_router} (or {addr_dex}), got {reg_router}"))
            else:
                warnings.append(Check(f"{name}.router", True, "manifest missing aerodrome.router.address"))

        # If registry router is DexAdapter, verify it points at the pinned Aerodrome router.
        if addr_dex and not _is_zero(addr_dex) and _norm_addr(reg_router) == _norm_addr(addr_dex) and aero_router:
            ok2, got2 = _call_one(addr_dex, "aerodromeRouter()(address)")
            if ok2:
                checks.append(_check_eq_addr("DexAdapter.aerodromeRouter", got2, aero_router))
            else:
                # DexAdapter in this repo historically used `aerodromeRouter` as a public var; if renamed, warn.
                warnings.append(Check("DexAdapter.aerodromeRouter", True, f"skipped ({got2})"))

            ok3, got3 = _call_one(addr_dex, "defaultFactory()(address)")
            if ok3 and aero_factory:
                checks.append(_check_eq_addr("DexAdapter.defaultFactory", got3, aero_factory))
            elif not ok3:
                warnings.append(Check("DexAdapter.defaultFactory", True, f"skipped ({got3})"))

            ok4, got4 = _call_one(addr_dex, "weth()(address)")
            if ok4 and aero_weth:
                checks.append(_check_eq_addr("DexAdapter.weth", got4, aero_weth))
            elif not ok4:
                warnings.append(Check("DexAdapter.weth", True, f"skipped ({got4})"))

        # WETH/CLAIM hop
        ok_hop, outs_hop, err_hop = cast.call(reg_addr, "getWethClaimHop()(bool,address)")
        if ok_hop and len(outs_hop) == 2:
            stable, pool = outs_hop
            if name == "FurnaceEntryTokenRegistry":
                hop_check, is_warning = _furnace_weth_claim_pool_status(
                    name,
                    pool,
                    expected_claim_weth_pool,
                    launch_genesis_finalized,
                    expected_pool_live,
                )
                if is_warning:
                    warnings.append(hop_check)
                else:
                    checks.append(hop_check)
                warnings.append(Check(f"{name}.wethClaimStable", True, f"stable={stable}"))
            else:
                # For MineCore registry, hop may be unused; report as info.
                warnings.append(Check(f"{name}.wethClaimHop", True, f"stable={stable}, pool={pool}"))
        else:
            warnings.append(Check(f"{name}.getWethClaimHop", True, f"skipped ({err_hop or outs_hop})"))

    _check_registry("FurnaceEntryTokenRegistry", addr_reg_furn)
    _check_registry("MineCoreEntryTokenRegistry", addr_reg_mine)

    # ------------------------------------------------------------
    # FurnaceQuoter wiring (view-only quoting helper)
    # ------------------------------------------------------------

    quoter_addr_effective = addr_furnace_quoter
    quoter_from_manifest = bool(addr_furnace_quoter and not _is_zero(addr_furnace_quoter))
    if addr_furn and not _is_zero(addr_furn):
        ok, got = _call_one(addr_furn, "furnaceQuoter()(address)")
        if ok:
            if quoter_from_manifest:
                checks.append(
                    _check_eq_addr("Furnace.furnaceQuoter", got, quoter_addr_effective)
                )
            elif is_local:
                if not _is_zero(got):
                    quoter_addr_effective = got
                    warnings.append(Check("Furnace.furnaceQuoter", True, f"discovered {got} (FurnaceQuoter not in manifest)"))
                else:
                    warnings.append(Check("Furnace.furnaceQuoter", True, "not set (0x0) and FurnaceQuoter not in manifest"))
            else:
                detail = (
                    f"manifest missing FurnaceQuoter while Furnace.furnaceQuoter() returns {got}"
                    if not _is_zero(got)
                    else "manifest missing FurnaceQuoter and Furnace.furnaceQuoter() is 0x0"
                )
                checks.append(Check("FurnaceQuoter.manifest", False, detail))
                # Do NOT set quoter_addr_effective from discovered address when
                # manifest is missing — downstream wiring checks would show
                # misleading PASS results against an unverified on-chain address.
        else:
            if quoter_from_manifest:
                checks.append(Check("Furnace.furnaceQuoter", False, got))
            elif is_local:
                warnings.append(Check("Furnace.furnaceQuoter", True, f"skipped ({got})"))
            else:
                checks.append(Check("FurnaceQuoter.manifest", False, f"manifest missing FurnaceQuoter and Furnace.furnaceQuoter() could not be read: {got}"))

    if quoter_addr_effective and not _is_zero(quoter_addr_effective):
        # FurnaceQuoter.furnace == Furnace
        if addr_furn and not _is_zero(addr_furn):
            ok, got = _call_one(quoter_addr_effective, "furnace()(address)")
            checks.append(
                _check_eq_addr("FurnaceQuoter.furnace", got, addr_furn)
                if ok
                else Check("FurnaceQuoter.furnace", False, got)
            )

        # FurnaceQuoter.claim == ClaimToken (immutable cached from Furnace)
        if addr_claim and not _is_zero(addr_claim):
            ok, got = _call_one(quoter_addr_effective, "claim()(address)")
            checks.append(
                _check_eq_addr("FurnaceQuoter.claim", got, addr_claim)
                if ok
                else Check("FurnaceQuoter.claim", False, got)
            )

        # FurnaceQuoter.ve == VeClaimNFT (immutable cached from Furnace)
        if addr_ve and not _is_zero(addr_ve):
            ok, got = _call_one(quoter_addr_effective, "ve()(address)")
            checks.append(
                _check_eq_addr("FurnaceQuoter.ve", got, addr_ve)
                if ok
                else Check("FurnaceQuoter.ve", False, got)
            )

    # ------------------------------------------------------------
    # AgentLens (view-only snapshot bundler)
    # ------------------------------------------------------------

    if addr_agent_lens and not _is_zero(addr_agent_lens):
        lens_expected: List[Tuple[str, str]] = [
            ("claimToken", addr_claim),
            ("veClaimNFT", addr_ve),
            ("mineCore", addr_mine),
            ("shareholderRoyalties", addr_roy),
            ("furnace", addr_furn),
            ("marketRouter", addr_market),
            ("lpStakingVault7D", addr_lp_vault),
            ("dexAdapter", addr_dex),
            ("furnaceEntryTokenRegistry", addr_reg_furn),
            ("mineCoreEntryTokenRegistry", addr_reg_mine),
            ("claimAllHelper", addr_helper),
            ("maintenanceHub", addr_maint),
            ("launchController", addr_launch),
            ("genesisLPVault24M", addr_genesis_vault),
        ]

        # DelegationHub is optional and may be omitted from some manifests.
        addr_delegation = _contract_addr(manifest, "DelegationHub")
        lens_expected.insert(10, ("delegationHub", addr_delegation))

        for field, want in lens_expected:
            expected = want if want and not _is_zero(want) else ZERO_ADDR
            ok, got = _call_one(addr_agent_lens, f"{field}()(address)")
            checks.append(
                _check_eq_addr(f"AgentLens.{field}", got, expected)
                if ok
                else Check(f"AgentLens.{field}", False, got)
            )

    # ------------------------------------------------------------
    # MaintenanceHub (getter + runtime bytecode scan for remaining immutables)
    # ------------------------------------------------------------

    if addr_maint and not _is_zero(addr_maint):
        ok, got = _call_one(addr_maint, "rescueRecipient()(address)")
        if ok:
            if manifest_rescue_recipient and not _is_zero(manifest_rescue_recipient):
                checks.append(
                    _check_eq_addr(
                        "MaintenanceHub.rescueRecipient",
                        got,
                        manifest_rescue_recipient,
                    )
                )
            elif not is_local:
                checks.append(
                    Check(
                        "MaintenanceHub.rescueRecipient",
                        False,
                        "manifest missing rescueRecipient (required for canonical deployment verification)",
                    )
                )
            else:
                checks.append(_check_nonzero("MaintenanceHub.rescueRecipient", got))
        else:
            checks.append(Check("MaintenanceHub.rescueRecipient", False, got))

    if not args.skip_maintenancehub_scan and addr_maint and not _is_zero(addr_maint):
        ok, code_hex, err = cast.code(addr_maint)
        if not ok:
            checks.append(Check("MaintenanceHub.code", False, err))
        else:
            # Scan for each expected immutable address. Solidity stores immutables in runtime bytecode.
            expected: List[Tuple[str, str]] = [
                ("marketRouter", addr_market),
                ("furnace", addr_furn),
                ("ve", addr_ve),
                ("royalties", addr_roy),
                ("weth", aero_weth),
            ]

            for field, addr in expected:
                if not addr or _is_zero(addr):
                    warnings.append(Check(f"MaintenanceHub.{field}", True, "manifest missing/zero (skipped)"))
                    continue

                frag = _addr_hex40(addr)
                # Use only the zero-padded 64-char form (matches Solidity's
                # 32-byte immutable storage layout).  The bare 40-char fragment
                # could theoretically substring-match unrelated bytecode.
                padded = "000000000000000000000000" + frag

                if _code_contains_any(code_hex, [padded]):
                    checks.append(Check(f"MaintenanceHub.{field}", True, "OK (found in runtime bytecode)"))
                else:
                    checks.append(Check(f"MaintenanceHub.{field}", False, f"expected {addr} not found in runtime bytecode"))

    elif addr_maint and not _is_zero(addr_maint) and args.skip_maintenancehub_scan:
        warnings.append(Check("MaintenanceHub.scan", True, "skipped by flag"))

    # ------------------------------------------------------------
    # Print
    # ------------------------------------------------------------
    print(f"Manifest: {manifest_path}")
    print(f"RPC: {args.rpc_url}")
    print()

    # Separate PASS/FAIL and WARN to keep output readable.
    print(_fmt(checks))
    if warnings:
        print()
        print("[WARN] non-fatal checks:")
        print(_fmt(warnings))

    failed = [c for c in checks if not c.ok]
    if failed:
        print()
        print(f"FAILED: {len(failed)} checks failed")
        return 1

    print()
    print("OK: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
