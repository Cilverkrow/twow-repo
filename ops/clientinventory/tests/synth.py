"""Synthetic fixtures: a minimal MPQ (format 1), a WDBC file and WDB records. No client data."""

import struct
from pathlib import Path

from clientinventory.mpqmini import _CRYPT, _HASH_FILE_KEY, _HASH_NAME_A, _HASH_NAME_B, _HASH_TABLE_OFFSET, hash_string


def encrypt(data: bytes, key: int) -> bytes:
    n = len(data) // 4
    words = struct.unpack(f"<{n}I", data)
    out = []
    seed = 0xEEEEEEEE
    for ch in words:
        seed = (seed + _CRYPT[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        w = ch ^ ((key + seed) & 0xFFFFFFFF)
        key = ((((~key) & 0xFFFFFFFF) << 21) + 0x11111111) & 0xFFFFFFFF | (key >> 11)
        seed = (ch + seed + (seed << 5) + 3) & 0xFFFFFFFF
        out.append(w)
    return struct.pack(f"<{n}I", *out)


def write_mpq(path: Path, files: dict[str, int], deleted=(), hash_size: int = 16) -> Path:
    """files: name -> file size (the data itself is not stored). ``deleted``: names with a delete marker."""
    hashes = [(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFF, 0xFFFF, 0xFFFFFFFF)] * hash_size
    blocks = []
    entries = [(n, len(blocks) + i) for i, n in enumerate(files)]
    for n, size in files.items():
        blocks.append((0, size, size, 0x80000000))
    entries += [(n, 0xFFFFFFFE) for n in deleted]
    for name, blk in entries:
        i = hash_string(name, _HASH_TABLE_OFFSET) & (hash_size - 1)
        while hashes[i][4] != 0xFFFFFFFF:
            i = (i + 1) & (hash_size - 1)
        hashes[i] = (hash_string(name, _HASH_NAME_A), hash_string(name, _HASH_NAME_B), 0, 0, blk)
    raw_hash = encrypt(b"".join(struct.pack("<IIHHI", *h) for h in hashes), hash_string("(hash table)", _HASH_FILE_KEY))
    raw_block = encrypt(b"".join(struct.pack("<IIII", *b) for b in blocks), hash_string("(block table)", _HASH_FILE_KEY))
    hpos = 32
    bpos = hpos + len(raw_hash)
    head = struct.pack("<4sIIHHIIII", b"MPQ\x1a", 32, bpos + len(raw_block), 0, 3, hpos, bpos, hash_size, len(blocks))
    Path(path).write_bytes(head + raw_hash + raw_block)
    return Path(path)


def write_wdbc(path: Path, rows: list[tuple], strings: bytes = b"\0") -> Path:
    fields = len(rows[0])
    body = b"".join(struct.pack(f"<{fields}I", *r) for r in rows)
    Path(path).write_bytes(struct.pack("<4sIIII", b"WDBC", len(rows), fields, fields * 4, len(strings)) + body + strings)
    return Path(path)


def wdb_file(records: list[tuple[int, bytes]], build: int = 5875) -> bytes:
    head = struct.pack("<4sI4sII", b"BDWI", build, b"BGne", 0, 0)
    body = b"".join(struct.pack("<II", e, len(p)) + p for e, p in records)
    return head + body + struct.pack("<II", 0, 0)
