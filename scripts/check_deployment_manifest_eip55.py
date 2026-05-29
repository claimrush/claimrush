#!/usr/bin/env python3
"""Guardrail: every address in `deployments/*.json` is EIP-55 checksummed.

Why this gate exists:
- External readers compare these manifests byte-for-byte with addresses they
  fetch from ethers/viem/cast. Mixed casing (lowercase in one field vs.
  mixed-case in another) creates spurious drift alarms and hides real
  governance pivots (same address appearing twice with different casing
  looks like two separate addresses in a casual grep/diff).
- EIP-55 is the long-standing normal form for Ethereum address strings.

What this gate does:
- Scans every string value in every deployment JSON that matches a 20-byte
  address shape (`0x` + 40 hex chars).
- Re-computes the EIP-55 mixed-case form using keccak-256 over the
  lowercased hex.
- Fails (exit 1) if any address in the committed manifest does not match
  its EIP-55 form.

Dependencies:
- `pycryptodome` provides `Crypto.Hash.keccak`. If unavailable we fail with
  a clear message rather than silently skipping the check.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEPLOYMENTS_DIR = ROOT / "deployments"
ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")


def _load_keccak():
    try:
        from Crypto.Hash import keccak  # type: ignore

        def _kec(data: bytes) -> bytes:
            h = keccak.new(digest_bits=256)
            h.update(data)
            return h.digest()

        return _kec
    except Exception:
        try:
            # Fallback: eth_hash is a common transitive dep of web3 tooling.
            from eth_hash.auto import keccak as _ekec  # type: ignore

            return lambda b: _ekec(b)
        except Exception:
            sys.stderr.write(
                "[manifest-eip55] ERROR: neither pycryptodome nor eth_hash is "
                "installed. Add `pycryptodome` to requirements-ci.txt.\n"
            )
            raise SystemExit(2)


_keccak = _load_keccak()


def _eip55(addr: str) -> str:
    lower = addr[2:].lower()
    digest = _keccak(lower.encode("ascii")).hex()
    out = ["0x"]
    for i, c in enumerate(lower):
        if "a" <= c <= "f":
            out.append(c.upper() if int(digest[i], 16) >= 8 else c)
        else:
            out.append(c)
    return "".join(out)


def _walk(node, path, out):
    if isinstance(node, dict):
        for k, v in node.items():
            _walk(v, f"{path}.{k}" if path else k, out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _walk(v, f"{path}[{i}]", out)
    elif isinstance(node, str) and ADDR_RE.match(node):
        expected = _eip55(node)
        if node != expected:
            out.append((path, node, expected))


def main() -> int:
    manifests = sorted(DEPLOYMENTS_DIR.glob("*.json"))
    if not manifests:
        sys.stderr.write("[manifest-eip55] ERROR: no deployment manifests found\n")
        return 1

    failures = 0
    for p in manifests:
        data = json.loads(p.read_text(encoding="utf-8"))
        drifts: list[tuple[str, str, str]] = []
        _walk(data, "", drifts)
        if drifts:
            failures += len(drifts)
            rel = p.relative_to(ROOT)
            for path, got, want in drifts:
                sys.stderr.write(
                    f"[manifest-eip55] {rel}: {path} is not EIP-55 checksummed\n"
                    f"    got:      {got}\n"
                    f"    expected: {want}\n"
                )

    if failures:
        sys.stderr.write(
            f"[manifest-eip55] FAIL: {failures} address(es) not EIP-55 checksummed. "
            f"Re-run scripts/deploy_prod.mjs (or normalise by hand) and commit.\n"
        )
        return 1

    print(f"[manifest-eip55] OK ({len(manifests)} manifests checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
