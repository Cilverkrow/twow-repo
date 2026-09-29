"""Synthetic mini DBCs for the tests.

This packer is deliberately independent of clientpatch.wdbc (plain struct
calls, its own string block), so the round-trip test compares the tool
against a second implementation instead of against itself. No real client
file is ever used or committed.
"""

from __future__ import annotations

import random
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from clientpatch.binding import Binding, load_binding  # noqa: E402

BINDINGS = ROOT / "bindings" / "1.12.1.5875"


def binding(name: str) -> Binding:
    return load_binding(BINDINGS / f"{name}.toml")


def pack(b: Binding, rows: list[dict], share_strings: bool = True) -> bytes:
    """rows: dicts column -> value; missing columns are 0 / ''."""
    block = bytearray(b"\0")
    offsets: dict[str, int] = {"": 0}
    recs = bytearray()
    for row in rows:
        for c in b.columns:
            v = row.get(c.name, "" if c.kind == "string" else 0)
            if c.kind == "string":
                if v in offsets and share_strings:
                    o = offsets[v]
                elif v == "":
                    o = 0
                else:
                    o = len(block)
                    block += v.encode("utf-8") + b"\0"
                    offsets.setdefault(v, o)
                recs += struct.pack("<I", o)
            elif c.kind == "float":
                recs += struct.pack("<f", float(v))
            else:
                recs += struct.pack("<" + c.code, v)
    header = struct.pack("<4s4I", b"WDBC", len(rows), b.field_count, b.record_size, len(block))
    return header + bytes(recs) + bytes(block)


def random_rows(b: Binding, n: int, seed: int = 1) -> list[dict]:
    rnd = random.Random(seed)
    words = ["Frost", "Earthen Bulwark", "Ghost Wolf", "", "Rank 1", "Rank 1", "Déjà vu"]
    rows = []
    for i in range(n):
        row = {}
        for c in b.columns:
            if c.name in b.key:
                row[c.name] = i + 1 if len(b.key) == 1 else rnd.randint(1, 9) * 10 + i
            elif c.kind == "string":
                row[c.name] = rnd.choice(words)
            elif c.kind == "float":
                row[c.name] = struct.unpack("<f", struct.pack("<f", rnd.uniform(-5, 5)))[0]
            else:
                bits = c.size * 8
                lo = -(2 ** (bits - 1)) if c.code.islower() else 0
                hi = 2 ** (bits - 1) - 1 if c.code.islower() else 2**bits - 1
                row[c.name] = rnd.randint(lo, hi)
        rows.append(row)
    return rows


def write(directory: Path, name: str, data: bytes) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    p = directory / f"{name}.dbc"
    p.write_bytes(data)
    return p
