"""Client WDB caches (1.12, build 5875): what a server once sent to this client.

Layout: ``magic(4) build(4) locale(4) unknown(4) unknown(4)`` followed by records
``entry(u32) size(u32) data[size]``; an entry of 0 ends the file. The client writes a
record when a server answers a query (quest, item, creature, game object), so an entry that
the current database does not know came from another server or from an older state of ours.
Only the fields needed to name and match the entry are decoded.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

HEADER = 20


@dataclass
class Header:
    magic: str
    build: int
    locale: str
    record_count_hint: int


def read_header(data: bytes) -> Header:
    magic, build, locale, hint, _ = struct.unpack_from("<4sI4sII", data)
    return Header(magic[::-1].decode("latin-1"), build, locale[::-1].decode("latin-1"), hint)


def records(data: bytes):
    """Yield ``(entry, payload)``. Stops at an entry of 0 or at damaged data."""
    pos = HEADER
    n = len(data)
    while pos + 8 <= n:
        entry, size = struct.unpack_from("<II", data, pos)
        pos += 8
        if entry == 0 or pos + size > n:
            return
        yield entry, data[pos : pos + size]
        pos += size


def cstrings(payload: bytes, start: int, count: int):
    """``count`` zero-terminated strings from ``start``; returns (list, next offset)."""
    out = []
    pos = start
    for _ in range(count):
        end = payload.find(b"\0", pos)
        if end < 0:
            return out, len(payload)
        out.append(payload[pos:end].decode("utf-8", errors="replace"))
        pos = end + 1
    return out, pos


def parse_creature(entry: int, p: bytes) -> dict:
    names, pos = cstrings(p, 0, 5)  # name x4, subname
    flags = ctype = family = rank = None
    if len(p) >= pos + 16:
        flags, ctype, family, rank = struct.unpack_from("<IIII", p, pos)
    return {"entry": entry, "name": names[0] if names else "", "subname": names[4] if len(names) > 4 else "",
            "type": ctype, "family": family, "rank": rank}


def parse_item(entry: int, p: bytes) -> dict:
    cls, sub = struct.unpack_from("<II", p, 0)
    names, pos = cstrings(p, 8, 4)
    disp = quality = None
    if len(p) >= pos + 8:
        disp, quality = struct.unpack_from("<II", p, pos)
    return {"entry": entry, "name": names[0] if names else "", "class": cls, "subclass": sub, "display": disp, "quality": quality}


def parse_gameobject(entry: int, p: bytes) -> dict:
    gtype, disp = struct.unpack_from("<II", p, 0)
    names, _ = cstrings(p, 8, 4)
    return {"entry": entry, "name": names[0] if names else "", "type": gtype, "display": disp}


def parse_quest(entry: int, p: bytes) -> dict:
    """Quest id, method, level and zone/sort come first; the title is the first text after the numbers."""
    qid, method, level = struct.unpack_from("<III", p, 0)
    zone = struct.unpack_from("<i", p, 12)[0]
    title = ""
    # The fixed numeric block is about 0x9C bytes; search for the first text run after the fourth field.
    i = 16
    while i < len(p) - 4:
        j = i
        while j < len(p) and 32 <= p[j] < 127:
            j += 1
        if j - i >= 3 and j < len(p) and p[j] == 0:
            title = p[i:j].decode("ascii")
            break
        i += 1
    return {"entry": entry, "quest": qid, "method": method, "level": level, "zone": zone, "title": title}


PARSERS = {
    "creaturecache": parse_creature, "itemcache": parse_item, "gameobjectcache": parse_gameobject, "questcache": parse_quest,
}


def load(path: Path):
    data = Path(path).read_bytes()
    hdr = read_header(data)
    parser = PARSERS.get(Path(path).stem)
    rows = []
    count = 0
    for entry, payload in records(data):
        count += 1
        if parser:
            try:
                rows.append(parser(entry, payload))
            except (struct.error, IndexError):
                rows.append({"entry": entry, "name": "", "title": ""})
    return hdr, count, rows
