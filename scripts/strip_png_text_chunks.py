#!/usr/bin/env python3
"""Strip non-essential textual metadata chunks from PNG files.

Removes `tEXt`, `zTXt`, `iTXt`, and `tIME` chunks (which commonly carry
"Software", "Author", "Comment", XMP, and modification-time metadata) while
preserving all rendering-relevant chunks (IHDR, PLTE, IDAT, IEND, tRNS, sRGB,
gAMA, cHRM, bKGD, pHYs, sBIT, iCCP, etc.).

This is lossless for the displayed image: no pixel data is touched; only the
ancillary metadata sidecars attached to the file are dropped. The recomputed
CRCs are written using zlib.crc32, matching the PNG specification.

Usage:
    python3 scripts/strip_png_text_chunks.py <path-glob-or-file> [...]
    python3 scripts/strip_png_text_chunks.py brand/logo/png/*.png
"""

from __future__ import annotations

import argparse
import sys
import zlib
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
CHUNKS_TO_STRIP = frozenset({b"tEXt", b"zTXt", b"iTXt", b"tIME"})


def _iter_chunks(data: bytes):
    offset = len(PNG_SIGNATURE)
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError("truncated PNG: chunk header past EOF")
        length = int.from_bytes(data[offset : offset + 4], "big")
        ctype = data[offset + 4 : offset + 8]
        body_start = offset + 8
        body_end = body_start + length
        crc_end = body_end + 4
        if crc_end > len(data):
            raise ValueError("truncated PNG: chunk body/CRC past EOF")
        body = data[body_start:body_end]
        yield ctype, body
        offset = crc_end
        if ctype == b"IEND":
            return


def strip_file(path: Path) -> tuple[int, int]:
    """Strip text metadata from *path* in place.

    Returns (chunks_kept, chunks_stripped).
    """
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path}: not a PNG file")

    out = bytearray(PNG_SIGNATURE)
    kept = 0
    stripped = 0
    for ctype, body in _iter_chunks(data):
        if ctype in CHUNKS_TO_STRIP:
            stripped += 1
            continue
        out += len(body).to_bytes(4, "big")
        out += ctype
        out += body
        out += zlib.crc32(ctype + body).to_bytes(4, "big")
        kept += 1

    if stripped == 0:
        return kept, 0

    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(bytes(out))
    tmp.replace(path)
    return kept, stripped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report which chunks would be stripped without modifying files.",
    )
    args = parser.parse_args()

    total_stripped = 0
    for p in args.paths:
        if not p.is_file():
            print(f"[strip-png] SKIP {p}: not a file", file=sys.stderr)
            continue
        try:
            if args.dry_run:
                data = p.read_bytes()
                if not data.startswith(PNG_SIGNATURE):
                    print(f"[strip-png] SKIP {p}: not a PNG", file=sys.stderr)
                    continue
                stripped = sum(
                    1 for ctype, _ in _iter_chunks(data) if ctype in CHUNKS_TO_STRIP
                )
                if stripped:
                    print(f"[strip-png] would strip {stripped} chunk(s) from {p}")
                    total_stripped += stripped
            else:
                kept, stripped = strip_file(p)
                if stripped:
                    print(f"[strip-png] stripped {stripped} chunk(s) from {p} (kept {kept})")
                    total_stripped += stripped
        except Exception as e:  # noqa: BLE001
            print(f"[strip-png] ERROR {p}: {e}", file=sys.stderr)
            return 1

    print(f"[strip-png] done: total chunks stripped = {total_stripped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
