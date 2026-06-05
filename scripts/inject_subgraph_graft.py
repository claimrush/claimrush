#!/usr/bin/env python3
"""Inject a `features: [grafting]` + `graft:` block into a subgraph manifest.

Grafting lets a new subgraph version copy an already-synced base deployment's
entity store at a chosen block and index only forward from there, turning a
full historical resync (hours-to-weeks on a mature subgraph) into the time to
index the tail. It is the standard path for ADDITIVE updates (new data source,
new entity, new field).

This operates on the ephemeral active manifest produced at deploy time, never
on a committed `subgraph.*.yaml` baseline — the committed manifests stay
graft-free so a clean full-sync remains the default and the CI parity checks
keep passing. Grafting is opt-in: the deploy script only calls this when
`GRAFT_BASE` (and `GRAFT_BLOCK`) are set.

Caveats (the operator owns these):
  - Additive only. Grafting inherits the base's already-indexed entities as-is
    and does NOT re-run changed handler logic over pre-graft blocks.
  - The base must be fully synced past `--block`.
  - Do not chain grafts indefinitely; periodically deploy one clean
    non-grafted baseline in the background to collapse the chain.
"""

from __future__ import annotations

import argparse
import re
import sys

# CIDv0 (Qm...) or CIDv1 (bafy...) deployment id of the base subgraph.
BASE_RE = re.compile(r"^(Qm[1-9A-HJ-NP-Za-km-z]{44}|bafy[a-z2-7]+)$")


def inject(text: str, base: str, block: int) -> str:
    if re.search(r"^graft:", text, flags=re.MULTILINE):
        raise SystemExit("manifest already contains a top-level `graft:` block")
    if re.search(r"^features:", text, flags=re.MULTILINE):
        raise SystemExit(
            "manifest already contains a top-level `features:` block; "
            "merge `grafting` by hand"
        )

    lines = text.splitlines(keepends=True)
    out: list[str] = []
    inserted = False
    for line in lines:
        out.append(line)
        if not inserted and line.startswith("specVersion:"):
            out.append("features:\n")
            out.append("  - grafting\n")
            out.append("graft:\n")
            out.append(f"  base: {base}\n")
            out.append(f"  block: {block}\n")
            inserted = True
    if not inserted:
        raise SystemExit("no top-level `specVersion:` line found in manifest")
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", required=True, help="path to the active manifest")
    ap.add_argument("--base", required=True, help="base deployment id (Qm.../bafy...)")
    ap.add_argument("--block", required=True, type=int, help="graft block (<= base head)")
    args = ap.parse_args()

    base = args.base.strip()
    if not BASE_RE.match(base):
        raise SystemExit(f"invalid --base {base!r}; expected an IPFS deployment id")
    if args.block <= 0:
        raise SystemExit("--block must be a positive integer")

    with open(args.manifest, "r", encoding="utf-8") as fh:
        text = fh.read()
    patched = inject(text, base, args.block)
    with open(args.manifest, "w", encoding="utf-8") as fh:
        fh.write(patched)

    print(f"grafted: base={base} block={args.block} -> {args.manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
