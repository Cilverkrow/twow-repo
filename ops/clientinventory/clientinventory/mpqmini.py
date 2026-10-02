"""Read-only MPQ (format 1) hash-table reader: does this archive contain a file?

The client MPQs carry an incomplete ``(listfile)`` (``terrain.MPQ`` names only a
fraction of its files), so listing is not enough to know which map tiles exist.
The hash table, however, answers "is there a file with this name" for any name.
This module reads only the header, the hash table and the block table; it never
decompresses or extracts anything, and it opens archives read-only.

Algorithm: the public MPQ format (hash types TABLE_OFFSET/NAME_A/NAME_B/FILE_KEY,
the crypt table seeded with 0x00100001). Python standard library only.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

_HASH_TABLE_OFFSET, _HASH_NAME_A, _HASH_NAME_B, _HASH_FILE_KEY = 0, 1, 2, 3
_EMPTY = 0xFFFFFFFF
_DELETED = 0xFFFFFFFE
_FLAG_EXISTS = 0x80000000


def _crypt_table() -> list[int]:
    table = [0] * 0x500
    seed = 0x00100001
    for index1 in range(0x100):
        index2 = index1
        for _ in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            temp1 = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            temp2 = seed & 0xFFFF
            table[index2] = temp1 | temp2
            index2 += 0x100
    return table


_CRYPT = _crypt_table()


def hash_string(name: str, hash_type: int) -> int:
    """MPQ name hash. ASCII upper-case, ``/`` counts as ``\\``."""
    seed1, seed2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in name.replace("/", "\\").upper().encode("latin-1", errors="replace"):
        seed1 = _CRYPT[hash_type * 0x100 + ch] ^ ((seed1 + seed2) & 0xFFFFFFFF)
        seed2 = (ch + seed1 + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
    return seed1


def decrypt(data: bytes, key: int) -> bytes:
    """Decrypt an MPQ table (little-endian dwords)."""
    n = len(data) // 4
    words = struct.unpack(f"<{n}I", data[: n * 4])
    out = []
    seed = 0xEEEEEEEE
    for w in words:
        seed = (seed + _CRYPT[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        ch = w ^ ((key + seed) & 0xFFFFFFFF)
        key = ((((~key) & 0xFFFFFFFF) << 21) + 0x11111111) & 0xFFFFFFFF | (key >> 11)
        seed = (ch + seed + (seed << 5) + 3) & 0xFFFFFFFF
        out.append(ch)
    return struct.pack(f"<{n}I", *out)


@dataclass
class Mpq:
    path: Path
    version: int
    archive_size: int
    hash_size: int
    block_size: int
    files: int  # block-table entries that carry the "exists" flag
    _hash: dict[tuple[int, int], list[int]]  # (name A, name B) -> [block index, ...]
    _blocks: list[tuple[int, int, int, int]] = None  # (offset, packed size, file size, flags) per block index

    def has(self, name: str) -> bool:
        """True if a file of this name is in the archive (any locale)."""
        key = (hash_string(name, _HASH_NAME_A), hash_string(name, _HASH_NAME_B))
        return any(b < _DELETED for b in self._hash.get(key, ()))

    def size_of(self, name: str):
        """``(packed size, file size)`` of the file, or None. No data is read."""
        key = (hash_string(name, _HASH_NAME_A), hash_string(name, _HASH_NAME_B))
        for b in self._hash.get(key, ()):
            if b < _DELETED and b < len(self._blocks):
                _off, packed, size, _flags = self._blocks[b]
                return packed, size
        return None

    def is_deleted(self, name: str) -> bool:
        """True if the archive holds a delete marker for the name (a patch removing a file)."""
        key = (hash_string(name, _HASH_NAME_A), hash_string(name, _HASH_NAME_B))
        return any(b == _DELETED for b in self._hash.get(key, ()))


def open_mpq(path: Path) -> Mpq:
    with open(path, "rb") as f:
        head = f.read(32)
        if len(head) < 32 or head[:4] != b"MPQ\x1a":
            raise ValueError(f"{path.name}: not an MPQ (no 'MPQ\\x1a' header at offset 0)")
        (_, hdr_size, arch_size, version, _shift, hpos, bpos, hcount, bcount) = struct.unpack("<4sIIHHIIII", head)
        f.seek(hpos)
        raw_hash = f.read(hcount * 16)
        f.seek(bpos)
        raw_block = f.read(bcount * 16)
    hash_tab = decrypt(raw_hash, hash_string("(hash table)", _HASH_FILE_KEY))
    block_tab = decrypt(raw_block, hash_string("(block table)", _HASH_FILE_KEY))
    table: dict[tuple[int, int], list[int]] = {}
    for i in range(hcount):
        a, b, _loc, _plat, blk = struct.unpack_from("<IIHHI", hash_tab, i * 16)
        if blk == _EMPTY:
            continue
        table.setdefault((a, b), []).append(blk)
    blocks = [struct.unpack_from("<IIII", block_tab, i * 16) for i in range(bcount)]
    files = sum(1 for b in blocks if b[3] & _FLAG_EXISTS)
    return Mpq(Path(path), version, arch_size, hcount, bcount, files, table, blocks)
