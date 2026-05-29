#!/usr/bin/env python3
"""Validate that ABI JSON files comply with Strict Mode requirements.

STRICT MODE (v1.0.0+) INVARIANTS:
- Furnace is the ONLY buyer/sink for veNFT locks.
- No user-to-user lock sales or swaps.
- The following symbols MUST NOT appear in any function or event ABI entries:
  - buyLock
  - LockBought
  - GlobalOfferFilled
  - bazaarAbsorbLock / bazaarRetargetLock
  - marketBuyWith* / marketSell
  - swapEthToClaimFromBazaar / swapTokenToClaimFromBazaar

Additionally, MarketRouter ABI:
  - MUST NOT contain forbidden function selectors (buyLock, marketBuyWith*, etc.)
  - MUST contain required function selectors (listLock, delistLock, sellLockToFurnace, etc.)
  - MUST contain required event signatures (LockListed, LockDelisted)

Usage:
  python3 scripts/check_abi_strict_mode.py --abi-dir abis/base_mainnet
  python3 scripts/check_abi_strict_mode.py --abi-dir abis/base_sepolia

Exit codes:
  0 = All ABIs pass validation
  1 = Forbidden symbols found or required symbols missing
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Dict, List, Set, Tuple

# Track if we're using hardcoded selectors (for CI warning)
_using_hardcoded_selectors = False

# Forbidden function/event names (exact match)
FORBIDDEN_NAMES: Set[str] = {
    "buyLock",
    "LockBought",
    "GlobalOfferFilled",
    "bazaarAbsorbLock",
    "bazaarRetargetLock",
    "marketBuyWithEth",
    "marketBuyWithClaim",
    "marketSell",
    "swapEthToClaimFromBazaar",
    "swapTokenToClaimFromBazaar",
}

# Forbidden function/event name prefixes
FORBIDDEN_PREFIXES: Tuple[str, ...] = (
    "marketBuyWith",
    "bazaarAbsorb",
    "bazaarRetarget",
    "swapEthToClaimFrom",
    "swapTokenToClaimFrom",
)

# Forbidden parameter names (should not appear in function/event inputs/outputs)
FORBIDDEN_PARAM_NAMES: Set[str] = set()

# Forbidden function selectors for MarketRouter
FORBIDDEN_SELECTORS_MARKETROUTER: List[str] = [
    "buyLock(uint256)",
    "marketBuyWithEth(uint256,uint256)",
    "marketBuyWithClaim(uint256,uint256)",
    "marketSell(uint256,uint256)",
    "acceptGlobalOffer(uint256,uint256)",
    "fillGlobalOfferFromListing(uint256,uint256)",
]

# Required function selectors for MarketRouter (Strict Mode)
REQUIRED_SELECTORS_MARKETROUTER: List[str] = [
    "listLock(uint256,uint256,uint256)",
    "delistLock(uint256)",
    "cancelExpiredListing(uint256)",
    "sellLockToFurnace(uint256,uint256,uint256)",
    "sellListedLockToFurnace(uint256,uint256)",
]

# Required event signatures for MarketRouter (Strict Mode)
REQUIRED_EVENTS_MARKETROUTER: List[str] = [
    "LockListed(uint256,address,uint256,uint256,uint256)",
    "LockDelisted(uint256,address,uint8)",
    "MarketSellToFurnace(uint256,address,uint256,uint256,uint256)",
]

# Hardcoded selectors (used when crypto libraries unavailable)
KNOWN_SELECTORS: Dict[str, str] = {
    # Forbidden
    "buyLock(uint256)": "0x0752881a",
    "marketBuyWithEth(uint256,uint256)": "0x8d7d3eea",
    "marketBuyWithClaim(uint256,uint256)": "0x6d5e0c4e",
    "marketSell(uint256,uint256)": "0x6c197ff5",
    "acceptGlobalOffer(uint256,uint256)": "0x5a9b0b89",
    "fillGlobalOfferFromListing(uint256,uint256)": "0x7c3a00fd",
    # Required functions
    "listLock(uint256,uint256,uint256)": "0xb1d09efe",
    "delistLock(uint256)": "0xae4a9d39",
    "cancelExpiredListing(uint256)": "0x254942ff",
    "sellLockToFurnace(uint256,uint256,uint256)": "0x4942b9f1",
    "sellListedLockToFurnace(uint256,uint256)": "0x4da16b79",
    # Required events (topic0)
    "LockListed(uint256,address,uint256,uint256,uint256)": "0xb19d00ff19499651f10295eab5ed2728f506834ab38aef5582c3234d785ab53c",
    "LockDelisted(uint256,address,uint8)": "0x5e29665a8a78403017927c22037096fabc3810f3f65369b4642330e0207d6750",
    "MarketSellToFurnace(uint256,address,uint256,uint256,uint256)": "0x985739016e56b1ad110e497bb7df09f253f571a5e7dbbf706971dbd09c446442",
}


def keccak256_selector(signature: str) -> str:
    """Compute the 4-byte function/event selector from a signature using keccak256."""
    global _using_hardcoded_selectors

    # Try pycryptodome
    try:
        from Crypto.Hash import keccak
        k = keccak.new(digest_bits=256)
        k.update(signature.encode("utf-8"))
        return "0x" + k.hexdigest()[:8]
    except ImportError:
        pass

    # Try pysha3
    try:
        import sha3
        k = sha3.keccak_256()
        k.update(signature.encode("utf-8"))
        return "0x" + k.hexdigest()[:8]
    except ImportError:
        pass

    # Try eth_hash
    try:
        from eth_hash.auto import keccak
        digest = keccak(signature.encode("utf-8"))
        return "0x" + digest.hex()[:8]
    except ImportError:
        pass

    # Fallback to hardcoded selectors
    if signature in KNOWN_SELECTORS:
        _using_hardcoded_selectors = True
        return KNOWN_SELECTORS[signature]

    # Unknown signature
    _using_hardcoded_selectors = True
    return ""


def keccak256_topic(signature: str) -> str:
    """Compute the 32-byte event topic0 from a signature using keccak256."""
    global _using_hardcoded_selectors

    # Try pycryptodome
    try:
        from Crypto.Hash import keccak
        k = keccak.new(digest_bits=256)
        k.update(signature.encode("utf-8"))
        return "0x" + k.hexdigest()
    except ImportError:
        pass

    # Try pysha3
    try:
        import sha3
        k = sha3.keccak_256()
        k.update(signature.encode("utf-8"))
        return "0x" + k.hexdigest()
    except ImportError:
        pass

    # Try eth_hash
    try:
        from eth_hash.auto import keccak
        digest = keccak(signature.encode("utf-8"))
        return "0x" + digest.hex()
    except ImportError:
        pass

    # Fallback - return empty (will cause a match failure, which is safer)
    _using_hardcoded_selectors = True
    return ""


def check_abi_entry(entry: dict, file_path: str) -> List[str]:
    """Check a single ABI entry for forbidden symbols. Returns list of violations."""
    violations = []
    entry_type = entry.get("type", "")
    name = entry.get("name", "")

    # Skip non-function/event entries
    if entry_type not in ("function", "event"):
        return violations

    # Check exact name match
    if name in FORBIDDEN_NAMES:
        violations.append(f"{file_path}: Forbidden {entry_type} name '{name}'")

    # Check prefix match
    for prefix in FORBIDDEN_PREFIXES:
        if name.startswith(prefix):
            violations.append(f"{file_path}: Forbidden {entry_type} name prefix '{prefix}' in '{name}'")
            break

    # Check parameter names in inputs
    for inp in entry.get("inputs", []):
        param_name = inp.get("name", "")
        if param_name in FORBIDDEN_PARAM_NAMES:
            violations.append(
                f"{file_path}: Forbidden parameter name '{param_name}' in {entry_type} '{name}'"
            )
        # Check tuple components recursively
        for comp in inp.get("components", []):
            comp_name = comp.get("name", "")
            if comp_name in FORBIDDEN_PARAM_NAMES:
                violations.append(
                    f"{file_path}: Forbidden component name '{comp_name}' in {entry_type} '{name}'"
                )

    # Check parameter names in outputs (for functions)
    for out in entry.get("outputs", []):
        param_name = out.get("name", "")
        if param_name in FORBIDDEN_PARAM_NAMES:
            violations.append(
                f"{file_path}: Forbidden output name '{param_name}' in {entry_type} '{name}'"
            )
        # Check tuple components recursively
        for comp in out.get("components", []):
            comp_name = comp.get("name", "")
            if comp_name in FORBIDDEN_PARAM_NAMES:
                violations.append(
                    f"{file_path}: Forbidden component name '{comp_name}' in {entry_type} '{name}'"
                )

    return violations


def compute_abi_selector(entry: dict) -> str:
    """Compute the 4-byte selector from an ABI function entry."""
    if entry.get("type") != "function":
        return ""
    name = entry.get("name", "")
    inputs = entry.get("inputs", [])
    param_types = []
    for inp in inputs:
        param_types.append(inp.get("type", ""))
    signature = f"{name}({','.join(param_types)})"
    return keccak256_selector(signature)


def compute_abi_event_signature(entry: dict) -> str:
    """Compute the event signature from an ABI event entry."""
    if entry.get("type") != "event":
        return ""
    name = entry.get("name", "")
    inputs = entry.get("inputs", [])
    param_types = []
    for inp in inputs:
        param_types.append(inp.get("type", ""))
    return f"{name}({','.join(param_types)})"


def check_marketrouter_selectors(file_path: Path, abi: list) -> List[str]:
    """Check MarketRouter ABI for forbidden and required function selectors."""
    violations = []

    # Build maps of selectors and signatures present in the ABI
    abi_selectors: Dict[str, str] = {}  # selector -> function name
    abi_function_sigs: Set[str] = set()  # function signatures present
    abi_event_sigs: Set[str] = set()  # event signatures present

    for entry in abi:
        if not isinstance(entry, dict):
            continue
        entry_type = entry.get("type", "")
        name = entry.get("name", "")

        if entry_type == "function":
            selector = compute_abi_selector(entry)
            if selector:
                abi_selectors[selector] = name
            # Build signature
            inputs = entry.get("inputs", [])
            param_types = [inp.get("type", "") for inp in inputs]
            sig = f"{name}({','.join(param_types)})"
            abi_function_sigs.add(sig)

        elif entry_type == "event":
            sig = compute_abi_event_signature(entry)
            if sig:
                abi_event_sigs.add(sig)

    # Check each forbidden signature
    for signature in FORBIDDEN_SELECTORS_MARKETROUTER:
        expected_selector = keccak256_selector(signature)
        if expected_selector and expected_selector in abi_selectors:
            violations.append(
                f"{file_path}: Forbidden selector {expected_selector} ({signature}) "
                f"found as function '{abi_selectors[expected_selector]}'"
            )

    # Check required function signatures exist
    for signature in REQUIRED_SELECTORS_MARKETROUTER:
        if signature not in abi_function_sigs:
            violations.append(
                f"{file_path}: Required function '{signature}' is MISSING"
            )

    # Check required event signatures exist
    for signature in REQUIRED_EVENTS_MARKETROUTER:
        if signature not in abi_event_sigs:
            violations.append(
                f"{file_path}: Required event '{signature}' is MISSING"
            )

    return violations


def check_abi_file(file_path: Path) -> List[str]:
    """Check an ABI JSON file for forbidden symbols. Returns list of violations."""
    violations = []
    try:
        with file_path.open("r", encoding="utf-8") as f:
            abi = json.load(f)
    except json.JSONDecodeError as e:
        violations.append(f"{file_path}: Invalid JSON: {e}")
        return violations
    except Exception as e:
        violations.append(f"{file_path}: Read error: {e}")
        return violations

    if not isinstance(abi, list):
        violations.append(f"{file_path}: ABI is not a list")
        return violations

    for entry in abi:
        if isinstance(entry, dict):
            violations.extend(check_abi_entry(entry, str(file_path)))

    # Additional selector check for MarketRouter
    if file_path.name == "MarketRouter.abi.json":
        violations.extend(check_marketrouter_selectors(file_path, abi))

    return violations


def main() -> int:
    global _using_hardcoded_selectors

    ap = argparse.ArgumentParser(description="Validate ABI files for Strict Mode compliance")
    ap.add_argument("--abi-dir", required=True, help="Directory containing ABI JSON files")
    ap.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    ap.add_argument("--allow-hardcoded-selectors", action="store_true", help="Allow fallback to hardcoded selectors/topics when no keccak256 library is installed (NOT recommended; weakens validation)")
    args = ap.parse_args()

    abi_dir = Path(args.abi_dir)
    if not abi_dir.is_dir():
        print(f"ERROR: {abi_dir} is not a directory", file=sys.stderr)
        return 1

    all_violations: List[str] = []
    files_checked = 0

    for abi_file in sorted(abi_dir.glob("*.abi.json")):
        files_checked += 1
        if args.verbose:
            print(f"Checking {abi_file}...")
        violations = check_abi_file(abi_file)
        all_violations.extend(violations)

    if files_checked == 0:
        print(f"WARNING: No ABI files found in {abi_dir}")
        return 0
    hardcoded_problem = _using_hardcoded_selectors and not args.allow_hardcoded_selectors

    # Keccak is required for correct selector/topic computation. Do not silently degrade.
    if _using_hardcoded_selectors:
        msg = (
            "No keccak256 library found. Strict Mode selector/topic checks would be incomplete. "
            "Install pinned deps: python3 -m pip install -r requirements-ci.txt"
        )
        if hardcoded_problem:
            print(f"ERROR: {msg}", file=sys.stderr)
            print("       If you need to bypass this check for the current run, re-run with --allow-hardcoded-selectors.", file=sys.stderr)
        else:
            print(f"WARNING: {msg}", file=sys.stderr)

    if all_violations:
        print(f"\nSTRICT MODE VIOLATIONS ({len(all_violations)}):\n", file=sys.stderr)
        for v in all_violations:
            print(f"  - {v}", file=sys.stderr)
        print(f"\nFailed: {len(all_violations)} violations in {files_checked} files", file=sys.stderr)
        return 1

    if hardcoded_problem:
        return 1

    print(f"OK: {files_checked} ABI files pass Strict Mode validation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
